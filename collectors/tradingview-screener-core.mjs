const PERIOD_SUFFIX = Object.freeze({ D: "", W: "|1W", M: "|1M" });
const INDICATOR_FIELDS = Object.freeze([
  ["close", "close"],
  ["change", "changePct"],
  ["volume", "volume"],
  ["Recommend.All", "recommendation"],
  ["RSI", "rsi"],
  ["MACD.macd", "macd"],
  ["MACD.signal", "macdSignal"],
  ["EMA20", "ema20"],
  ["EMA50", "ema50"],
  ["EMA200", "ema200"],
  ["ATR", "atr"],
]);
const SUPPORTED_TIMEFRAMES = new Set(["D", "W", "M", "3M"]);
const AMERICA_EXCHANGES = new Set(["NASDAQ", "NYSE", "AMEX"]);

function unique(values) {
  return [...new Set(values)];
}

export function resolveScannerTickers(symbol) {
  const requested = String(symbol || "").trim().toUpperCase();
  if (!requested.includes(":")) throw new Error(`TradingView-qualified symbol required: ${symbol}`);
  const [exchange, ticker] = requested.split(":", 2);
  if (!ticker) throw new Error(`Invalid TradingView symbol: ${symbol}`);
  if (exchange === "GATEIO") return [`GATE:${ticker}`];
  if (exchange === "OKX" && !ticker.endsWith(".P")) return [`OKX:${ticker}`, `OKX:${ticker}.P`];
  return [requested];
}

function resolveScannerMarket(symbol) {
  const exchange = String(symbol || "").trim().toUpperCase().split(":", 1)[0];
  return AMERICA_EXCHANGES.has(exchange) ? "america" : "crypto";
}

function buildColumns(timeframes) {
  const columns = ["name"];
  for (const timeframe of timeframes) {
    if (timeframe === "3M") continue;
    const suffix = PERIOD_SUFFIX[timeframe];
    for (const [field] of INDICATOR_FIELDS) columns.push(`${field}${suffix}`);
  }
  if (timeframes.includes("3M")) columns.push("High.3M", "Low.3M", "Perf.3M");
  columns.push("update_mode", "exchange", "description", "pricescale", "minmov");
  return columns;
}

export function buildScanRequest(symbols, timeframes = ["D", "W", "M", "3M"]) {
  const requestedSymbols = unique(symbols.map((value) => String(value).trim().toUpperCase()).filter(Boolean));
  const requestedTimeframes = unique(timeframes.map((value) => String(value).trim().toUpperCase()).filter(Boolean));
  for (const timeframe of requestedTimeframes) {
    if (!SUPPORTED_TIMEFRAMES.has(timeframe)) throw new Error(`Unsupported timeframe: ${timeframe}`);
  }
  const aliases = requestedSymbols.map((symbol) => ({ symbol, scannerTickers: resolveScannerTickers(symbol) }));
  const tickers = unique(aliases.flatMap((entry) => entry.scannerTickers));
  const columns = buildColumns(requestedTimeframes);
  const markets = unique(requestedSymbols.map(resolveScannerMarket));
  if (markets.length > 1) throw new Error("A scan request cannot mix scanner markets; use buildScanRequests().");
  return {
    market: markets[0] || "crypto",
    symbols: requestedSymbols,
    timeframes: requestedTimeframes,
    aliases,
    body: {
      symbols: { tickers, query: { types: [] } },
      columns,
      range: [0, tickers.length],
    },
  };
}

export function buildScanRequests(symbols, timeframes = ["D", "W", "M", "3M"]) {
  const groups = new Map();
  for (const symbol of symbols) {
    const normalized = String(symbol || "").trim().toUpperCase();
    if (!normalized) continue;
    const market = resolveScannerMarket(normalized);
    if (!groups.has(market)) groups.set(market, []);
    groups.get(market).push(normalized);
  }
  return [...groups.values()].map((group) => buildScanRequest(group, timeframes));
}

function valueMap(columns, values) {
  return Object.fromEntries(columns.map((column, index) => [column, values[index]]));
}

function periodFromValues(values, timeframe) {
  if (timeframe === "3M") {
    const ok = values["High.3M"] != null && values["Low.3M"] != null;
    return {
      ok,
      high: values["High.3M"],
      low: values["Low.3M"],
      changePct: values["Perf.3M"],
      ...(ok ? {} : { error: "missing_scanner_timeframe_data" }),
    };
  }
  const suffix = PERIOD_SUFFIX[timeframe];
  const period = { ok: values[`close${suffix}`] != null };
  for (const [field, outputName] of INDICATOR_FIELDS) period[outputName] = values[`${field}${suffix}`];
  if (!period.ok) period.error = "missing_scanner_timeframe_data";
  return period;
}

export function parseScanResponse(request, response) {
  const rows = Array.isArray(response?.data) ? response.data : [];
  const byTicker = new Map(rows.map((row) => [String(row?.s || "").toUpperCase(), row]));
  return request.aliases.map(({ symbol, scannerTickers }) => {
    const scannerSymbol = scannerTickers.find((candidate) => byTicker.has(candidate));
    if (!scannerSymbol) return { symbol, error: "missing_scanner_result" };
    const row = byTicker.get(scannerSymbol);
    if (!Array.isArray(row?.d) || row.d.length < request.body.columns.length) {
      return { symbol, scannerSymbol, error: "incomplete_scanner_row" };
    }
    const values = valueMap(request.body.columns, row.d);
    const periods = {};
    for (const timeframe of request.timeframes) periods[timeframe] = periodFromValues(values, timeframe);
    return {
      symbol,
      scannerSymbol,
      name: values.name,
      description: values.description,
      exchange: values.exchange,
      updateMode: values.update_mode,
      priceScale: values.pricescale,
      minMove: values.minmov,
      periods,
    };
  });
}
