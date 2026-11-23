param(
    [Parameter(Mandatory)]
    [string]$Scope,

    [Parameter(Mandatory)]
    [string]$Statement,

    [string[]]$Supersedes = @(),

    [string]$StorePath
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $StorePath) {
    $StorePath = Join-Path $projectRoot 'state\decisions\decisions.jsonl'
}
$resolvedStore = [IO.Path]::GetFullPath($StorePath)
$storeDirectory = Split-Path -Parent $resolvedStore
New-Item -ItemType Directory -Path $storeDirectory -Force | Out-Null

if ([string]::IsNullOrWhiteSpace($Scope)) { throw 'Scope cannot be empty.' }
if ([string]::IsNullOrWhiteSpace($Statement)) { throw 'Statement cannot be empty.' }

$decision = [ordered]@{
    id = 'decision-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmssfff') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    effectiveAt = [DateTime]::UtcNow.ToString('o')
    scope = $Scope.Trim()
    statement = $Statement.Trim()
    status = 'active'
    supersedes = @($Supersedes | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

$mutex = [Threading.Mutex]::new($false, 'Local\TradingviewDecisionStoreV1')
$acquired = $false
try {
    $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(10))
    if (-not $acquired) { throw 'Timed out waiting for the decision store lock.' }

    $existing = if (Test-Path -LiteralPath $resolvedStore) {
        @(Get-Content -LiteralPath $resolvedStore | Where-Object { $_.Trim() })
    }
    else { @() }
    $lines = @($existing) + ($decision | ConvertTo-Json -Compress -Depth 8)
    $temporary = Join-Path $storeDirectory ('.decisions-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $lines | Set-Content -LiteralPath $temporary -Encoding utf8
        Move-Item -LiteralPath $temporary -Destination $resolvedStore -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}
finally {
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}

$decision | ConvertTo-Json -Depth 8
