$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$state = Join-Path $root 'state'
if (-not (Test-Path -LiteralPath $state)) {
    & (Join-Path $PSScriptRoot 'init-demo.ps1') | Out-Null
}
foreach ($account in 'ashare','binance','gate','ok') {
    $current = Get-Content -Raw -LiteralPath (Join-Path $state "current/$account.json") | ConvertFrom-Json
    if ($current.source -ne 'synthetic-example') {
        throw 'The demo requires synthetic account data. Use a fresh checkout.'
    }
}

$sampleEnd = [datetimeoffset]'2019-11-24T12:00:00Z'
$cycle = & (Join-Path $PSScriptRoot 'get-weekly-cycle-context.ps1') -AsOf $sampleEnd | ConvertFrom-Json
if (@($cycle.markets | Where-Object status -eq 'ready').Count -ne 3) {
    throw 'Expected three complete synthetic weekly series.'
}
$accountIds = @('ashare','binance','gate','ok')
$context = & (Join-Path $PSScriptRoot 'get-compact-account-context.ps1') -AccountId $accountIds | ConvertFrom-Json
$report = @(
    '# 三市场投资分析 · 样本报告'
    ''
    "**样本行情截至 $($cycle.expectedWeek)**。账户、行情与行业证据均为虚构。"
    ''
    '## 1. 月度与季度方向'
    ''
    '演示按截至样本日的过去 4 周和 13 周涨跌判定方向，分别使用 ±2% 和 ±5% 的震荡区间。改判时重算对应窗口。'
    ''
    '| 市场 | 未来一个月 | 未来一个季度 | 短线与波段证据 |'
    '| --- | --- | --- | --- |'
)
foreach ($market in $cycle.markets) {
    $history = @(Import-Csv (Join-Path $state "cycle-weekly/v1/$($market.market).csv") |
        Where-Object week -LE $cycle.expectedWeek)
    $latest = [double]$history[-1].price
    $returns = @{}
    foreach ($weeks in 1,4,13) {
        $returns[$weeks] = 100 * ($latest / [double]$history[-1-$weeks].price - 1)
    }
    $month = if ($returns[4] -gt 2) { '偏上' } elseif ($returns[4] -lt -2) { '偏下' } else { '震荡' }
    $quarter = if ($returns[13] -gt 5) { '偏上' } elseif ($returns[13] -lt -5) { '偏下' } else { '震荡' }
    $evidence = '1 周 {0:+0.0;-0.0;0.0}%，4 周 {1:+0.0;-0.0;0.0}%，13 周 {2:+0.0;-0.0;0.0}%' -f $returns[1],$returns[4],$returns[13]
    $report += "| $($market.market) | $month | $quarter | $evidence |"
}
$report += @(
    ''
    '## 2. 周线周期与改判条件'
    ''
    '| 市场 | 周线 Z | 52 周价格分位 | 距 52 周高点 | Z 观察区 |'
    '| --- | ---: | ---: | ---: | --- |'
)
$limits = @{
    CSI300TR = @{ low=-2; high=2 }
    SPY = @{ low=-0.78; high=2 }
    BTC = @{ low=0.3; high=2.2 }
}
foreach ($market in $cycle.markets) {
    $limit = $limits[$market.market]
    $zone = if ($market.z -le $limit.low) { '低位' } elseif ($market.z -ge $limit.high) { '高位' } else { '观察线之间' }
    $report += "| $($market.market) | $($market.z) | $($market.percentile52)% | $($market.drawdown52Pct)% | $zone |"
}
$report += @(
    ''
    '- **沪深300**：若价格分位靠近年内低端，复核股债相对强弱。价格再创新低时，观察 Z 能否高于前一低点，并等待价格收复两次低点之间的反弹高点。'
    '- **SPY 与 BTC**：方向一致时复核后续周收盘能否延续。出现背离时，分别核对 SPY 对债券、BTC 对短债的相对强弱。'
    ''
    '## 3. A 股从板块到个股'
    ''
    '下表演示筛选顺序。板块与公司为独立编造的教学情景。'
    ''
    '| 板块样本 | 盈利周期证据 | 个股与技术复核 | 结论 |'
    '| --- | --- | --- | --- |'
    '| 工业自动化 | 新订单增长，毛利率改善，经营现金流回升 | 样本甲现金流同步改善，价格仍在整理，观察放量突破后能否守住 | 首选复核样本甲 |'
    '| 周期材料 | 当季利润仍高，订单放缓，库存上升 | 样本乙股价仍强，板块盈利接近峰值的风险上升 | 暂缓进入 |'
    ''
    '## 4. 账户、挂单与仓位复核'
    ''
    '| 账户 | 样本余额 | 样本持仓 | 待成交委托 | 机器人 |'
    '| --- | --- | --- | --- | --- |'
)
foreach ($account in $context.accounts) {
    $balances = @($account.balances | ForEach-Object { "$($_.quantity) $($_.asset)" }) -join '、'
    $positions = @($account.positions | ForEach-Object { "$($_.symbol) × $($_.quantity)" }) -join '、'
    $orders = @($account.orders | ForEach-Object { "$($_.symbol) $($_.side) $($_.quantity) @ $($_.price)" }) -join '、'
    $bots = @($account.bots | ForEach-Object { "$($_.symbol) $($_.status)" }) -join '、'
    $report += "| $($account.accountId) | $($balances ? $balances : '—') | $($positions ? $positions : '—') | $($orders ? $orders : '—') | $($bots ? $bots : '—') |"
}
& (Join-Path $root 'research/btc-paired.ps1') | Out-Null
$events = @(Import-Csv (Join-Path $state 'runtime/btc-paired.csv'))
$completed = @($events | Where-Object relative_52w_pct -ne '').Count
$report += @(
    ''
    '## 5. 回测与证据状态'
    ''
    "BTC 样本配对实验本次生成 **$($events.Count) 轮预警**，其中 **$completed 轮**有完整 52 周比较。对照的是 Z 触发即行动与等待 AHR999 或 Pi 确认。可打开 [逐轮信号 CSV](btc-paired.csv)。样本结果用于演示复核过程。"
    ''
    '实时行情、链上资金流、财报和交易所账户核验在本次离线演示中均未运行。报告内没有据此填写实时读数，也没有登记新的预测或委托。'
    ''
    '## 现在怎么做'
    ''
    '1. **A 股**：先复核工业自动化样本甲，等价格突破后的承接确认。样本持仓仍需实际财报、报价与可用资金才能评估。'
    '2. **美股**：跟踪 SPY 的月度与季度情景。此样本没有记录可供逐笔复核的美股相关产品。'
    '3. **币圈**：保留 OKX 样本限价单，先核对该账户可用余额和全部成交后的风险。币安样本余额按币安单独核算。Gate 网格缺区间和投入金额，先补参数再判断。'
    ''
    '[账户总览](../../PORTFOLIO.md) · [完整工作流](../../WORKFLOW.md)'
)
& (Join-Path $PSScriptRoot 'build-account-overview.ps1') | Out-Null
$reportPath = Join-Path $state 'runtime/demo-report.md'
$report | Set-Content -LiteralPath $reportPath -Encoding utf8
Write-Output $reportPath
