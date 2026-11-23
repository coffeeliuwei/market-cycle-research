param(
    [string]$ProjectRoot,
    [string[]]$CandidateSymbols,
    [string[]]$IncludeSymbols
)

$ErrorActionPreference = 'Stop'
if (-not $ProjectRoot) { $ProjectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)) }

$budgetPath = Join-Path $ProjectRoot 'config\analysis-budget.json'
$watchlistPath = Join-Path $ProjectRoot 'config\watchlist.json'
$currentPath = Join-Path $ProjectRoot 'state\current'
foreach ($path in @($budgetPath, $watchlistPath, $currentPath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required dynamic-scope input is missing: $path" }
}

$budget = Get-Content -Raw -LiteralPath $budgetPath | ConvertFrom-Json
$watchlist = Get-Content -Raw -LiteralPath $watchlistPath | ConvertFrom-Json
$scopeConfig = $budget.cryptoAnalysis
$dustThresholdUsd = if ($null -ne $scopeConfig.dustThresholdUsd) { [decimal]$scopeConfig.dustThresholdUsd } else { [decimal]100 }
$maxFinalists = if ($null -ne $scopeConfig.maxScreenedFinalists) { [int]$scopeConfig.maxScreenedFinalists } else { 5 }
$configuredAccountIds = @($scopeConfig.accountIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
$accountIds = if ($configuredAccountIds.Count) { $configuredAccountIds } else { @('binance','gate','ok') }
$stableAssets = @('USD','USDT','USDC','BUSD','FDUSD','TUSD','DAI','USDE')

# Instruments that exist on an exchange but have no legitimate underlying
# TradingView chart. They must be reported as excluded with an explicit reason
# instead of falling through to a fabricated spot-symbol guess.
$unmappableMap = @{}
if ($null -ne $scopeConfig.PSObject.Properties['unmappableInstruments']) {
    foreach ($prop in $scopeConfig.unmappableInstruments.PSObject.Properties) {
        $unmappableMap[$prop.Name.ToUpperInvariant()] = $prop.Value
    }
}

$watchMap = @{}
foreach ($item in @($watchlist.symbols | Where-Object { $_.category -eq 'crypto' -and $_.tradingView })) {
    $watchMap[([string]$item.id).ToUpperInvariant()] = ([string]$item.tradingView).ToUpperInvariant()
}
$accountInstrumentMap = @{}
foreach ($item in @($watchlist.symbols | Where-Object { $_.enabled -ne $false -and $_.tradingView })) {
    $id = ([string]$item.id).ToUpperInvariant()
    if ($id) { $accountInstrumentMap[$id] = ([string]$item.tradingView).ToUpperInvariant() }
}

function Get-BaseAsset {
    param([Parameter(Mandatory)][string]$Symbol)
    $value = $Symbol.Trim().ToUpperInvariant()
    if ($value.Contains(':')) { $value = $value.Split(':', 2)[1] }
    $value = $value -replace '[/_\-]', ''
    foreach ($quote in @('FDUSD','USDT','USDC','BUSD','TUSD','USDE','USD')) {
        if ($value.EndsWith($quote, [StringComparison]::Ordinal) -and $value.Length -gt $quote.Length) {
            return $value.Substring(0, $value.Length - $quote.Length)
        }
    }
    return $value
}

function Resolve-TradingViewSymbol {
    param(
        [Parameter(Mandatory)][string]$Symbol,
        [string]$AccountId = 'binance'
    )
    $raw = $Symbol.Trim().ToUpperInvariant()
    if (-not $raw) { return $null }
    if ($raw.Contains(':')) { return $raw }
    $base = Get-BaseAsset -Symbol $raw
    if (-not $base -or $base -in $stableAssets) { return $null }
    $underlyingMap = $scopeConfig.PSObject.Properties['underlyingChartMappings']
    if ($underlyingMap -and $underlyingMap.Value.PSObject.Properties[$raw]) {
        return [string]$underlyingMap.Value.$raw
    }
    if ($underlyingMap -and $underlyingMap.Value.PSObject.Properties[$base]) {
        return [string]$underlyingMap.Value.$base
    }
    # Account objects can contain Binance TradFi perpetual tickers such as
    # ORCLUSDT. Resolve those to the underlying exchange chart instead of
    # fabricating a BINANCE crypto spot symbol.
    if ($accountInstrumentMap.ContainsKey($base) -and -not $watchMap.ContainsKey($base)) {
        return $accountInstrumentMap[$base]
    }
    if ($watchMap.ContainsKey($base)) { return $watchMap[$base] }
    $prefix = switch ($AccountId.ToLowerInvariant()) {
        'gate' { 'GATEIO' }
        'ok' { 'OKX' }
        default { 'BINANCE' }
    }
    return "${prefix}:${base}USDT"
}

function Test-ActiveOrder {
    param([object]$Order)
    return ([string]$Order.status).ToLowerInvariant() -notin @('canceled','cancelled','filled','closed','rejected','failed','expired')
}

function Test-RunningBot {
    param([object]$Bot)
    return ([string]$Bot.status).ToLowerInvariant() -in @('running','active','confirmed')
}

$accountSymbols = [Collections.Generic.List[string]]::new()
$candidateOutput = [Collections.Generic.List[string]]::new()
$excluded = [Collections.Generic.List[object]]::new()
$seenAccount = @{}
$seenCandidates = @{}

function Add-AccountSymbol {
    param([AllowEmptyString()][string]$Symbol, [string]$AccountId)
    if ([string]::IsNullOrWhiteSpace($Symbol)) { return }
    $base = Get-BaseAsset -Symbol $Symbol
    if ($base -and $unmappableMap.ContainsKey($base)) {
        $rule = $unmappableMap[$base]
        $appliesTo = @($rule.accountIds)
        if (-not $appliesTo.Count -or ($appliesTo -contains $AccountId)) {
            $excluded.Add([pscustomobject]@{
                accountId = $AccountId
                symbol = [string]$Symbol
                reason = [string]$rule.reason
                detail = [string]$rule.detail
                reportedValueUsd = $null
                discloseInAnalysis = [bool]$rule.discloseInAnalysis
            })
            return
        }
    }
    $resolved = Resolve-TradingViewSymbol -Symbol $Symbol -AccountId $AccountId
    if ($resolved -and -not $seenAccount.ContainsKey($resolved)) {
        $seenAccount[$resolved] = $true
        $accountSymbols.Add($resolved)
    }
}

foreach ($accountId in $accountIds) {
    $stateFile = Join-Path $currentPath "$accountId.json"
    if (-not (Test-Path -LiteralPath $stateFile -PathType Leaf)) { continue }
    $state = Get-Content -Raw -LiteralPath $stateFile | ConvertFrom-Json
    $spotMapping = if ($scopeConfig.accountSpotChartMappings) {
        $scopeConfig.accountSpotChartMappings.PSObject.Properties[$accountId].Value
    }

    foreach ($position in @($state.positions)) {
        if ($null -ne $position.quantity -and [decimal]$position.quantity -le 0) { continue }
        $hasValue = $null -ne $position.PSObject.Properties['reportedValueUsd'] -and $null -ne $position.reportedValueUsd
        if (-not $hasValue) {
            $excluded.Add([pscustomobject]@{ accountId=$accountId; symbol=[string]$position.symbol; reason='position_value_unavailable'; reportedValueUsd=$null })
            continue
        }
        if ($hasValue -and [decimal]$position.reportedValueUsd -lt $dustThresholdUsd) {
            $excluded.Add([pscustomobject]@{ accountId=$accountId; symbol=[string]$position.symbol; reason='position_dust'; reportedValueUsd=[decimal]$position.reportedValueUsd })
            continue
        }
        $exactChart = if ($spotMapping) { $spotMapping.PSObject.Properties[[string]$position.symbol].Value }
        $chartInput = if ($exactChart) { [string]$exactChart } else { [string]$position.symbol }
        Add-AccountSymbol -Symbol $chartInput -AccountId $accountId
    }
    foreach ($order in @($state.orders | Where-Object { Test-ActiveOrder $_ })) {
        Add-AccountSymbol -Symbol ([string]$order.symbol) -AccountId $accountId
    }
    foreach ($bot in @($state.bots | Where-Object { Test-RunningBot $_ })) {
        Add-AccountSymbol -Symbol ([string]$bot.symbol) -AccountId $accountId
    }
}

foreach ($symbol in @($IncludeSymbols | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
    Add-AccountSymbol -Symbol ([string]$symbol) -AccountId 'binance'
}

foreach ($symbol in @($CandidateSymbols | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
    if ($candidateOutput.Count -ge $maxFinalists) { break }
    $resolved = Resolve-TradingViewSymbol -Symbol ([string]$symbol) -AccountId 'binance'
    if ($resolved -and -not $seenCandidates.ContainsKey($resolved)) {
        $seenCandidates[$resolved] = $true
        $candidateOutput.Add($resolved)
    }
}

$allSymbols = @($accountSymbols) + @($candidateOutput | Where-Object { -not $seenAccount.ContainsKey($_) })
[ordered]@{
    schemaVersion = 1
    generatedAt = [DateTimeOffset]::UtcNow.ToString('o')
    dustThresholdUsd = $dustThresholdUsd
    maxScreenedFinalists = $maxFinalists
    accountIds = @($accountIds)
    accountSymbols = @($accountSymbols)
    candidateSymbols = @($candidateOutput)
    symbols = @($allSymbols)
    excluded = @($excluded)
} | ConvertTo-Json -Depth 8 -Compress
