import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const require = createRequire(import.meta.url);
const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const CDP = require(path.join(projectRoot, 'tradingview-mcp', 'node_modules', 'chrome-remote-interface'));

const PORT = Number(process.env.COINGLASS_CDP_PORT || 9225);
const requested = process.argv.slice(2).join(' ').trim();
const now = () => new Date().toISOString();
const CDP_TIMEOUT_MS = Number(process.env.COINGLASS_CDP_TIMEOUT_MS || 20000);
const NAVIGATION_ATTEMPTS = 2;
const SNAPSHOT_ATTEMPTS = 6;
const SNAPSHOT_INTERVAL_MS = 750;
const MAX_RENDERED_WAIT_MS = NAVIGATION_ATTEMPTS * SNAPSHOT_ATTEMPTS * SNAPSHOT_INTERVAL_MS;
const lthMvrvRoute = 'bitcoin-long-term-holder-mvrv';

const aliases = [
  { names: [lthMvrvRoute, 'long-term holder mvrv', 'lth-mvrv'], route: lthMvrvRoute, path: '/pro/onchain/' + lthMvrvRoute, label: 'Long-Term Holder MVRV' },
  { names: ['mvrv z-score', 'mvrv z score', 'mvrvz', 'mvrv z', 'bitcoin mvrv zscore', 'bitcoin-mvrv-z-score', 'bitcoin-mvrv-zscore'], route: 'bitcoin-mvrv-zscore', label: 'MVRV Z-score' },
  { names: ['mvrv ratio', 'mvrv-ratio', 'mvrv'], route: 'mvrv-ratio', label: 'MVRV Ratio' },
  { names: ['puell', 'puell multiple', 'bitcoin-puell-multiple', 'pm'], route: 'PM', label: 'Puell Multiple' },
  { names: ['ahr999', 'bitcoin-ahr999'], route: 'ahr999', label: 'AHR999' },
  { names: ['pi cycle', 'pi-cycle', 'pi cycle top', 'bitcoin-pi-cycle-top-indicator'], route: 'pi-cycle-top-prediction', label: 'Pi Cycle' },
  { names: ['200 week', '200wma', '200 wma', '200 week moving average', 'heatmap', 'bitcoin-200-week-moving-average-heatmap'], route: '200WMA', label: '200 Week Moving Average Heatmap' },
  { names: ['rainbow', 'rainbow chart', 'bitcoin-rainbow-chart'], route: 'bitcoin-rainbow-chart', label: 'Rainbow Chart' },
  { names: ['bitcoin treasuries', 'bitcoin treasury', 'bitcoin-treasuries', 'bitcoin-treasuries-index', 'institution holdings', 'institutional holdings', '机构持仓'], route: 'bitcoin-treasuries-index', path: '/BitcoinTreasuries', label: 'Bitcoin Treasuries' },
  { names: ['bitcoin-net-unrealized-profit-loss', 'nupl'], route: 'nupl', label: 'Bitcoin NUPL' },
  { names: ['bitcoin-reserve-risk', 'reserve risk'], route: 'reserve-risk', label: 'Bitcoin Reserve Risk' },
  { names: ['bitcoin-long-term-holder-supply', 'long term holder supply'], route: 'long-term-holder-supply', label: 'Long-term Holder Supply' },
];

if (process.argv.includes('--describe')) {
  const requestedAliases = [
    'bitcoin-net-unrealized-profit-loss',
    'bitcoin-reserve-risk',
    'bitcoin-long-term-holder-supply',
    lthMvrvRoute,
    'institution holdings',
  ];
  const routeAliases = Object.fromEntries(requestedAliases.map((name) => {
    const alias = aliases.find((item) => item.names.includes(name));
    return [name, alias?.path || alias?.route || null];
  }));
  console.log(JSON.stringify({
    cdpPort: PORT,
    networkPayloadFallback: true,
    maxRenderedWaitMs: MAX_RENDERED_WAIT_MS,
    routeAliases,
  }));
  process.exit(0);
}

const normalize = (value) => String(value ?? '')
  .toLowerCase()
  .replace(/https?:\/\/[^/]+/g, '')
  .replace(/^\/pro\/(?:i|onchain)\//, '')
  .replace(/[_/]+/g, ' ')
  .replace(/[-]+/g, ' ')
  .replace(/\s+/g, ' ')
  .trim();

function resolveStatic(value) {
  let input = String(value ?? '').trim();
  try {
    if (/^https?:\/\//i.test(input)) input = new URL(input).pathname;
  } catch {
    // Keep the original string and let discovery handle it.
  }
  const token = normalize(input);
  const exact = aliases.find((item) => item.names.some((name) => normalize(name) === token));
  if (exact) return { route: exact.route, path: exact.path, label: exact.label, method: 'alias' };
  const fuzzy = aliases.find((item) => item.names.some((name) => token.includes(normalize(name)) || normalize(name).includes(token)));
  if (fuzzy) return { route: fuzzy.route, path: fuzzy.path, label: fuzzy.label, method: 'alias_fuzzy' };
  if (/^[a-z0-9]+(?:-[a-z0-9]+)*$/i.test(input.replace(/^.*\//, ''))) {
    return { route: input.replace(/^.*\//, ''), label: input, method: 'direct' };
  }
  return null;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function failureReason(error) {
  const message = String(error?.message || '').toLowerCase();
  if (message.includes('auth') || message.includes('401') || message.includes('403')) return 'auth_failure';
  if (message.includes('timeout') || message.includes('timed out') || message.includes('econn') || message.includes('websocket')) {
    return 'network_timeout';
  }
  return 'browser_extraction_error';
}

async function withTimeout(promise, label) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(`${label} timed out`)), CDP_TIMEOUT_MS);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

function baseResult(extra = {}) {
  return {
    source: 'coinglass',
    requested,
    checkedAt: now(),
    ready: false,
    reason: 'unknown',
    ...extra,
  };
}

async function collectLthMvrv(resolved) {
  const url = 'https://www.coinglass.com' + resolved.path;
  try {
    const response = await fetch(url, { redirect: 'error', signal: AbortSignal.timeout(8000) });
    if (!response.ok) return baseResult({ ...resolved, url, reason: 'http_' + response.status });
    const html = await response.text();
    const serialized = html.match(/<script\b[^>]*\bid="__NEXT_DATA__"[^>]*>([\s\S]*?)<\/script>/)?.[1];
    const { metric, initial } = JSON.parse(serialized ?? '{}').props?.pageProps ?? {};
    const last = initial?.facts?.last;
    if (metric?.slug !== lthMvrvRoute || !metric.metricId || initial?.metricId !== metric.metricId) {
      return baseResult({ ...resolved, url, reason: 'metric_identity_mismatch' });
    }
    if (!Array.isArray(last) || !Number.isFinite(last[0]) || !Number.isFinite(last[1]) ||
        last[0] <= 0 || last[0] > Date.now() || last[1] <= 0) {
      return baseResult({ ...resolved, url, reason: 'metric_observation_missing' });
    }
    return baseResult({ ...resolved, url, ready: true, reason: 'ok', provenance: 'public_page',
      metricId: metric.metricId, dataDate: new Date(last[0]).toISOString().slice(0, 10), value: last[1],
      rows: initial.facts.points, last });
  } catch (error) {
    return baseResult({ ...resolved, url, reason: error.name === 'TimeoutError' ? 'network_timeout' : 'public_page_error' });
  }
}

async function listCoinGlassTarget() {
  const targets = await withTimeout(CDP.List({ port: PORT }), 'CoinGlass CDP target listing');
  const pages = targets.filter((item) => {
    if (item.type !== 'page') return false;
    try {
      return /(^|\.)coinglass\.com$/i.test(new URL(item.url).hostname);
    } catch {
      return false;
    }
  });
  pages.sort((a, b) => {
    const score = (item) => /coinglass\.com\/pro\/i\//i.test(item.url) ? 2 : 1;
    return score(b) - score(a);
  });
  return pages[0] ?? null;
}

async function evaluateJson(runtime, expression) {
  const value = await withTimeout(
    runtime.evaluate({ expression, returnByValue: true }),
    'CoinGlass runtime evaluation',
  );
  if (value?.exceptionDetails) {
    const detail = value.exceptionDetails.exception?.description
      || value.exceptionDetails.text
      || 'runtime expression failed';
    throw new Error(detail);
  }
  const raw = value?.result?.value;
  if (typeof raw !== 'string') throw new Error('runtime returned no JSON string');
  return JSON.parse(raw);
}

function largestSeries(value, depth = 0) {
  if (depth > 9 || value == null) return null;
  if (Array.isArray(value)) {
    const usable = value.length >= 2 && value.some((item) => item !== null && typeof item !== 'string');
    let best = usable ? value : null;
    for (const item of value.slice(0, 20)) {
      const nested = largestSeries(item, depth + 1);
      if (nested && (!best || nested.length > best.length)) best = nested;
    }
    return best;
  }
  if (typeof value === 'object') {
    let best = null;
    for (const nestedValue of Object.values(value)) {
      const nested = largestSeries(nestedValue, depth + 1);
      if (nested && (!best || nested.length > best.length)) best = nested;
    }
    return best;
  }
  return null;
}

const snapshotExpression = `(() => {
  const safe = (value) => {
    try { JSON.stringify(value); return value; } catch { return String(value); }
  };
  const chartNodes = [...document.querySelectorAll('[_echarts_instance_]')];
  const tableRows = [...document.querySelectorAll('table tbody tr, [role="row"]')]
    .map((row) => (row.innerText || '').replace(/\s+/g, ' ').trim())
    .filter(Boolean);
  const charts = chartNodes.map((dom) => {
    let option = null;
    try {
      const instance = window.echarts?.getInstanceByDom?.(dom);
      option = instance?.getOption?.() ?? null;
    } catch {}
    const series = Array.isArray(option?.series) ? option.series : [];
    const rows = series.reduce((sum, item) => sum + (Array.isArray(item?.data) ? item.data.length : 0), 0);
    const first = series.find((item) => Array.isArray(item?.data) && item.data.length)?.data?.[0] ?? null;
    const last = [...series].reverse().find((item) => Array.isArray(item?.data) && item.data.length)?.data?.at(-1) ?? null;
    return { series: series.length, rows, first: safe(first), last: safe(last) };
  });

  const candidates = [];
  for (const dom of chartNodes) {
    const fiberKey = Object.keys(dom).find((key) => key.startsWith('__reactFiber$') || key.startsWith('__reactInternalInstance$'));
    let fiber = fiberKey ? dom[fiberKey] : null;
    let depth = 0;
    while (fiber && depth++ < 220) {
      const state = fiber.stateNode?.state;
      if (state && typeof state === 'object') {
        for (const [key, value] of Object.entries(state)) {
          if (!Array.isArray(value) || value.length < 2) continue;
          if (/data|series|chart|dataset|list/i.test(key)) candidates.push({ key, rows: value.length, data: value });
        }
      }
      fiber = fiber.return;
    }
  }
  candidates.sort((a, b) => b.rows - a.rows);
  const seriesCandidate = candidates[0];
  const resources = [...new Set(performance.getEntriesByType('resource')
    .map((entry) => entry.name)
    .filter((name) => /capi\\.coinglass\\.com|\\/api\\//i.test(name)))].slice(-40);
  const bodyText = (document.body?.innerText || '').replace(/\\s+/g, ' ').trim();
  const bodySnippet = bodyText.slice(0, 900);
  const echartsRows = charts.reduce((sum, item) => sum + item.rows, 0);
  const rows = Math.max(echartsRows, seriesCandidate?.rows ?? 0);
  const tableReady = tableRows.length >= 2;
  const ready = rows > 0 || charts.some((item) => item.series > 0) || tableReady;
  let reason = 'chart_not_rendered';
  if (ready) reason = 'ok';
  else if (/404|not found|page not found|页面不存在/i.test(bodyText)) reason = 'route_not_found';
  else if (chartNodes.length > 0) reason = resources.length ? 'rendered_chart_has_no_series' : 'chart_has_no_api_resource';
  else if (resources.length > 0) reason = 'api_loaded_chart_not_rendered';
  return JSON.stringify({
    ready, reason, url: location.href, title: document.title,
    charts: chartNodes.length, canvases: document.querySelectorAll('canvas').length, tableRows: tableRows.length,
    echarts: charts, rows,
    first: safe(seriesCandidate?.data?.[0] ?? charts.find((item) => item.first !== null)?.first ?? tableRows[0] ?? null),
    last: safe(seriesCandidate?.data?.at(-1) ?? [...charts].reverse().find((item) => item.last !== null)?.last ?? tableRows.at(-1) ?? null),
    resources, bodySnippet, renderedAt: Date.now(),
  });
})()`;

if (process.argv.includes('--validate-expression')) {
  try {
    new Function(`return ${snapshotExpression};`);
    console.log(JSON.stringify({ valid: true }));
    process.exit(0);
  } catch (error) {
    console.log(JSON.stringify({ valid: false, error: String(error?.message || error) }));
    process.exit(2);
  }
}

async function discoverRoute(runtime) {
  const expression = `JSON.stringify([...document.querySelectorAll('a[href*="/pro/i/"]')].map((anchor) => ({ text: (anchor.innerText || anchor.getAttribute('aria-label') || '').trim(), href: anchor.href })).filter((item) => item.href).slice(0, 300))`;
  const links = await evaluateJson(runtime, expression);
  const token = normalize(requested);
  const match = links.find((item) => token && `${normalize(item.text)} ${normalize(item.href)}`.includes(token));
  if (!match) return null;
  const route = new URL(match.href).pathname.split('/').filter(Boolean).at(-1);
  return route ? { route, label: match.text || route, method: 'page_discovery', href: match.href } : null;
}

async function main() {
  if (!requested) return baseResult({ reason: 'missing_route', action: 'pass a CoinGlass route, URL, or chart name' });

  let resolved = resolveStatic(requested);
  if (resolved?.route === lthMvrvRoute) return collectLthMvrv(resolved);
  let target;
  try {
    target = await listCoinGlassTarget();
  } catch (error) {
    return baseResult({
      reason: failureReason(error),
      action: 'verify that the configured CoinGlass browser session is running',
    });
  }
  if (!target) return baseResult({ reason: 'browser_tab_not_found', action: 'open CoinGlass in the configured Edge session' });

  let client;
  try {
    client = await withTimeout(CDP({ target, port: PORT }), 'CoinGlass CDP connection');
    const { Page, Runtime, Network } = client;
    await withTimeout(Page.enable(), 'CoinGlass page enable');
    if (Network) {
      await withTimeout(Network.enable(), 'CoinGlass network enable');
      await withTimeout(Network.setCacheDisabled({ cacheDisabled: true }), 'CoinGlass cache disable');
    }
    let networkSnapshot = null;
    if (Network) {
      Network.responseReceived(async ({ requestId, response, type }) => {
        if (!['XHR', 'Fetch'].includes(type) || !/coinglass|capi\.coinglass\.com/i.test(response?.url || '')) return;
        try {
          const body = await Network.getResponseBody({ requestId });
          if (body.base64Encoded || !body.body || body.body.length > 8 * 1024 * 1024) return;
          const payload = JSON.parse(body.body);
          const series = largestSeries(payload);
          if (!series || series.length < 2) return;
          if (!networkSnapshot || series.length > networkSnapshot.rows) {
            networkSnapshot = {
              ready: true,
              reason: 'ok',
              extraction: 'network_api',
              rows: series.length,
              first: series[0],
              last: series.at(-1),
              apiUrl: response.url,
            };
          }
        } catch {}
      });
    }
    if (!resolved) {
      resolved = await discoverRoute(Runtime);
      if (!resolved) return baseResult({ reason: 'route_discovery_failed', currentUrl: target.url, action: 'use a visible CoinGlass chart name or inspect the current menu' });
    }
    const baseUrl = resolved.path
      ? `https://www.coinglass.com${resolved.path}`
      : `https://www.coinglass.com/pro/i/${resolved.route}`;
    let snapshot = null;
    for (let navigationAttempt = 1; navigationAttempt <= NAVIGATION_ATTEMPTS; navigationAttempt += 1) {
      const url = `${baseUrl}?fresh=${Date.now()}&attempt=${navigationAttempt}`;
      await withTimeout(Page.navigate({ url }), 'CoinGlass navigation');

      for (let pollAttempt = 1; pollAttempt <= SNAPSHOT_ATTEMPTS; pollAttempt += 1) {
        await sleep(SNAPSHOT_INTERVAL_MS);
        snapshot = await evaluateJson(Runtime, snapshotExpression);
        if (!snapshot.ready && networkSnapshot?.ready) {
          snapshot = { ...snapshot, ...networkSnapshot };
        }
        if (snapshot.ready || snapshot.reason === 'route_not_found') {
          return baseResult({
            ...resolved,
            ...snapshot,
            requested,
            url: snapshot?.url || url,
            attempts: { navigation: navigationAttempt, polls: pollAttempt },
          });
        }
      }
    }
    return baseResult({
      ...resolved,
      ...snapshot,
      requested,
      url: snapshot?.url || baseUrl,
      reason: snapshot?.reason || 'no_data',
      attempts: { navigation: NAVIGATION_ATTEMPTS, polls: SNAPSHOT_ATTEMPTS },
    });
  } catch (error) {
    return baseResult({
      ...resolved,
      reason: failureReason(error),
      detail: String(error?.message || 'unknown browser extraction error').slice(0, 240),
      action: 'check CoinGlass connectivity and the configured browser session, then retry',
    });
  } finally {
    if (client) await client.close().catch(() => {});
  }
}

const result = await main();
console.log(JSON.stringify(result));
process.exitCode = result.ready ? 0 : 2;
