import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { existsSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { filterTimelineItems, normalizeTwitterPayload } from './x-normalize.mjs';

const execFileAsync = promisify(execFile);
const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const toolsRoot = resolve(process.env.ANALYSIS_X_TOOLS_ROOT || resolve(projectRoot, '.tools', 'x-runtime'));
const query = process.argv.slice(2).join(' ').trim() || 'bitcoin';
const checkedAt = new Date().toISOString();
const cachePath = process.env.ANALYSIS_X_CACHE_PATH || '';
const cacheMaxAgeMinutes = Number(process.env.ANALYSIS_X_CACHE_MAX_AGE_MINUTES || 30);
const timeoutMs = Number(process.env.ANALYSIS_X_TIMEOUT_MS || 20000);
const searchTimeoutMs = Number(process.env.ANALYSIS_X_SEARCH_TIMEOUT_MS || Math.min(timeoutMs, 5000));
const searchAdapter = fileURLToPath(new URL('./x-search.py', import.meta.url));

function result(extra = {}) {
  return { source: 'x', checkedAt, query, ready: false, reason: 'unknown', items: [], ...extra };
}

function emit(value, exitCode = 0) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
  process.exitCode = exitCode;
}

function readCache() {
  if (!cachePath || !existsSync(cachePath)) return null;
  let ageMinutes = (Date.now() - statSync(cachePath).mtimeMs) / 60000;
  let payload;
  try {
    payload = JSON.parse(readFileSync(cachePath, 'utf8').replace(/^\uFEFF/, ''));
  } catch {
    return result({ reason: 'cache_invalid', cacheAgeMinutes: Number(ageMinutes.toFixed(2)) });
  }
  if (typeof payload.query !== 'string' || payload.query.trim().toLocaleLowerCase() !== query.toLocaleLowerCase()) {
    return null;
  }
  // File writes do not make old observations current. Keep the original
  // observation timestamp, degradation, and failure evidence across reuse.
  const capturedAt = payload.capturedAt || payload.checkedAt;
  const capturedMs = Date.parse(capturedAt);
  if (!Number.isFinite(capturedMs) || capturedMs > Date.now() + 60000) {
    return result({ reason: 'cache_invalid_timestamp' });
  }
  ageMinutes = Math.max(ageMinutes, 0, (Date.now() - capturedMs) / 60000);
  if (ageMinutes > cacheMaxAgeMinutes) {
    return result({ reason: 'cache_stale', cacheAgeMinutes: Number(ageMinutes.toFixed(2)), cacheMaxAgeMinutes });
  }
  const items = Array.isArray(payload.items) ? payload.items.slice(0, 10) : [];
  if (payload.ready === false || items.length === 0) {
    return result({ reason: 'cache_incomplete', searchDiagnostics: payload.searchDiagnostics || [],
      degraded: Boolean(payload.degraded), cacheAgeMinutes: Number(ageMinutes.toFixed(2)) });
  }
  return result({
    ready: true,
    reason: 'ok',
    provenance: 'fresh_cache',
    capturedAt,
    degraded: Boolean(payload.degraded),
    cacheSourceProvenance: payload.cacheSourceProvenance || payload.provenance || 'unknown',
    searchDiagnostics: payload.searchDiagnostics || [],
    cacheAgeMinutes: Number(ageMinutes.toFixed(2)),
    items,
  });
}

async function findCommand(name) {
  const executableName = process.platform === 'win32' ? `${name}.exe` : name;
  const localCandidates = process.platform === 'win32'
    ? [resolve(toolsRoot, 'Scripts', executableName), resolve(toolsRoot, executableName)]
    : [resolve(toolsRoot, 'bin', executableName), resolve(toolsRoot, executableName)];
  for (const candidate of localCandidates) {
    if (existsSync(candidate)) return candidate;
  }
  try {
    const { stdout } = await execFileAsync('where.exe', [name], { windowsHide: true, timeout: 3000 });
    return stdout.split(/\r?\n/).map((line) => line.trim()).find(Boolean) || null;
  } catch {
    return null;
  }
}

async function run() {
  if (process.argv.includes('--describe')) {
    const [resolvedAgentReach, resolvedTwitter, resolvedOpencli] = await Promise.all([
      findCommand('agent-reach'),
      findCommand('twitter'),
      findCommand('opencli'),
    ]);
    emit({
      projectRoot,
      toolsRoot,
      resolvedAgentReach,
      resolvedTwitter,
      resolvedOpencli,
      cacheMaxAgeMinutes,
      searchTimeoutMs,
      cachePathConfigured: Boolean(cachePath),
      requiresExplicitCredentials: true,
      maxItems: 10,
    });
    return;
  }

  const cached = readCache();
  if (cached?.ready) {
    emit(cached);
    return;
  }

  const twitter = await findCommand('twitter');
  const opencli = await findCommand('opencli');
  if (!twitter && !opencli) {
    emit(cached || result({
      reason: 'collector_unavailable',
      action: 'run scripts/setup-x.ps1 to install the project-local twitter-cli, or configure OpenCLI',
    }), 2);
    return;
  }

  if (twitter && (!process.env.TWITTER_AUTH_TOKEN || !process.env.TWITTER_CT0)) {
    emit(cached || result({ reason: 'auth_not_configured', action: 'run scripts/configure-x-auth.ps1, or provide TWITTER_AUTH_TOKEN and TWITTER_CT0 explicitly' }), 2);
    return;
  }

  const commandOptions = (timeout) => ({ windowsHide: true, timeout, maxBuffer: 2 * 1024 * 1024 });
  let parsed = null;
  let provenance = null;
  const searchDiagnostics = [];
  if (twitter) {
    const python = resolve(dirname(twitter), process.platform === 'win32' ? 'python.exe' : 'python');
    const searchCommands = [
      ...(existsSync(python) && existsSync(searchAdapter)
        ? [{ command: python, args: [searchAdapter, query], source: 'x_authenticated_search', timeout: timeoutMs }]
        : []),
      { command: twitter, args: ['search', '--type', 'Latest', '-n', '10', '--json', '--', query], source: 'twitter_cli_search', timeout: searchTimeoutMs },
    ];
    for (const { command, args, source, timeout } of searchCommands) {
      try {
        const { stdout } = await execFileAsync(command, args, commandOptions(timeout));
        parsed = JSON.parse(stdout);
        provenance = source;
        break;
      } catch (error) {
        let payload;
        try { payload = JSON.parse(error.stdout || '{}'); } catch {}
        const code = payload?.error?.code || (error.killed ? 'timeout' : 'search_failed');
        searchDiagnostics.push({source, code,
          reason: code === 'not_found' ? 'upstream_search_endpoint_404' : code});
      }
    }
  }

  if (!parsed && opencli) {
    try {
      const { stdout } = await execFileAsync(opencli, ['twitter', 'search', query, '-f', 'json'], commandOptions(timeoutMs));
      parsed = JSON.parse(stdout);
      provenance = 'opencli_search';
    } catch { }
  }

  let items = parsed ? normalizeTwitterPayload(parsed, 10) : [];
  let degraded = false;
  if (!items.length && twitter) {
    try {
      const { stdout } = await execFileAsync(twitter, ['feed', '-n', '50', '--json'], commandOptions(timeoutMs));
      const feedItems = normalizeTwitterPayload(JSON.parse(stdout), 50);
      items = filterTimelineItems(feedItems, query, 10);
      provenance = 'twitter_cli_feed_fallback';
      degraded = true;
    } catch { }
  }

  if (!items.length) {
    emit(result({
      cacheStatus: cached?.reason || null,
      searchDiagnostics,
      reason: degraded ? 'feed_fallback_no_match' : 'live_collection_failed',
      provenance,
      degraded,
      action: degraded ? 'no matching items were present in the current X timeline' : 'configure OpenCLI for browser-backed X search',
    }), 2);
    return;
  }

  const live = result({ ready: true, reason: 'ok', provenance, degraded, searchDiagnostics, capturedAt: checkedAt, items });
  if (cachePath) {
    try { writeFileSync(cachePath, JSON.stringify(live), { encoding: 'utf8', mode: 0o600 }); } catch {}
  }
  emit(live);
}

run().catch(() => emit(result({ reason: 'unexpected_collector_failure' }), 2));
