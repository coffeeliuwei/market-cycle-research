param(
    [string]$Query = 'bitcoin',
    [string]$CollectorPath,
    [string]$CredentialPath,
    [switch]$Envelope
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$nodeResolver = Join-Path $projectRoot 'scripts\resolve-node.ps1'
if (-not $CollectorPath) { $CollectorPath = Join-Path $projectRoot 'collectors\x-live.mjs' }
if (-not $CredentialPath) { $CredentialPath = Join-Path $projectRoot 'state\private\x-auth.clixml' }

function Convert-SecureValueToPlainText {
    param([Parameter(Mandatory)][Security.SecureString]$Value)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function ConvertTo-HttpProxyUrl {
    param([string]$ProxyServer)
    if (-not $ProxyServer) { return $null }
    $candidate = $ProxyServer.Trim()
    if ($candidate -match ';') {
        $parts = @{}
        foreach ($entry in ($candidate -split ';')) {
            if ($entry -match '^\s*([^=]+)=(.+)$') { $parts[$matches[1].Trim().ToLowerInvariant()] = $matches[2].Trim() }
        }
        $candidate = if ($parts.ContainsKey('https')) { $parts['https'] } elseif ($parts.ContainsKey('http')) { $parts['http'] } else { $null }
    }
    if (-not $candidate) { return $null }
    if ($candidate -notmatch '^[a-z][a-z0-9+.-]*://') { $candidate = 'http://' + $candidate }
    $candidate
}

function Get-EnabledWindowsProxy {
    if ($env:ANALYSIS_X_SYSTEM_PROXY) { return ConvertTo-HttpProxyUrl $env:ANALYSIS_X_SYSTEM_PROXY }
    try {
        $settings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if ([int]$settings.ProxyEnable -eq 1) { return ConvertTo-HttpProxyUrl ([string]$settings.ProxyServer) }
    }
    catch { }
    $null
}

$node = & $nodeResolver
$previousAuthToken = $env:TWITTER_AUTH_TOKEN
$previousCt0 = $env:TWITTER_CT0
$previousHttpProxy = $env:HTTP_PROXY
$previousHttpsProxy = $env:HTTPS_PROXY
$previousPythonUtf8 = $env:PYTHONUTF8
try {
    if (Test-Path -LiteralPath $CredentialPath -PathType Leaf) {
        $credential = Import-Clixml -LiteralPath $CredentialPath
        if (-not ($credential.AuthToken -is [Security.SecureString]) -or -not ($credential.Ct0 -is [Security.SecureString])) {
            throw "X credential file has an invalid format: $CredentialPath"
        }
        $env:TWITTER_AUTH_TOKEN = Convert-SecureValueToPlainText $credential.AuthToken
        $env:TWITTER_CT0 = Convert-SecureValueToPlainText $credential.Ct0
    }

    $systemProxy = Get-EnabledWindowsProxy
    if (-not $env:HTTP_PROXY -and $systemProxy) { $env:HTTP_PROXY = $systemProxy }
    if (-not $env:HTTPS_PROXY -and $systemProxy) { $env:HTTPS_PROXY = $systemProxy }
    if (-not $env:PYTHONUTF8) { $env:PYTHONUTF8 = '1' }

    $raw = @(& $node $CollectorPath $Query)
    $collectorExitCode = $LASTEXITCODE
    if ($Envelope) {
        [ordered]@{
            exitCode = $collectorExitCode
            stdout = ($raw -join "`n")
        } | ConvertTo-Json -Compress
    }
    else {
        $raw
    }
}
finally {
    $env:TWITTER_AUTH_TOKEN = $previousAuthToken
    $env:TWITTER_CT0 = $previousCt0
    $env:HTTP_PROXY = $previousHttpProxy
    $env:HTTPS_PROXY = $previousHttpsProxy
    $env:PYTHONUTF8 = $previousPythonUtf8
}
