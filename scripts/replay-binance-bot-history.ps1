param(
    [Parameter(Mandatory)] [string]$SpotGridPath,
    [Parameter(Mandatory)] [string]$FuturesGridPath,
    [Parameter(Mandatory)] [string]$LedgerPath,
    [string]$OutputPath,
    [string]$ReportPath,
    [string[]]$CurrentFuturesGridIds = @(),
    [string]$CurrentSpotStartsJson = '{}'
)

$ErrorActionPreference = 'Stop'

function Convert-Decimal {
    param([AllowEmptyString()] [string]$Text)
    $value = ([string]$Text).Trim().Replace(',', '')
    if ([string]::IsNullOrWhiteSpace($value)) { return [decimal]0 }
    return [decimal]::Parse($value, [Globalization.CultureInfo]::InvariantCulture)
}

function Split-NumberAndAsset {
    param([AllowEmptyString()] [string]$Text)
    $value = ([string]$Text).Trim().Replace(',', '')
    if ($value -match '^([+-]?(?:\d+(?:\.\d+)?|\.\d+))(.*)$') {
        return [pscustomobject]@{
            quantity = Convert-Decimal $Matches[1]
            asset = $Matches[2].Trim().ToUpperInvariant()
        }
    }
    return [pscustomobject]@{ quantity = [decimal]0; asset = '' }
}

function Convert-BinanceTime {
    param([Parameter(Mandatory)] [string]$Text)
    $local = [datetime]::ParseExact($Text.Trim(), 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    return [DateTimeOffset]::new($local, [TimeSpan]::FromHours(8))
}

function Get-XlsxRows {
    param([Parameter(Mandatory)] [string]$Path)

    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "Workbook not found: $resolved" }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($resolved)
    try {
        $entry = $archive.GetEntry('xl/worksheets/sheet1.xml')
        if (-not $entry) { throw "Workbook has no sheet1.xml: $resolved" }
        $reader = [IO.StreamReader]::new($entry.Open())
        try { [xml]$sheet = $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    finally { $archive.Dispose() }

    $ns = [Xml.XmlNamespaceManager]::new($sheet.NameTable)
    $ns.AddNamespace('m', 'http://schemas.openxmlformats.org/spreadsheetml/2006/main')
    $output = [Collections.Generic.List[object]]::new()
    foreach ($row in $sheet.SelectNodes('//m:sheetData/m:row', $ns)) {
        $values = @{}
        foreach ($cell in $row.SelectNodes('m:c', $ns)) {
            if ([string]$cell.r -notmatch '^([A-Z]+)') { continue }
            $column = $Matches[1]
            $inline = $cell.SelectSingleNode('m:is/m:t', $ns)
            $value = $cell.SelectSingleNode('m:v', $ns)
            $values[$column] = if ($inline) { [string]$inline.InnerText } elseif ($value) { [string]$value.InnerText } else { '' }
        }
        $output.Add([pscustomobject]@{ row = [int]$row.r; values = $values })
    }
    return @($output)
}

function Sum-DecimalProperty {
    param([object[]]$Items, [string]$Property)
    $sum = [decimal]0
    foreach ($item in @($Items)) { $sum += [decimal]$item.$Property }
    return $sum
}

$resolvedSpot = [IO.Path]::GetFullPath($SpotGridPath)
$resolvedFutures = [IO.Path]::GetFullPath($FuturesGridPath)
$resolvedLedger = [IO.Path]::GetFullPath($LedgerPath)
if (-not (Test-Path -LiteralPath $resolvedLedger -PathType Leaf)) { throw "Ledger not found: $resolvedLedger" }

$spotRows = Get-XlsxRows $resolvedSpot
$spotHeader = @($spotRows | Where-Object { $_.values['D'] -eq '订单号' -and $_.values['E'] -eq '交易对' } | Select-Object -First 1)
if (-not $spotHeader) { throw 'Could not locate spot-grid header.' }
$spotOrders = [Collections.Generic.List[object]]::new()
foreach ($entry in $spotRows | Where-Object row -gt $spotHeader.row) {
    $v = $entry.values
    if ([string]::IsNullOrWhiteSpace($v['D']) -or [string]::IsNullOrWhiteSpace($v['E'])) { continue }
    $executed = Split-NumberAndAsset $v['K']
    $quote = Split-NumberAndAsset $v['M']
    $spotOrders.Add([pscustomobject][ordered]@{
        row = $entry.row
        orderId = [string]$v['D']
        symbol = $v['E'].Trim().ToUpperInvariant()
        side = $v['G'].Trim().ToUpperInvariant()
        orderTime = (Convert-BinanceTime $v['C']).ToString('yyyy-MM-ddTHH:mm:sszzz')
        eventTime = (Convert-BinanceTime $v['J']).ToString('yyyy-MM-ddTHH:mm:sszzz')
        executedQuantity = $executed.quantity
        averagePrice = Convert-Decimal $v['L']
        quoteTotal = $quote.quantity
        status = $v['N'].Trim().ToUpperInvariant()
    })
}

$futureRows = Get-XlsxRows $resolvedFutures
$futureHeader = @($futureRows | Where-Object { $_.values['D'] -match '^订单(号|编号)$' -and $_.values['E'] -match '币|交易对' } | Select-Object -First 1)
if (-not $futureHeader) { throw 'Could not locate futures-grid header.' }
$futureOrders = [Collections.Generic.List[object]]::new()
foreach ($entry in $futureRows | Where-Object row -gt $futureHeader.row) {
    $v = $entry.values
    if ([string]::IsNullOrWhiteSpace($v['D']) -or [string]::IsNullOrWhiteSpace($v['E'])) { continue }
    $executionObserved = -not [string]::IsNullOrWhiteSpace($v['K'])
    $futureOrders.Add([pscustomobject][ordered]@{
        row = $entry.row
        orderId = [string]$v['D']
        symbol = $v['E'].Trim().ToUpperInvariant()
        side = $v['G'].Trim().ToUpperInvariant()
        gridId = [string]$v['H']
        orderTime = (Convert-BinanceTime $v['C']).ToString('yyyy-MM-ddTHH:mm:sszzz')
        limitPrice = Convert-Decimal $v['J']
        executedPrice = Convert-Decimal $v['K']
        quantity = Convert-Decimal $v['L']
        executionObserved = $executionObserved
        resolution = if ($executionObserved) { 'executed_price_observed' } else { 'unresolved' }
    })
}

$spotDuplicateKeys = @($spotOrders | Group-Object orderId | Where-Object Count -gt 1)
$futureDuplicateKeys = @($futureOrders | Group-Object { "$($_.gridId)|$($_.orderId)" } | Where-Object Count -gt 1)
if ($spotDuplicateKeys.Count -gt 0) { throw "Duplicate spot-grid order IDs: $($spotDuplicateKeys.Count)" }
if ($futureDuplicateKeys.Count -gt 0) { throw "Duplicate futures grid/order IDs: $($futureDuplicateKeys.Count)" }

$spotStartsObject = $CurrentSpotStartsJson | ConvertFrom-Json
$spotStarts = @{}
foreach ($property in $spotStartsObject.PSObject.Properties) {
    $spotStarts[$property.Name.ToUpperInvariant()] = [DateTimeOffset]::Parse([string]$property.Value)
}

$spotSummary = @($spotOrders | Group-Object symbol | ForEach-Object {
    $items = @($_.Group)
    [pscustomobject][ordered]@{
        symbol = $_.Name
        orders = $items.Count
        filled = @($items | Where-Object status -eq 'FILLED').Count
        canceled = @($items | Where-Object status -eq 'CANCELED').Count
        new = @($items | Where-Object status -eq 'NEW').Count
        firstOrderTime = @($items | Sort-Object orderTime | Select-Object -First 1).orderTime
        lastEventTime = @($items | Sort-Object eventTime -Descending | Select-Object -First 1).eventTime
    }
} | Sort-Object orders -Descending)

$currentSpotSummary = @($spotStarts.Keys | Sort-Object | ForEach-Object {
    $symbol = $_
    $start = $spotStarts[$symbol]
    $items = @($spotOrders | Where-Object { $_.symbol -eq $symbol -and [DateTimeOffset]::Parse($_.orderTime) -ge $start })
    $filled = @($items | Where-Object status -eq 'FILLED')
    [pscustomobject][ordered]@{
        symbol = $symbol
        configuredStart = $start.ToString('o')
        ordersSinceStart = $items.Count
        filledSinceStart = $filled.Count
        buyFills = @($filled | Where-Object side -eq 'BUY').Count
        sellFills = @($filled | Where-Object side -eq 'SELL').Count
        newSinceStart = @($items | Where-Object status -eq 'NEW').Count
        canceledSinceStart = @($items | Where-Object status -eq 'CANCELED').Count
    }
})

$gridSummary = @($futureOrders | Group-Object gridId | ForEach-Object {
    $items = @($_.Group)
    $observed = @($items | Where-Object executionObserved)
    $buy = @($observed | Where-Object side -eq 'BUY')
    $sell = @($observed | Where-Object side -eq 'SELL')
    $turnover = [decimal]0
    foreach ($order in $observed) { $turnover += [decimal]$order.executedPrice * [decimal]$order.quantity }
    [pscustomobject][ordered]@{
        gridId = $_.Name
        symbol = @($items.symbol | Sort-Object -Unique) -join ','
        orders = $items.Count
        executionObserved = $observed.Count
        unresolved = @($items | Where-Object { -not $_.executionObserved }).Count
        buyExecutions = $buy.Count
        sellExecutions = $sell.Count
        approximateMatchedCount = [Math]::Min($buy.Count, $sell.Count)
        quoteTurnover = $turnover
        firstOrderTime = @($items | Sort-Object orderTime | Select-Object -First 1).orderTime
        lastOrderTime = @($items | Sort-Object orderTime -Descending | Select-Object -First 1).orderTime
        currentGridCandidate = ($_.Name -in $CurrentFuturesGridIds)
    }
} | Sort-Object orders -Descending)
$currentGridSummary = @($gridSummary | Where-Object currentGridCandidate | Sort-Object symbol)

$ledgerRows = @(Import-Csv -LiteralPath $resolvedLedger)
$ledger = [Collections.Generic.List[object]]::new()
$ledgerIndex = 1
foreach ($row in $ledgerRows) {
    $ledger.Add([pscustomobject][ordered]@{
        row = $ledgerIndex
        time = (Convert-BinanceTime $row.'时间').ToString('yyyy-MM-ddTHH:mm:sszzz')
        account = [string]$row.'账户'
        operation = [string]$row.'操作'
        asset = ([string]$row.'币种').ToUpperInvariant()
        change = Convert-Decimal $row.'变更'
    })
    $ledgerIndex++
}

$futuresLedger = @($ledger | Where-Object account -eq 'USD-M Futures')
$futuresLedgerSummary = @($futuresLedger | Group-Object operation, asset | ForEach-Object {
    $items = @($_.Group)
    [pscustomobject][ordered]@{
        operation = $items[0].operation
        asset = $items[0].asset
        rows = $items.Count
        netChange = Sum-DecimalProperty $items 'change'
    }
} | Sort-Object operation, asset)

$stableAssets = @('USDT', 'USDC')
$stableRealized = @($futuresLedgerSummary | Where-Object { $_.operation -in @('Realized P&L', 'Realized Profit and Loss') -and $_.asset -in $stableAssets })
$stableFees = @($futuresLedgerSummary | Where-Object { $_.operation -eq 'Fee' -and $_.asset -in $stableAssets })
$stableFunding = @($futuresLedgerSummary | Where-Object { $_.operation -eq 'Funding Fee' -and $_.asset -in $stableAssets })
$realizedTotal = Sum-DecimalProperty $stableRealized 'netChange'
$feeTotal = Sum-DecimalProperty $stableFees 'netChange'
$fundingTotal = Sum-DecimalProperty $stableFunding 'netChange'

$result = [ordered]@{
    schemaVersion = 1
    generatedAt = [DateTimeOffset]::UtcNow.ToString('o')
    source = [ordered]@{
        spotGrid = [ordered]@{ path = $resolvedSpot; sheet = 'Sheet0'; headerRow = $spotHeader.row; firstDataRow = $spotHeader.row + 1; lastDataRow = ($spotOrders | Measure-Object row -Maximum).Maximum }
        futuresGrid = [ordered]@{ path = $resolvedFutures; sheet = 'Sheet0'; headerRow = $futureHeader.row; firstDataRow = $futureHeader.row + 1; lastDataRow = ($futureOrders | Measure-Object row -Maximum).Maximum }
        ledger = [ordered]@{ path = $resolvedLedger; firstDataRow = 2; lastDataRow = $ledgerRows.Count + 1 }
    }
    methodology = [ordered]@{
        spotStatus = 'Use exported final status.'
        futuresResolution = 'A non-empty executed-price cell proves an observed execution. A blank cell is unresolved, not assumed open or canceled.'
        currentSpotAttribution = 'Spot-grid workbooks have no bot ID; current generations are sliced only by caller-supplied bot start timestamps.'
        currentFuturesAttribution = 'Futures grids are matched by caller-supplied grid IDs.'
        ledgerScope = 'Futures ledger totals cover the full export period and all USD-M activity. The export does not identify symbols for funding fee or realized P&L rows.'
        privacy = 'User identifier, contact, address, and remarks are excluded from derived output.'
    }
    summary = [ordered]@{
        spotGridOrders = $spotOrders.Count
        futuresGridOrders = $futureOrders.Count
        futuresExecutionObserved = @($futureOrders | Where-Object executionObserved).Count
        futuresUnresolved = @($futureOrders | Where-Object { -not $_.executionObserved }).Count
        ledgerRows = $ledger.Count
        futuresStableRealizedPnl = $realizedTotal
        futuresStableFees = $feeTotal
        futuresStableFunding = $fundingTotal
        futuresStableNetAfterFeeAndFunding = $realizedTotal + $feeTotal + $fundingTotal
    }
    spotGridBySymbol = $spotSummary
    currentSpotGridSlices = $currentSpotSummary
    futuresGridById = $gridSummary
    currentFuturesGridCandidates = $currentGridSummary
    futuresLedgerByOperationAsset = $futuresLedgerSummary
}

if ($result.summary.spotGridOrders -ne 5462) { throw "Expected 5462 spot-grid rows; found $($result.summary.spotGridOrders)." }
if ($result.summary.futuresGridOrders -ne 45352) { throw "Expected 45352 futures-grid rows; found $($result.summary.futuresGridOrders)." }
if ($result.summary.ledgerRows -ne 78260) { throw "Expected 78260 ledger rows; found $($result.summary.ledgerRows)." }
if ($result.summary.futuresExecutionObserved + $result.summary.futuresUnresolved -ne $result.summary.futuresGridOrders) { throw 'Futures resolution counts do not reconcile.' }

$json = [pscustomobject]$result | ConvertTo-Json -Depth 10
if ($json -match '(?i)"user\s*id"\s*:|"userid"\s*:|"用户\s*ID"\s*:') { throw 'Derived JSON contains a prohibited personal-data field.' }
if ($OutputPath) {
    $resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
    New-Item -ItemType Directory -Path (Split-Path -Parent $resolvedOutput) -Force | Out-Null
    $json | Set-Content -LiteralPath $resolvedOutput -Encoding utf8
}

if ($ReportPath) {
    $resolvedReport = [IO.Path]::GetFullPath($ReportPath)
    New-Item -ItemType Directory -Path (Split-Path -Parent $resolvedReport) -Force | Out-Null
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('# Binance机器人订单与流水补充回放')
    $lines.Add('')
    $lines.Add('- 本报告评价机器人执行层；自主选币、资金迁移和撤单纪律仍以普通现货决策回放为主。')
    $lines.Add('- 期货订单只有成交均价非空时才记为“观察到成交”；其余行一律记为“结果未决”，不冒充当前挂单。')
    $lines.Add('- USD-M流水汇总覆盖整个导出期和全部策略；因流水不含交易对，不能安全拆成单币种收益或资金费。')
    $lines.Add('- 派生文件不含用户ID、联系方式、地址或流水备注。')
    $lines.Add('')
    $lines.Add('## 总量核对')
    $lines.Add('')
    $lines.Add("- 现货网格订单：$($result.summary.spotGridOrders)")
    $lines.Add("- 期货机器人订单：$($result.summary.futuresGridOrders)；观察到成交：$($result.summary.futuresExecutionObserved)；结果未决：$($result.summary.futuresUnresolved)")
    $lines.Add("- 流水：$($result.summary.ledgerRows)")
    $lines.Add("- USD-M稳定币已实现盈亏：$([math]::Round([double]$realizedTotal, 2))；手续费：$([math]::Round([double]$feeTotal, 2))；资金费：$([math]::Round([double]$fundingTotal, 2))；三项净额：$([math]::Round([double]($realizedTotal + $feeTotal + $fundingTotal), 2))")
    $lines.Add('')
    $lines.Add('## 当前期货机器人候选')
    $lines.Add('')
    $lines.Add('| 标的 | 网格ID | 订单 | 观察到成交 | 结果未决 | 买入成交 | 卖出成交 | 近似往返下限 | 成交额近似 |')
    $lines.Add('|---|---|---:|---:|---:|---:|---:|---:|---:|')
    foreach ($grid in $currentGridSummary) {
        $lines.Add("| $($grid.symbol) | $($grid.gridId) | $($grid.orders) | $($grid.executionObserved) | $($grid.unresolved) | $($grid.buyExecutions) | $($grid.sellExecutions) | $($grid.approximateMatchedCount) | $([math]::Round([double]$grid.quoteTurnover, 2)) |")
    }
    $lines.Add('')
    $lines.Add('“近似往返下限”仅为买卖成交笔数较小者，不等于币安实际配对次数或利润。买入远多于卖出表示方向性库存正在累积。')
    $lines.Add('')
    $lines.Add('## 当前现货网格切片')
    $lines.Add('')
    $lines.Add('| 标的 | 配置启动时间 | 启动后订单 | 成交 | 买成交 | 卖成交 | NEW | 撤销 |')
    $lines.Add('|---|---|---:|---:|---:|---:|---:|---:|')
    foreach ($item in $currentSpotSummary) {
        $lines.Add("| $($item.symbol) | $($item.configuredStart) | $($item.ordersSinceStart) | $($item.filledSinceStart) | $($item.buyFills) | $($item.sellFills) | $($item.newSinceStart) | $($item.canceledSinceStart) |")
    }
    $lines | Set-Content -LiteralPath $resolvedReport -Encoding utf8
}

[pscustomobject]$result
