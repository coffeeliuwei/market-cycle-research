param(
    [Parameter(Mandatory)][ValidateSet('record','review','list')][string]$Action,
    [string]$DataJson,
    [string]$Symbol,
    [ValidateRange(1,50)][int]$Limit = 8,
    [string]$StorePath = (Join-Path $PSScriptRoot '../state/forecasts/market.jsonl')
)

$ErrorActionPreference = 'Stop'
$StorePath = [IO.Path]::GetFullPath($StorePath)
$now = [DateTimeOffset]::UtcNow
$horizonDays = @{
    short = @{ min = 1; max = 3 }
    swing = @{ min = 7; max = 28 }
    monthly = @{ min = 28; max = 35 }
    quarterly = @{ min = 84; max = 98 }
}

function Require-Fields($Data, [string[]]$Fields) {
    foreach ($field in $Fields) {
        if ([string]::IsNullOrWhiteSpace([string]$Data.$field)) { throw "Missing forecast field: $field" }
    }
}

function Get-Direction([decimal]$ReturnPct, [decimal]$BandPct) {
    if ($ReturnPct -gt $BandPct) { return 'up' }
    if ($ReturnPct -lt -$BandPct) { return 'down' }
    return 'range'
}

$mutex = [Threading.Mutex]::new($false, 'Local\TradingviewMarketForecastV1')
$locked = $false
try {
    $locked = $mutex.WaitOne([TimeSpan]::FromSeconds(10))
    if (-not $locked) { throw 'Timed out waiting for forecast ledger.' }
    $entries = @(if (Test-Path -LiteralPath $StorePath) {
        Get-Content -LiteralPath $StorePath | Where-Object { $_.Trim() } | ConvertFrom-Json
    })
    $forecasts = @($entries | Where-Object type -eq forecast)
    $reviews = @{}
    $entries | Where-Object type -eq review | ForEach-Object { $reviews[$_.id] = $_ }

    if ($Action -eq 'list') {
        $matches = @($forecasts | Where-Object { -not $Symbol -or $_.symbol -eq $Symbol })
        $due = @($matches | Where-Object { -not $reviews.ContainsKey($_.id) -and [DateTimeOffset]$_.expiresAt -le $now })
        $recent = @($matches | Select-Object -Last $Limit | ForEach-Object {
            [ordered]@{ forecast = $_; review = $reviews[$_.id] }
        })
        [ordered]@{ dueCount = $due.Count; due = @($due | Select-Object -First $Limit); recent = $recent } | ConvertTo-Json -Depth 12
        return
    }

    if (-not $DataJson) { throw 'Supply -DataJson for record or review.' }
    $data = $DataJson | ConvertFrom-Json -AsHashtable
    Require-Fields $data @('id')
    $original = $forecasts | Where-Object id -eq $data.id | Select-Object -First 1
    if ($Action -eq 'record') {
        Require-Fields $data @('symbol','basis','source','observedAt','expiresAt','startPrice','bandPct','horizon','direction','alternative','evidence','counterEvidence','invalidation')
        if ($original) { throw 'Forecast id already exists. Preserve the original and use a new id for a revision.' }
        if ($data.direction -notin @('up','down','range') -or $data.alternative -notin @('up','down','range') -or $data.alternative -eq $data.direction) {
            throw 'Provide two distinct directions: up, down or range.'
        }
        $window = $horizonDays[[string]$data.horizon]
        if (-not $window) { throw 'Invalid forecast horizon.' }
        if ([decimal]$data.startPrice -le 0 -or [decimal]$data.bandPct -le 0 -or [decimal]$data.bandPct -ge 100) {
            throw 'Invalid start price or neutral band.'
        }
        $observedAt = [DateTimeOffset]$data.observedAt
        $expiresAt = [DateTimeOffset]$data.expiresAt
        if ($observedAt -gt $now -or $expiresAt -le $now) { throw 'Live forecasts need an observed start and a future deadline.' }
        $windowDays = ($expiresAt - $observedAt).TotalDays
        if ($windowDays -lt $window.min -or $windowDays -gt $window.max) {
            throw 'Deadline is outside the selected forecast horizon.'
        }
        if ($data.baselineDirection -and $data.baselineDirection -notin @('up','down','range')) { throw 'Invalid baseline direction.' }
        $data.type = 'forecast'
        $data.observedAt = $observedAt.ToString('o')
        $data.expiresAt = $expiresAt.ToString('o')
        $data.issuedAt = $now.ToString('o')
    }
    else {
        Require-Fields $data @('symbol','basis','source','observedAt','endPrice')
        if (-not $original) { throw 'Unknown forecast id.' }
        if ($reviews.ContainsKey($data.id)) { throw 'Forecast has already been reviewed.' }
        $observedAt = [DateTimeOffset]$data.observedAt
        if ($data.symbol -cne $original.symbol -or $data.basis -cne $original.basis) { throw 'Review symbol and price basis must match the original.' }
        if ($observedAt -ne [DateTimeOffset]$original.expiresAt -or $observedAt -gt $now) { throw 'Review requires the exact completed deadline observation.' }
        $startPrice = [decimal]$original.startPrice
        $endPrice = [decimal]$data.endPrice
        if ($endPrice -le 0) { throw 'Invalid end price.' }
        $returnPct = 100 * ($endPrice / $startPrice - 1)
        $data.type = 'review'
        $data.observedAt = $observedAt.ToString('o')
        $data.reviewedAt = $now.ToString('o')
        $data.actualDirection = Get-Direction $returnPct ([decimal]$original.bandPct)
        $data.returnPct = [math]::Round($returnPct, 6)
        $data.hit = $data.actualDirection -eq $original.direction
        $data.baselineHit = if ($original.baselineDirection) { $data.actualDirection -eq $original.baselineDirection }
        $data.maxAdversePct = $null
        if ($data.Contains('windowHigh') -or $data.Contains('windowLow')) {
            Require-Fields $data @('windowHigh','windowLow','pathSource')
            $high = [decimal]$data.windowHigh
            $low = [decimal]$data.windowLow
            if ($low -le 0 -or $low -gt $endPrice -or $high -lt $endPrice) { throw 'Invalid review window extrema.' }
            $data.maxAdversePct = switch ($original.direction) {
                'up' { [math]::Round([math]::Max(0, 100 * (1 - $low / $startPrice)), 6) }
                'down' { [math]::Round([math]::Max(0, 100 * ($high / $startPrice - 1)), 6) }
                'range' { [math]::Round([math]::Max(0, [math]::Max(100 * ($high / $startPrice - 1), 100 * (1 - $low / $startPrice)) - [decimal]$original.bandPct), 6) }
            }
        }
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $StorePath) -Force | Out-Null
    $line = $data | ConvertTo-Json -Depth 12 -Compress
    Add-Content -LiteralPath $StorePath -Value $line -Encoding utf8
    $line
}
finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
