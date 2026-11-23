param(
    [ValidateSet('All','Codex','OpenCode')]
    [string]$HostName = 'All',
    [switch]$Apply,
    [switch]$EnableBinance
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$sourcePath = Join-Path $projectRoot 'config\official-mcp-sources.json'
$openCodePath = Join-Path $projectRoot 'opencode.jsonc'
$sources = Get-Content -Raw -LiteralPath $sourcePath | ConvertFrom-Json

function Get-CommandPath([string]$Name) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

$result = [ordered]@{
    schemaVersion = 1
    projectRoot = $projectRoot
    applyRequested = [bool]$Apply
    tradingView = [ordered]@{
        url = $sources.tradingViewOfficial.url
        enabled = [bool]$sources.tradingViewOfficial.enabledByDefault
        authenticationRequired = $true
        disabledReason = $sources.tradingViewOfficial.disabledReason
    }
    binance = [ordered]@{
        url = $sources.binanceOfficial.url
        enabled = [bool]$EnableBinance
        authenticationRequired = $true
        allowedScopes = @($sources.binanceOfficial.allowedScopes)
        forbiddenScopes = @($sources.binanceOfficial.forbiddenScopes)
    }
    hosts = @()
}

if ($HostName -in @('All','OpenCode')) {
    $openCode = Get-CommandPath 'opencode'
    $entry = [ordered]@{
        host = 'OpenCode'
        cli = $openCode
        projectConfig = $openCodePath
        configured = (Test-Path -LiteralPath $openCodePath -PathType Leaf)
        applied = $false
        nextStep = 'TradingView official MCP is disabled for the free account. Keep using the project Screener and desktop-CDP path.'
    }
    if ($Apply -and $openCode) {
        & $openCode mcp auth tradingview-official
        $entry.applied = ($LASTEXITCODE -eq 0)
    }
    $result.hosts += $entry
}

if ($HostName -in @('All','Codex')) {
    $codex = Get-CommandPath 'codex'
    $entry = [ordered]@{
        host = 'Codex'
        cli = $codex
        configured = $false
        applied = $false
        nextStep = 'TradingView official MCP is disabled for the free account. Keep using the project Screener and desktop-CDP path.'
    }
    if ($Apply -and $codex) {
        & $codex mcp add tradingview-official --url $sources.tradingViewOfficial.url
        $entry.configured = ($LASTEXITCODE -eq 0)
        $entry.applied = $entry.configured
        if ($EnableBinance) {
            & $codex mcp add binance-official --url $sources.binanceOfficial.url
            if ($LASTEXITCODE -ne 0) { $entry.applied = $false }
            $entry.nextStep = 'Complete Binance OAuth with only Market data and Read account; reject Trade and Transfer.'
        }
    }
    elseif ($codex) {
        $entry.nextStep = 'Run this script with -HostName Codex -Apply, then complete OAuth.'
    }
    $result.hosts += $entry
}

$result | ConvertTo-Json -Depth 8
