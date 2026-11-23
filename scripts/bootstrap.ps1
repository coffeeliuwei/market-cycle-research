param([switch]$SkipInstall)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$overviewBuilder = Join-Path $projectRoot 'scripts\build-account-overview.ps1'
$mcpRoot = Join-Path $projectRoot 'tradingview-mcp'
$packageLock = Join-Path $mcpRoot 'package-lock.json'
if (-not (Test-Path -LiteralPath $packageLock -PathType Leaf)) {
    throw "TradingView MCP package lock is missing: $packageLock"
}

New-Item -ItemType Directory -Path (Join-Path $projectRoot 'state\snapshots\runtime') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $projectRoot 'logs') -Force | Out-Null

if (-not $SkipInstall) {
    $npm = Get-Command npm.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $npm) { $npm = Get-Command npm -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if (-not $npm) {
        $node = & (Join-Path $projectRoot 'scripts\resolve-node.ps1')
        $candidate = Join-Path (Split-Path -Parent $node) 'npm.cmd'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $npm = Get-Item -LiteralPath $candidate }
    }
    if (-not $npm) { throw 'npm was not found. Install Node.js with npm, then rerun bootstrap.' }
    & $npm.Source ci --prefix $mcpRoot
    if ($LASTEXITCODE -ne 0) { throw "npm ci failed with code $LASTEXITCODE." }
}

& $overviewBuilder | Out-Null

& (Join-Path $projectRoot 'scripts\doctor.ps1') -Offline
