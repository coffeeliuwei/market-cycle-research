param(
    [switch]$DryRun,
    [string[]]$Symbols,
    [string[]]$CandidateSymbols,
    [string[]]$IncludeSymbols,
    [string[]]$DeepSymbols,
    [string]$OutputPath,
    [int]$MaxAgeMinutes = 10,
    [switch]$ForceRefresh,
    [switch]$EmitFullJson,
    [switch]$LockProbe,
    [int]$HoldLockSeconds = 0,
    [int]$MutexTimeoutSeconds = 60,
    [ValidateSet('portfolio','targeted','screen','confirm')][string]$Profile = 'portfolio',
    [string[]]$Timeframes,
    [string]$RunId
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$watchlistPath = Join-Path $projectRoot 'config\watchlist.json'
$analysisUniversePath = Join-Path $projectRoot 'config\analysis-universe.json'
$sourcesPath = Join-Path $projectRoot 'config\sources.json'
$budgetPath = Join-Path $projectRoot 'config\analysis-budget.json'
$tvScript = Join-Path $projectRoot 'collectors\tradingview-refresh.mjs'
$tvScreenerScript = Join-Path $projectRoot 'collectors\tradingview-screener.mjs'
$deepScopeScript = Join-Path $projectRoot 'scripts\resolve-tradingview-deep-symbols.ps1'
$coinGlassScript = Join-Path $projectRoot 'collectors\coinglass-live.mjs'
$coinGlassBrowserScript = Join-Path $projectRoot 'collectors\ensure-coinglass-browser.mjs'
$coinGlassPublicRoute = 'bitcoin-long-term-holder-mvrv'
$polyMarketScript = Join-Path $projectRoot 'collectors\polymarket-live.mjs'
$xScript = Join-Path $projectRoot 'collectors\x-live.mjs'
$xInvoker = Join-Path $projectRoot 'scripts\invoke-x-collector.ps1'
$deferredAlertScript = Join-Path $projectRoot 'scripts\get-deferred-order-alerts.ps1'
$deferredSummaryLib = Join-Path $projectRoot 'scripts\deferred-order-summary-lib.ps1'
$dynamicScopeScript = Join-Path $projectRoot 'scripts\get-dynamic-crypto-analysis-symbols.ps1'
$socialPlanScript = Join-Path $projectRoot 'scripts\get-social-intelligence-plan.ps1'
$socialConfigPath = Join-Path $projectRoot 'config\social-intelligence.json'
$xCachePath = Join-Path $projectRoot 'state\cache\x-live.json'
$nodeResolver = Join-Path $projectRoot 'scripts\resolve-node.ps1'

function Test-ExactStringSet {
    param(
        [object[]]$Actual,
        [object[]]$Expected
    )

    $actualValues = @($Actual | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    $expectedValues = @($Expected | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    return (($actualValues.Count -eq $expectedValues.Count) -and (($actualValues -join "`n") -ceq ($expectedValues -join "`n")))
}

function Write-RefreshResult {
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)][string]$SnapshotPath,
        [Parameter(Mandatory)][bool]$Reused,
        [Parameter(Mandatory)][bool]$IncludeFullJson
    )

    if ($IncludeFullJson) {
        $Snapshot | ConvertTo-Json -Depth 30
        return
    }

    $allFailures = @($Snapshot.failures)
    $requiredFailures = @($allFailures | Where-Object { $_.required -eq $true })
    $optionalFailures = @($allFailures | Where-Object { $_.required -ne $true })
    $capturedAtText = if ($Snapshot.capturedAt -is [DateTime]) {
        ([DateTime]$Snapshot.capturedAt).ToUniversalTime().ToString('o')
    }
    else {
        [string]$Snapshot.capturedAt
    }
    $deferred = Get-CompactDeferredOrderView -RuleCheck $Snapshot.deferredOrderRuleCheck -Alerts @($Snapshot.deferredOrderAlerts)
    [ordered]@{
        schemaVersion = 2
        capturedAt = $capturedAtText
        complete = [bool]$Snapshot.complete
        reused = $Reused
        outputPath = [IO.Path]::GetFullPath($SnapshotPath)
        symbolsRequested = @($Snapshot.symbolsRequested).Count
        requiredTimeframes = @($Snapshot.requiredTimeframes)
        tradingViewScreenerResults = @($Snapshot.tradingViewScreener.results).Count
        tradingViewResults = @($Snapshot.tradingView.results).Count
        tradingViewDeepSymbols = @($Snapshot.tradingViewDeepScope.symbols).Count
        requiredFailures = $requiredFailures.Count
        optionalFailures = $optionalFailures.Count
        failedItems = $allFailures
        deferredOrderRuleCheck = $deferred.ruleCheck
        deferredOrderAlertSummary = $deferred.summary
        deferredOrderAlerts = @($deferred.actionableAlerts)
    } | ConvertTo-Json -Depth 10
}

function Set-SnapshotProperty {
    param([Parameter(Mandatory)][object]$Snapshot, [Parameter(Mandatory)][string]$Name, [Parameter()][object]$Value)
    if ($null -ne $Snapshot.PSObject.Properties[$Name]) { $Snapshot.$Name = $Value }
    else { Add-Member -InputObject $Snapshot -MemberType NoteProperty -Name $Name -Value $Value }
}

function Add-DeferredOrderAlerts {
    param([Parameter(Mandatory)][object]$Snapshot)
    try {
        $raw = & $deferredAlertScript -ProjectRoot $projectRoot
        $check = ($raw -join "`n") | ConvertFrom-Json
    }
    catch {
        $check = [pscustomobject]@{
            schemaVersion = 1
            checkedAt = [DateTimeOffset]::UtcNow.ToString('o')
            deferredOrdersCount = 0
            checkedCount = 0
            complete = $false
            alerts = @()
            failures = @([pscustomobject]@{ accountId = $null; symbol = $null; reason = $_.Exception.Message })
        }
    }
    Set-SnapshotProperty -Snapshot $Snapshot -Name 'deferredOrderRuleCheck' -Value $check
    Set-SnapshotProperty -Snapshot $Snapshot -Name 'deferredOrderAlerts' -Value @($check.alerts)
    return $Snapshot
}

foreach ($path in @($watchlistPath, $analysisUniversePath, $sourcesPath, $budgetPath, $tvScript, $tvScreenerScript, $deepScopeScript, $coinGlassScript, $coinGlassBrowserScript, $polyMarketScript, $xScript, $xInvoker, $nodeResolver, $deferredAlertScript, $deferredSummaryLib, $dynamicScopeScript, $socialPlanScript, $socialConfigPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required portable analysis file is missing: $path"
    }
}
. $deferredSummaryLib

$watchlist = Get-Content -Raw -LiteralPath $watchlistPath | ConvertFrom-Json
$analysisUniverse = Get-Content -Raw -LiteralPath $analysisUniversePath | ConvertFrom-Json
$sources = Get-Content -Raw -LiteralPath $sourcesPath | ConvertFrom-Json
$budget = Get-Content -Raw -LiteralPath $budgetPath | ConvertFrom-Json
$symbolScopeWasExplicit = $PSBoundParameters.ContainsKey('Symbols')
if (-not $Symbols -or $Symbols.Count -eq 0) {
    if ($Profile -ne 'portfolio') { throw "Profile '$Profile' requires an explicit -Symbols scope." }
    $scopeRaw = & $dynamicScopeScript -ProjectRoot $projectRoot -CandidateSymbols $CandidateSymbols -IncludeSymbols $IncludeSymbols
    $dynamicScope = ($scopeRaw -join "`n") | ConvertFrom-Json
    $Symbols = @($dynamicScope.symbols)
    if ($Symbols.Count -eq 0) { throw 'Dynamic crypto analysis scope is empty.' }
}
$socialPlanRaw = & $socialPlanScript -ProjectRoot $projectRoot -CandidateSymbols $CandidateSymbols -IncludeSymbols $IncludeSymbols
$socialPlan = ($socialPlanRaw -join "`n") | ConvertFrom-Json
$profileConfig = $budget.profiles.$Profile
if (@($Symbols).Count -gt [int]$profileConfig.maxSymbols) { throw "Profile '$Profile' allows at most $($profileConfig.maxSymbols) symbols." }
$periods = if ($Timeframes) { @($Timeframes) } else { @($profileConfig.timeframes) }
foreach ($period in $periods) { if ($period -notin @($sources.requiredTimeframes)) { throw "Unsupported timeframe: $period" } }
$mutexName = [string]$sources.tradingView.mutexName
$deepMaxSymbols = if ($null -ne $sources.tradingView.deepMaxSymbols) { [int]$sources.tradingView.deepMaxSymbols } else { 8 }
$criticalBoundaryPercent = if ($null -ne $sources.tradingView.criticalBoundaryPercent) { [decimal]$sources.tradingView.criticalBoundaryPercent } else { [decimal]10 }
if ($PSBoundParameters.ContainsKey('MutexTimeoutSeconds') -eq $false) {
    $MutexTimeoutSeconds = [int]$sources.tradingView.mutexTimeoutSeconds
}

$plan = [ordered]@{
    schemaVersion = 2
    profile = $Profile
    runId = $RunId
    projectRoot = $projectRoot
    symbols = @($Symbols)
    symbolScope = if ($null -ne $dynamicScope) { $dynamicScope } else { $null }
    socialIntelligence = $socialPlan
    periods = $periods
    tradingViewScreener = [ordered]@{
        script = $tvScreenerScript
        endpoint = if ($sources.tradingViewScreener.endpoint) { [string]$sources.tradingViewScreener.endpoint } else { 'https://scanner.tradingview.com/crypto/scan' }
        batch = $true
        symbols = @($Symbols)
        timeoutSeconds = if ($sources.tradingViewScreener.timeoutSeconds) { [int]$sources.tradingViewScreener.timeoutSeconds } else { 15 }
    }
    tradingView = [ordered]@{
        script = $tvScript
        parallel = $false
        mutexName = $mutexName
        cdpHost = [string]$sources.tradingView.cdpHost
        cdpPort = [int]$sources.tradingView.cdpPort
        deepMaxSymbols = $deepMaxSymbols
        criticalBoundaryPercent = $criticalBoundaryPercent
    }
    coinGlass = [ordered]@{
        script = $coinGlassScript
        browserScript = $coinGlassBrowserScript
        routes = @($sources.coinGlass.routes)
        required = [bool]$sources.coinGlass.required
        cacheMaxAgeMinutes = [int]$sources.coinGlass.cacheMaxAgeMinutes
    }
    polymarket = [ordered]@{
        script = $polyMarketScript
        query = [string]$sources.polymarket.query
        required = [bool]$sources.polymarket.required
    }
    x = [ordered]@{
        script = $xScript
        invoker = $xInvoker
        cachePath = $xCachePath
        query = [string]$sources.x.query
        required = [bool]$sources.x.required
        cacheMaxAgeMinutes = [int]$sources.x.cacheMaxAgeMinutes
    }
    cryptoFearGreed = [ordered]@{
        url = [string]$sources.cryptoFearGreed.url
        required = [bool]$sources.cryptoFearGreed.required
    }
}

if ($DryRun) {
    $plan | ConvertTo-Json -Depth 10
    exit 0
}

if (-not $ForceRefresh -and -not $OutputPath -and $MaxAgeMinutes -gt 0) {
    $runtimeDirectory = Join-Path $projectRoot 'state\snapshots\runtime'
    if (Test-Path -LiteralPath $runtimeDirectory -PathType Container) {
        $now = [DateTimeOffset]::UtcNow
        $snapshotFiles = Get-ChildItem -LiteralPath $runtimeDirectory -Filter '*.json' -File |
            Sort-Object LastWriteTimeUtc -Descending
        foreach ($snapshotFile in $snapshotFiles) {
            $compatibleSnapshot = $null
            try {
                $snapshot = Get-Content -Raw -LiteralPath $snapshotFile.FullName | ConvertFrom-Json
                $capturedAt = if ($snapshot.capturedAt -is [DateTime]) {
                    [DateTimeOffset]::new([DateTime]$snapshot.capturedAt).ToUniversalTime()
                }
                else {
                    [DateTimeOffset]::Parse([string]$snapshot.capturedAt).ToUniversalTime()
                }
                $age = $now - $capturedAt
                if ($age.TotalMinutes -lt 0 -or $age.TotalMinutes -gt $MaxAgeMinutes) {
                    Write-Verbose "Skipping snapshot outside freshness window: $($snapshotFile.FullName)"
                    continue
                }
                if ($snapshot.complete -ne $true) {
                    Write-Verbose "Skipping incomplete snapshot: $($snapshotFile.FullName)"
                    continue
                }
                if ($coinGlassPublicRoute -in $plan.coinGlass.routes -and @($snapshot.coinGlass | Where-Object {
                    $_.requested -eq $coinGlassPublicRoute -and $_.ready -eq $true -and -not $_.metricId
                }).Count -gt 0) { continue }
                if (-not (Test-ExactStringSet -Actual @($snapshot.symbolsRequested) -Expected @($Symbols))) {
                    Write-Verbose "Skipping snapshot with a different symbol scope: $($snapshotFile.FullName)"
                    continue
                }
                if (-not (Test-ExactStringSet -Actual @($snapshot.requiredTimeframes) -Expected @($periods))) {
                    Write-Verbose "Skipping snapshot with different timeframes: $($snapshotFile.FullName)"
                    continue
                }
                if ($null -eq $snapshot.socialIntelligence -or
                    -not (Test-ExactStringSet -Actual @($snapshot.socialIntelligence.scope.cryptoAssets) -Expected @($socialPlan.scope.cryptoAssets)) -or
                    -not (Test-ExactStringSet -Actual @($snapshot.socialIntelligence.scope.candidateAssets) -Expected @($socialPlan.scope.candidateAssets))) {
                    Write-Verbose "Skipping snapshot with missing or different social-intelligence scope: $($snapshotFile.FullName)"
                    continue
                }
                $compatibleSnapshot = $snapshot
            }
            catch {
                Write-Verbose "Skipping unreadable snapshot $($snapshotFile.FullName): $($_.Exception.Message)"
                continue
            }
            if ($null -ne $compatibleSnapshot) {
                $compatibleSnapshot = Add-DeferredOrderAlerts -Snapshot $compatibleSnapshot
                Write-RefreshResult -Snapshot $compatibleSnapshot -SnapshotPath $snapshotFile.FullName -Reused $true -IncludeFullJson ([bool]$EmitFullJson)
                exit 0
            }
        }
    }
}

$mutex = [Threading.Mutex]::new($false, $mutexName)
$acquired = $false
try {
    $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($MutexTimeoutSeconds))
    if (-not $acquired) {
        throw 'Timed out waiting for the analysis-wide TradingView mutex.'
    }

    if ($LockProbe) {
        'ACQUIRED'
        if ($HoldLockSeconds -gt 0) { Start-Sleep -Seconds $HoldLockSeconds }
        exit 0
    }

    $node = & $nodeResolver
    $capturedAt = [DateTime]::UtcNow.ToString('o')
    $failures = [Collections.Generic.List[object]]::new()

    $tvScreener = $null
    $screenerReady = $false
    $previousScreenerUrl = $env:ANALYSIS_TRADINGVIEW_SCREENER_URL
    $previousScreenerShell = $env:ANALYSIS_POWERSHELL_PATH
    try {
        $env:ANALYSIS_TRADINGVIEW_SCREENER_URL = [string]$plan.tradingViewScreener.endpoint
        if (-not $previousScreenerShell -and $PSVersionTable.PSVersion.Major -ge 7) {
            $env:ANALYSIS_POWERSHELL_PATH = (Get-Process -Id $PID).Path
        }
        $screenerRaw = & $node $tvScreenerScript "--timeframes=$($periods -join ',')" "--timeout-ms=$([int]$plan.tradingViewScreener.timeoutSeconds * 1000)" @Symbols
        if ($LASTEXITCODE -ne 0) { throw "TradingView Screener collector exited with code $LASTEXITCODE." }
        $tvScreener = ($screenerRaw -join "`n") | ConvertFrom-Json
        $screenerReady = $true
    }
    catch {
        $failures.Add([ordered]@{ source='tradingViewScreener'; symbol=$null; timeframe=$null; reason=$_.Exception.Message; required=$false })
        $tvScreener = [ordered]@{ source='tradingview_screener'; capturedAt=$capturedAt; results=@() }
    }
    finally {
        $env:ANALYSIS_TRADINGVIEW_SCREENER_URL = $previousScreenerUrl
        $env:ANALYSIS_POWERSHELL_PATH = $previousScreenerShell
    }

    $deepScope = $null
    if ($Profile -eq 'screen') {
        $deepSymbolsResolved = @()
        $deepScope = [pscustomobject]@{ schemaVersion=1; maxSymbols=0; boundaryPercent=$criticalBoundaryPercent; symbols=@(); reasons=[pscustomobject]@{} }
    }
    elseif ($symbolScopeWasExplicit -and $Profile -ne 'portfolio') {
        $deepSymbolsResolved = @($Symbols)
        $reasonName = if ($screenerReady) { 'explicit_scope' } else { 'screener_unavailable_fallback' }
        $reasonObject = [ordered]@{}
        foreach ($symbol in $deepSymbolsResolved) { $reasonObject[$symbol] = @($reasonName) }
        $deepScope = [pscustomobject]@{ schemaVersion=1; maxSymbols=@($Symbols).Count; boundaryPercent=$criticalBoundaryPercent; symbols=$deepSymbolsResolved; reasons=[pscustomobject]$reasonObject }
    }
    else {
        $screenerTemporary = Join-Path ([IO.Path]::GetTempPath()) ('tv-screener-' + [guid]::NewGuid().ToString('N') + '.json')
        try {
            $tvScreener | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $screenerTemporary -Encoding utf8
            $candidateScope = if ($null -ne $dynamicScope) { @($dynamicScope.candidateSymbols) } else { @($CandidateSymbols) }
            $explicitDeep = @($IncludeSymbols) + @($DeepSymbols)
            $deepRaw = & $deepScopeScript -ProjectRoot $projectRoot -Symbols $Symbols -CandidateSymbols $candidateScope -IncludeSymbols $explicitDeep -ScannerPath $screenerTemporary -MaxSymbols $deepMaxSymbols -BoundaryPercent $criticalBoundaryPercent
            $deepScope = ($deepRaw -join "`n") | ConvertFrom-Json
            $deepSymbolsResolved = @($deepScope.symbols)
        }
        finally {
            if (Test-Path -LiteralPath $screenerTemporary) { Remove-Item -LiteralPath $screenerTemporary -Force }
        }
    }

    $tv = [ordered]@{ source='tradingview_desktop'; capturedAt=$capturedAt; symbolsRequested=@($deepSymbolsResolved); results=@() }
    if (@($deepSymbolsResolved).Count -gt 0) {
        try {
            $tvRaw = & $node $tvScript "--timeframes=$($periods -join ',')" @deepSymbolsResolved
            if ($LASTEXITCODE -ne 0) { throw "TradingView collector exited with code $LASTEXITCODE." }
            $tv = ($tvRaw -join "`n") | ConvertFrom-Json
        }
        catch {
            $failures.Add([ordered]@{ source='tradingViewDesktop'; symbol=$null; timeframe=$null; reason=$_.Exception.Message; required=$false })
            $tv = [ordered]@{ source='tradingview_desktop'; capturedAt=$capturedAt; symbolsRequested=@($deepSymbolsResolved); results=@() }
        }
    }

    foreach ($symbol in $Symbols) {
        $fastItem = @($tvScreener.results | Where-Object symbol -eq $symbol | Select-Object -First 1)[0]
        $deepItem = @($tv.results | Where-Object symbol -eq $symbol | Select-Object -First 1)[0]
        if ($fastItem.error) {
            $failures.Add([ordered]@{ source='tradingViewScreener'; symbol=$symbol; timeframe=$null; reason=[string]$fastItem.error; required=$false })
        }
        if ($deepItem.error) {
            $failures.Add([ordered]@{ source='tradingViewDesktop'; symbol=$symbol; timeframe=$null; reason=[string]$deepItem.error; required=$false })
        }
        foreach ($period in $periods) {
            $fastPeriod = if ($fastItem) { $fastItem.periods.$period } else { $null }
            $deepPeriod = if ($deepItem) { $deepItem.periods.$period } else { $null }
            if ($fastPeriod -and -not $fastPeriod.ok) {
                $failures.Add([ordered]@{ source='tradingViewScreener'; symbol=$symbol; timeframe=$period; reason=if($fastPeriod.error){[string]$fastPeriod.error}else{'failed_timeframe'}; required=$false })
            }
            if ($deepPeriod -and -not $deepPeriod.ok) {
                $failures.Add([ordered]@{ source='tradingViewDesktop'; symbol=$symbol; timeframe=$period; reason=if($deepPeriod.error){[string]$deepPeriod.error}else{'failed_timeframe'}; required=$false })
            }
            if ((-not $fastPeriod -or -not $fastPeriod.ok) -and (-not $deepPeriod -or -not $deepPeriod.ok)) {
                $failures.Add([ordered]@{ source='tradingView'; symbol=$symbol; timeframe=$period; reason='no_current_screener_or_deep_result'; required=$true })
            }
        }
    }

    $coinGlass = [Collections.Generic.List[object]]::new()
    $coinGlassCache = @{}
    if (-not $ForceRefresh -and $plan.coinGlass.cacheMaxAgeMinutes -gt 0) {
        $coinGlassRuntimeDirectory = Join-Path $projectRoot 'state\snapshots\runtime'
        if (Test-Path -LiteralPath $coinGlassRuntimeDirectory -PathType Container) {
            $coinGlassNow = [DateTimeOffset]::UtcNow
            $coinGlassSnapshotFiles = Get-ChildItem -LiteralPath $coinGlassRuntimeDirectory -Filter '*.json' -File |
                Sort-Object LastWriteTimeUtc -Descending
            foreach ($coinGlassSnapshotFile in $coinGlassSnapshotFiles) {
                try {
                    $coinGlassSnapshot = Get-Content -Raw -LiteralPath $coinGlassSnapshotFile.FullName | ConvertFrom-Json
                    foreach ($cachedItem in @($coinGlassSnapshot.coinGlass)) {
                        $cachedRoute = [string]$cachedItem.requested
                        if (-not $cachedRoute -or $cachedItem.ready -ne $true -or $coinGlassCache.ContainsKey($cachedRoute)) { continue }
                        if ($cachedRoute -eq $coinGlassPublicRoute -and (-not $cachedItem.metricId -or -not $cachedItem.dataDate -or $cachedItem.route -ne $coinGlassPublicRoute)) { continue }
                        # ConvertFrom-Json materializes ISO timestamps as DateTime.
                        # Casting that to string discards Kind/offset and shifts UTC
                        # by the host timezone on the subsequent Parse.
                        $cachedAtValue = if ($cachedItem.checkedAt) { $cachedItem.checkedAt } else { $coinGlassSnapshot.capturedAt }
                        $cachedAt = if ($cachedAtValue -is [DateTime]) {
                            [DateTimeOffset]::new([DateTime]$cachedAtValue).ToUniversalTime()
                        } else {
                            [DateTimeOffset]::Parse([string]$cachedAtValue).ToUniversalTime()
                        }
                        $cacheAge = $coinGlassNow - $cachedAt
                        if ($cacheAge.TotalMinutes -lt 0 -or $cacheAge.TotalMinutes -gt $plan.coinGlass.cacheMaxAgeMinutes) { continue }
                        $cachedCopy = [ordered]@{}
                        foreach ($property in $cachedItem.PSObject.Properties) { $cachedCopy[$property.Name] = $property.Value }
                        $cachedCopy['provenance'] = 'fresh_cache'
                        $cachedCopy['cacheAgeMinutes'] = [math]::Round($cacheAge.TotalMinutes, 2)
                        $cachedCopy['cacheSnapshot'] = if ($cachedItem.cacheSnapshot) { $cachedItem.cacheSnapshot } else { $coinGlassSnapshotFile.Name }
                        $coinGlassCache[$cachedRoute] = $cachedCopy
                    }
                }
                catch {
                    Write-Verbose "Skipping unreadable CoinGlass cache $($coinGlassSnapshotFile.FullName): $($_.Exception.Message)"
                }
            }
        }
    }
    $uncachedCoinGlassRoutes = @($plan.coinGlass.routes | Where-Object { $_ -ne $coinGlassPublicRoute -and -not $coinGlassCache.ContainsKey([string]$_) })
    $coinGlassBrowserReady = ($uncachedCoinGlassRoutes.Count -eq 0)
    $coinGlassBrowserFailure = $null
    if ($uncachedCoinGlassRoutes.Count -gt 0) {
        try {
            $browserRaw = & $node $coinGlassBrowserScript
            if ($LASTEXITCODE -ne 0) { throw "CoinGlass browser helper exited with code $LASTEXITCODE." }
            $browserResult = ($browserRaw -join "`n") | ConvertFrom-Json
            if (-not $browserResult.ready) { throw "CoinGlass browser is not ready: $($browserResult.reason)" }
            $coinGlassBrowserReady = $true
        }
        catch {
            $coinGlassBrowserFailure = $_.Exception.Message
            $failures.Add([ordered]@{ source='coinGlassBrowser'; reason=$coinGlassBrowserFailure; required=[bool]$plan.coinGlass.required })
        }
    }
    foreach ($route in $plan.coinGlass.routes) {
        if ($coinGlassCache.ContainsKey([string]$route)) {
            $coinGlass.Add($coinGlassCache[[string]$route])
            continue
        }
        if (-not $coinGlassBrowserReady -and $route -ne $coinGlassPublicRoute) {
            $reason = if ($coinGlassBrowserFailure) { $coinGlassBrowserFailure } else { 'CoinGlass browser is unavailable.' }
            $coinGlass.Add([ordered]@{ source='coinglass'; requested=$route; ready=$false; reason='browser_unavailable'; detail=$reason })
            $failures.Add([ordered]@{ source='coinGlass'; route=$route; reason='browser_unavailable'; required=[bool]$plan.coinGlass.required })
            continue
        }
        try {
            $raw = & $node $coinGlassScript $route
            $coinGlassExitCode = $LASTEXITCODE
            $parsed = ($raw -join "`n") | ConvertFrom-Json
            $coinGlass.Add($parsed)
            if ($parsed.ready -eq $false) {
                $failures.Add([ordered]@{ source='coinGlass'; route=$route; reason=[string]$parsed.reason; required=[bool]$plan.coinGlass.required })
            }
            elseif ($coinGlassExitCode -ne 0) {
                $failures.Add([ordered]@{ source='coinGlass'; route=$route; reason="collector_exit_$coinGlassExitCode"; required=[bool]$plan.coinGlass.required })
            }
        }
        catch {
            $coinGlass.Add([ordered]@{ source='coinglass'; requested=$route; ready=$false; reason=$_.Exception.Message })
            $failures.Add([ordered]@{ source='coinGlass'; route=$route; reason=$_.Exception.Message; required=[bool]$plan.coinGlass.required })
        }
    }

    $fearGreed = $null
    try {
        $fearGreedResponse = Invoke-RestMethod -Uri $plan.cryptoFearGreed.url -TimeoutSec 20
        $fearGreed = @($fearGreedResponse.data)
    }
    catch {
        $failures.Add([ordered]@{ source='cryptoFearGreed'; reason=$_.Exception.Message; required=[bool]$plan.cryptoFearGreed.required })
    }

    $polymarket = $null
    try {
        $polyRaw = & $node $polyMarketScript $plan.polymarket.query
        $polyExitCode = $LASTEXITCODE
        $polyText = $polyRaw -join "`n"
        try { $polymarket = $polyText | ConvertFrom-Json }
        catch { $polymarket = [ordered]@{ source='polymarket'; raw=$polyText } }
        if ($polyExitCode -ne 0 -or $polymarket.ready -eq $false) {
            $reason = if ($polymarket.reason) { $polymarket.reason } else { "Polymarket collector exited with code $polyExitCode." }
            throw $reason
        }
    }
    catch {
        $failures.Add([ordered]@{ source='polymarket'; reason=$_.Exception.Message; required=[bool]$plan.polymarket.required })
    }

    $x = $null
    try {
        $previousXCacheMaxAge = $env:ANALYSIS_X_CACHE_MAX_AGE_MINUTES
        $previousXCachePath = $env:ANALYSIS_X_CACHE_PATH
        $env:ANALYSIS_X_CACHE_MAX_AGE_MINUTES = [string]$socialPlan.x.cacheMaxAgeMinutes
        New-Item -ItemType Directory -Path (Split-Path -Parent $plan.x.cachePath) -Force | Out-Null
        $xQueryResults = [Collections.Generic.List[object]]::new()
        . (Join-Path $projectRoot 'scripts/x-asset-coverage-lib.ps1')
        $xItems = [Collections.Generic.List[object]]::new()
        $seenXItems = @{}
        $coveredXAssets = [Collections.Generic.List[string]]::new()
        $xQueryIndex = 0
        foreach ($queryPlan in @($socialPlan.x.queries)) {
            $xQueryIndex++
            $queryCachePath = Join-Path (Split-Path -Parent $plan.x.cachePath) ("x-live-$xQueryIndex.json")
            $env:ANALYSIS_X_CACHE_PATH = $queryCachePath
            try {
                $xEnvelopeRaw = & $xInvoker -CollectorPath $xScript -Query ([string]$queryPlan.query) -Envelope
                $xEnvelope = (($xEnvelopeRaw -join "`n") | ConvertFrom-Json)
                $xResult = ([string]$xEnvelope.stdout | ConvertFrom-Json)
                $queryItems = @($xResult.items | Where-Object { $_ } | Select-Object -First ([int]$socialPlan.x.maxItemsPerQuery))
                $queryReady = ([int]$xEnvelope.exitCode -eq 0 -and $xResult.ready -eq $true -and $queryItems.Count -gt 0)
                $matchedAssets = @(if ($queryReady) { Get-XMatchedAssets -Assets @($queryPlan.assets) -Items $queryItems })
                $queryCovered = @(if (-not $xResult.degraded) { $matchedAssets })
                if ($queryReady) {
                    foreach ($asset in $queryCovered) {
                        if ($asset -notin @($coveredXAssets)) { $coveredXAssets.Add([string]$asset) }
                    }
                    foreach ($item in $queryItems) {
                        $identity = if ($item.id) { [string]$item.id } elseif ($item.url) { [string]$item.url } else { ([string]$item.author + '|' + [string]$item.text) }
                        if (-not $seenXItems.ContainsKey($identity)) { $seenXItems[$identity]=$true; $xItems.Add($item) }
                    }
                }
                $xQueryResults.Add([pscustomobject]@{
                    kind = [string]$queryPlan.kind
                    assets = @($queryPlan.assets)
                    matchedAssets = $matchedAssets
                    coveredAssets = $queryCovered
                    uncoveredAssets = @($queryPlan.assets | Where-Object { $_ -notin $queryCovered })
                    query = [string]$queryPlan.query
                    ready = $queryReady
                    reason = [string]$xResult.reason
                    provenance = [string]$xResult.provenance
                    cacheSourceProvenance = $xResult.cacheSourceProvenance
                    degraded = [bool]$xResult.degraded
                    searchDiagnostics = @($xResult.searchDiagnostics)
                    checkedAt = $xResult.checkedAt
                    capturedAt = $xResult.capturedAt
                    cacheAgeMinutes = $xResult.cacheAgeMinutes
                    itemCount = @($xResult.items).Count
                })
            }
            catch {
                $xQueryResults.Add([pscustomobject]@{ kind=[string]$queryPlan.kind; assets=@($queryPlan.assets); matchedAssets=@(); coveredAssets=@(); uncoveredAssets=@($queryPlan.assets); query=[string]$queryPlan.query; ready=$false; reason=$_.Exception.Message; degraded=$true; itemCount=0 })
            }
        }
        $readyXQueries = @($xQueryResults | Where-Object ready)
        $failedXQueries = @($xQueryResults | Where-Object { -not $_.ready -or $_.degraded })
        $plannedXAssets = @(@($socialPlan.x.uncoveredAssets) + @($xQueryResults | ForEach-Object { $_.assets }) | Select-Object -Unique)
        $uncoveredXAssets = @($plannedXAssets | Where-Object { $_ -notin $coveredXAssets })
        $x = [pscustomobject]@{
            source = 'x'
            ready = ($readyXQueries.Count -gt 0)
            reason = if ($readyXQueries.Count -eq 0) { 'all_queries_unavailable' } elseif ($uncoveredXAssets.Count -gt 0 -or $failedXQueries.Count -gt 0) { 'partial_query_coverage' } else { $null }
            provenance = 'multi_query_account_scope'
            degraded = ($uncoveredXAssets.Count -gt 0 -or $failedXQueries.Count -gt 0)
            checkedAt = [DateTimeOffset]::UtcNow.ToString('o')
            queries = @($xQueryResults)
            coveredAssets = @($coveredXAssets)
            uncoveredAssets = $uncoveredXAssets
            items = @($xItems)
        }
        if ($x.ready -eq $false) {
            $failures.Add([ordered]@{ source='x'; reason=[string]$x.reason; required=[bool]$socialPlan.x.required })
        }
    }
    catch {
        $failures.Add([ordered]@{ source='x'; reason=$_.Exception.Message; required=[bool]$socialPlan.x.required })
    }
    finally {
        $env:ANALYSIS_X_CACHE_MAX_AGE_MINUTES = $previousXCacheMaxAge
        $env:ANALYSIS_X_CACHE_PATH = $previousXCachePath
    }

    $requiredFailures = @($failures | Where-Object required)
    $result = [ordered]@{
        schemaVersion = 2
        capturedAt = $capturedAt
        complete = ($requiredFailures.Count -eq 0)
        symbolsRequested = @($Symbols)
        requiredTimeframes = $periods
        failures = @($failures)
        tradingViewScreener = $tvScreener
        tradingViewDeepScope = $deepScope
        tradingView = $tv
        coinGlass = @($coinGlass)
        cryptoFearGreed = $fearGreed
        polymarket = $polymarket
        x = $x
        socialIntelligence = $socialPlan
    }
    $result = Add-DeferredOrderAlerts -Snapshot ([pscustomobject]$result)
    $json = $result | ConvertTo-Json -Depth 30

    if (-not $OutputPath) {
        $runtimeDirectory = Join-Path $projectRoot 'state\snapshots\runtime'
        New-Item -ItemType Directory -Path $runtimeDirectory -Force | Out-Null
        $OutputPath = Join-Path $runtimeDirectory ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmssfff') + '.json')
    }
    $resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
    $outputDirectory = Split-Path -Parent $resolvedOutput
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    $temporary = Join-Path $outputDirectory ('.refresh-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json | Set-Content -LiteralPath $temporary -Encoding utf8
        Move-Item -LiteralPath $temporary -Destination $resolvedOutput -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
    Write-RefreshResult -Snapshot $result -SnapshotPath $resolvedOutput -Reused $false -IncludeFullJson ([bool]$EmitFullJson)
    if ($result.complete) { exit 0 }
    exit 1
}
finally {
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
