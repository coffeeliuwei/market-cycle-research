param(
    [Parameter(Mandatory)]
    [string]$InputPath,

    [string]$OutputPath,

    [string]$ReportPath,

    [int]$DecisionClusterMinutes = 30
)

$ErrorActionPreference = 'Stop'

function Get-CellText {
    param(
        [Parameter(Mandatory)] [System.Xml.XmlElement]$Cell,
        [Parameter(Mandatory)] [System.Xml.XmlNamespaceManager]$NamespaceManager
    )

    $inline = $Cell.SelectSingleNode('m:is/m:t', $NamespaceManager)
    if ($inline) { return [string]$inline.InnerText }
    $value = $Cell.SelectSingleNode('m:v', $NamespaceManager)
    if ($value) { return [string]$value.InnerText }
    return ''
}

function Split-NumberAndAsset {
    param([AllowEmptyString()] [string]$Text)

    $trimmed = ([string]$Text).Trim().Replace(',', '')
    if ($trimmed -match '^([+-]?(?:\d+(?:\.\d+)?|\.\d+))(.*)$') {
        return [pscustomobject]@{
            quantity = [decimal]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
            asset = $Matches[2].Trim().ToUpperInvariant()
        }
    }
    return [pscustomobject]@{ quantity = [decimal]0; asset = '' }
}

function Convert-Decimal {
    param([AllowEmptyString()] [string]$Text)

    $value = ([string]$Text).Trim().Replace(',', '')
    if ([string]::IsNullOrWhiteSpace($value)) { return [decimal]0 }
    return [decimal]::Parse($value, [Globalization.CultureInfo]::InvariantCulture)
}

function Convert-BinanceTime {
    param([Parameter(Mandatory)] [string]$Text)

    $localTime = [datetime]::ParseExact(
        $Text.Trim(),
        'yyyy-MM-dd HH:mm:ss',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None
    )
    return [DateTimeOffset]::new($localTime, [TimeSpan]::FromHours(8))
}

function Get-BaseAndQuote {
    param([Parameter(Mandatory)] [string]$Symbol)

    $normalized = $Symbol.Trim().ToUpperInvariant()
    foreach ($quote in @('FDUSD', 'USDC', 'USDT', 'BUSD', 'TUSD', 'BTC', 'ETH', 'BNB', 'EUR', 'TRY')) {
        if ($normalized.EndsWith($quote) -and $normalized.Length -gt $quote.Length) {
            return [pscustomobject]@{
                baseAsset = $normalized.Substring(0, $normalized.Length - $quote.Length)
                quoteAsset = $quote
            }
        }
    }
    return [pscustomobject]@{ baseAsset = $normalized; quoteAsset = '' }
}

function Get-DecisionIntent {
    param([Parameter(Mandatory)] [object]$Order)

    if ($Order.status -eq 'CANCELED' -and $Order.executedQuantity -eq 0) { return 'unexecuted_price_hypothesis' }
    if ($Order.status -eq 'NEW') { return 'active_price_hypothesis' }
    if ($Order.status -eq 'PARTIALLY_FILLED') {
        if ($Order.side -eq 'BUY') { return 'partial_accumulation' }
        return 'partial_reduction'
    }
    if ($Order.side -eq 'BUY') { return 'capital_activation' }
    return 'capital_reduction_or_rotation'
}

$resolvedInput = [IO.Path]::GetFullPath($InputPath)
if (-not (Test-Path -LiteralPath $resolvedInput -PathType Leaf)) {
    throw "Workbook not found: $resolvedInput"
}
if ([IO.Path]::GetExtension($resolvedInput) -ne '.xlsx') {
    throw 'Only .xlsx order-history exports are supported.'
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($resolvedInput)
try {
    $sheetEntry = $archive.GetEntry('xl/worksheets/sheet1.xml')
    if (-not $sheetEntry) { throw 'Workbook does not contain xl/worksheets/sheet1.xml.' }
    $reader = [IO.StreamReader]::new($sheetEntry.Open())
    try { [xml]$sheet = $reader.ReadToEnd() } finally { $reader.Dispose() }
}
finally {
    $archive.Dispose()
}

$ns = [Xml.XmlNamespaceManager]::new($sheet.NameTable)
$ns.AddNamespace('m', 'http://schemas.openxmlformats.org/spreadsheetml/2006/main')
$rows = @($sheet.SelectNodes('//m:sheetData/m:row', $ns))
$headerRow = $null
foreach ($row in $rows) {
    $values = @{}
    foreach ($cell in $row.SelectNodes('m:c', $ns)) {
        if ([string]$cell.r -match '^([A-Z]+)') { $values[$Matches[1]] = Get-CellText -Cell $cell -NamespaceManager $ns }
    }
    if ($values['D'] -eq '订单号' -and $values['E'] -eq '交易对') { $headerRow = [int]$row.r; break }
}
if (-not $headerRow) { throw 'Could not locate the Binance order-history header row.' }

$orders = [Collections.Generic.List[object]]::new()
foreach ($row in $rows | Where-Object { [int]$_.r -gt $headerRow }) {
    $values = @{}
    foreach ($cell in $row.SelectNodes('m:c', $ns)) {
        if ([string]$cell.r -match '^([A-Z]+)') { $values[$Matches[1]] = Get-CellText -Cell $cell -NamespaceManager $ns }
    }
    if ([string]::IsNullOrWhiteSpace($values['D']) -or [string]::IsNullOrWhiteSpace($values['E'])) { continue }

    $orderAmount = Split-NumberAndAsset $values['I']
    $executed = Split-NumberAndAsset $values['K']
    $quoteTotal = Split-NumberAndAsset $values['M']
    $pair = Get-BaseAndQuote $values['E']
    $orderTime = Convert-BinanceTime $values['C']
    $eventTime = Convert-BinanceTime $values['J']
    $status = $values['N'].Trim().ToUpperInvariant()
    $side = $values['G'].Trim().ToUpperInvariant()

    $attribution = 'unknown'

    $order = [pscustomobject][ordered]@{
        row = [int]$row.r
        orderId = [string]$values['D']
        symbol = $values['E'].Trim().ToUpperInvariant()
        baseAsset = $pair.baseAsset
        quoteAsset = $pair.quoteAsset
        type = $values['F'].Trim().ToUpperInvariant()
        side = $side
        orderTime = $orderTime.ToString('yyyy-MM-ddTHH:mm:sszzz')
        eventTime = $eventTime.ToString('yyyy-MM-ddTHH:mm:sszzz')
        limitPrice = Convert-Decimal $values['H']
        orderQuantity = $orderAmount.quantity
        executedQuantity = $executed.quantity
        averagePrice = Convert-Decimal $values['L']
        quoteTotal = $quoteTotal.quantity
        status = $status
        exposureActivated = ($executed.quantity -gt 0)
        intentClass = ''
        attribution = $attribution
        postResult = $null
    }
    $order.intentClass = Get-DecisionIntent $order
    $orders.Add($order)
}

$filled = @($orders | Where-Object { $_.executedQuantity -gt 0 } | Sort-Object eventTime, row)
$lotsByAsset = @{}
$matches = [Collections.Generic.List[object]]::new()
$unmatchedSells = [Collections.Generic.List[object]]::new()

foreach ($order in $filled) {
    $asset = $order.baseAsset
    if (-not $lotsByAsset.ContainsKey($asset)) { $lotsByAsset[$asset] = [Collections.Generic.List[object]]::new() }
    $lots = $lotsByAsset[$asset]
    if ($order.side -eq 'BUY') {
        $lots.Add([pscustomobject]@{
            orderId = $order.orderId
            symbol = $order.symbol
            quoteAsset = $order.quoteAsset
            eventTime = [DateTimeOffset]::Parse($order.eventTime)
            remainingQuantity = [decimal]$order.executedQuantity
            unitCost = if ($order.executedQuantity -gt 0) { [decimal]$order.quoteTotal / [decimal]$order.executedQuantity } else { [decimal]0 }
        })
        continue
    }

    $remainingSell = [decimal]$order.executedQuantity
    foreach ($lot in @($lots | Where-Object { $_.remainingQuantity -gt 0 -and ($_.quoteAsset -eq $order.quoteAsset -or ($_.quoteAsset -in @('USDC','USDT','FDUSD','BUSD')) -and ($order.quoteAsset -in @('USDC','USDT','FDUSD','BUSD'))) })) {
        if ($remainingSell -le 0) { break }
        $matchedQty = [Math]::Min($remainingSell, [decimal]$lot.remainingQuantity)
        $allocatedCost = $matchedQty * [decimal]$lot.unitCost
        $proceeds = if ($order.executedQuantity -gt 0) { [decimal]$order.quoteTotal * $matchedQty / [decimal]$order.executedQuantity } else { [decimal]0 }
        $pnl = $proceeds - $allocatedCost
        $holdingHours = ([DateTimeOffset]::Parse($order.eventTime) - $lot.eventTime).TotalHours
        $matches.Add([pscustomobject][ordered]@{
            baseAsset = $asset
            buyOrderId = $lot.orderId
            sellOrderId = $order.orderId
            buySymbol = $lot.symbol
            sellSymbol = $order.symbol
            quantity = $matchedQty
            allocatedCost = $allocatedCost
            proceeds = $proceeds
            realizedPnl = $pnl
            realizedPnlPct = if ($allocatedCost -gt 0) { [decimal]($pnl / $allocatedCost * 100) } else { $null }
            buyTime = $lot.eventTime.ToString('yyyy-MM-ddTHH:mm:sszzz')
            sellTime = $order.eventTime
            holdingHours = [Math]::Round($holdingHours, 4)
            stableQuoteAssumption = ($lot.quoteAsset -ne $order.quoteAsset)
        })
        $lot.remainingQuantity -= $matchedQty
        $remainingSell -= $matchedQty
    }
    if ($remainingSell -gt 0) {
        $unmatchedSells.Add([pscustomobject]@{
            orderId = $order.orderId
            symbol = $order.symbol
            eventTime = $order.eventTime
            unmatchedQuantity = $remainingSell
            reason = 'No earlier matching buy exists in this export period, or inventory came from transfer/grid/earlier history.'
        })
    }
}

$matchBySell = @{}
foreach ($match in $matches) {
    if (-not $matchBySell.ContainsKey($match.sellOrderId)) { $matchBySell[$match.sellOrderId] = [Collections.Generic.List[object]]::new() }
    $matchBySell[$match.sellOrderId].Add($match)
}
foreach ($order in $orders) {
    if ($matchBySell.ContainsKey($order.orderId)) {
        $related = @($matchBySell[$order.orderId])
        $cost = [decimal](($related | Measure-Object allocatedCost -Sum).Sum)
        $proceeds = [decimal](($related | Measure-Object proceeds -Sum).Sum)
        $order.postResult = [pscustomobject]@{
            matchedQuantity = [decimal](($related | Measure-Object quantity -Sum).Sum)
            allocatedCost = $cost
            proceeds = $proceeds
            realizedPnl = $proceeds - $cost
            realizedPnlPct = if ($cost -gt 0) { [decimal](($proceeds - $cost) / $cost * 100) } else { $null }
        }
    }
}

$pairSummary = @($orders | Group-Object symbol | ForEach-Object {
    $group = @($_.Group)
    [pscustomobject][ordered]@{
        symbol = $_.Name
        orders = $group.Count
        filled = @($group | Where-Object status -eq 'FILLED').Count
        partiallyFilled = @($group | Where-Object status -eq 'PARTIALLY_FILLED').Count
        open = @($group | Where-Object status -eq 'NEW').Count
        canceled = @($group | Where-Object status -eq 'CANCELED').Count
        executedQuoteTotal = [decimal](($group | Where-Object executedQuantity -gt 0 | Measure-Object quoteTotal -Sum).Sum)
    }
} | Sort-Object -Property @{ Expression = 'orders'; Descending = $true }, symbol)

$decisionClusters = [Collections.Generic.List[object]]::new()
foreach ($assetGroup in ($orders | Sort-Object orderTime, row | Group-Object baseAsset, side)) {
    $current = $null
    foreach ($order in @($assetGroup.Group | Sort-Object orderTime, row)) {
        $time = [DateTimeOffset]::Parse($order.orderTime)
        if (-not $current -or ($time - $current.lastOrderTime).TotalMinutes -gt $DecisionClusterMinutes) {
            if ($current) { $decisionClusters.Add($current.output) }
            $clusterOrders = [Collections.Generic.List[object]]::new()
            $clusterOrders.Add($order)
            $current = [pscustomobject]@{
                lastOrderTime = $time
                output = [pscustomobject][ordered]@{
                    baseAsset = $order.baseAsset
                    side = $order.side
                    startedAt = $order.orderTime
                    endedAt = $order.orderTime
                    orderIds = $clusterOrders
                }
            }
        }
        else {
            $current.output.orderIds.Add($order)
            $current.output.endedAt = $order.orderTime
            $current.lastOrderTime = $time
        }
    }
    if ($current) { $decisionClusters.Add($current.output) }
}

$clusterOutput = @($decisionClusters | ForEach-Object {
    $clusterOrders = @($_.orderIds)
    [pscustomobject][ordered]@{
        baseAsset = $_.baseAsset
        side = $_.side
        startedAt = $_.startedAt
        endedAt = $_.endedAt
        orderCount = $clusterOrders.Count
        orderIds = @($clusterOrders.orderId)
        prices = @($clusterOrders.limitPrice)
        statuses = @($clusterOrders.status | Sort-Object -Unique)
        executedOrderCount = @($clusterOrders | Where-Object exposureActivated).Count
        attribution = @($clusterOrders.attribution | Sort-Object -Unique)
    }
} | Sort-Object startedAt)

$statusCounts = [ordered]@{}
foreach ($statusGroup in ($orders | Group-Object status | Sort-Object Name)) { $statusCounts[$statusGroup.Name] = $statusGroup.Count }
$knownCost = [decimal](($matches | Measure-Object allocatedCost -Sum).Sum)
$knownProceeds = [decimal](($matches | Measure-Object proceeds -Sum).Sum)

$result = [ordered]@{
    schemaVersion = 1
    generatedAt = [DateTimeOffset]::UtcNow.ToString('o')
    source = [ordered]@{
        path = $resolvedInput
        sheet = 'Sheet0'
        headerRow = $headerRow
        firstDataRow = $headerRow + 1
        lastDataRow = ($orders | Measure-Object row -Maximum).Maximum
        scope = 'Binance ordinary spot order history only; excludes grid internals, futures, earn, deposits, withdrawals, and complete transfer history.'
    }
    methodology = [ordered]@{
        noLookahead = $true
        decisionClock = 'orderTime'
        exposureClock = 'eventTime when executedQuantity > 0'
        matching = 'FIFO by base asset; USDC/USDT/FDUSD/BUSD treated as 1:1 only for matched-lot estimation.'
        limitation = 'Realized PnL is reported only for sells matched to earlier buys in this export. Unmatched sells are not assigned invented cost basis.'
    }
    summary = [ordered]@{
        orderCount = $orders.Count
        statusCounts = $statusCounts
        exposureActivatedOrders = @($orders | Where-Object exposureActivated).Count
        pairCount = @($pairSummary).Count
        decisionClusterCount = @($clusterOutput).Count
        fifoMatchCount = $matches.Count
        unmatchedSellCount = $unmatchedSells.Count
        matchedCost = $knownCost
        matchedProceeds = $knownProceeds
        matchedRealizedPnl = $knownProceeds - $knownCost
        matchedRealizedPnlPct = if ($knownCost -gt 0) { [decimal](($knownProceeds - $knownCost) / $knownCost * 100) } else { $null }
    }
    pairSummary = $pairSummary
    decisionClusters = $clusterOutput
    fifoMatches = @($matches)
    unmatchedSells = @($unmatchedSells)
    orders = @($orders | Sort-Object -Property @{ Expression = 'orderTime'; Descending = $true }, row)
}

if ($result.summary.orderCount -ne 287) { throw "Expected 287 order rows, found $($result.summary.orderCount)." }
if ($result.summary.statusCounts.FILLED -ne 98) { throw "Expected 98 filled orders, found $($result.summary.statusCounts.FILLED)." }
if ($result.summary.statusCounts.CANCELED -ne 169) { throw "Expected 169 canceled orders, found $($result.summary.statusCounts.CANCELED)." }
if ($result.summary.statusCounts.NEW -ne 19) { throw "Expected 19 open orders, found $($result.summary.statusCounts.NEW)." }
if ($result.summary.statusCounts.PARTIALLY_FILLED -ne 1) { throw "Expected 1 partially filled order, found $($result.summary.statusCounts.PARTIALLY_FILLED)." }

$json = $result | ConvertTo-Json -Depth 14
if ($OutputPath) {
    $resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
    $outputDirectory = Split-Path -Parent $resolvedOutput
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    $json | Set-Content -LiteralPath $resolvedOutput -Encoding utf8
}

if ($ReportPath) {
    $resolvedReport = [IO.Path]::GetFullPath($ReportPath)
    $reportDirectory = Split-Path -Parent $resolvedReport
    New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('# Binance普通现货订单决策回放')
    $lines.Add('')
    $lines.Add('- 范围：普通现货订单；不含网格内部成交、期货、理财、充提和完整划转流水。')
    $lines.Add('- 决策时钟：下单时间。风险暴露时钟：实际成交时间。')
    $lines.Add('- 结果口径：仅对导出期内存在更早买单的卖出使用FIFO配对；没有成本来源的卖出不计算收益。')
    $lines.Add("- 订单：$($result.summary.orderCount)；决策簇：$($result.summary.decisionClusterCount)；FIFO配对：$($result.summary.fifoMatchCount)；无成本来源卖出：$($result.summary.unmatchedSellCount)。")
    $lines.Add('')
    $lines.Add('## 交易对汇总')
    $lines.Add('')
    $lines.Add('| 交易对 | 订单 | 成交 | 部分成交 | 当前挂单 | 撤销 | 已执行交易总额 |')
    $lines.Add('|---|---:|---:|---:|---:|---:|---:|')
    foreach ($pair in $pairSummary) {
        $lines.Add("| $($pair.symbol) | $($pair.orders) | $($pair.filled) | $($pair.partiallyFilled) | $($pair.open) | $($pair.canceled) | $([math]::Round([double]$pair.executedQuoteTotal, 4)) |")
    }
    $lines.Add('')
    $lines.Add('## 可验证FIFO配对')
    $lines.Add('')
    $lines.Add('| 资产 | 买单 | 卖单 | 数量 | 成本 | 收入 | 盈亏 | 收益率 | 持有小时 |')
    $lines.Add('|---|---|---|---:|---:|---:|---:|---:|---:|')
    foreach ($match in $matches) {
        $pct = if ($null -eq $match.realizedPnlPct) { '' } else { [math]::Round([double]$match.realizedPnlPct, 2) }
        $lines.Add("| $($match.baseAsset) | $($match.buyOrderId) | $($match.sellOrderId) | $([math]::Round([double]$match.quantity, 8)) | $([math]::Round([double]$match.allocatedCost, 4)) | $([math]::Round([double]$match.proceeds, 4)) | $([math]::Round([double]$match.realizedPnl, 4)) | $pct% | $($match.holdingHours) |")
    }
    $lines.Add('')
    $lines.Add('## 决策簇')
    $lines.Add('')
    $lines.Add('30分钟内同资产、同方向的连续改单或阶梯单合并为一个决策簇；原始订单仍在下一节逐笔保留。')
    $lines.Add('')
    $lines.Add('| 开始时间 | 资产 | 方向 | 订单数 | 有成交订单 | 价格 | 状态 | 归因 |')
    $lines.Add('|---|---|---|---:|---:|---|---|---|')
    foreach ($cluster in $clusterOutput) {
        $lines.Add("| $($cluster.startedAt) | $($cluster.baseAsset) | $($cluster.side) | $($cluster.orderCount) | $($cluster.executedOrderCount) | $($cluster.prices -join ', ') | $($cluster.statuses -join ', ') | $($cluster.attribution -join ', ') |")
    }
    $lines.Add('')
    $lines.Add('## 全部订单逐笔记录')
    $lines.Add('')
    $lines.Add('| 行 | 下单时间 | 结果时间 | 订单号 | 交易对 | 方向 | 限价 | 委托数量 | 成交数量 | 均价 | 交易总额 | 状态 | 意图分类 | 归因 |')
    $lines.Add('|---:|---|---|---|---|---|---:|---:|---:|---:|---:|---|---|---|')
    foreach ($order in @($orders | Sort-Object orderTime, row)) {
        $lines.Add("| $($order.row) | $($order.orderTime) | $($order.eventTime) | $($order.orderId) | $($order.symbol) | $($order.side) | $($order.limitPrice) | $($order.orderQuantity) | $($order.executedQuantity) | $($order.averagePrice) | $($order.quoteTotal) | $($order.status) | $($order.intentClass) | $($order.attribution) |")
    }
    $lines | Set-Content -LiteralPath $resolvedReport -Encoding utf8
}

[pscustomobject]$result

