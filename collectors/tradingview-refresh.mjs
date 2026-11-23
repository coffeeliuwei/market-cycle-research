import { createRequire } from "module";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { existsSync } from "node:fs";

const require = createRequire(import.meta.url);
const collectorRoot = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(collectorRoot, "..");
const mcpRoot = path.join(projectRoot, "tradingview-mcp");
const ensureCdpScript = path.join(projectRoot, "scripts", "ensure-tradingview-cdp.ps1");
const powerShellCandidates = [
  process.env.ANALYSIS_POWERSHELL_PATH,
  path.join(process.env.SystemRoot || "C:\\Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe"),
].filter(Boolean);
const powerShellExecutable = powerShellCandidates.find((candidate) => existsSync(candidate));
if (!powerShellExecutable) throw new Error("PowerShell executable was not found. Set ANALYSIS_POWERSHELL_PATH.");
const { getOhlcv } = require(path.join(mcpRoot, "src", "core", "data.js"));
const { setSymbol, setTimeframe, getState } = require(path.join(mcpRoot, "src", "core", "chart.js"));
const { disconnect } = require(path.join(mcpRoot, "src", "connection.js"));

const periodCatalog = new Map([["D", 86_400], ["W", 604_800], ["M", 2_419_200], ["3M", 7_257_600]]);
const MINIMUM_BARS_FOR_SPACING = 2;
const SYMBOL_SELECTION_ATTEMPTS = 3;
const OHLCV_ATTEMPTS = 3;
const ticker = (value) => String(value || "").split(":").at(-1).replace("!", "").toUpperCase();
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function range(bars, count) {
  const data = bars.slice(-count);
  return { low: Math.min(...data.map((bar) => bar.low)), high: Math.max(...data.map((bar) => bar.high)) };
}

function summarize(bars) {
  const last = bars.at(-1);
  return {
    count: bars.length,
    time: last.time,
    open: last.open,
    high: last.high,
    low: last.low,
    close: last.close,
    changePct: Number((((last.close / last.open) - 1) * 100).toFixed(2)),
    last4: range(bars, 4),
    last12: range(bars, 12),
  };
}

function spacingMatches(bars, expected) {
  if (bars.length < MINIMUM_BARS_FOR_SPACING) return false;
  const deltas = bars.slice(-6).map((bar, index, data) => index ? bar.time - data[index - 1].time : null).filter(Boolean);
  const median = deltas.sort((a, b) => a - b)[Math.floor(deltas.length / 2)];
  return median >= expected * 0.65 && median <= expected * 1.45;
}

async function selectSymbol(symbol) {
  let lastState = null;
  for (let attempt = 1; attempt <= SYMBOL_SELECTION_ATTEMPTS; attempt += 1) {
    await setSymbol({ symbol });
    lastState = await getState();
    if (ticker(lastState.symbol) === ticker(symbol) && ticker(lastState.seriesSymbol) === ticker(symbol)) return;
    if (attempt < SYMBOL_SELECTION_ATTEMPTS) await sleep(400);
  }
  throw new Error(`symbol selection mismatch:api=${lastState?.symbol || "unknown"}:series=${lastState?.seriesSymbol || "unknown"}`);
}

async function fetchPeriod(symbol, resolution, expectedSpacing) {
  let lastError = new Error("OHLCV refresh failed");
  for (let attempt = 1; attempt <= OHLCV_ATTEMPTS; attempt += 1) {
    try {
      await setTimeframe({ timeframe: resolution });
      const state = await getState();
      const actualResolution = String(state.resolution).toUpperCase().replace(/^1(?=[DWM]$)/, "");
      const seriesResolution = String(state.seriesResolution).toUpperCase().replace(/^1(?=[DWM]$)/, "");
      if (ticker(state.symbol) !== ticker(symbol) || ticker(state.seriesSymbol) !== ticker(symbol) || actualResolution !== resolution || seriesResolution !== resolution) {
        throw new Error(`chart state mismatch:api=${state.symbol}:${state.resolution}:series=${state.seriesSymbol}:${state.seriesResolution}`);
      }
      const response = await getOhlcv({ count: 120, expectedSymbol: symbol });
      if (spacingMatches(response.bars, expectedSpacing)) return summarize(response.bars);
      lastError = new Error("bar spacing mismatch");
    } catch (error) {
      lastError = error;
      if (String(error?.message || error).startsWith("chart state mismatch:")) {
        await selectSymbol(symbol);
      }
    }
    if (attempt < OHLCV_ATTEMPTS) await sleep(600);
  }
  throw lastError;
}

async function main() {
  if (process.argv.includes("--describe")) {
    process.stdout.write(JSON.stringify({
      projectRoot,
      mcpRoot,
      ensureCdpScript,
      powerShellExecutable,
      periods: [...periodCatalog.keys()],
      supportsTimeframeSelection: true,
      minimumBarsForSpacing: MINIMUM_BARS_FOR_SPACING,
      symbolSelectionAttempts: SYMBOL_SELECTION_ATTEMPTS,
      ohlcvAttempts: OHLCV_ATTEMPTS,
    }, null, 2));
    return;
  }
  execFileSync(powerShellExecutable, ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ensureCdpScript, "-Port", "9222", "-StartupTimeoutSeconds", "25"], { stdio: "ignore", timeout: 35_000 });
  const option = process.argv.find((value) => value.startsWith("--timeframes="));
  const names = option ? option.slice(13).split(",").filter(Boolean) : [...periodCatalog.keys()];
  for (const name of names) if (!periodCatalog.has(name)) throw new Error(`Unsupported timeframe: ${name}`);
  const requestedPeriods = names.map((name) => [name, periodCatalog.get(name)]);
  const results = [];
  for (const symbol of process.argv.slice(2).filter((value) => !value.startsWith("--"))) {
    const item = { symbol, capturedAt: new Date().toISOString(), periods: {} };
    try {
      await selectSymbol(symbol);
      for (const [resolution, spacing] of requestedPeriods) {
        try { item.periods[resolution] = { ok: true, ...(await fetchPeriod(symbol, resolution, spacing)) }; }
        catch (error) { item.periods[resolution] = { ok: false, error: String(error?.message || error) }; }
      }
    } catch (error) { item.error = `symbol refresh failed: ${String(error?.message || error)}`; }
    results.push(item);
  }
  process.stdout.write(JSON.stringify({ source: "tradingview_desktop", capturedAt: new Date().toISOString(), results }, null, 2));
}

main().catch(() => { process.exitCode = 1; }).finally(disconnect);
