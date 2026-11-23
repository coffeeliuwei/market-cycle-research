#!/usr/bin/env python3
"""Read-only A-share market collector: AKShare first, BaoStock quote fallback."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
from pathlib import Path
import time


def records(frame):
    if frame is None or getattr(frame, "empty", True):
        return []
    return json.loads(frame.to_json(orient="records", force_ascii=False, date_format="iso"))


def market_prefix(symbol: str) -> str:
    return "sh" if symbol.startswith(("5", "6", "9")) else "sz"


def parse_tencent_quotes(payload: str, symbols: list[str]) -> list[dict]:
    requested = set(symbols)
    parsed = []
    for line in payload.splitlines():
        if '="' not in line:
            continue
        body = line.split('="', 1)[1].rsplit('"', 1)[0]
        fields = body.split("~")
        if len(fields) < 7 or fields[2] not in requested or not fields[3]:
            continue
        last = fields[3]
        previous = fields[4] if len(fields) > 4 else ""
        try:
            change_pct = str(round((float(last) / float(previous) - 1) * 100, 6)) if float(previous) else ""
        except (TypeError, ValueError):
            change_pct = ""
        parsed.append({
            "代码": fields[2],
            "名称": fields[1],
            "最新价": last,
            "涨跌幅": change_pct,
            "成交量": fields[6],
            "成交额": fields[37] if len(fields) > 37 else "",
        })
    return sorted(parsed, key=lambda row: row["代码"])


def collect_tencent_quotes(symbols: list[str]) -> list[dict]:
    import requests

    if not symbols:
        return []
    codes = ",".join(f"{market_prefix(symbol)}{symbol}" for symbol in symbols)
    url = f"https://qt.gtimg.cn/q={codes}"
    last_error = None
    for attempt in range(3):
        try:
            response = requests.get(url, timeout=10, headers={"User-Agent": "Mozilla/5.0"})
            response.raise_for_status()
            response.encoding = "gbk"
            rows = parse_tencent_quotes(response.text, symbols)
            if {row["代码"] for row in rows} == set(symbols):
                return rows
            raise RuntimeError(f"quote coverage {len(rows)}/{len(symbols)}")
        except Exception as exc:
            last_error = exc
            if attempt < 2:
                time.sleep(0.5 * (attempt + 1))
    raise RuntimeError(f"Tencent quote fallback failed: {last_error}")


def baostock_query_window(today: dt.date) -> tuple[str, str]:
    return (today - dt.timedelta(days=14)).isoformat(), today.isoformat()


def collect_published_dataset(call, now=None):
    """Bounded publication lag fallback; never label prior-day rows as today's."""
    now = now or dt.datetime.now()
    errors = []
    for offset in range(8):
        day = now.date() - dt.timedelta(days=offset)
        if day.weekday() >= 5:
            continue
        try:
            rows = records(call(day.strftime('%Y%m%d')))
            if rows:
                return rows, {'dataDate': day.isoformat(), 'lagCalendarDays': offset,
                              'status': 'current' if offset == 0 else 'latest_published'}
        except Exception as exc:
            errors.append(str(exc))
    raise RuntimeError('No published dataset in bounded 8-day window: ' + '; '.join(errors))


def parse_eastmoney_fund_flow(data, symbol):
    if not isinstance(data, dict) or data.get("code") != symbol:
        raise ValueError("Eastmoney fund-flow symbol mismatch or missing")
    valid = []
    for line in data.get("klines") or []:
        fields = line.split(",")
        try:
            date = dt.date.fromisoformat(fields[0])
            net, pct = float(fields[1]), float(fields[6])
        except (IndexError, ValueError):
            continue
        if math.isfinite(net) and math.isfinite(pct):
            valid.append((date, net, pct))
    if not valid:
        raise ValueError("no dated Eastmoney fund-flow observation")
    date, net, pct = max(valid, key=lambda row: row[0])
    return {"代码": symbol, "名称": data.get("name", ""), "日期": date.isoformat(),
            "主力净流入-净额": net, "主力净流入-净占比": pct,
            "source": "eastmoney_historical_direct"}


def collect_eastmoney_fund_flow(symbol, market):
    import requests

    response = requests.get(
        "https://push2his.eastmoney.com/api/qt/stock/fflow/daykline/get",
        params={"secid": f"{int(market == 'sh')}.{symbol}", "lmt": 5, "klt": 101,
                "fields1": "f1,f2,f3,f7", "fields2": "f51,f52,f53,f54,f55,f56,f57"},
        headers={"User-Agent": "Mozilla/5.0"}, timeout=6,
    )
    response.raise_for_status()
    payload = response.json()
    if payload.get("rc") != 0:
        raise ValueError("Eastmoney fund-flow API returned an error")
    return parse_eastmoney_fund_flow(payload.get("data"), symbol)


def collect_akshare(symbols: list[str]) -> dict:
    today = dt.datetime.now().strftime("%Y%m%d")
    failures: list[dict] = []
    quote_rows = collect_tencent_quotes(symbols)
    quote_provider = "tencent"
    try:
        import akshare as ak
    except Exception as exc:
        return {
            "capturedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
            "provider": "tencent",
            "quoteProvider": quote_provider,
            "quotes": quote_rows,
            "individualFundFlow": [],
            "limitUpPool": [],
            "dragonTiger": [],
            "marginSummary": [],
            "failures": [{"source": "akshare.import", "error": str(exc), "required": False}],
        }

    current_fund_flow = getattr(ak, "stock_fund_flow_individual_hist_em", None)
    flows = []
    flow_attempts = []
    akshare_flow_block = None
    for symbol in symbols:
        market = "sh" if symbol.startswith(("5", "6", "9")) else "sz"
        primary_status = "skipped_after_rate_limit" if akshare_flow_block else "failed"
        try:
            if akshare_flow_block:
                raise RuntimeError(akshare_flow_block)
            if current_fund_flow is not None:
                frame = current_fund_flow(symbol=symbol, market=market)
            else:
                frame = ak.stock_individual_fund_flow(stock=symbol, market=market)
            latest = frame.dropna(subset=["日期", "主力净流入-净额", "主力净流入-净占比"]).sort_values("日期").tail(1).copy()
            if latest.empty:
                raise RuntimeError("no dated fund-flow observation")
            latest["日期"] = latest["日期"].map(lambda value: str(value)[:10])
            latest.insert(0, "代码", symbol)
            latest["source"] = "akshare.fund_flow"
            if "名称" not in latest.columns:
                match = next((row for row in quote_rows if str(row.get("代码", "")) == symbol), None)
                latest.insert(1, "名称", "" if match is None else str(match.get("名称", "")))
            flows.extend(records(latest))
        except Exception as exc:
            if "限流" in str(exc):
                akshare_flow_block = str(exc)
            attempt = {"symbol": symbol, "source": "akshare.fund_flow", "status": primary_status, "error": str(exc)}
            try:
                flows.append(collect_eastmoney_fund_flow(symbol, market))
                attempt["recoveredBy"] = "eastmoney_historical_direct"
            except Exception as fallback_error:
                failures.append({**attempt, "fallbackError": str(fallback_error), "required": False})
            flow_attempts.append(attempt)

    def safe(name, call):
        try:
            return records(call())
        except Exception as exc:
            failures.append({"source": name, "error": str(exc), "required": False})
            return []

    publication = {}
    def published(name, call):
        try:
            rows, metadata = collect_published_dataset(call)
            publication[name] = metadata
            return rows
        except Exception as exc:
            failures.append({'source': name, 'error': str(exc), 'required': False})
            return []

    dragon = published('akshare.dragon_tiger', lambda date: ak.stock_lhb_detail_em(start_date=date, end_date=date))
    margin = published('akshare.margin_sse', lambda date: ak.stock_margin_detail_sse(date=date))
    return {
        "capturedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "provider": "tencent+akshare",
        "quoteProvider": quote_provider,
        "quotes": quote_rows,
        "individualFundFlow": flows,
        "fundFlowAttempts": flow_attempts,
        "limitUpPool": safe("akshare.limit_up", lambda: ak.stock_zt_pool_em(date=today)),
        "dragonTiger": dragon,
        "marginSummary": margin,
        "enrichmentPublication": publication,
        "failures": failures,
    }


def collect_baostock_quotes(symbols: list[str], prior_error: str) -> dict:
    import baostock as bs

    login = bs.login()
    failures = [{"source": "akshare", "error": prior_error, "required": True}]
    quotes = []
    try:
        if login.error_code != "0":
            raise RuntimeError(login.error_msg)
        start_date, end_date = baostock_query_window(dt.date.today())
        for symbol in symbols:
            prefix = market_prefix(symbol)
            result = bs.query_history_k_data_plus(
                f"{prefix}.{symbol}",
                "date,code,close,volume,amount,pctChg",
                start_date=start_date,
                end_date=end_date,
                frequency="d",
                adjustflag="3",
            )
            latest = None
            while result.error_code == "0" and result.next():
                row = dict(zip(result.fields, result.get_row_data()))
                latest = row
            if latest:
                quotes.append({
                    "代码": symbol,
                    "名称": "",
                    "最新价": latest.get("close"),
                    "涨跌幅": latest.get("pctChg"),
                    "成交量": latest.get("volume"),
                    "成交额": latest.get("amount"),
                    "交易日期": latest.get("date"),
                })
            if result.error_code != "0":
                failures.append({"source": "baostock.quote", "symbol": symbol, "error": result.error_msg, "required": True})
    finally:
        bs.logout()
    return {
        "capturedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "provider": "baostock",
        "quoteProvider": "baostock",
        "quotes": quotes,
        "individualFundFlow": [],
        "limitUpPool": [],
        "dragonTiger": [],
        "marginSummary": [],
        "failures": failures,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--symbols", default="")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    symbols = sorted({value.strip() for value in args.symbols.split(",") if value.strip().isdigit() and len(value.strip()) == 6})
    try:
        result = collect_akshare(symbols)
    except Exception as exc:
        result = collect_baostock_quotes(symbols, str(exc))
    Path(args.output).write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
