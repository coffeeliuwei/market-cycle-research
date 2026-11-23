param(
    [string]$ProjectRoot,
    [string[]]$CandidateSymbols,
    [string[]]$IncludeSymbols
)

$ErrorActionPreference = 'Stop'
if (-not $ProjectRoot) { $ProjectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)) }

$configPath = Join-Path $ProjectRoot 'config\social-intelligence.json'
$watchlistPath = Join-Path $ProjectRoot 'config\watchlist.json'
$scopeScript = Join-Path $ProjectRoot 'scripts\get-dynamic-crypto-analysis-symbols.ps1'
foreach ($path in @($configPath,$watchlistPath,$scopeScript)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required social-intelligence input is missing: $path" }
}

$config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
$watchlist = Get-Content -Raw -LiteralPath $watchlistPath | ConvertFrom-Json
$scopeRaw = & $scopeScript -ProjectRoot $ProjectRoot -CandidateSymbols $CandidateSymbols -IncludeSymbols $IncludeSymbols
$scope = ($scopeRaw -join "`n") | ConvertFrom-Json

$categoryByChart = @{}
foreach ($item in @($watchlist.symbols | Where-Object { $_.tradingView })) {
    $categoryByChart[([string]$item.tradingView).ToUpperInvariant()] = [string]$item.category
}

function Get-UnderlyingAsset {
    param([Parameter(Mandatory)][string]$Symbol)
    $value = $Symbol.Trim().ToUpperInvariant()
    if ($value.Contains(':')) { $value = $value.Split(':',2)[1] }
    $value = $value -replace '\.P$','' -replace '[/_\-]',''
    foreach ($quote in @('FDUSD','USDT','USDC','BUSD','TUSD','USDE','USD')) {
        if ($value.EndsWith($quote,[StringComparison]::Ordinal) -and $value.Length -gt $quote.Length) {
            return $value.Substring(0,$value.Length-$quote.Length)
        }
    }
    return $value
}

$accountCrypto = [Collections.Generic.List[string]]::new()
$accountTradFi = [Collections.Generic.List[string]]::new()
$candidateAssets = [Collections.Generic.List[string]]::new()
$seenCrypto = @{}; $seenTradFi = @{}; $seenCandidate = @{}
foreach ($symbol in @($scope.accountSymbols)) {
    $chart = ([string]$symbol).ToUpperInvariant()
    $asset = Get-UnderlyingAsset -Symbol $chart
    $category = if ($categoryByChart.ContainsKey($chart)) { $categoryByChart[$chart] } else { 'crypto' }
    if ($category -eq 'crypto') {
        if (-not $seenCrypto.ContainsKey($asset)) { $seenCrypto[$asset]=$true; $accountCrypto.Add($asset) }
    } elseif (-not $seenTradFi.ContainsKey($asset)) {
        $seenTradFi[$asset]=$true; $accountTradFi.Add($asset)
    }
}
foreach ($symbol in @($scope.candidateSymbols)) {
    $asset = Get-UnderlyingAsset -Symbol ([string]$symbol)
    if (-not $seenCandidate.ContainsKey($asset)) { $seenCandidate[$asset]=$true; $candidateAssets.Add($asset) }
}

$allCrypto = [Collections.Generic.List[string]]::new()
$seenAll = @{}
foreach ($asset in @($candidateAssets) + @($accountCrypto)) {
    if (-not $seenAll.ContainsKey($asset)) { $seenAll[$asset]=$true; $allCrypto.Add($asset) }
}

$maxQueries = [int]$config.x.maxQueries
$assetsPerQuery = [Math]::Max(1,[int]$config.x.assetsPerQuery)
$queries = [Collections.Generic.List[object]]::new()
$queries.Add([pscustomobject]@{ kind='market_risk'; assets=@('BTC'); query=[string]$config.x.marketRiskQuery })
for ($offset=0; $offset -lt $allCrypto.Count -and $queries.Count -lt $maxQueries; $offset += $assetsPerQuery) {
    $take = [Math]::Min($assetsPerQuery,$allCrypto.Count-$offset)
    $batch = @($allCrypto.GetRange($offset,$take))
    $assetTerms = @($batch | ForEach-Object {
        '$' + $_
        if ($_ -eq 'ALGO') { 'Algorand' }
    }) -join ' OR '
    $queries.Add([pscustomobject]@{
        kind = 'account_assets'
        assets = $batch
        query = "($assetTerms) $([string]$config.x.assetRiskTerms)"
    })
}

$covered = @($queries | ForEach-Object { @($_.assets) } | Select-Object -Unique)
$uncovered = @($allCrypto | Where-Object { $_ -notin $covered })
$maxDeep = [int]$config.binanceSquare.maxDeepAssets
$deepAssets = @($candidateAssets | Select-Object -First $maxDeep)
if ($deepAssets.Count -lt $maxDeep) {
    $deepAssets += @($accountCrypto | Where-Object { $_ -notin $deepAssets } | Select-Object -First ($maxDeep-$deepAssets.Count))
}

[ordered]@{
    schemaVersion = 1
    generatedAt = [DateTimeOffset]::UtcNow.ToString('o')
    scope = [ordered]@{
        dustThresholdUsd = $scope.dustThresholdUsd
        accountSymbols = @($scope.accountSymbols)
        cryptoAssets = @($accountCrypto)
        tradFiAssets = @($accountTradFi)
        candidateAssets = @($candidateAssets)
        excluded = @($scope.excluded)
    }
    x = [ordered]@{
        required = [bool]$config.x.required
        cacheMaxAgeMinutes = [int]$config.x.cacheMaxAgeMinutes
        maxQueries = $maxQueries
        maxItemsPerQuery = [int]$config.x.maxItemsPerQuery
        queries = @($queries)
        uncoveredAssets = $uncovered
        completeScope = ($uncovered.Count -eq 0)
    }
    binanceSquare = [ordered]@{
        required = [bool]$config.binanceSquare.required
        marketOverview = [bool]$config.binanceSquare.marketOverview
        hotCoin = [bool]$config.binanceSquare.hotCoin
        maxDeepAssets = $maxDeep
        deepTool = [string]$config.binanceSquare.deepTool
        deepAssets = @($deepAssets)
    }
    sourceTiers = @($config.sourceTiers)
    policy = $config.policy
} | ConvertTo-Json -Depth 12 -Compress
