import { buildScanRequests, parseScanResponse } from "./tradingview-screener-core.mjs";
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const DEFAULT_ENDPOINT = "https://scanner.tradingview.com/crypto/scan";
const collectorRoot = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(collectorRoot, "..");
const invokeJsonPostScript = path.join(projectRoot, "scripts", "invoke-json-post.ps1");
const powerShellCandidates = [
  process.env.ANALYSIS_POWERSHELL_PATH,
  path.join(process.env.SystemRoot || "C:\\Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe"),
].filter(Boolean);
const powerShellExecutable = powerShellCandidates.find((candidate) => existsSync(candidate));

function optionValue(prefix) {
  return process.argv.find((value) => value.startsWith(prefix))?.slice(prefix.length);
}

function endpointForMarket(endpoint, market) {
  return endpoint.replace(/\/(?:crypto|america)\/scan(?:\?.*)?$/i, `/${market}/scan`);
}

async function postScan(endpoint, body, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    if (process.platform === "win32" && powerShellExecutable && existsSync(invokeJsonPostScript)) {
      const encodedBody = Buffer.from(JSON.stringify(body), "utf8").toString("base64");
      const raw = execFileSync(powerShellExecutable, [
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", invokeJsonPostScript,
        "-Uri", endpoint, "-BodyBase64", encodedBody, "-TimeoutSeconds", String(Math.ceil(timeoutMs / 1000)),
      ], { encoding: "utf8", timeout: timeoutMs + 5_000, windowsHide: true });
      return JSON.parse(raw);
    }
    const response = await fetch(endpoint, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "user-agent": "portable-investment-analysis/1.0",
      },
      body: JSON.stringify(body),
      signal: controller.signal,
    });
    if (!response.ok) throw new Error(`TradingView Screener HTTP ${response.status}`);
    return await response.json();
  } finally {
    clearTimeout(timer);
  }
}

async function main() {
  if (process.argv.includes("--describe")) {
    process.stdout.write(JSON.stringify({
      source: "tradingview_screener",
      endpoint: DEFAULT_ENDPOINT,
      batch: true,
      authenticated: false,
      systemProxyFallback: true,
      supportedTimeframes: ["D", "W", "M", "3M"],
    }, null, 2));
    return;
  }
  const symbols = process.argv.slice(2).filter((value) => !value.startsWith("--"));
  if (!symbols.length) throw new Error("At least one TradingView-qualified symbol is required.");
  const timeframes = (optionValue("--timeframes=") || "D,W,M,3M").split(",").filter(Boolean);
  const timeoutMs = Number(optionValue("--timeout-ms=") || 15_000);
  const endpoint = process.env.ANALYSIS_TRADINGVIEW_SCREENER_URL || DEFAULT_ENDPOINT;
  const requests = buildScanRequests(symbols, timeframes);
  const results = [];
  const endpoints = [];
  for (const request of requests) {
    const marketEndpoint = endpointForMarket(endpoint, request.market);
    endpoints.push(marketEndpoint);
    const payload = await postScan(marketEndpoint, request.body, timeoutMs);
    results.push(...parseScanResponse(request, payload));
  }
  const bySymbol = new Map(results.map((item) => [item.symbol, item]));
  const capturedAt = new Date().toISOString();
  process.stdout.write(JSON.stringify({
    source: "tradingview_screener",
    capturedAt,
    endpoint,
    endpoints,
    symbolsRequested: symbols.map((value) => String(value).trim().toUpperCase()).filter(Boolean),
    timeframesRequested: timeframes,
    results: symbols.map((value) => bySymbol.get(String(value).trim().toUpperCase())).filter(Boolean).map((item) => ({ capturedAt, ...item })),
  }, null, 2));
}

main().catch((error) => {
  process.stderr.write(`${String(error?.message || error)}\n`);
  process.exitCode = 1;
});
