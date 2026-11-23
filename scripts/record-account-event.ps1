param(
    [string]$ProjectRoot,

    [Parameter(Mandatory)][string]$AccountId,
    [Parameter(Mandatory)][string]$EventId,
    [Parameter(Mandatory)][string]$EventType,
    [Parameter(Mandatory)][string]$Status,
    [Parameter(Mandatory)][string]$OccurredAt,
    [Parameter(Mandatory)][string]$Evidence,
    [Parameter(Mandatory)][string]$Source,

    [string]$Market,
    [string]$Symbol,
    [string]$RecordId,
    [string]$OrderId,
    [string]$ClientOrderId,
    [string]$BotId,
    [string]$TransferId,
    [string]$Side,
    [string]$Type,
    [string]$Price,
    [string]$Quantity,
    [string]$QuoteAmount,
    [string]$OriginalQuantity,
    [string]$FilledQuantity,
    [string]$RemainingQuantity,
    [string]$Asset,
    [string]$AccountBucket,
    [string]$DetailsJson
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'account-event-lib.ps1')

$resolvedRoot = Get-ProjectRoot -ProjectRoot $ProjectRoot
$account = Get-AccountConfig -ProjectRoot $resolvedRoot -AccountId $AccountId
$statePath = Join-Path $resolvedRoot $account.stateFile
$state = Read-JsonDocument -Path $statePath

$raw = @{
    AccountId = $AccountId
    EventId = $EventId
    EventType = $EventType
    Status = $Status
    OccurredAt = $OccurredAt
    Evidence = $Evidence
    Source = $Source
}
foreach ($name in @(
    'Market', 'Symbol', 'RecordId', 'OrderId', 'ClientOrderId', 'BotId', 'TransferId', 'Side', 'Type',
    'Price', 'Quantity', 'QuoteAmount', 'OriginalQuantity', 'FilledQuantity', 'RemainingQuantity',
    'Asset', 'AccountBucket', 'DetailsJson'
)) {
    if ($PSBoundParameters.ContainsKey($name)) { $raw[$name] = $PSBoundParameters[$name] }
}
$event = Convert-EventParameters -Parameters $raw
$event = Complete-CreatedOrderFromProposal -Event $event -State $state
Assert-AccountEvent -Event $event -ExpectedAccountId $AccountId
Assert-AccountState -State $state -ExpectedAccountId $AccountId

$validator = Join-Path $PSScriptRoot 'validate-account-state.ps1'
$overview = Join-Path $PSScriptRoot 'build-account-overview.ps1'
$accountTest = Join-Path $resolvedRoot "tests\$AccountId-state.Tests.ps1"

$mutex = [Threading.Mutex]::new($false, 'Local\TradingviewAccountEventStoreV1')
$acquired = $false
try {
    $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(30))
    if (-not $acquired) { throw 'Timed out waiting for the account event store lock.' }

    $events = @(Read-AccountEvents -ProjectRoot $resolvedRoot)
    $existing = @($events | Where-Object { $_.accountId -eq $event.accountId -and $_.eventId -eq $event.eventId })
    if ($existing.Count -gt 1) { throw "Account event log already contains duplicate eventId: $($event.eventId)" }
    if ($existing.Count -eq 0) {
        Append-AccountEvent -ProjectRoot $resolvedRoot -Event $event -ExistingEvents $events
    }
    else {
        Assert-EquivalentAccountEvent -Expected $existing[0] -Actual $event
    }

    $events = @(Assert-AccountEventLog -ProjectRoot $resolvedRoot)
    $state = Read-JsonDocument -Path $statePath
    Assert-AccountState -State $state -ExpectedAccountId $AccountId
    foreach ($accountEvent in @($events | Where-Object { $_.accountId -eq $AccountId })) {
        $state = Apply-AccountEvent -State $state -Event $accountEvent
    }
    Assert-AccountState -State $state -ExpectedAccountId $AccountId
    Write-JsonDocumentAtomic -Path $statePath -Value $state

    & $validator -ProjectRoot $resolvedRoot -AccountId $AccountId | Out-Null
    & $overview -ProjectRoot $resolvedRoot | Out-Null

    if (-not (Test-Path -LiteralPath $accountTest -PathType Leaf)) {
        $accountTest = Join-Path $PSScriptRoot '..\tests\account-state-common.ps1'
        if (-not (Test-Path -LiteralPath $accountTest -PathType Leaf)) {
            throw "No account state test is available for account '$AccountId'."
        }
        . $accountTest
        Test-AccountState -ProjectRoot $resolvedRoot -AccountId $AccountId | Out-Null
    }
    else {
        & $accountTest -ProjectRoot $resolvedRoot | Out-Null
    }
}
finally {
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}

$event | ConvertTo-Json -Depth 100
