[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$ForceRefresh,
    [string]$FixturePath,
    [string]$OutputPath,
    [string[]]$Symbols
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$statePath = Join-Path $root 'state\current\ashare.json'
$budgetPath = Join-Path $root 'config\analysis-budget.json'
$budget = Get-Content -Raw -LiteralPath $budgetPath | ConvertFrom-Json
$ashareBudget = $budget.ashareAnalysis

function Get-NormalizedSymbol([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    if ($Value -match '(?<!\d)(\d{6})(?!\d)') { return $Matches[1] }
    return $null
}

function Get-AnalysisSymbols {
    $found = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in @($Symbols)) {
        $symbol = Get-NormalizedSymbol $item
        if ($symbol) { [void]$found.Add($symbol) }
    }
    if (Test-Path -LiteralPath $statePath) {
        $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
        foreach ($item in @($state.positions) + @($state.orders)) {
            $symbol = Get-NormalizedSymbol ([string]$item.symbol)
            if ($symbol) { [void]$found.Add($symbol) }
        }
    }
    return @($found | Sort-Object)
}

$resolvedSymbols = @(Get-AnalysisSymbols)
$plan = [ordered]@{
    schemaVersion = 1
    readOnly = $true
    providers = @('tencent', 'akshare', 'baostock')
    tushareEnabled = $false
    scopeSource = 'account_plus_explicit'
    symbols = $resolvedSymbols
    quota = [ordered]@{
        cacheMaxAgeMinutes = [int]$ashareBudget.cacheMaxAgeMinutes
        maxFullRefreshesPerRun = [int]$ashareBudget.maxFullRefreshesPerRun
        defaultOutput = [string]$ashareBudget.defaultOutput
    }
}

if ($DryRun) {
    $plan | ConvertTo-Json -Depth 6 -Compress
    exit 0
}

$cacheCandidate = $null
if (-not $FixturePath -and -not $OutputPath) {
    $cacheDirectory = Join-Path $root 'state\runtime\ashare'
    New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null
    $cacheCandidate = Join-Path $cacheDirectory 'ashare-latest.json'
    if (-not $ForceRefresh -and (Test-Path -LiteralPath $cacheCandidate -PathType Leaf)) {
        try {
            $cached = Get-Content -Raw -LiteralPath $cacheCandidate | ConvertFrom-Json
            $cachedSymbols = @($cached.symbols | ForEach-Object { [string]$_ } | Sort-Object)
            $sameScope = (($cachedSymbols -join ',') -eq (($resolvedSymbols | Sort-Object) -join ','))
            $captured = [DateTimeOffset]::Parse([string]$cached.capturedAt)
            $ageMinutes = ([DateTimeOffset]::Now - $captured).TotalMinutes
            if ($cached.schemaVersion -eq 2 -and $cached.complete -eq $true -and $sameScope -and $ageMinutes -ge 0 -and $ageMinutes -le [double]$ashareBudget.cacheMaxAgeMinutes) {
                [ordered]@{
                    complete = $true
                    provider = [string]$cached.provider
                    quoteProvider = if ($cached.quoteProvider) { [string]$cached.quoteProvider } else { [string]$cached.provider }
                    capturedAt = $captured.ToString('o')
                    quoteCount = @($cached.quotes).Count
                    fundFlowCount = @($cached.fundFlow).Count
                    limitUpCount = @($cached.limitUp).Count
                    failureCount = @($cached.failures).Count
                    requiredFailureCount = if ($null -ne $cached.requiredFailureCount) { [int]$cached.requiredFailureCount } else { 0 }
                    optionalFailureCount = if ($null -ne $cached.optionalFailureCount) { [int]$cached.optionalFailureCount } else { @($cached.failures).Count }
                    enrichmentComplete = $cached.enrichmentComplete
                    reused = $true
                    cacheAgeMinutes = [math]::Round($ageMinutes, 2)
                    snapshotPath = [IO.Path]::GetFullPath($cacheCandidate)
                } | ConvertTo-Json -Depth 5 -Compress
                exit 0
            }
        }
        catch {
            # A corrupt or schema-incompatible cache is ignored; it never blocks a fresh read.
        }
    }
    $OutputPath = $cacheCandidate
}

if ($FixturePath) {
    if (-not (Test-Path -LiteralPath $FixturePath -PathType Leaf)) { throw "Fixture not found: $FixturePath" }
    $raw = Get-Content -Raw -LiteralPath $FixturePath | ConvertFrom-Json
    $provider = 'akshare-fixture'
}
else {
    $collector = Join-Path $root 'collectors\ashare-market-data.py'
    $uv = Join-Path $root '.tools\uv\uv.exe'
    if (-not (Test-Path -LiteralPath $uv -PathType Leaf)) { throw 'uv runtime is missing; run scripts/bootstrap.ps1 first.' }
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('ashare-raw-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        & $uv run --quiet --with akshare --with baostock python $collector --symbols ($resolvedSymbols -join ',') --output $temp
        if ($LASTEXITCODE -ne 0) { throw "A-share collector failed with exit code $LASTEXITCODE" }
        $raw = Get-Content -Raw -LiteralPath $temp | ConvertFrom-Json
        $provider = [string]$raw.provider
    }
    finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    }
}

function Convert-Number($Value) {
    if ($null -eq $Value -or $Value -eq '' -or $Value -eq '-') { return $null }
    return [double]$Value
}

$quotes = @($raw.quotes | ForEach-Object {
    [ordered]@{ symbol = [string]$_.代码; name = [string]$_.名称; last = Convert-Number $_.最新价; changePct = Convert-Number $_.涨跌幅; volume = Convert-Number $_.成交量; turnover = Convert-Number $_.成交额 }
})
$marketDate = if ($raw.capturedAt) { ([DateTimeOffset]$raw.capturedAt).ToOffset([TimeSpan]::FromHours(8)).ToString('yyyy-MM-dd') } else { [DateTimeOffset]::UtcNow.ToOffset([TimeSpan]::FromHours(8)).ToString('yyyy-MM-dd') }
$fundFlow = @($raw.individualFundFlow | Where-Object { $null -ne $_ } | ForEach-Object {
    $date = if ($_.'日期' -is [DateTime]) { $_.'日期'.ToString('yyyy-MM-dd') } else { [string]$_.'日期' }
    $publicationStatus = if (-not $date) { 'date_unknown' } elseif ($date -eq $marketDate) { 'current' } else { 'latest_published' }
    [ordered]@{
        symbol = [string]$_.代码
        name = [string]$_.名称
        mainNetInflow = Convert-Number ($_.'主力净流入-净额' ?? $_.'今日主力净流入-净额')
        mainNetInflowPct = Convert-Number ($_.'主力净流入-净占比' ?? $_.'今日主力净流入-净占比')
        dataDate = $date
        source = $_.source
        publicationStatus = $publicationStatus
        classification = 'estimated_trade_size_bucket'
    }
})
$limitUp = @($raw.limitUpPool | ForEach-Object {
    [ordered]@{ symbol = [string]$_.代码; name = [string]$_.名称; last = Convert-Number $_.最新价; changePct = Convert-Number $_.涨跌幅; streak = Convert-Number $_.连板数; classification = 'realtime_exchange_derived' }
})
$dragonTiger = @($raw.dragonTiger | ForEach-Object {
    [ordered]@{ symbol = [string]$_.代码; name = [string]$_.名称; tradeDate = [string]$_.上榜日; netBuy = Convert-Number $_.龙虎榜净买额; classification = 'official_t_plus_1' }
})
$margin = @($raw.marginSummary | ForEach-Object {
    [ordered]@{ symbol = [string]$_.'标的证券代码'; financingBalance = Convert-Number $_.融资余额; securitiesLendingBalance = Convert-Number $_.融券余量; classification = 'official_delayed' }
})
$failures = @($raw.failures | Where-Object { $null -ne $_ })
$quoteSymbols = @($quotes | ForEach-Object { [string]$_.symbol } | Sort-Object -Unique)
$missingQuoteSymbols = @($resolvedSymbols | Where-Object { $_ -notin $quoteSymbols })
$requiredFailures = @($failures | Where-Object {
    $_.required -eq $true -and [string]::IsNullOrWhiteSpace([string]$_.recoveredBy)
})
$optionalFailures = @($failures | Where-Object { $_.required -eq $false })
if ($FixturePath) { $missingQuoteSymbols = @() }
$coreComplete = ($missingQuoteSymbols.Count -eq 0 -and $requiredFailures.Count -eq 0 -and [string]$raw.provider -ne 'baostock')
$snapshot = [ordered]@{
    schemaVersion = 2
    capturedAt = if ($raw.capturedAt) { ([DateTimeOffset]$raw.capturedAt).ToString('o') } else { [DateTimeOffset]::UtcNow.ToString('o') }
    readOnly = $true
    provider = $provider
    quoteProvider = if ($raw.quoteProvider) { [string]$raw.quoteProvider } else { $provider }
    providers = @($plan.providers)
    symbols = $resolvedSymbols
    complete = $coreComplete
    enrichmentComplete = ($failures.Count -eq 0)
    missingQuoteSymbols = $missingQuoteSymbols
    requiredFailureCount = $requiredFailures.Count
    optionalFailureCount = $optionalFailures.Count
    quotes = $quotes
    fundFlow = $fundFlow
    fundFlowAttempts = @($raw.fundFlowAttempts | Where-Object { $_ })
    limitUp = $limitUp
    dragonTiger = $dragonTiger
    margin = $margin
    enrichmentPublication = $raw.enrichmentPublication
    failures = $failures
}

if (-not $OutputPath) {
    $dir = Join-Path $root 'state\runtime\ashare'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $OutputPath = Join-Path $dir ('ashare-' + (Get-Date -Format 'yyyyMMdd-HHmmssfff') + '.json')
}
$parent = Split-Path -Parent $OutputPath
if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
$snapshot | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding utf8

[ordered]@{
    complete = $snapshot.complete
    provider = $snapshot.provider
    quoteProvider = $snapshot.quoteProvider
    capturedAt = $snapshot.capturedAt
    quoteCount = $quotes.Count
    fundFlowCount = $fundFlow.Count
    limitUpCount = $limitUp.Count
    failureCount = $failures.Count
    requiredFailureCount = $requiredFailures.Count
    optionalFailureCount = $optionalFailures.Count
    enrichmentComplete = $snapshot.enrichmentComplete
    reused = $false
    snapshotPath = [IO.Path]::GetFullPath($OutputPath)
} | ConvertTo-Json -Depth 5 -Compress
