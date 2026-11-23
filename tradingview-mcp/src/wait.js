import { evaluate, KNOWN_PATHS } from './connection.js';

const DEFAULT_TIMEOUT = 10000;
const POLL_INTERVAL = 200;

const ticker = (value) => String(value || '').split(':').at(-1).replace('!', '').toUpperCase();
const resolution = (value) => String(value || '').toUpperCase().replace(/^1(?=[DWM]$)/, '');

function expectedSpacingSeconds(value) {
  const normalized = resolution(value);
  if (normalized === 'D') return 86400;
  if (normalized === 'W') return 604800;
  if (normalized === 'M') return 2592000;
  const minutes = Number(normalized);
  return Number.isFinite(minutes) && minutes > 0 ? minutes * 60 : null;
}

export function chartStateMatches({ state, expectedSymbol = null, expectedTf = null }) {
  if (!state || Number(state.barCount || 0) <= 0 || !state.lastBarTime) return false;
  const apiTicker = ticker(state.apiSymbol);
  const seriesTicker = ticker(state.seriesSymbol);
  if (!apiTicker || !seriesTicker || apiTicker !== seriesTicker) return false;
  if (resolution(state.resolution) !== resolution(state.seriesResolution)) return false;
  if (expectedSymbol && apiTicker !== ticker(expectedSymbol)) return false;
  if (expectedTf && (resolution(state.resolution) !== resolution(expectedTf) || resolution(state.seriesResolution) !== resolution(expectedTf))) return false;
  const expectedSpacing = expectedTf ? expectedSpacingSeconds(expectedTf) : null;
  if (expectedSpacing && Number.isFinite(Number(state.barSpacing))) {
    const actualSpacing = Number(state.barSpacing);
    if (actualSpacing < expectedSpacing * 0.65 || actualSpacing > expectedSpacing * 1.45) return false;
  }
  return true;
}

export async function waitForChartReady(expectedSymbol = null, expectedTf = null, timeout = DEFAULT_TIMEOUT) {
  const start = Date.now();
  let lastSignature = '';
  let stableCount = 0;

  while (Date.now() - start < timeout) {
    const state = await evaluate(`
      (function() {
        var chart = ${KNOWN_PATHS.chartApi};
        var mainSeries = chart._chartWidget.model().mainSeries();
        var bars = mainSeries.bars();
        var start = bars.firstIndex();
        var end = bars.lastIndex();
        var last = end >= start ? bars.valueAt(end) : null;
        var times = [];
        for (var i = Math.max(start, end - 6); i <= end; i++) {
          var value = bars.valueAt(i);
          if (value && Number.isFinite(Number(value[0]))) times.push(Number(value[0]));
        }
        var deltas = [];
        for (var j = 1; j < times.length; j++) {
          var delta = times[j] - times[j - 1];
          if (delta > 0) deltas.push(delta);
        }
        deltas.sort(function(a, b) { return a - b; });
        var barSpacing = deltas.length ? deltas[Math.floor(deltas.length / 2)] : null;
        return {
          apiSymbol: chart.symbol(),
          seriesSymbol: mainSeries.symbol(),
          resolution: chart.resolution(),
          seriesResolution: mainSeries.interval(),
          barCount: bars.size(),
          lastBarTime: last ? last[0] : null,
          barSpacing: barSpacing
        };
      })()
    `);

    if (!state) {
      await new Promise(r => setTimeout(r, POLL_INTERVAL));
      continue;
    }

    if (!chartStateMatches({ state, expectedSymbol, expectedTf })) {
      stableCount = 0;
      await new Promise(r => setTimeout(r, POLL_INTERVAL));
      continue;
    }

    const signature = `${state.apiSymbol}|${state.seriesSymbol}|${state.resolution}|${state.seriesResolution}|${state.barCount}|${state.lastBarTime}|${state.barSpacing}`;
    if (signature === lastSignature) {
      stableCount++;
    } else {
      stableCount = 0;
    }
    lastSignature = signature;

    if (stableCount >= 2) {
      return true;
    }

    await new Promise(r => setTimeout(r, POLL_INTERVAL));
  }

  // Timeout — return true anyway, caller should verify
  return false;
}
