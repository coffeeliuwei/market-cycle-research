param(
    [switch]$Json,
    [switch]$Offline,
    [switch]$Repair,
    [string]$ProjectRoot,
    [int]$CdpPort = 9222,
    [string]$EnsureScript
)

$ErrorActionPreference = 'Stop'
if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
if (-not $EnsureScript) { $EnsureScript = Join-Path $ProjectRoot 'scripts\ensure-tradingview-cdp.ps1' }
$checks = [Collections.Generic.List[object]]::new()

function Add-Check {
    param([string]$Name, [bool]$Ok, [bool]$Required, [string]$Details)
    $checks.Add([ordered]@{ name=$Name; ok=$Ok; required=$Required; details=$Details })
}

$requiredFiles = @(
    'AGENTS.md',
    'WORKFLOW.md',
    'PORTFOLIO.md',
    'config\watchlist.json',
    'config\accounts.json',
    'config\sources.json',
    'config\official-mcp-sources.json',
    'opencode.jsonc',
    'state\decisions\decisions.jsonl',
    'collectors\tradingview-refresh.mjs',
    'collectors\tradingview-screener.mjs',
    'collectors\tradingview-screener-core.mjs',
    'collectors\coinglass-live.mjs',
    'collectors\polymarket-live.mjs',
    'collectors\x-live.mjs',
    'scripts\run-analysis-refresh.ps1',
    'scripts\build-account-overview.ps1',
    'scripts\resolve-node.ps1',
    'scripts\invoke-x-collector.ps1',
    'scripts\invoke-json-post.ps1',
    'scripts\resolve-tradingview-deep-symbols.ps1',
    'scripts\setup-x.ps1',
    'scripts\setup-official-market-mcps.ps1',
    'scripts\configure-x-auth.ps1',
    'tradingview-mcp\package.json',
    'tradingview-mcp\package-lock.json'
)
foreach ($relative in $requiredFiles) {
    $path = Join-Path $ProjectRoot $relative
    Add-Check -Name ($relative -replace '\\','/') -Ok (Test-Path -LiteralPath $path -PathType Leaf) -Required $true -Details $path
}

$nodePath = $null
$resolver = Join-Path $ProjectRoot 'scripts\resolve-node.ps1'
if (Test-Path -LiteralPath $resolver -PathType Leaf) {
    try {
        $nodePath = & $resolver
        $version = (& $nodePath --version 2>&1) -join ' '
        Add-Check -Name 'runtime/node' -Ok ($LASTEXITCODE -eq 0) -Required $true -Details "$nodePath $version"
    }
    catch { Add-Check -Name 'runtime/node' -Ok $false -Required $true -Details $_.Exception.Message }
}
else {
    Add-Check -Name 'runtime/node' -Ok $false -Required $true -Details 'Node resolver is missing.'
}

$nodeModules = Join-Path $ProjectRoot 'tradingview-mcp\node_modules\@modelcontextprotocol\sdk'
Add-Check -Name 'runtime/mcp-dependencies' -Ok (Test-Path -LiteralPath $nodeModules -PathType Container) -Required $true -Details $nodeModules

$xRuntimeRoot = Join-Path $ProjectRoot '.tools\x-runtime\Scripts'
$xAgentReach = Join-Path $xRuntimeRoot 'agent-reach.exe'
$xTwitter = Join-Path $xRuntimeRoot 'twitter.exe'
$xRuntimeOk = (Test-Path -LiteralPath $xAgentReach -PathType Leaf) -and (Test-Path -LiteralPath $xTwitter -PathType Leaf)
Add-Check -Name 'optional/x-runtime' -Ok $xRuntimeOk -Required $false -Details "$xAgentReach; $xTwitter"
$xCredentialPath = Join-Path $ProjectRoot 'state\private\x-auth.clixml'
Add-Check -Name 'optional/x-authentication' -Ok (Test-Path -LiteralPath $xCredentialPath -PathType Leaf) -Required $false -Details $xCredentialPath

$tradingViewExecutable = $null
try {
    $running = Get-Process -Name TradingView -ErrorAction SilentlyContinue |
        Where-Object Path | Select-Object -First 1
    if ($running -and (Test-Path -LiteralPath $running.Path -PathType Leaf)) {
        $tradingViewExecutable = $running.Path
    }
    if (-not $tradingViewExecutable) {
        $package = Get-AppxPackage -Name 'TradingView.Desktop' -ErrorAction SilentlyContinue |
            Sort-Object Version -Descending | Select-Object -First 1
        if ($package) {
            $candidate = Join-Path $package.InstallLocation 'TradingView.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $tradingViewExecutable = $candidate }
        }
    }
}
catch { }
Add-Check -Name 'runtime/tradingview-installation' -Ok ([bool]$tradingViewExecutable) -Required $true -Details ([string]$tradingViewExecutable)

if (-not $Offline) {
    $cdpOk = $false
    $cdpUrl = "http://127.0.0.1:$CdpPort/json/version"
    $details = $cdpUrl
    try {
        $version = Invoke-RestMethod -Uri $cdpUrl -TimeoutSec 2
        $cdpOk = [bool]$version.webSocketDebuggerUrl
    }
    catch { $details = $_.Exception.Message }

    if (-not $cdpOk -and $Repair) {
        try {
            if (-not (Test-Path -LiteralPath $EnsureScript -PathType Leaf)) {
                throw "TradingView CDP recovery script is missing: $EnsureScript"
            }
            $shell = (Get-Process -Id $PID).Path
            & $shell -NoProfile -File $EnsureScript -Port $CdpPort -StartupTimeoutSeconds 30 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "TradingView CDP recovery exited with code $LASTEXITCODE." }
            $version = Invoke-RestMethod -Uri $cdpUrl -TimeoutSec 2
            $cdpOk = [bool]$version.webSocketDebuggerUrl
            $details = if ($cdpOk) { "$cdpUrl (repaired)" } else { 'TradingView CDP recovery completed but the endpoint is still unavailable.' }
        }
        catch {
            $details = "Repair failed: $($_.Exception.Message)"
        }
    }
    Add-Check -Name 'runtime/tradingview-cdp' -Ok $cdpOk -Required $true -Details $details
}

$snapshotDirectory = Join-Path $ProjectRoot 'state\snapshots\runtime'
$writable = $false
$snapshotDetail = $snapshotDirectory
try {
    New-Item -ItemType Directory -Path $snapshotDirectory -Force | Out-Null
    $probe = Join-Path $snapshotDirectory ('.doctor-' + [guid]::NewGuid().ToString('N') + '.tmp')
    'ok' | Set-Content -LiteralPath $probe -Encoding utf8
    Remove-Item -LiteralPath $probe -Force
    $writable = $true
}
catch {
    # Keep the real reason in the report. A swallowed exception here previously
    # reported a bare "not writable" with no cause, which made a sandboxed or
    # permission-denied probe indistinguishable from a genuinely bad path.
    $snapshotDetail = "$snapshotDirectory :: $($_.Exception.Message)"
}
Add-Check -Name 'runtime/snapshot-writable' -Ok $writable -Required $true -Details $snapshotDetail

$requiredFailures = @($checks | Where-Object { $_.required -and -not $_.ok })
$report = [ordered]@{
    schemaVersion = 1
    checkedAt = [DateTime]::UtcNow.ToString('o')
    projectRoot = $ProjectRoot
    offline = [bool]$Offline
    ok = ($requiredFailures.Count -eq 0)
    checks = @($checks)
}

if ($Json) { $report | ConvertTo-Json -Depth 8 }
else {
    $checks | Format-Table name,ok,required,details -AutoSize
    "Doctor OK: $($report.ok)"
}
if (-not $report.ok) { exit 1 }
