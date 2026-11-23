param(
    [Parameter(Mandatory)][string]$Uri,
    [Parameter(Mandatory)][string]$BodyBase64,
    [int]$TimeoutSeconds = 15
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$body = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($BodyBase64))
$response = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $Uri -ContentType 'application/json' -Body $body -TimeoutSec $TimeoutSeconds
[Console]::Out.Write($response.Content)
