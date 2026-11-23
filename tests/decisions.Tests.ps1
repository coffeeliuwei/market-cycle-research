$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$record = Join-Path $root 'scripts\record-decision.ps1'
$effective = Join-Path $root 'scripts\get-effective-decisions.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("tradingview-decisions-" + [guid]::NewGuid().ToString('N'))
$store = Join-Path $tempRoot 'decisions.jsonl'
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    '{"id":"old-rule","effectiveAt":"2026-08-01T00:00:00Z","scope":"gate:STX","statement":"old","status":"active","supersedes":[]}' |
        Set-Content -LiteralPath $store -Encoding utf8

    $created = & $record -Scope 'gate:STX' -Statement 'STX不到1 USDC以上不卖。' -Supersedes 'old-rule' -StorePath $store |
        ConvertFrom-Json
    if (-not $created.id -or $created.status -ne 'active') {
        throw 'record-decision did not return a valid active decision.'
    }

    $resolved = @(& $effective -Scope 'gate:STX' -StorePath $store | ConvertFrom-Json)
    if ($resolved.Count -ne 1) { throw "Expected one effective decision, got $($resolved.Count)." }
    if ($resolved[0].statement -ne 'STX不到1 USDC以上不卖。') {
        throw 'The new STX decision did not supersede the old rule.'
    }

    $lines = @(Get-Content -LiteralPath $store | Where-Object { $_.Trim() })
    if ($lines.Count -ne 2) { throw 'Decision recording was not append-only.' }

    'PASS decisions'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
