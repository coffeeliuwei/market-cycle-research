import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { existsSync } from "node:fs";
import path from "node:path";

const curlCandidates = [
  process.env.ANALYSIS_CURL_PATH,
  path.join(process.env.SystemRoot || "C:\\Windows", "System32", "curl.exe"),
].filter(Boolean);
const CURL_EXECUTABLE = curlCandidates.find((candidate) => existsSync(candidate));
if (!CURL_EXECUTABLE) throw new Error("curl.exe was not found. Set ANALYSIS_CURL_PATH.");

const execFileAsync = promisify(execFile);
const MARKET_DATA_PROXY =
  process.env.MARKET_DATA_PROXY ||
  process.env.HTTPS_PROXY ||
  "http://127.0.0.1:7897";
const REQUEST_TIMEOUT_MS = 6500;
const MAX_ATTEMPTS = 3;
const RETRY_DELAY_MS = 500;
const MAX_MARKETS = 10;
if (process.argv.includes("--describe")) {
  console.log(JSON.stringify({ curlExecutable: CURL_EXECUTABLE, maxAttempts: MAX_ATTEMPTS, maxMarkets: MAX_MARKETS }, null, 2));
  process.exit(0);
}
const keywords = process.argv.slice(2).join(" ").trim().toLowerCase();
const terms = keywords ? keywords.split(/\s+/).filter(Boolean) : ["bitcoin", "btc"];
const checkedAt = new Date().toISOString();
const nowMs = Date.now();

const endpoints = [
  {
    name: "gamma_public_search",
    url: `https://gamma-api.polymarket.com/public-search?q=${encodeURIComponent(keywords || "bitcoin")}&limit_per_type=50&events_status=active`,
    items: (payload) => (Array.isArray(payload?.events) ? payload.events : [])
      .flatMap((event) => (event.markets || []).map((market) => ({
        ...market,
        _eventTitle: event.title || event.question || null,
      }))),
  },
  {
    name: "gamma_markets",
    url: "https://gamma-api.polymarket.com/markets?active=true&closed=false&limit=100&order=volume24hr&ascending=false",
    items: (payload) => Array.isArray(payload) ? payload : [],
  },
  {
    name: "gamma_events",
    url: "https://gamma-api.polymarket.com/events?active=true&closed=false&limit=100&order=volume24hr&ascending=false",
    items: (payload) => (Array.isArray(payload) ? payload : []).flatMap((event) => event.markets || []),
  },
  {
    name: "clob_markets",
    url: "https://clob.polymarket.com/markets",
    items: (payload) => Array.isArray(payload?.data) ? payload.data : (Array.isArray(payload) ? payload : []),
  },
];

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function errorCode(error) {
  if (error?.name === "AbortError" || error?.code === "timeout") return "network_timeout";
  if (error?.status === 401 || error?.status === 403) return "auth_failure";
  return "network_error";
}

async function fetchJsonOnce(url) {
  try {
    const { stdout } = await execFileAsync(
      CURL_EXECUTABLE,
      [
        "--fail",
        "--silent",
        "--show-error",
        "--location",
        "--max-time",
        String(Math.ceil(REQUEST_TIMEOUT_MS / 1000)),
        "--proxy",
        MARKET_DATA_PROXY,
        "--header",
        "accept: application/json",
        "--header",
        "user-agent: local-market-data-workflow/1.0",
        url,
      ],
      { windowsHide: true, maxBuffer: 16 * 1024 * 1024 },
    );
    return JSON.parse(stdout);
  } catch (error) {
    const text = `${error?.stderr || ""} ${error?.message || ""}`.toLowerCase();
    if (text.includes("timed out") || text.includes("curl: (28)")) {
      const timeout = new Error("request timeout");
      timeout.code = "timeout";
      throw timeout;
    }
    const status = text.match(/\b(401|403)\b/);
    if (status) {
      const responseError = new Error(`HTTP ${status[1]}`);
      responseError.status = Number(status[1]);
      throw responseError;
    }
    throw error;
  }
}

async function fetchJsonWithRetry(endpoint) {
  let lastError;
  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt += 1) {
    try {
      return { payload: await fetchJsonOnce(endpoint.url), attempts: attempt };
    } catch (error) {
      lastError = error;
      if (attempt < MAX_ATTEMPTS) await sleep(RETRY_DELAY_MS * attempt);
    }
  }
  return { error: lastError, attempts: MAX_ATTEMPTS };
}

function simplify(market) {
  const parseArray = (value) => {
    if (Array.isArray(value)) return value;
    if (typeof value !== "string") return [];
    try {
      const parsed = JSON.parse(value);
      return Array.isArray(parsed) ? parsed : [];
    } catch {
      return [];
    }
  };
  const outcomes = parseArray(market.outcomes);
  const prices = parseArray(market.outcomePrices).map((value) => Number(value));
  const probabilities = Object.fromEntries(outcomes.map((outcome, index) => [
    outcome,
    Number.isFinite(prices[index]) ? prices[index] : null,
  ]));
  return {
    id: market.id || market.condition_id || market.conditionId || null,
    question: market.question || market.title || null,
    slug: market.slug || null,
    outcomes,
    outcomePrices: prices,
    probabilities,
    volume: market.volume || market.volumeNum || null,
    liquidity: market.liquidity || market.liquidityNum || null,
    endDate: market.endDate || market.end_date_iso || null,
  };
}

function matchesTerms(market) {
  const searchable = [
    market.question,
    market.title,
    market.slug,
    market._eventTitle,
    Array.isArray(market.tags) ? market.tags.join(" ") : "",
  ].join(" ").toLowerCase();
  // Bitcoin and BTC are aliases, not an AND query. Requiring both caused
  // valid markets to disappear whenever only one spelling was present.
  if (!keywords) return terms.some((term) => searchable.includes(term));
  return terms.every((term) => searchable.includes(term));
}

function isLiveMarket(market) {
  if (market.active === false || market.closed === true || market.archived === true) return false;
  if (market.acceptingOrders === false) return false;
  const end = market.endDate || market.end_date_iso;
  if (end) {
    const endMs = Date.parse(end);
    if (Number.isFinite(endMs) && endMs <= nowMs) return false;
  }
  return true;
}

function dedupe(markets) {
  const seen = new Set();
  return markets.filter((market) => {
    const key = market.id || market.condition_id || market.conditionId || market.slug || market.question;
    if (!key || seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

async function main() {
  const responses = await Promise.all(endpoints.map(async (endpoint) => ({
    endpoint,
    result: await fetchJsonWithRetry(endpoint),
  })));

  const successful = responses.filter(({ result }) => !result.error);
  const failures = responses
    .filter(({ result }) => result.error)
    .map(({ endpoint, result }) => ({
      endpoint: endpoint.name,
      code: errorCode(result.error),
      attempts: result.attempts,
    }));

  if (successful.length === 0) {
    const codes = failures.map((failure) => failure.code);
    const reason = codes.every((code) => code === "network_timeout")
      ? "network_timeout"
      : codes.some((code) => code === "auth_failure")
        ? "auth_failure"
        : "network_error";
    process.stdout.write(JSON.stringify({
      source: "polymarket",
      checkedAt,
      ready: false,
      reason,
      errors: failures,
      markets: [],
    }, null, 2) + "\n");
    process.exitCode = 2;
    return;
  }

  const markets = dedupe(successful.flatMap(({ endpoint, result }) => endpoint.items(result.payload)));
  const matched = markets
    .filter(isLiveMarket)
    .filter(matchesTerms)
    .sort((a, b) => Number(b.volume || b.volumeNum || 0) - Number(a.volume || a.volumeNum || 0))
    .slice(0, MAX_MARKETS)
    .map(simplify);
  process.stdout.write(JSON.stringify({
    source: "polymarket",
    checkedAt,
    ready: true,
    reason: matched.length > 0 ? "ok" : "no_data",
    endpointCount: successful.length,
    failedEndpoints: failures,
    query: terms,
    matchedMarketCount: matched.length,
    markets: matched,
  }, null, 2) + "\n");
  process.exitCode = 0;
}

main().catch(() => {
  process.stdout.write(JSON.stringify({
    source: "polymarket",
    checkedAt: new Date().toISOString(),
    ready: false,
    reason: "network_error",
    error: "unexpected public endpoint failure",
    markets: [],
  }) + "\n");
  process.exitCode = 1;
});
