import test from "node:test";
import assert from "node:assert/strict";

import {
  buildScanRequest,
  buildScanRequests,
  parseScanResponse,
  resolveScannerTickers,
} from "../collectors/tradingview-screener-core.mjs";

test("exchange aliases preserve the requested symbol", () => {
  assert.deepEqual(resolveScannerTickers("GATEIO:EXAMPLEUSDT"), ["GATE:EXAMPLEUSDT"]);
  assert.deepEqual(resolveScannerTickers("OKX:SAMPLEUSDT"), ["OKX:SAMPLEUSDT", "OKX:SAMPLEUSDT.P"]);
  assert.deepEqual(resolveScannerTickers("BINANCE:BTCUSDT"), ["BINANCE:BTCUSDT"]);
});

test("one scan request contains every ticker and interval column", () => {
  const request = buildScanRequest(
    ["BINANCE:BTCUSDT", "GATEIO:EXAMPLEUSDT"],
    ["D", "W", "M", "3M"],
  );

  assert.deepEqual(request.body.symbols.tickers, [
    "BINANCE:BTCUSDT",
    "GATE:EXAMPLEUSDT",
  ]);
  assert.ok(request.body.columns.includes("RSI"));
  assert.ok(request.body.columns.includes("RSI|1W"));
  assert.ok(request.body.columns.includes("RSI|1M"));
  assert.ok(request.body.columns.includes("High.3M"));
  assert.equal(request.body.range[1], 2);
});

test("mixed crypto and US-stock symbols are routed to their own scanner markets", () => {
  const requests = buildScanRequests(
    ["BINANCE:BTCUSDT", "NASDAQ:DEMO", "NYSE:MOCK"],
    ["D", "W", "M", "3M"],
  );

  assert.deepEqual(requests.map(({ market }) => market), ["crypto", "america"]);
  assert.deepEqual(requests[0].symbols, ["BINANCE:BTCUSDT"]);
  assert.deepEqual(requests[1].symbols, ["NASDAQ:DEMO", "NYSE:MOCK"]);
  assert.deepEqual(requests[1].body.symbols.tickers, ["NASDAQ:DEMO", "NYSE:MOCK"]);
});

test("scanner response maps aliases back and reports missing symbols", () => {
  const request = buildScanRequest(
    ["GATEIO:EXAMPLEUSDT", "OKX:SAMPLEUSDT", "BINANCE:MISSINGUSDT"],
    ["D", "W", "M", "3M"],
  );
  const row = (symbol, start) => ({
    s: symbol,
    d: request.body.columns.map((_, index) => start + index),
  });
  const parsed = parseScanResponse(request, {
    totalCount: 2,
    data: [row("GATE:EXAMPLEUSDT", 10), row("OKX:SAMPLEUSDT.P", 100)],
  });

  assert.equal(parsed[0].symbol, "GATEIO:EXAMPLEUSDT");
  assert.equal(parsed[0].scannerSymbol, "GATE:EXAMPLEUSDT");
  assert.equal(parsed[0].periods.D.close, 11);
  assert.equal(parsed[0].periods.W.close, 22);
  assert.equal(parsed[0].periods["3M"].high, 44);
  assert.equal(parsed[1].symbol, "OKX:SAMPLEUSDT");
  assert.equal(parsed[1].scannerSymbol, "OKX:SAMPLEUSDT.P");
  assert.equal(parsed[2].error, "missing_scanner_result");
});

test("malformed rows fail only the affected symbol", () => {
  const request = buildScanRequest(["BINANCE:BTCUSDT"], ["D"]);
  const parsed = parseScanResponse(request, {
    totalCount: 1,
    data: [{ s: "BINANCE:BTCUSDT", d: ["BTCUSDT"] }],
  });

  assert.equal(parsed[0].symbol, "BINANCE:BTCUSDT");
  assert.equal(parsed[0].error, "incomplete_scanner_row");
});

