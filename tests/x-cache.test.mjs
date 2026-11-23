import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
const collector = new URL('../collectors/x-live.mjs', import.meta.url);

function collect(payload) {
  const dir = mkdtempSync(join(tmpdir(), 'x-cache-test-'));
  try {
    const cache = join(dir, 'cache.json');
    writeFileSync(cache, JSON.stringify(payload));
    const result = spawnSync(process.execPath, [collector.pathname.replace(/^\/(\w:)/, '$1'), 'bitcoin'], {
      encoding: 'utf8', windowsHide: true,
      env: { ...process.env, ANALYSIS_X_TOOLS_ROOT: dir, ANALYSIS_X_CACHE_PATH: cache,
        ANALYSIS_X_CACHE_MAX_AGE_MINUTES: '30', TWITTER_AUTH_TOKEN: '', TWITTER_CT0: '' },
    });
    return JSON.parse(result.stdout);
  } finally { rmSync(dir, { recursive: true, force: true }); }
}

test('fresh feed cache preserves degraded coverage and upstream failure', () => {
  const payload = { query: 'bitcoin', capturedAt: new Date().toISOString(), ready: true,
    provenance: 'twitter_cli_feed_fallback', degraded: true,
    searchDiagnostics: [{ code: 'not_found', reason: 'upstream_search_endpoint_404' }],
    items: [{ id: '1', text: 'bitcoin' }] };
  const result = collect(payload);
  assert.equal(result.provenance, 'fresh_cache');
  assert.equal(result.degraded, true);
  assert.equal(result.cacheSourceProvenance, payload.provenance);
  assert.deepEqual(result.searchDiagnostics, payload.searchDiagnostics);
});

test('empty or unsuccessful cached search cannot become ready', () => {
  const result = collect({ query: 'bitcoin', capturedAt: new Date().toISOString(),
    ready: false, items: [], reason: 'feed_fallback_no_match' });
  assert.equal(result.ready, false);
});

test('rewriting an old cache file does not refresh the source data age', () => {
  const result = collect({ query: 'bitcoin', capturedAt: new Date(Date.now() - 90 * 60000).toISOString(),
    ready: true, items: [{ id: 'old' }] });
  assert.equal(result.ready, false);
  assert.equal(result.reason, 'cache_stale');
  assert.ok(result.cacheAgeMinutes >= 89);
});
