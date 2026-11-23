import test from 'node:test';
import assert from 'node:assert/strict';
import {selectChartTarget} from '../src/connection.js';
test('Desktop shell and error pages are never selected as charts', () => {
  const shell={type:'page',url:'file:///TradingView/resources/app/window/index.html'};
  const error={type:'page',url:'file:///TradingView/resources/app/error-view/index.html'};
  assert.equal(selectChartTarget([shell,error]),null);
  const chart={type:'page',url:'https://www.tradingview.com/chart/abc/'};
  assert.equal(selectChartTarget([shell,error,chart]),chart);
});
