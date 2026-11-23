param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$candidates = [Collections.Generic.List[string]]::new()

if ($env:ANALYSIS_NODE_PATH) { $candidates.Add($env:ANALYSIS_NODE_PATH) }

$command = Get-Command node -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($command) { $candidates.Add($command.Source) }

if ($env:USERPROFILE) {
    $candidates.Add((Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'))
}
if ($env:ProgramFiles) {
    $candidates.Add((Join-Path $env:ProgramFiles 'nodejs\node.exe'))
}
$candidates.Add((Join-Path $projectRoot 'runtime\node\node.exe'))

foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        [IO.Path]::GetFullPath($candidate)
        exit 0
    }
}

throw 'Node.js was not found. Install Node.js or set ANALYSIS_NODE_PATH to node.exe.'
