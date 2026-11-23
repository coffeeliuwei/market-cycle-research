param(
    [string]$Scope,
    [string]$StorePath
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $StorePath) {
    $StorePath = Join-Path $projectRoot 'state\decisions\decisions.jsonl'
}
$resolvedStore = [IO.Path]::GetFullPath($StorePath)
if (-not (Test-Path -LiteralPath $resolvedStore -PathType Leaf)) {
    throw "Decision store is missing: $resolvedStore"
}

$records = @(Get-Content -LiteralPath $resolvedStore |
    Where-Object { $_.Trim() } |
    ForEach-Object { $_ | ConvertFrom-Json })

$superseded = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($record in $records | Where-Object status -eq 'active') {
    foreach ($id in @($record.supersedes)) {
        if ($id) { [void]$superseded.Add([string]$id) }
    }
}

$effective = @($records |
    Where-Object {
        $_.status -eq 'active' -and
        -not $superseded.Contains([string]$_.id) -and
        (-not $Scope -or $_.scope -eq $Scope)
    } |
    Sort-Object effectiveAt)

ConvertTo-Json -InputObject $effective -Depth 8
