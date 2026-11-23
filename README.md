# 三市场投资研究工作台

面向 A 股、美股与数字资产的个人研究项目。包含行情采集、账户事件、持仓及挂单分析、研究知识库、月季预测与到期复核、周线周期提醒、历史回测和分析报告流程。仓库中的账户、交易事件、研究案例和初始化行情均为虚构样本。

## 首次使用（离线样本）
使用 PowerShell 7，在仓库根目录运行：
```powershell
./scripts/init-demo.ps1
./scripts/get-compact-account-context.ps1
./scripts/get-effective-decisions.ps1
./scripts/get-weekly-cycle-context.ps1 -AsOf '2019-11-24T12:00:00Z'
./scripts/find-research-cases.ps1 -Terms 行业
./scripts/market-forecast.ps1 -Action list
./research/btc-paired.ps1
./tests/Run-All.ps1
```
初始化会从 examples/state 生成本地 state，并生成 PORTFOLIO.md。初始化仅适用于没有 state 目录的新副本。样本日期固定，以当天时间读取会报告陈旧。研究样本只用于验证流程。

## 项目入口
- WORKFLOW.md 规定盘点、行情刷新、证据复核、预测和行动建议的顺序；AGENTS.md 与 OPENCODE.md 为两个宿主的入口。
- scripts/record-account-event.ps1 按稳定事件编号处理提议、建单、部分成交、成交、撤单、余额、持仓和机器人变化；幂等更新事件流水、当前状态与总览。样本含四个账户和四个对应事件。
- knowledge/ 保存分析模板、行业周期筛选、顶底判断、现货与网格方法。历史研究按 availableBy 截断。含账户策略的知识文件使用通用样本。
- 三市场周线模块使用此前156周计算 Z。research/ 提供 Z 确认策略和 BTC 双指标配对实验，结果写入本地 state/runtime。研究代码默认使用初始化数据；真实研究应自行提供授权的历史数据，区分回测和样本外验证。
- 市场归属按标的分析，订单和风险按交易场所归集。账户、现金与挂单的真实性由操作者自行核验。

## 联网采集
Windows 下安装 Node.js 20+ 与 npm，运行 scripts/bootstrap.ps1 安装 TradingView 桌面桥接依赖，scripts/doctor.ps1 -Repair -Json 检查本机桌面连接。A 股采集使用 Python 3.10+、requests、akshare 和 baostock。独立行情入口：
```sh
node collectors/tradingview-screener.mjs NASDAQ:AAPL BINANCE:BTCUSDT --timeframes=D,W
node --test tests/tradingview-screener.test.mjs
```
完整组合刷新用 scripts/run-analysis-refresh.ps1；A 股用 scripts/run-ashare-refresh.ps1。CoinGlass、Polymarket、X、可选官方 MCP 的可用性取决于授权、网络和宿主，失败或缓存须披露。账户与交易所交互限只读；本地事件记录不会发送订单。TradingView 桥接组件保留其原有 LICENSE。

## 本地数据与发布
examples/ 只存虚构输入。所有实际 state/、账户总览、行情快照、导出、截图、日志和凭据都应留在本机。项目采用按文件放行的 Git 规则。若自定义已跟踪的配置或示例，请使用本地私有副本，避免将修改推回共享仓库。
