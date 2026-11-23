# 三市场行情与周期研究
面向 A 股、美股和数字资产的只读研究工具。使用者自行指定市场代码和数据源。

## 行情
Node.js 20+ 可运行公开行情筛选器：
```sh
node collectors/tradingview-screener.mjs NASDAQ:AAPL BINANCE:BTCUSDT --timeframes=D,W
node --test tests/tradingview-screener.test.mjs
```

A 股采集使用 Python 3.10+，依赖 requests、akshare、baostock。输出目录须预先存在：
```sh
python collectors/ashare-market-data.py --symbols 600000 --output quotes.json
```

## 周线研究
用 PowerShell 7 运行以下命令。输入目录中分别提供 CSI300TR.csv、SPY.csv、BTC.csv，每个文件包含 week,price,benchmark 三列。使用按时间升序排列的周五日期和同周正数价格，建议至少 313 周。股票及债券基准请使用一致的含息口径。
```powershell
./scripts/get-weekly-cycle-context.ps1 -HistoryRoot ./data
```
程序计算价格与基准对数比值相对此前 156 周的 Z 分数、52 周分位和回撤，并检查周线峰谷背离。输出包含市场日期和数据状态；stale 表示周线滞后，unavailable 表示输入不可用。指标用于研究，交易由使用者自行决定。
