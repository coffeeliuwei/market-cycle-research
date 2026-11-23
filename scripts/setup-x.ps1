param(
    [switch]$Describe
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$toolsBase = Join-Path $projectRoot '.tools'
$runtimeRoot = Join-Path $toolsBase 'x-runtime'
$uvRoot = Join-Path $toolsBase 'uv'
$uvExecutable = Join-Path $uvRoot 'uv.exe'
$pythonExecutable = Join-Path $runtimeRoot 'Scripts\python.exe'
$agentReachExecutable = Join-Path $runtimeRoot 'Scripts\agent-reach.exe'
$twitterExecutable = Join-Path $runtimeRoot 'Scripts\twitter.exe'
$credentialPath = Join-Path $projectRoot 'state\private\x-auth.clixml'

$description = [ordered]@{
    projectRoot = $projectRoot
    toolsRoot = $toolsBase
    runtimeRoot = $runtimeRoot
    uvExecutable = $uvExecutable
    pythonExecutable = $pythonExecutable
    agentReachExecutable = $agentReachExecutable
    twitterExecutable = $twitterExecutable
    credentialPath = $credentialPath
}
if ($Describe) {
    $description | ConvertTo-Json -Compress
    exit 0
}

New-Item -ItemType Directory -Path $toolsBase, $uvRoot -Force | Out-Null
if (-not (Test-Path -LiteralPath $uvExecutable -PathType Leaf)) {
    $architecture = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'aarch64' } else { 'x86_64' }
    $uvDownloadUrl = "https://github.com/astral-sh/uv/releases/latest/download/uv-$architecture-pc-windows-msvc.zip"
    $downloadsRoot = [IO.Path]::GetFullPath((Join-Path $toolsBase 'downloads'))
    $downloadRoot = [IO.Path]::GetFullPath((Join-Path $downloadsRoot ([guid]::NewGuid().ToString('N'))))
    if (-not $downloadRoot.StartsWith($downloadsRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe X tool download directory: $downloadRoot"
    }
    New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null
    try {
        $archive = Join-Path $downloadRoot 'uv.zip'
        $expanded = Join-Path $downloadRoot 'expanded'
        Invoke-WebRequest -Uri $uvDownloadUrl -OutFile $archive -UseBasicParsing
        Expand-Archive -LiteralPath $archive -DestinationPath $expanded -Force
        $downloadedUv = Get-ChildItem -LiteralPath $expanded -Filter 'uv.exe' -Recurse -File | Select-Object -First 1
        if (-not $downloadedUv) { throw 'Downloaded uv archive does not contain uv.exe.' }
        Copy-Item -LiteralPath $downloadedUv.FullName -Destination $uvExecutable -Force
    }
    finally {
        if (Test-Path -LiteralPath $downloadRoot) { Remove-Item -LiteralPath $downloadRoot -Recurse -Force }
    }
}

if (-not (Test-Path -LiteralPath $pythonExecutable -PathType Leaf)) {
    & $uvExecutable venv --python 3.12 $runtimeRoot
    if ($LASTEXITCODE -ne 0) { throw "uv could not create the project-local X runtime (exit $LASTEXITCODE)." }
}

$previousHttpTimeout = $env:UV_HTTP_TIMEOUT
$previousHttpRetries = $env:UV_HTTP_RETRIES
$previousLinkMode = $env:UV_LINK_MODE
try {
    if (-not $env:UV_HTTP_TIMEOUT) { $env:UV_HTTP_TIMEOUT = '180' }
    if (-not $env:UV_HTTP_RETRIES) { $env:UV_HTTP_RETRIES = '6' }
    if (-not $env:UV_LINK_MODE) { $env:UV_LINK_MODE = 'copy' }
    & $uvExecutable pip install --python $pythonExecutable --upgrade `
        'https://github.com/Panniantong/agent-reach/archive/main.zip' `
        'twitter-cli>=0.8.5'
    if ($LASTEXITCODE -ne 0) { throw "uv could not install the X collector packages (exit $LASTEXITCODE)." }
}
finally {
    $env:UV_HTTP_TIMEOUT = $previousHttpTimeout
    $env:UV_HTTP_RETRIES = $previousHttpRetries
    $env:UV_LINK_MODE = $previousLinkMode
}

foreach ($requiredExecutable in @($agentReachExecutable, $twitterExecutable)) {
    if (-not (Test-Path -LiteralPath $requiredExecutable -PathType Leaf)) {
        throw "X collector installation is incomplete; missing: $requiredExecutable"
    }
}

[ordered]@{
    installed = $true
    toolsRoot = $toolsBase
    runtimeRoot = $runtimeRoot
    agentReachExecutable = $agentReachExecutable
    twitterExecutable = $twitterExecutable
    authenticationConfigured = (Test-Path -LiteralPath $credentialPath -PathType Leaf)
    nextCommand = '.\scripts\configure-x-auth.ps1'
} | ConvertTo-Json -Compress
