import test from 'node:test';
import assert from 'node:assert/strict';

import * as wait from '../src/wait.js';

test('chartStateMatches accepts a stable internal series for the requested symbol and timeframe', () => {
  assert.equal(typeof wait.chartStateMatches, 'function');
  assert.equal(wait.chartStateMatches({
    state: {
      apiSymbol: 'BINANCE:BTCUSDT',
      seriesSymbol: 'BTCUSDT',
      resolution: '1D',
      seriesResolution: 'D',
      barCount: 120,
      lastBarTime: 1792230000,
      barSpacing: 86400,
    },
    expectedSymbol: 'BINANCE:BTCUSDT',
    expectedTf: 'D',
  }), true);
});

test('chartStateMatches rejects a stale main series even when the chart API symbol changed', () => {
  assert.equal(typeof wait.chartStateMatches, 'function');
  assert.equal(wait.chartStateMatches({
    state: {
      apiSymbol: 'BINANCE:RSRUSDT',
      seriesSymbol: 'AMEX:EWY',
      resolution: 'M',
      seriesResolution: 'M',
      barCount: 120,
      lastBarTime: 1790861400,
    },
    expectedSymbol: 'BINANCE:RSRUSDT',
    expectedTf: 'M',
  }), false);
});

test('chartStateMatches rejects bars that still use the previous timeframe', () => {
  assert.equal(wait.chartStateMatches({
    state: {
      apiSymbol: 'BINANCE:BTCUSDT',
      seriesSymbol: 'BINANCE:BTCUSDT',
      resolution: 'D',
      seriesResolution: 'M',
      barCount: 120,
      lastBarTime: 1790861400,
    },
    expectedSymbol: 'BINANCE:BTCUSDT',
    expectedTf: 'D',
  }), false);
});

test('chartStateMatches rejects daily metadata backed by stale monthly bars', () => {
  assert.equal(wait.chartStateMatches({
    state: {
      apiSymbol: 'BINANCE:BTCUSDT',
      seriesSymbol: 'BINANCE:BTCUSDT',
      resolution: 'D',
      seriesResolution: 'D',
      barCount: 120,
      lastBarTime: 1790861400,
      barSpacing: 2592000,
    },
    expectedSymbol: 'BINANCE:BTCUSDT',
    expectedTf: 'D',
  }), false);
});
