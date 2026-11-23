import CDP from 'chrome-remote-interface';

let client = null;
let targetInfo = null;
const CDP_HOST = 'localhost';
const CDP_PORT = 9222;
const MAX_RETRIES = 5;
const BASE_DELAY = 500;
const CDP_COMMAND_TIMEOUT = 12000;

export async function withCdpTimeout(promise, { timeout = CDP_COMMAND_TIMEOUT, operation = 'command' } = {}) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(
          () => reject(new Error(`CDP ${operation} timed out after ${timeout}ms`)),
          timeout,
        );
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

// Known direct API paths discovered via live probing (see PROBE_RESULTS.md)
const KNOWN_PATHS = {
  chartApi: 'window.TradingViewApi._activeChartWidgetWV.value()',
  chartWidgetCollection: 'window.TradingViewApi._chartWidgetCollection',
  bottomWidgetBar: 'window.TradingView.bottomWidgetBar',
  replayApi: 'window.TradingViewApi._replayApi',
  alertService: 'window.TradingViewApi._alertService',
  chartApiInstance: 'window.ChartApiInstance',
  mainSeriesBars: 'window.TradingViewApi._activeChartWidgetWV.value()._chartWidget.model().mainSeries().bars()',
  // Phase 1: Strategy data — model().dataSources() → find strategy → .performance().value(), .ordersData(), .reportData()
  strategyStudy: 'chart._chartWidget.model().model().dataSources()',
  // Phase 2: Layouts — getSavedCharts(cb), loadChartFromServer(id)
  layoutManager: 'window.TradingViewApi.getSavedCharts',
  // Phase 5: Symbol search — searchSymbols(query) returns Promise
  symbolSearchApi: 'window.TradingViewApi.searchSymbols',
  // Phase 6: Pine scripts — REST API at pine-facade.tradingview.com/pine-facade/list/?filter=saved
  pineFacadeApi: 'https://pine-facade.tradingview.com/pine-facade',
};

export { KNOWN_PATHS };

/**
 * Sanitize a string for safe interpolation into JavaScript code evaluated via CDP.
 * Uses JSON.stringify to produce a properly escaped JS string literal (with quotes).
 * Prevents injection via quotes, backticks, template literals, or control chars.
 */
export function safeString(str) {
  return JSON.stringify(String(str));
}

/**
 * Validate that a value is a finite number. Throws if NaN, Infinity, or non-numeric.
 * Prevents corrupt values from reaching TradingView APIs that persist to cloud state.
 */
export function requireFinite(value, name) {
  const n = Number(value);
  if (!Number.isFinite(n)) throw new Error(`${name} must be a finite number, got: ${value}`);
  return n;
}

export async function getClient() {
  if (client) {
    try {
      // Quick liveness check
      await withCdpTimeout(
        client.Runtime.evaluate({ expression: '1', returnByValue: true }),
        { operation: 'liveness check' },
      );
      return client;
    } catch {
      try { await client.close(); } catch {}
      client = null;
      targetInfo = null;
    }
  }
  return connect();
}

export async function connect() {
  let lastError;
  for (let attempt = 0; attempt < MAX_RETRIES; attempt++) {
    try {
      const target = await findChartTarget();
      if (!target) {
        throw new Error('No TradingView chart target found. Is TradingView open with a chart?');
      }
      targetInfo = target;
      client = await CDP({ host: CDP_HOST, port: CDP_PORT, target: target.id });

      // Enable required domains
      await client.Runtime.enable();
      await client.Page.enable();
      await client.DOM.enable();

      return client;
    } catch (err) {
      lastError = err;
      const delay = Math.min(BASE_DELAY * Math.pow(2, attempt), 30000);
      await new Promise(r => setTimeout(r, delay));
    }
  }
  throw new Error(`CDP connection failed after ${MAX_RETRIES} attempts: ${lastError?.message}`);
}

export function selectChartTarget(targets) {
  return targets.find(t => t.type === 'page' && /^https:\/\/(?:[a-z]+\.)?tradingview\.com\/chart\//i.test(t.url)) || null;
}

async function findChartTarget() {
  const resp = await fetch(`http://${CDP_HOST}:${CDP_PORT}/json/list`);
  const targets = await resp.json();
  // Prefer targets with tradingview.com/chart in the URL
  const chart = selectChartTarget(targets);
  if (chart) return chart;
  // Recover only the failed chart renderer, never navigate Desktop's shell.
  const failed = targets.find(t => t.type === 'page' && /\/error-view\/index\.html/.test(t.url));
  if (!failed) return null;
  const recovery = await CDP({host: CDP_HOST, port: CDP_PORT, target: failed.id});
  try {
    await recovery.Page.navigate({url: 'https://www.tradingview.com/chart/'});
    for (let i = 0; i < 40; i++) {
      const r = await recovery.Runtime.evaluate({expression: '!!window.TradingViewApi?._activeChartWidgetWV?.value()', returnByValue: true});
      if (r.result?.value === true) return {...failed, url:'https://www.tradingview.com/chart/'};
      await new Promise(resolve => setTimeout(resolve, 500));
    }
    throw new Error('TradingView failed-chart navigation did not restore chart API');
  } finally { await recovery.close(); }
}

export async function getTargetInfo() {
  if (!targetInfo) {
    await getClient();
  }
  return targetInfo;
}

export async function evaluate(expression, opts = {}) {
  const c = await getClient();
  const { timeout = CDP_COMMAND_TIMEOUT, ...runtimeOptions } = opts;
  let result;
  try {
    result = await withCdpTimeout(c.Runtime.evaluate({
      expression,
      returnByValue: true,
      awaitPromise: runtimeOptions.awaitPromise ?? false,
      ...runtimeOptions,
    }), { timeout, operation: 'Runtime.evaluate' });
  } catch (error) {
    try { await c.close(); } catch {}
    client = null;
    targetInfo = null;
    throw error;
  }
  if (result.exceptionDetails) {
    const msg = result.exceptionDetails.exception?.description
      || result.exceptionDetails.text
      || 'Unknown evaluation error';
    throw new Error(`JS evaluation error: ${msg}`);
  }
  return result.result?.value;
}

export async function evaluateAsync(expression) {
  return evaluate(expression, { awaitPromise: true });
}

export async function reloadPage({ timeout = 15000 } = {}) {
  const c = await getClient();
  const loaded = new Promise((resolve) => c.Page.loadEventFired(resolve));
  await c.Page.reload({ ignoreCache: true });
  await Promise.race([
    loaded,
    new Promise((_, reject) => setTimeout(() => reject(new Error('TradingView page reload timeout')), timeout)),
  ]);

  const started = Date.now();
  while (Date.now() - started < timeout) {
    try {
      const ready = await evaluate(`document.readyState === 'complete' && !!(${KNOWN_PATHS.chartApi})`);
      if (ready) return true;
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new Error('TradingView chart API did not recover after page reload');
}

export async function disconnect() {
  if (client) {
    try { await client.close(); } catch {}
    client = null;
    targetInfo = null;
  }
}

// --- Direct API path helpers ---
// Each returns the STRING expression path after verifying it exists.
// Callers use the returned string in their own evaluate() calls.

async function verifyAndReturn(path, name) {
  const exists = await evaluate(`typeof (${path}) !== 'undefined' && (${path}) !== null`);
  if (!exists) {
    throw new Error(`${name} not available at ${path}`);
  }
  return path;
}

export async function getChartApi() {
  return verifyAndReturn(KNOWN_PATHS.chartApi, 'Chart API');
}

export async function getChartCollection() {
  return verifyAndReturn(KNOWN_PATHS.chartWidgetCollection, 'Chart Widget Collection');
}

export async function getBottomBar() {
  return verifyAndReturn(KNOWN_PATHS.bottomWidgetBar, 'Bottom Widget Bar');
}

export async function getReplayApi() {
  return verifyAndReturn(KNOWN_PATHS.replayApi, 'Replay API');
}

export async function getMainSeriesBars() {
  return verifyAndReturn(KNOWN_PATHS.mainSeriesBars, 'Main Series Bars');
}
