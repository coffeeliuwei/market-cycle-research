/**
 * Core chart control logic.
 */
import { evaluate as _evaluate, evaluateAsync as _evaluateAsync, reloadPage as _reloadPage, safeString, requireFinite } from '../connection.js';
import { waitForChartReady as _waitForChartReady } from '../wait.js';

const CHART_API = 'window.TradingViewApi._activeChartWidgetWV.value()';

function _resolve(deps) {
  return {
    evaluate: deps?.evaluate || _evaluate,
    evaluateAsync: deps?.evaluateAsync || _evaluateAsync,
    reloadPage: deps?.reloadPage || _reloadPage,
    waitForChartReady: deps?.waitForChartReady || _waitForChartReady,
  };
}

export async function dismissBlockingPromotions({ _deps } = {}) {
  const { evaluate } = _resolve(_deps);
  return evaluate(`
    (function() {
      var phrases = [
        'Analyze markets in TradingView Desktop',
        'Upgrade your plan',
        'Time to upgrade?'
      ];
      function visible(el) {
        if (!el || !el.isConnected || el.getClientRects().length === 0) return false;
        var style = window.getComputedStyle(el);
        return style.display !== 'none' && style.visibility !== 'hidden' && style.opacity !== '0';
      }
      function isPromotion(el) {
        var text = (el.innerText || el.textContent || '').trim();
        return visible(el) && phrases.some(function(phrase) { return text.indexOf(phrase) !== -1; });
      }
      function dismissNow() {
        var roots = Array.from(document.querySelectorAll('[role="dialog"], [data-name*="dialog"], [class*="dialog"], [class*="modal"]'));
        var promotionRoots = roots.filter(isPromotion);
        var detected = promotionRoots.length;
        var dismissed = 0;
        var removed = 0;
        var globalClose = detected > 0 && Array.from(document.querySelectorAll('button, [role="button"]')).find(function(el) {
          var label = ((el.getAttribute('aria-label') || '') + ' ' + (el.innerText || el.textContent || '')).trim();
          var className = String(el.className || '');
          return visible(el) && (label.indexOf('关闭广告') !== -1 || className.indexOf('closeButton') !== -1);
        });
        if (globalClose) {
          globalClose.click();
          dismissed = detected;
        } else {
          promotionRoots.forEach(function(root) {
            var candidates = Array.from(root.querySelectorAll('button, [role="button"], [data-name*="close"], [aria-label]'));
            var close = candidates.find(function(el) {
              var label = ((el.getAttribute('aria-label') || '') + ' ' + (el.getAttribute('data-name') || '') + ' ' + (el.innerText || '')).toLowerCase();
              return /(^|\\s)(close|dismiss|cancel|not now|关闭|取消|稍后)(\\s|$)/.test(label)
                || label.indexOf('dialog-close') !== -1
                || label.indexOf('close-button') !== -1;
            });
            if (close) {
              close.click();
              dismissed += 1;
            } else {
              document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', keyCode: 27, which: 27, bubbles: true }));
            }
          });
        }
        // TradingView's current free-plan upsell has no real close control and
        // ignores synthetic Escape events. Hide only roots whose own text matches
        // our recognized promotion phrases; never touch unrelated dialogs.
        promotionRoots.forEach(function(root) {
          if (visible(root)) {
            root.style.display = 'none';
            root.setAttribute('aria-hidden', 'true');
            removed += 1;
          }
        });
        // The no-close free-plan dialog leaves TradingView's page-level scroll
        // lock behind when it is hidden. Release it only when no other visible
        // dialog remains, so normal dialogs keep their own interaction lock.
        var visibleDialogs = roots.filter(function(el) {
          return el.tagName !== 'BUTTON' && visible(el);
        });
        if (visibleDialogs.length === 0 && document.body) {
          document.body.classList.remove('i-no-scroll');
        }
        // Some promotional dialogs intentionally expose no close button, while
        // unrelated ads elsewhere on the page do. Escape is the reliable scoped
        // fallback, so send it whenever a recognized promotion is present.
        if (detected > 0) {
          document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', keyCode: 27, which: 27, bubbles: true }));
        }
        return { detected: detected, dismissed: dismissed, removed: removed };
      }
      var result = dismissNow();
      var observerInstalled = !!window.__tvPromotionGuardObserver;
      if (!observerInstalled && document.documentElement) {
        var queued = false;
        window.__tvPromotionGuardObserver = new MutationObserver(function() {
          if (queued) return;
          queued = true;
          setTimeout(function() {
            queued = false;
            dismissNow();
          }, 0);
        });
        window.__tvPromotionGuardObserver.observe(document.documentElement, { childList: true, subtree: true });
        observerInstalled = true;
      }
      return Object.assign(result, { observerInstalled: observerInstalled });
    })()
  `);
}

export async function getState({ _deps } = {}) {
  const { evaluate } = _resolve(_deps);
  const state = await evaluate(`
    (function() {
      var chart = ${CHART_API};
      var studies = [];
      try {
        var allStudies = chart.getAllStudies();
        studies = allStudies.map(function(s) {
          return { id: s.id, name: s.name || s.title || 'unknown' };
        });
      } catch(e) {}
      return {
        symbol: chart.symbol(),
        seriesSymbol: (function() {
          try { return chart._chartWidget.model().mainSeries().symbol(); }
          catch(e) { return null; }
        })(),
        resolution: chart.resolution(),
        seriesResolution: (function() {
          try { return chart._chartWidget.model().mainSeries().interval(); }
          catch(e) { return null; }
        })(),
        chartType: chart.chartType(),
        studies: studies,
      };
    })()
  `);
  return { success: true, ...state };
}

export async function setSymbol({ symbol, _deps }) {
  const { evaluateAsync, reloadPage, waitForChartReady } = _resolve(_deps);
  async function selectAndWait() {
    await dismissBlockingPromotions({ _deps });
    await evaluateAsync(`
    (function() {
      var chart = ${CHART_API};
      return new Promise(function(resolve) {
        chart.setSymbol(${safeString(symbol)}, {});
        setTimeout(resolve, 500);
      });
    })()
    `);
    return waitForChartReady(symbol);
  }

  let ready = await selectAndWait();
  let recovered = false;
  if (!ready) {
    await reloadPage();
    recovered = true;
    ready = await selectAndWait();
  }
  if (!ready) throw new Error(`chart readiness timeout for ${symbol}`);
  return { success: true, symbol, chart_ready: ready, recovered };
}

export async function setTimeframe({ timeframe, _deps }) {
  const { evaluate, reloadPage, waitForChartReady } = _resolve(_deps);
  async function selectAndWait() {
    await dismissBlockingPromotions({ _deps });
    await evaluate(`
      (function() {
        var chart = ${CHART_API};
        chart.setResolution(${safeString(timeframe)}, {});
      })()
    `);
    return waitForChartReady(null, timeframe);
  }

  let ready = await selectAndWait();
  let recovered = false;
  if (!ready) {
    await reloadPage();
    recovered = true;
    ready = await selectAndWait();
  }
  if (!ready) throw new Error(`chart readiness timeout for timeframe ${timeframe}`);
  return { success: true, timeframe, chart_ready: ready, recovered };
}

export async function setType({ chart_type, _deps }) {
  const { evaluate } = _resolve(_deps);
  const typeMap = {
    'Bars': 0, 'Candles': 1, 'Line': 2, 'Area': 3,
    'Renko': 4, 'Kagi': 5, 'PointAndFigure': 6, 'LineBreak': 7,
    'HeikinAshi': 8, 'HollowCandles': 9,
  };
  const typeNum = typeMap[chart_type] ?? Number(chart_type);
  if (isNaN(typeNum) || typeNum < 0 || typeNum > 9 || !Number.isInteger(typeNum)) {
    throw new Error(`Unknown chart type: ${chart_type}. Use a name (Candles, Line, etc.) or number (0-9).`);
  }
  await evaluate(`
    (function() {
      var chart = ${CHART_API};
      chart.setChartType(${typeNum});
    })()
  `);
  return { success: true, chart_type, type_num: typeNum };
}

export async function manageIndicator({ action, indicator, entity_id, inputs: inputsRaw, _deps }) {
  const { evaluate } = _resolve(_deps);
  const inputs = inputsRaw ? (typeof inputsRaw === 'string' ? JSON.parse(inputsRaw) : inputsRaw) : undefined;

  if (action === 'add') {
    const inputArr = inputs ? Object.entries(inputs).map(([k, v]) => ({ id: k, value: v })) : [];
    const before = await evaluate(`${CHART_API}.getAllStudies().map(function(s) { return s.id; })`);
    await evaluate(`
      (function() {
        var chart = ${CHART_API};
        chart.createStudy(${safeString(indicator)}, false, false, ${JSON.stringify(inputArr)});
      })()
    `);
    await new Promise(r => setTimeout(r, 1500));
    const after = await evaluate(`${CHART_API}.getAllStudies().map(function(s) { return s.id; })`);
    const newIds = (after || []).filter(id => !(before || []).includes(id));
    return { success: newIds.length > 0, action: 'add', indicator, entity_id: newIds[0] || null, new_study_count: newIds.length };
  } else if (action === 'remove') {
    if (!entity_id) throw new Error('entity_id required for remove action. Use chart_get_state to find study IDs.');
    await evaluate(`
      (function() {
        var chart = ${CHART_API};
        chart.removeEntity(${safeString(entity_id)});
      })()
    `);
    return { success: true, action: 'remove', entity_id };
  } else {
    throw new Error('action must be "add" or "remove"');
  }
}

export async function getVisibleRange() {
  const result = await evaluate(`
    (function() {
      var chart = ${CHART_API};
      return { visible_range: chart.getVisibleRange(), bars_range: chart.getVisibleBarsRange() };
    })()
  `);
  return { success: true, visible_range: result.visible_range, bars_range: result.bars_range };
}

export async function setVisibleRange({ from, to, _deps }) {
  const { evaluate } = _resolve(_deps);
  const f = requireFinite(from, 'from');
  const t = requireFinite(to, 'to');
  await evaluate(`
    (function() {
      var chart = ${CHART_API};
      var m = chart._chartWidget.model();
      var ts = m.timeScale();
      var bars = m.mainSeries().bars();
      var startIdx = bars.firstIndex();
      var endIdx = bars.lastIndex();
      var fromIdx = startIdx, toIdx = endIdx;
      for (var i = startIdx; i <= endIdx; i++) {
        var v = bars.valueAt(i);
        if (v && v[0] >= ${f} && fromIdx === startIdx) fromIdx = i;
        if (v && v[0] <= ${t}) toIdx = i;
      }
      ts.zoomToBarsRange(fromIdx, toIdx);
    })()
  `);
  await new Promise(r => setTimeout(r, 500));
  const actual = await evaluate(`
    (function() {
      var chart = ${CHART_API};
      try { var r = chart.getVisibleRange(); return { from: r.from || 0, to: r.to || 0 }; }
      catch(e) { return { from: 0, to: 0, error: e.message }; }
    })()
  `);
  return { success: true, requested: { from, to }, actual: actual || { from: 0, to: 0 } };
}

export async function scrollToDate({ date }) {
  let timestamp;
  if (/^\d+$/.test(date)) timestamp = Number(date);
  else timestamp = Math.floor(new Date(date).getTime() / 1000);
  if (isNaN(timestamp)) throw new Error(`Could not parse date: ${date}. Use ISO format (2024-01-15) or unix timestamp.`);

  const resolution = await evaluate(`${CHART_API}.resolution()`);
  let secsPerBar = 60;
  const res = String(resolution);
  if (res === 'D' || res === '1D') secsPerBar = 86400;
  else if (res === 'W' || res === '1W') secsPerBar = 604800;
  else if (res === 'M' || res === '1M') secsPerBar = 2592000;
  else { const mins = parseInt(res, 10); if (!isNaN(mins)) secsPerBar = mins * 60; }

  const halfWindow = 25 * secsPerBar;
  const from = timestamp - halfWindow;
  const to = timestamp + halfWindow;

  await evaluate(`
    (function() {
      var chart = ${CHART_API};
      var m = chart._chartWidget.model();
      var ts = m.timeScale();
      var bars = m.mainSeries().bars();
      var startIdx = bars.firstIndex();
      var endIdx = bars.lastIndex();
      var fromIdx = startIdx, toIdx = endIdx;
      for (var i = startIdx; i <= endIdx; i++) {
        var v = bars.valueAt(i);
        if (v && v[0] >= ${from} && fromIdx === startIdx) fromIdx = i;
        if (v && v[0] <= ${to}) toIdx = i;
      }
      ts.zoomToBarsRange(fromIdx, toIdx);
    })()
  `);
  await new Promise(r => setTimeout(r, 500));
  return { success: true, date, centered_on: timestamp, resolution, window: { from, to } };
}

export async function symbolInfo() {
  const result = await evaluate(`
    (function() {
      var chart = ${CHART_API};
      var info = chart.symbolExt();
      return {
        symbol: info.symbol, full_name: info.full_name, exchange: info.exchange,
        description: info.description, type: info.type, pro_name: info.pro_name,
        typespecs: info.typespecs, resolution: chart.resolution(), chart_type: chart.chartType()
      };
    })()
  `);
  return { success: true, ...result };
}

export async function symbolSearch({ query, type }) {
  // Use TradingView's public symbol search REST API (works without auth)
  const params = new URLSearchParams({
    text: query,
    hl: '1',
    exchange: '',
    lang: 'en',
    search_type: type || '',
    domain: 'production',
  });

  const resp = await fetch(`https://symbol-search.tradingview.com/symbol_search/v3/?${params}`, {
    headers: { 'Origin': 'https://www.tradingview.com', 'Referer': 'https://www.tradingview.com/' },
  });
  if (!resp.ok) throw new Error(`Symbol search API returned ${resp.status}`);
  const data = await resp.json();

  const strip = s => (s || '').replace(/<\/?em>/g, '');
  const results = (data.symbols || data || []).slice(0, 15).map(r => ({
    symbol: strip(r.symbol),
    description: strip(r.description),
    exchange: r.exchange || r.prefix || '',
    type: r.type || '',
    full_name: r.exchange ? `${r.exchange}:${strip(r.symbol)}` : strip(r.symbol),
  }));

  return { success: true, query, source: 'rest_api', results, count: results.length };
}
