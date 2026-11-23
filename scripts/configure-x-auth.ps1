param(
    [string]$CookieHeaderPath,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
if (-not $OutputPath) {
    $OutputPath = Join-Path $projectRoot 'state\private\x-auth.clixml'
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)

function Convert-SecureValueToPlainText {
    param([Parameter(Mandatory)][Security.SecureString]$Value)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

if ($CookieHeaderPath) {
    $cookieHeader = (Get-Content -LiteralPath $CookieHeaderPath -Raw).Trim()
}
else {
    Write-Host 'Paste Cookie-Editor Export > Header String below. Input is hidden:'
    $secureHeader = Read-Host -AsSecureString
    $cookieHeader = Convert-SecureValueToPlainText $secureHeader
}

$cookies = @{}
foreach ($part in $cookieHeader -split ';') {
    $trimmed = $part.Trim()
    $separator = $trimmed.IndexOf('=')
    if ($separator -le 0) { continue }
    $name = $trimmed.Substring(0, $separator).Trim()
    $value = $trimmed.Substring($separator + 1).Trim()
    if ($name) { $cookies[$name] = $value }
}

if (-not $cookies.ContainsKey('auth_token') -or -not $cookies['auth_token']) {
    throw 'Cookie Header String is missing auth_token. Export it from a signed-in x.com page.'
}
if (-not $cookies.ContainsKey('ct0') -or -not $cookies['ct0']) {
    throw 'Cookie Header String is missing ct0. Export it from a signed-in x.com page.'
}

$parent = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Path $parent -Force | Out-Null
[pscustomobject]@{
    SchemaVersion = 1
    ConfiguredAt = [DateTime]::UtcNow.ToString('o')
    AuthToken = ConvertTo-SecureString -String ([string]$cookies['auth_token']) -AsPlainText -Force
    Ct0 = ConvertTo-SecureString -String ([string]$cookies['ct0']) -AsPlainText -Force
} | Export-Clixml -LiteralPath $OutputPath -Force

[ordered]@{
    configured = $true
    credentialPath = $OutputPath
    protection = 'windows_dpapi_current_user'
    restartRequired = $false
} | ConvertTo-Json -Compress
