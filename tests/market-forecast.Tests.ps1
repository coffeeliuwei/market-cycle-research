$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'scripts/market-forecast.ps1'
$store = Join-Path ([IO.Path]::GetTempPath()) ("market-forecast-" + [guid]::NewGuid() + '.jsonl')

function Invoke-Ledger($Action, $Data) {
    & $script -Action $Action -StorePath $store -DataJson ($Data | ConvertTo-Json -Compress) | ConvertFrom-Json
}

function Assert-Rejected($Action, $Data, $Pattern) {
    try { $null = Invoke-Ledger $Action $Data }
    catch {
        if ($_.Exception.Message -like $Pattern) { return }
        throw
    }
    throw "Expected rejection: $Pattern"
}

try {
    $now = [DateTimeOffset]::UtcNow
    $forecast = @{
        id = 'test-up'; symbol = 'BINANCE:BTCUSDT'; basis = 'spot'; source = 'fixture'
        observedAt = $now.ToString('o'); expiresAt = $now.AddDays(2).ToString('o')
        startPrice = 100; bandPct = 1; horizon = 'short'; direction = 'up'; alternative = 'range'
        evidence = 'Higher closing price'; counterEvidence = 'Weak volume'; invalidation = 'Daily close below 98'
        baselineDirection = 'down'
    }
    $saved = Invoke-Ledger record $forecast
    if ($saved.direction -ne 'up') { throw 'Forecast was not persisted.' }
    Assert-Rejected record $forecast '*already exists*'
    $swing = $forecast.Clone()
    $swing.id = 'test-swing'
    $swing.horizon = 'swing'
    Assert-Rejected record $swing '*outside the selected forecast horizon*'
    $swing.expiresAt = $now.AddDays(7).ToString('o')
    $swingSaved = Invoke-Ledger record $swing
    if ($swingSaved.horizon -ne 'swing') { throw 'Swing forecast was not persisted.' }
    foreach ($case in @(
        @{ horizon = 'monthly'; validDays = 30; shortDays = 27; longDays = 36 }
        @{ horizon = 'quarterly'; validDays = 92; shortDays = 83; longDays = 99 }
    )) {
        $longForecast = $forecast.Clone()
        $longForecast.id = "test-$($case.horizon)"
        $longForecast.horizon = $case.horizon
        foreach ($days in $case.shortDays, $case.longDays) {
            $longForecast.expiresAt = $now.AddDays($days).ToString('o')
            Assert-Rejected record $longForecast '*outside the selected forecast horizon*'
        }
        $longForecast.expiresAt = $now.AddDays($case.validDays).ToString('o')
        $longSaved = Invoke-Ledger record $longForecast
        if ($longSaved.horizon -ne $case.horizon) { throw 'Long horizon was not persisted.' }
    }
    $review = @{
        id = $forecast.id; symbol = $forecast.symbol; basis = $forecast.basis; source = 'fixture'
        observedAt = $forecast.expiresAt; endPrice = 101
    }
    Assert-Rejected review $review '*exact completed deadline*'

    # Import a past fixture into the isolated test ledger. The live record path rejects it.
    $forecast.id = 'test-past'
    $forecast.observedAt = $now.AddDays(-3).ToString('o')
    $forecast.expiresAt = $now.AddDays(-1).ToString('o')
    Assert-Rejected record $forecast '*future deadline*'
    $forecast.type = 'forecast'
    Add-Content -LiteralPath $store -Value ($forecast | ConvertTo-Json -Compress)
    $list = & $script -Action list -StorePath $store | ConvertFrom-Json
    if ($list.dueCount -ne 1 -or $list.due[0].id -ne 'test-past') { throw 'Due forecast was not identified.' }
    $review.id = $forecast.id
    $review.observedAt = $forecast.expiresAt
    $review.symbol = 'OKX:BTCUSDT'
    Assert-Rejected review $review '*must match*'
    $review.symbol = $forecast.symbol
    $review.observedAt = $now.ToString('o')
    Assert-Rejected review $review '*exact completed deadline*'
    $review.observedAt = $forecast.expiresAt
    $review.windowLow = 96
    $review.windowHigh = 103
    $review.pathSource = 'fixture'
    $result = Invoke-Ledger review $review
    if ($result.actualDirection -ne 'range' -or $result.hit -ne $false -or
        $result.baselineHit -ne $false -or $result.maxAdversePct -ne 4) {
        throw 'Wrong outcome at the neutral-band boundary or wrong adverse excursion.'
    }
    Assert-Rejected review $review '*already been reviewed*'
    $list = & $script -Action list -StorePath $store | ConvertFrom-Json
    if ($list.dueCount -ne 0 -or $list.recent.Count -ne 5) { throw 'Review did not resolve the due record.' }
    'PASS market-forecast'
}
finally {
    if (Test-Path -LiteralPath $store) { Remove-Item -LiteralPath $store -Force }
}
