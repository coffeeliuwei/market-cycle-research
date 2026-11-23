param(
    [string]$ProjectRoot,
    [string]$FixturePath,
    [string]$BinanceApiBaseUrl = 'https://api.binance.com',
    [string]$GateApiBaseUrl = 'https://api.gateio.ws'
)

$ErrorActionPreference = 'Stop'
$root = if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
}
else {
    [IO.Path]::GetFullPath($ProjectRoot)
}

$checkedAt = [DateTimeOffset]::UtcNow.ToString('o')
$fixture = $null
if (-not [string]::IsNullOrWhiteSpace($FixturePath)) {
    $fixture = Get-Content -LiteralPath $FixturePath -Raw | ConvertFrom-Json
}

function Test-Property {
    param([object]$Object, [string]$Name)
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Get-DecimalValue {
    param([object]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    return [decimal]$Value
}

function Get-Filter {
    param([object]$SymbolInfo, [string]$FilterType)
    return @($SymbolInfo.filters | Where-Object { $_.filterType -eq $FilterType })[0]
}

function Test-StepValue {
    param([decimal]$Value, [decimal]$Base, [decimal]$Step)
    if ($Step -le 0) { return $true }
    $remainder = ($Value - $Base) % $Step
    return [math]::Abs($remainder) -le ($Step / 1000000)
}

function Add-Failure {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Failures,
        [Parameter(Mandatory)][string]$Rule,
        [Parameter(Mandatory)][string]$Reason,
        [object]$Boundary
    )
    $item = [ordered]@{ rule = $Rule; reason = $Reason }
    if ($null -ne $Boundary) { $item.boundary = $Boundary }
    $Failures.Add([pscustomobject]$item) | Out-Null
}

function Get-BinanceRulePayload {
    param([Parameter(Mandatory)][string]$Symbol)

    if ($null -ne $fixture) {
        $accountFixture = $fixture.PSObject.Properties['binance']
        $symbolFixture = if ($null -ne $accountFixture) { $accountFixture.Value.PSObject.Properties[$Symbol] } else { $null }
        if ($null -eq $symbolFixture) { throw "Fixture has no Binance symbol '$Symbol'." }
        return $symbolFixture.Value
    }

    $encoded = [Uri]::EscapeDataString($Symbol)
    $exchangeInfo = Invoke-RestMethod -Uri ("$BinanceApiBaseUrl/api/v3/exchangeInfo?symbol=$encoded") -TimeoutSec 20
    $avgPrice = Invoke-RestMethod -Uri ("$BinanceApiBaseUrl/api/v3/avgPrice?symbol=$encoded") -TimeoutSec 20
    $symbolInfo = @($exchangeInfo.symbols | Where-Object { $_.symbol -eq $Symbol })[0]
    if ($null -eq $symbolInfo) { throw "Binance exchangeInfo did not return '$Symbol'." }
    return [pscustomobject]@{ symbolInfo = $symbolInfo; avgPrice = $avgPrice; source = 'binance-public-exchangeInfo-and-avgPrice' }
}

function Get-GateRulePayload {
    param([Parameter(Mandatory)][string]$Symbol)

    if ($null -ne $fixture) {
        $accountFixture = $fixture.PSObject.Properties['gate']
        $symbolFixture = if ($null -ne $accountFixture) { $accountFixture.Value.PSObject.Properties[$Symbol] } else { $null }
        if ($null -eq $symbolFixture) { throw "Fixture has no Gate symbol '$Symbol'." }
        return $symbolFixture.Value
    }

    $pair = if ($Symbol.EndsWith('USDT')) { $Symbol.Substring(0, $Symbol.Length - 4) + '_USDT' } else { $Symbol }
    $encoded = [Uri]::EscapeDataString($pair)
    $pairInfo = Invoke-RestMethod -Uri ("$GateApiBaseUrl/api/v4/spot/currency_pairs/$encoded") -TimeoutSec 20
    $ticker = @(Invoke-RestMethod -Uri ("$GateApiBaseUrl/api/v4/spot/tickers?currency_pair=$encoded") -TimeoutSec 20)[0]
    return [pscustomobject]@{ pairInfo = $pairInfo; ticker = $ticker; source = 'gate-public-currency-pair-and-ticker' }
}

function Evaluate-BinanceOrder {
    param(
        [Parameter(Mandatory)][object]$Order,
        [Parameter(Mandatory)][object]$Payload
    )

    $failures = [System.Collections.Generic.List[object]]::new()
    $symbolInfo = $Payload.symbolInfo
    $price = Get-DecimalValue $Order.price
    $quantity = if (Test-Property $Order 'quantity') { Get-DecimalValue $Order.quantity } else { $null }
    $quoteAmount = if (Test-Property $Order 'quoteAmount') { Get-DecimalValue $Order.quoteAmount } else { $null }
    $notional = if ($null -ne $quantity -and $null -ne $price) { $quantity * $price } else { $quoteAmount }
    $priceFilter = Get-Filter -SymbolInfo $symbolInfo -FilterType 'PRICE_FILTER'
    if ($null -ne $priceFilter -and $null -ne $price) {
        $minPrice = Get-DecimalValue $priceFilter.minPrice
        $maxPrice = Get-DecimalValue $priceFilter.maxPrice
        $tickSize = Get-DecimalValue $priceFilter.tickSize
        if ($null -ne $minPrice -and $price -lt $minPrice) { Add-Failure $failures 'PRICE_FILTER.minPrice' "target price is below $minPrice" $minPrice }
        if ($null -ne $maxPrice -and $maxPrice -gt 0 -and $price -gt $maxPrice) { Add-Failure $failures 'PRICE_FILTER.maxPrice' "target price is above $maxPrice" $maxPrice }
        if ($null -ne $tickSize -and $tickSize -gt 0 -and -not (Test-StepValue $price $minPrice $tickSize)) { Add-Failure $failures 'PRICE_FILTER.tickSize' "target price does not match tick size $tickSize" $tickSize }
    }

    $lotFilter = Get-Filter -SymbolInfo $symbolInfo -FilterType 'LOT_SIZE'
    if ($null -ne $lotFilter -and $null -ne $quantity) {
        $minQuantity = Get-DecimalValue $lotFilter.minQty
        $maxQuantity = Get-DecimalValue $lotFilter.maxQty
        $stepSize = Get-DecimalValue $lotFilter.stepSize
        if ($null -ne $minQuantity -and $quantity -lt $minQuantity) { Add-Failure $failures 'LOT_SIZE.minQty' "quantity is below $minQuantity" $minQuantity }
        if ($null -ne $maxQuantity -and $maxQuantity -gt 0 -and $quantity -gt $maxQuantity) { Add-Failure $failures 'LOT_SIZE.maxQty' "quantity is above $maxQuantity" $maxQuantity }
        if ($null -ne $stepSize -and $stepSize -gt 0 -and -not (Test-StepValue $quantity $minQuantity $stepSize)) { Add-Failure $failures 'LOT_SIZE.stepSize' "quantity does not match step size $stepSize" $stepSize }
    }

    foreach ($filterType in @('MIN_NOTIONAL', 'NOTIONAL')) {
        $notionalFilter = Get-Filter -SymbolInfo $symbolInfo -FilterType $filterType
        if ($null -ne $notionalFilter -and $null -ne $notional) {
            $minNotional = Get-DecimalValue $notionalFilter.minNotional
            $maxNotional = Get-DecimalValue $notionalFilter.maxNotional
            if ($null -ne $minNotional -and $notional -lt $minNotional) { Add-Failure $failures "$filterType.minNotional" "notional is below $minNotional" $minNotional }
            if ($null -ne $maxNotional -and $maxNotional -gt 0 -and $notional -gt $maxNotional) { Add-Failure $failures "$filterType.maxNotional" "notional is above $maxNotional" $maxNotional }
        }
    }

    $dynamicFilter = Get-Filter -SymbolInfo $symbolInfo -FilterType 'PERCENT_PRICE_BY_SIDE'
    if ($null -eq $dynamicFilter) { $dynamicFilter = Get-Filter -SymbolInfo $symbolInfo -FilterType 'PERCENT_PRICE' }
    $weightedAverage = Get-DecimalValue $Payload.avgPrice.price
    $triggerAverage = $null
    $currentBoundary = $null
    $dynamicFailure = $false
    if ($null -ne $dynamicFilter -and $null -ne $weightedAverage -and $null -ne $price) {
        $isBuy = ([string]$Order.side).ToLowerInvariant() -eq 'buy'
        $down = if ($dynamicFilter.filterType -eq 'PERCENT_PRICE_BY_SIDE') {
            if ($isBuy) { Get-DecimalValue $dynamicFilter.bidMultiplierDown } else { Get-DecimalValue $dynamicFilter.askMultiplierDown }
        } else { Get-DecimalValue $dynamicFilter.multiplierDown }
        $up = if ($dynamicFilter.filterType -eq 'PERCENT_PRICE_BY_SIDE') {
            if ($isBuy) { Get-DecimalValue $dynamicFilter.bidMultiplierUp } else { Get-DecimalValue $dynamicFilter.askMultiplierUp }
        } else { Get-DecimalValue $dynamicFilter.multiplierUp }
        if ($null -ne $down -and $down -gt 0) {
            $currentBoundary = $weightedAverage * $down
            $triggerAverage = $price / $down
            if ($price -lt $currentBoundary) {
                $dynamicFailure = $true
                Add-Failure $failures $dynamicFilter.filterType "target price is below current dynamic boundary $currentBoundary" $currentBoundary
            }
        }
        if ($null -ne $up -and $up -gt 0 -and $price -gt ($weightedAverage * $up)) {
            $dynamicFailure = $true
            Add-Failure $failures $dynamicFilter.filterType "target price is above current dynamic boundary $($weightedAverage * $up)" ($weightedAverage * $up)
        }
    }
    elseif ($null -eq $dynamicFilter) {
        Add-Failure $failures 'dynamic-price-filter' 'exchange symbol did not provide a dynamic price filter' $null
    }
    else {
        Add-Failure $failures 'dynamic-price-filter' 'weighted average price was unavailable' $null
    }

    $distancePct = $null
    if ($null -ne $triggerAverage -and $null -ne $weightedAverage -and $triggerAverage -gt 0) {
        $distancePct = [math]::Round([double]([math]::Max([decimal]0, ($weightedAverage - $triggerAverage)) / $triggerAverage * 100), 4)
    }
    $staticFailures = @($failures | Where-Object { $_.rule -notlike 'PERCENT_PRICE*' })
    $currentExecutable = $failures.Count -eq 0
    $alertLevel = if ($currentExecutable) { 'current_executable' }
        elseif ($staticFailures.Count -gt 0) { 'blocked' }
        elseif ($null -ne $distancePct -and $distancePct -le 10) { 'prepare' }
        else { 'waiting' }
    $message = switch ($alertLevel) {
        'current_executable' { '当前可尝试挂单：目标价已通过当前平台规则核验，但不会自动提交。' }
        'prepare' { '准备挂单：距离动态过滤器触发线不超过10%，达到条件后需手动提交。' }
        'blocked' { '当前不可挂单：存在精度、数量或名义金额等静态规则失败。' }
        default { '条件计划等待：目标价尚未接近平台规则触发线。' }
    }
    return [ordered]@{
        currentExecutable = $currentExecutable
        alertLevel = $alertLevel
        message = $message
        weightedAveragePrice = $weightedAverage
        currentDynamicBoundary = $currentBoundary
        triggerAveragePrice = $triggerAverage
        distanceToTriggerPct = $distancePct
        failedRules = @($failures)
        ruleCheckStatus = 'checked'
        source = if ($Payload.source) { $Payload.source } else { 'binance-public-exchangeInfo-and-avgPrice' }
    }
}

function Evaluate-GateOrder {
    param([Parameter(Mandatory)][object]$Order, [Parameter(Mandatory)][object]$Payload)
    $failures = [System.Collections.Generic.List[object]]::new()
    $pair = $Payload.pairInfo
    $price = Get-DecimalValue $Order.price
    $quantity = if (Test-Property $Order 'quantity') { Get-DecimalValue $Order.quantity } else { $null }
    $precision = if (Test-Property $pair 'precision') { [int]$pair.precision } else { $null }
    $amountPrecision = if (Test-Property $pair 'amount_precision') { [int]$pair.amount_precision } else { $null }
    if ($null -ne $precision -and $price -ne [math]::Round($price, $precision)) { Add-Failure $failures 'currency_pair.precision' "price exceeds $precision decimal places" $precision }
    if ($null -ne $amountPrecision -and $null -ne $quantity -and $quantity -ne [math]::Round($quantity, $amountPrecision)) { Add-Failure $failures 'currency_pair.amount_precision' "quantity exceeds $amountPrecision decimal places" $amountPrecision }
    $minQuote = Get-DecimalValue $pair.min_quote_amount
    if ($null -ne $minQuote -and $null -ne $price -and $null -ne $quantity -and ($price * $quantity) -lt $minQuote) { Add-Failure $failures 'currency_pair.min_quote_amount' "notional is below $minQuote" $minQuote }
    $currentExecutable = $failures.Count -eq 0
    return [ordered]@{
        currentExecutable = $currentExecutable
        alertLevel = if ($currentExecutable) { 'current_executable' } else { 'blocked' }
        message = if ($currentExecutable) { '当前可尝试挂单：目标价已通过当前平台规则核验，但不会自动提交。' } else { '当前不可挂单：存在Gate静态规则失败。' }
        weightedAveragePrice = if ($Payload.ticker) { Get-DecimalValue $Payload.ticker.last } else { $null }
        currentDynamicBoundary = $null
        triggerAveragePrice = $null
        distanceToTriggerPct = $null
        failedRules = @($failures)
        ruleCheckStatus = 'checked'
        source = if ($Payload.source) { $Payload.source } else { 'gate-public-currency-pair-and-ticker' }
    }
}

$alerts = [System.Collections.Generic.List[object]]::new()
$failures = [System.Collections.Generic.List[object]]::new()
$excluded = [System.Collections.Generic.List[object]]::new()
$exclusionPath = Join-Path $root 'config/deferred-order-exclusions.json'
$exclusions = if (Test-Path -LiteralPath $exclusionPath -PathType Leaf) {
    Get-Content -LiteralPath $exclusionPath -Raw | ConvertFrom-Json -AsHashtable
} else { @{} }
foreach ($accountId in @('binance', 'gate', 'ok', 'ashare')) {
    $statePath = Join-Path $root "state\current\$accountId.json"
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { continue }
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    foreach ($order in @($state.deferredOrders)) {
        $recordId = [string]$order.recordId
        $accountExclusions = $exclusions[$accountId]
        if ($accountExclusions -and $accountExclusions.Contains($recordId)) {
            $excluded.Add([pscustomobject]@{ accountId=$accountId; recordId=$recordId; symbol=[string]$order.symbol; reason=$accountExclusions[$recordId] })
            continue
        }
        $base = [ordered]@{
            accountId = $accountId
            recordId = [string]$order.recordId
            market = [string]$order.market
            symbol = [string]$order.symbol
            side = [string]$order.side
            type = [string]$order.type
            price = if (Test-Property $order 'price') { [decimal]$order.price } else { $null }
            quantity = if (Test-Property $order 'quantity') { [decimal]$order.quantity } else { $null }
            quoteAmount = if (Test-Property $order 'quoteAmount') { [decimal]$order.quoteAmount } else { $null }
            status = [string]$order.status
            checkedAt = $checkedAt
        }
        try {
            if ($accountId -eq 'binance') {
                $evaluation = Evaluate-BinanceOrder -Order $order -Payload (Get-BinanceRulePayload -Symbol ([string]$order.symbol).ToUpperInvariant())
            }
            elseif ($accountId -eq 'gate') {
                $evaluation = Evaluate-GateOrder -Order $order -Payload (Get-GateRulePayload -Symbol ([string]$order.symbol).ToUpperInvariant())
            }
            else {
                throw "No official deferred-order rule adapter is configured for account '$accountId'."
            }
            foreach ($property in $evaluation.Keys) { $base[$property] = $evaluation[$property] }
        }
        catch {
            $base.ruleCheckStatus = 'unavailable'
            $base.alertLevel = 'unavailable'
            $base.currentExecutable = $false
            $base.message = '本次未完成平台规则核验，不能提示可挂单。'
            $base.failedRules = @()
            $base.error = $_.Exception.Message
            $failures.Add([pscustomobject]@{ accountId = $accountId; symbol = [string]$order.symbol; reason = $_.Exception.Message }) | Out-Null
        }
        $alerts.Add([pscustomobject]$base) | Out-Null
    }
}

[ordered]@{
    schemaVersion = 1
    checkedAt = $checkedAt
    deferredOrdersCount = $alerts.Count
    checkedCount = @($alerts | Where-Object ruleCheckStatus -eq 'checked').Count
    complete = $failures.Count -eq 0
    alerts = @($alerts)
    excluded = @($excluded)
    failures = @($failures)
} | ConvertTo-Json -Depth 20
