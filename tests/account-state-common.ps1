$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\account-event-lib.ps1')

function Test-AccountState {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$AccountId
    )

    $resolvedRoot = Get-ProjectRoot -ProjectRoot $ProjectRoot
    $account = Get-AccountConfig -ProjectRoot $resolvedRoot -AccountId $AccountId
    $state = Read-JsonDocument -Path (Join-Path $resolvedRoot $account.stateFile)
    Assert-AccountState -State $state -ExpectedAccountId $AccountId
    $events = @(Assert-AccountEventLog -ProjectRoot $resolvedRoot -AccountId $AccountId)
    foreach ($event in @($events | Where-Object { $_.accountId -eq $AccountId })) {
        if (@($state.appliedEventIds | Where-Object { $_ -eq $event.eventId }).Count -eq 0) {
            throw "Account state has not projected event $($event.eventId)."
        }
    }
    return $state
}
