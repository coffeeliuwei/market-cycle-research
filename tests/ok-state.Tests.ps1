param([string]$ProjectRoot = (Split-Path $PSScriptRoot))
. (Join-Path $PSScriptRoot 'account-state-common.ps1')
Test-AccountState -ProjectRoot $ProjectRoot -AccountId 'ok' | Out-Null
