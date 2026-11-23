import test from 'node:test';
import assert from 'node:assert/strict';

import * as chart from '../src/core/chart.js';
import * as data from '../src/core/data.js';

test('dismissBlockingPromotions exposes a reusable TradingView modal guard', async () => {
  assert.equal(typeof chart.dismissBlockingPromotions, 'function');

  let expression = '';
  const result = await chart.dismissBlockingPromotions({
    _deps: {
      evaluate: async (value) => {
        expression = value;
        return { detected: 1, dismissed: 1 };
      },
    },
  });

  assert.deepEqual(result, { detected: 1, dismissed: 1 });
  assert.match(expression, /Analyze markets in TradingView Desktop/);
  assert.match(expression, /Upgrade your plan/);
  assert.match(expression, /关闭广告/);
  assert.doesNotMatch(expression, /root\.remove\(\)/);
  assert.match(expression, /root\.style\.display = 'none'/);
  assert.match(expression, /KeyboardEvent\('keydown'/);
});

test('dismissBlockingPromotions installs a persistent observer for asynchronously injected promotions', async () => {
  let expression = '';
  await chart.dismissBlockingPromotions({
    _deps: {
      evaluate: async (value) => {
        expression = value;
        return { detected: 0, dismissed: 0, removed: 0, observerInstalled: true };
      },
    },
  });

  assert.match(expression, /MutationObserver/);
  assert.match(expression, /__tvPromotionGuardObserver/);
  assert.match(expression, /observerInstalled/);
});

test('dismissBlockingPromotions treats fixed-position dialogs as visible', async () => {
  const calls = [];
  const deps = {
    evaluate: async (expression) => {
      calls.push(expression);
      return { detected: 0, dismissed: 0, removed: 0, observerInstalled: true };
    },
  };

  await chart.dismissBlockingPromotions({ _deps: deps });

  assert.match(calls[0], /getClientRects\(\)\.length/);
  assert.doesNotMatch(calls[0], /offsetParent !== null/);
});

test('dismissBlockingPromotions always sends Escape for a detected promotion', async () => {
  let expression = '';
  await chart.dismissBlockingPromotions({
    _deps: {
      evaluate: async (value) => {
        expression = value;
        return { detected: 1, dismissed: 1, removed: 0, observerInstalled: true };
      },
    },
  });

  assert.match(expression, /if \(detected > 0\)[\s\S]*KeyboardEvent\('keydown'/);
});

test('dismissBlockingPromotions releases the page scroll lock only after no visible dialog remains', async () => {
  let expression = '';
  await chart.dismissBlockingPromotions({
    _deps: {
      evaluate: async (value) => {
        expression = value;
        return { detected: 1, dismissed: 0, removed: 1, observerInstalled: true };
      },
    },
  });

  assert.match(expression, /visibleDialogs\.length === 0/);
  assert.match(expression, /document\.body\.classList\.remove\('i-no-scroll'\)/);
});

test('dismissBlockingPromotions does not treat dialog launcher buttons as open dialogs', async () => {
  let expression = '';
  await chart.dismissBlockingPromotions({
    _deps: {
      evaluate: async (value) => {
        expression = value;
        return { detected: 1, dismissed: 0, removed: 1, observerInstalled: true };
      },
    },
  });

  assert.match(expression, /var visibleDialogs = roots\.filter\(function\(el\)/);
  assert.match(expression, /el\.tagName !== 'BUTTON'/);
});

test('setSymbol rejects a chart that never becomes ready after modal cleanup', async () => {
  assert.equal(typeof chart.dismissBlockingPromotions, 'function');

  const calls = [];
  await assert.rejects(
    chart.setSymbol({
      symbol: 'BINANCE:RSRUSDT',
      _deps: {
        evaluate: async () => {
          calls.push('dismiss');
          return { detected: 1, dismissed: 1 };
        },
        evaluateAsync: async () => calls.push('setSymbol'),
        waitForChartReady: async () => false,
        reloadPage: async () => calls.push('reload'),
      },
    }),
    /chart readiness timeout.*BINANCE:RSRUSDT/i,
  );
  assert.deepEqual(calls, ['dismiss', 'setSymbol', 'reload', 'dismiss', 'setSymbol']);
});

test('setSymbol reloads once and reselects the symbol when the chart is desynchronized', async () => {
  const calls = [];
  let readinessChecks = 0;

  const result = await chart.setSymbol({
    symbol: 'BINANCE:RVNUSDT',
    _deps: {
      evaluate: async () => {
        calls.push('dismiss');
        return { detected: 0, dismissed: 0, removed: 0, observerInstalled: true };
      },
      evaluateAsync: async () => calls.push('setSymbol'),
      waitForChartReady: async () => {
        readinessChecks += 1;
        calls.push(`ready:${readinessChecks}`);
        return readinessChecks === 2;
      },
      reloadPage: async () => calls.push('reload'),
    },
  });

  assert.equal(result.recovered, true);
  assert.deepEqual(calls, [
    'dismiss', 'setSymbol', 'ready:1',
    'reload', 'dismiss', 'setSymbol', 'ready:2',
  ]);
});

test('setTimeframe reloads once and reapplies the timeframe when the chart renderer stalls', async () => {
  const calls = [];
  let readinessChecks = 0;

  const result = await chart.setTimeframe({
    timeframe: 'D',
    _deps: {
      evaluate: async (expression) => {
        calls.push(expression.includes('setResolution') ? 'setTimeframe' : 'dismiss');
        return { detected: 0, dismissed: 0, removed: 0, observerInstalled: true };
      },
      waitForChartReady: async () => {
        readinessChecks += 1;
        calls.push(`ready:${readinessChecks}`);
        return readinessChecks === 2;
      },
      reloadPage: async () => calls.push('reload'),
    },
  });

  assert.equal(result.recovered, true);
  assert.deepEqual(calls, [
    'dismiss', 'setTimeframe', 'ready:1',
    'reload', 'dismiss', 'setTimeframe', 'ready:2',
  ]);
});

test('assertOhlcvIdentity rejects stale bars from a previous TradingView symbol', () => {
  assert.equal(typeof data.assertOhlcvIdentity, 'function');

  assert.throws(
    () => data.assertOhlcvIdentity({
      expectedSymbol: 'BINANCE:RSRUSDT',
      apiSymbol: 'BINANCE:RSRUSDT',
      seriesSymbol: 'AMEX:EWY',
    }),
    /OHLCV symbol mismatch.*AMEX:EWY.*BINANCE:RSRUSDT/i,
  );
});

test('assertOhlcvIdentity accepts exchange-qualified aliases for the same ticker', () => {
  assert.equal(typeof data.assertOhlcvIdentity, 'function');

  assert.doesNotThrow(() => data.assertOhlcvIdentity({
    expectedSymbol: 'BINANCE:BTCUSDT',
    apiSymbol: 'BTCUSDT',
    seriesSymbol: 'BINANCE:BTCUSDT',
  }));
});
