# 三市场投资研究工作台

面向 A 股、美股与数字资产的个人研究项目。包含行情采集、账户事件、持仓及挂单分析、研究知识库、月季预测与到期复核、周线周期提醒、历史回测和分析报告流程。仓库中的账户、交易事件、研究案例和初始化行情均为虚构样本。

## 浏览器在线试用

[用 GitHub Codespaces 打开](https://codespaces.new/coffeeliuwei/market-cycle-research?quickstart=1)

登录 GitHub，有本仓库访问权限的试用者即可创建 Codespace。首次启动会安装 PowerShell、初始化虚构账户和合成行情，并打开生成的三市场样本分析。报告覆盖月季方向、周期预警、A 股板块筛选、分账户挂单复核、BTC 回测和行动清单。可在浏览器编辑器中切换到 Markdown 预览。

体验其他模块时，可在 Codespaces 的终端运行下面的命令。

```sh
pwsh -NoProfile -File scripts/run-demo.ps1
pwsh -NoProfile -File research/btc-paired.ps1
pwsh -NoProfile -File tests/Run-All.ps1
```

在线环境使用离线样本，适合试用账户、周期和回测流程。依赖本机 TradingView Desktop 的实时采集按下方联网说明运行。Codespaces 的可用额度取决于试用者的 GitHub 账户。仓库目前为私有，向试用者分享时需先授予仓库访问权限。

## Windows 本机运行

第一次先跑样本。你只需要安装 **PowerShell 7**，就能生成和在线试用一样的三市场报告。样本使用虚构账户和合成行情。

### 第 1 步　把项目下载到电脑

1. 登录有仓库访问权限的 GitHub 账号。在本页文件列表上方，点绿色 **Code**，再点 **Download ZIP**。
2. 打开 Windows 的**下载**文件夹，找到刚下载的 ZIP。右键点击它，选择**全部解压缩**。
3. 打开解压后的文件夹，直到同一层能看到 **README.md** 和 **scripts** 文件夹。后面的命令都在这个位置运行。

### 第 2 步　安装 PowerShell 7

按 Windows 开始键，输入 **cmd**，打开**命令提示符**。复制下面一行，粘贴进去，按回车。

```cmd
winget install --id Microsoft.PowerShell --exact --source winget
```

安装结束后关掉命令提示符。如果电脑提示找不到 winget，可以下载微软提供的安装包，双击后按提示安装。[微软 PowerShell 7 安装指南](https://learn.microsoft.com/zh-cn/powershell/scripting/install/installing-powershell-on-windows)

### 第 3 步　在项目文件夹运行

回到同时能看到 **README.md** 和 **scripts** 的文件夹。点击资源管理器上方显示文件夹路径的**地址栏**，输入 **cmd**，按回车。新开的黑色窗口会直接位于这个项目文件夹。

先复制下面这一行并按回车。看到 `PowerShell 7.x.x` 就说明安装成功。

```cmd
pwsh --version
```

再复制下面这一行并按回车。首次运行会自动准备样本数据并生成报告。运行完成时，窗口会打印报告保存的位置。

```cmd
pwsh -NoProfile -File scripts/run-demo.ps1
```

### 第 4 步　打开报告

在刚才的窗口再运行这一行，记事本会打开报告。

```cmd
notepad state\runtime\demo-report.md
```

报告标题是 **三市场投资分析 · 样本报告**。从上往下可以看到月季方向、周线周期、A 股筛选、账户与挂单、BTC 回测，最后是**现在怎么做**。如果你已经安装 VS Code，也可以在里面打开该文件，按 **Ctrl+Shift+V** 查看排版后的表格。

项目文件夹里还会生成两份可以打开的结果。

| 文件 | 可以看到什么 |
|---|---|
| `PORTFOLIO.md` | 样本账户、持仓、挂单和机器人 |
| `state/runtime/btc-paired.csv` | 每轮 BTC 预警及等待确认后的比较结果，可用表格软件打开 |

### 卡住时先检查这三项

- **提示找不到 pwsh**。先关掉旧窗口，再按第 3 步重新打开一个。如果仍然找不到，回到第 2 步检查是否安装了 PowerShell 7。
- **提示找不到 scripts/run-demo.ps1**。回到资源管理器，确认现在打开的是同时能看到 README.md 和 scripts 的那一层，再从地址栏输入 cmd。
- **提示已有账户数据**。另解压一份 ZIP 到新文件夹，在新副本里试用，已有账户资料留在原处。

想接入实时行情时，继续看下面的[联网采集](#联网采集)。想逐项试用账户摘要、周期计算和测试时，可以在同一窗口运行以下命令。

```cmd
pwsh -NoProfile -File scripts/get-compact-account-context.ps1
pwsh -NoProfile -File scripts/get-weekly-cycle-context.ps1 -AsOf 2019-11-24T12:00:00Z
pwsh -NoProfile -File tests/Run-All.ps1
```

## 一次研究如何完成

以“复核组合里的买单”为例，项目先从本地事件流水还原各账户的持仓、可用资金和有效委托，再确定本轮要查的标的。美股相关产品按对应股票或指数研究，资金占用和订单仍按实际交易场所核算。单纯查询持仓时，可以直接读取账户摘要，省去行情刷新。

| 环节 | 研究问题 | 可以复核的输出 |
|---|---|---|
| 核对账户 | 这是计划中的买单、已挂委托，还是已成交持仓？ | 分账户摘要、稳定事件编号、待核验项 |
| 分市场研究 | A 股板块盈利处在周期哪一段？美股指数和 BTC 同向还是背离？ | 行业与公司证据、月度和季度情景、改变判断的条件 |
| 查看周期位置 | 当前价格处于过去一年什么位置？相对基准的强弱有无背离？ | 三市场周线 Z、52 周价格分位、回撤和观测日期 |
| 检验指标 | BTC 低位时加入 AHR999、高位时加入 Pi，等待确认是否值得？ | 同轮配对结果、13 周和 52 周表现、尚未到期的样本 |
| 回到挂单 | 如果逐档成交，现金占用和风险是否仍可承受？ | 保留或复核哪些委托、下次观察条件；实际操作由使用者决定 |

脚本负责采集、计算和记账；研究者或宿主助手依据知识库解释结果。预测在发布时记录观察日期、期限和失效条件，到期后再用同口径数据复核。完整步骤见[分析工作流](WORKFLOW.md)，报告结构见[分析输出模板](knowledge/analysis-template.md)。

## 仓库目录导航

| 目录 | 内容与入口 |
|---|---|
| [collectors/](collectors/) | 从 TradingView、A 股行情源、CoinGlass、Polymarket 和 X 读取数据。按来源排查原始报价或采集失败时从这里看。 |
| [config/](config/) | 账户定义、标的范围、刷新预算、缓存窗口、舆情范围和官方数据源配置。 |
| [docs/](docs/) | 数据源运行说明，含[如何核验失败与恢复](docs/analysis-source-incidents.md)。 |
| [examples/](examples/) | 可复制的离线样本。[current](examples/state/current/) 放四个虚构账户的状态，[events](examples/state/events/) 放对应事件，[decisions](examples/state/decisions/) 放示例规则。 |
| [knowledge/](knowledge/) | 分析方法和输出口径。可从[行业与市场研究索引](knowledge/research-index.md)、[周期与顶底方法](knowledge/bottom-top-methodology.md)或[预测及到期复核](knowledge/market-forecast.md)进入。 |
| [research/](research/) | 可重复运行的回测。[三市场 Z 确认实验](research/z-confirmation.py)比较调仓规则，[BTC 配对实验](research/btc-paired.ps1)比较立即行动和等待确认。 |
| [schemas/](schemas/) | 账户状态与行情刷新结果的 JSON 结构定义，方便接入其他程序。 |
| [scripts/](scripts/) | 日常操作入口，包括初始化、账户摘要、行情刷新、预测登记、事件回放和数据校验。 |
| [tests/](tests/) | 账户事件、长期规则、预测台账和采集器测试。[fixtures](tests/fixtures/) 放测试用输入或辅助用例。 |
| [tradingview-mcp/](tradingview-mcp/) | TradingView 桌面桥接组件。[src](tradingview-mcp/src/) 含核心逻辑、命令行和工具，[scripts](tradingview-mcp/scripts/) 含启动脚本，[skills](tradingview-mcp/skills/) 和 [agents](tradingview-mcp/agents/) 提供图表研究说明，[tests](tradingview-mcp/tests/) 验证桥接行为。 |

根目录的 [AGENTS.md](AGENTS.md) 与 [OPENCODE.md](OPENCODE.md) 分别供 Codex 和 OpenCode 读取，共用同一套工作流与本地账户状态。[opencode.jsonc](opencode.jsonc) 提供 OpenCode 的可选连接配置。

### 初始化后在本机生成的文件

| 位置 | 用途 |
|---|---|
| `PORTFOLIO.md` | 打开即可查看的账户总览，由当前账户数据生成。 |
| `state/current/`、`state/events/`、`state/decisions/` | 当前账户、事件流水与长期决策。样本初始化后，在本机分别维护。 |
| `state/cycle-weekly/v1/` | 三市场的成对周线，每行包含日期、资产价格和基准值。 |
| `state/forecasts/`、`state/snapshots/` | 用于存放预测记录和按次保存的行情快照，便于到期复盘和核对当时证据。 |
| `state/runtime/` | 运行所需的临时数据和研究结果，包括 BTC 配对回测输出。 |

## 常用操作与规则
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
