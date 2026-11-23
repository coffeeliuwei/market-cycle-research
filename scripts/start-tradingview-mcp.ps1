param()

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$node = & (Join-Path $projectRoot 'scripts\resolve-node.ps1')
$server = Join-Path $projectRoot 'tradingview-mcp\src\server.js'
if (-not (Test-Path -LiteralPath $server -PathType Leaf)) {
    throw "TradingView MCP server is missing: $server"
}

& $node $server
exit $LASTEXITCODE
