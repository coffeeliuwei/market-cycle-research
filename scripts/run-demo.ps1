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
$report = @(
    '# 三市场在线演示'
    ''
    '本页由项目脚本运行生成，使用虚构账户与合成行情。'
    ''
    "## 三市场周线读数（$($cycle.expectedWeek)）"
    ''
    '| 市场 | 周线 Z | 52 周价格分位 | 52 周回撤 |'
    '| --- | ---: | ---: | ---: |'
)
$report += foreach ($market in $cycle.markets) {
    "| $($market.market) | $($market.z) | $($market.percentile52)% | $($market.drawdown52Pct)% |"
}
$report += @(
    ''
    '## 继续试用'
    ''
    '- [账户总览](../../PORTFOLIO.md)'
    '- [回测脚本与运行步骤](../../README.md#首次使用离线样本)'
    ''
)
& (Join-Path $PSScriptRoot 'build-account-overview.ps1') | Out-Null
$reportPath = Join-Path $state 'runtime/demo-report.md'
$report | Set-Content -LiteralPath $reportPath -Encoding utf8
Write-Output $reportPath
