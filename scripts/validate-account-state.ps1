param(
    [string]$ProjectRoot,
    [string]$AccountId
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'account-event-lib.ps1')

$resolvedRoot = Get-ProjectRoot -ProjectRoot $ProjectRoot
$accounts = Read-JsonDocument -Path (Join-Path $resolvedRoot 'config\accounts.json')
$configuredAccounts = @($accounts.accounts)
if (-not [string]::IsNullOrWhiteSpace($AccountId)) {
    $configuredAccounts = @($configuredAccounts | Where-Object { $_.id -eq $AccountId })
    if ($configuredAccounts.Count -ne 1) { throw "Account '$AccountId' is not configured exactly once." }
}

$events = @(Assert-AccountEventLog -ProjectRoot $resolvedRoot -AccountId $AccountId)
foreach ($account in $configuredAccounts) {
    $statePath = Join-Path $resolvedRoot $account.stateFile
    $state = Read-JsonDocument -Path $statePath
    Assert-AccountState -State $state -ExpectedAccountId $account.id
    $accountEvents = @($events | Where-Object { $_.accountId -eq $account.id })
    foreach ($event in $accountEvents) {
        if (@($state.appliedEventIds | Where-Object { $_ -eq $event.eventId }).Count -eq 0) {
            throw "Account state $($account.id) has not projected event $($event.eventId)."
        }
    }
}

Write-Output "PASS account-state-validation ($($configuredAccounts.Count) account(s), $($events.Count) event(s))"
