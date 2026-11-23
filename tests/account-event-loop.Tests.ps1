$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$recordScript = Join-Path $projectRoot 'scripts\record-account-event.ps1'
$buildScript = Join-Path $projectRoot 'scripts\build-account-overview.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('tradingview-account-event-test-' + [guid]::NewGuid().ToString('N'))

function Write-TestJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Value
    )

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Read-TestJson {
    param([Parameter(Mandatory)][string]$Path)
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Invoke-AccountEvent {
    param(
        [Parameter(Mandatory)][hashtable]$Arguments
    )
    & $recordScript @Arguments | Out-Null
}

function Assert-ExpectedFailure {
    param([Parameter(Mandatory)][scriptblock]$Action)
    $failed = $false
    try {
        & $Action
    }
    catch {
        $failed = $true
    }
    if (-not $failed) { throw 'Expected account event invocation to fail.' }
}

$realStateFiles = @(
    'state/current/binance.json',
    'state/current/gate.json',
    'state/current/ok.json',
    'state/current/ashare.json'
)
$realHashesBefore = @{}
foreach ($relativePath in $realStateFiles) {
    $realHashesBefore[$relativePath] = (Get-FileHash -LiteralPath (Join-Path $projectRoot $relativePath) -Algorithm SHA256).Hash
}

try {
    New-Item -ItemType Directory -Path (Join-Path $tempRoot 'config'), (Join-Path $tempRoot 'state\current'), (Join-Path $tempRoot 'state\events') -Force | Out-Null

    Write-TestJson -Path (Join-Path $tempRoot 'config\accounts.json') -Value @{
        schemaVersion = 1
        accounts = @(
            @{
                id = 'test-account'
                label = 'Test Account'
                ownership = 'personal'
                userHasFullTradingAuthority = $true
                stateFile = 'state/current/test-account.json'
            }
        )
    }

    Write-TestJson -Path (Join-Path $tempRoot 'state\current\test-account.json') -Value @{
        schemaVersion = 1
        accountId = 'test-account'
        observedAt = '2026-09-05T11:00:00Z'
        source = 'isolated account-event test fixture'
        verificationRequired = $false
        balances = @()
        positions = @()
        orders = @()
        bots = @()
        stoppedBots = @()
        notes = @()
    }

    $orphanedEvent = [ordered]@{
        schemaVersion = 1
        eventId = 'test-recovery-event'
        accountId = 'test-account'
        eventType = 'balance.updated'
        status = 'confirmed'
        asset = 'RECOVERY'
        quantity = 7
        occurredAt = '2026-09-05T11:30:00Z'
        evidence = 'simulated append-before-projection interruption'
        source = 'account-event-loop.Tests.ps1'
    }
    [IO.File]::WriteAllText(
        (Join-Path $tempRoot 'state\events\account-events.jsonl'),
        ($orphanedEvent | ConvertTo-Json -Compress) + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )

    $created = @{
        ProjectRoot = $tempRoot
        AccountId = 'test-account'
        EventId = 'test-order-created'
        EventType = 'order.created'
        Market = 'spot'
        Symbol = 'TESTUSDT'
        OrderId = 'test-order-1'
        Side = 'buy'
        Type = 'limit'
        Price = '1.25'
        Quantity = '100'
        QuoteAmount = '125'
        Status = 'open'
        OccurredAt = '2026-09-05T12:00:00Z'
        Evidence = 'isolated test fixture'
        Source = 'account-event-loop.Tests.ps1'
    }

    $missingAccount = $created.Clone()
    $missingAccount.AccountId = 'missing-account'
    Assert-ExpectedFailure { Invoke-AccountEvent -Arguments $missingAccount }

    $missingEventId = $created.Clone()
    $missingEventId.EventId = ''
    Assert-ExpectedFailure { Invoke-AccountEvent -Arguments $missingEventId }

    $missingOrderIdentity = $created.Clone()
    $missingOrderIdentity.OrderId = ''
    Assert-ExpectedFailure { Invoke-AccountEvent -Arguments $missingOrderIdentity }

    Invoke-AccountEvent -Arguments $created

    $statePath = Join-Path $tempRoot 'state\current\test-account.json'
    $stateAfterCreate = Read-TestJson -Path $statePath
    if (@($stateAfterCreate.orders).Count -ne 1) { throw 'Created order was not projected.' }
    if ($stateAfterCreate.orders[0].orderId -ne 'test-order-1') { throw 'Created order identity is missing.' }
    if ($stateAfterCreate.orders[0].remainingQuantity -ne 100) { throw 'Created order remaining quantity is wrong.' }
    if (@($stateAfterCreate.balances | Where-Object asset -eq 'RECOVERY').Count -ne 1) {
        throw 'Previously appended event was not automatically recovered and projected.'
    }

    Invoke-AccountEvent -Arguments @{
        ProjectRoot = $tempRoot
        AccountId = 'test-account'
        EventId = 'test-order-unknown-1'
        EventType = 'order.unknown'
        Market = 'spot'
        Symbol = 'TESTUSDT'
        OrderId = 'test-order-1'
        Status = 'unknown'
        OccurredAt = '2026-09-05T12:00:30Z'
        Evidence = 'isolated test fixture'
        Source = 'account-event-loop.Tests.ps1'
    }
    $stateAfterUnknown = Read-TestJson -Path $statePath
    if ($stateAfterUnknown.orders[0].remainingQuantity -ne 100) { throw 'Unknown event changed confirmed order state.' }
    if (@($stateAfterUnknown.pendingVerifications).Count -ne 1) { throw 'Unknown event was not recorded for verification.' }

    Invoke-AccountEvent -Arguments @{
        ProjectRoot = $tempRoot
        AccountId = 'test-account'
        EventId = 'test-order-rejected-1'
        EventType = 'order.rejected'
        Market = 'spot'
        Symbol = 'REJECTEDUSDT'
        RecordId = 'test-order-rejected'
        OrderId = 'test-order-rejected'
        Status = 'rejected'
        OccurredAt = '2026-09-05T12:00:40Z'
        Evidence = 'isolated test fixture'
        Source = 'account-event-loop.Tests.ps1'
    }
    $stateAfterRejected = Read-TestJson -Path $statePath
    if (@($stateAfterRejected.orders | Where-Object orderId -eq 'test-order-rejected').Count -ne 0) { throw 'Rejected order entered current orders.' }
    if (@($stateAfterRejected.failedEvents).Count -ne 1) { throw 'Rejected order failure was not recorded.' }

    Invoke-AccountEvent -Arguments $created
    $eventsAfterDuplicate = @(Get-Content -LiteralPath (Join-Path $tempRoot 'state\events\account-events.jsonl') | Where-Object { $_.Trim() })
    if ($eventsAfterDuplicate.Count -ne 4) { throw 'Duplicate event was appended to the event log.' }
    if (@((Read-TestJson -Path $statePath).orders).Count -ne 1) { throw 'Duplicate event duplicated the current order.' }

    Invoke-AccountEvent -Arguments @{
        ProjectRoot = $tempRoot
        AccountId = 'test-account'
        EventId = 'test-order-proposed'
        EventType = 'order.proposed'
        RecordId = 'test-order-proposal-1'
        Market = 'spot'
        Symbol = 'PROPOSALUSDT'
        Side = 'buy'
        Type = 'limit'
        Price = '0.25'
        QuoteAmount = '500'
        Status = 'proposed'
        OccurredAt = '2026-09-05T12:00:35Z'
        Evidence = 'agent generated a concrete order recommendation'
        Source = 'account-event-loop.Tests.ps1'
        DetailsJson = '{"quote":"USDT"}'
    }
    $stateAfterProposal = Read-TestJson -Path $statePath
    if (@($stateAfterProposal.proposedOrders | Where-Object recordId -eq 'test-order-proposal-1').Count -ne 1) {
        throw 'Concrete order recommendation was not persisted.'
    }
    if (@($stateAfterProposal.orders | Where-Object recordId -eq 'test-order-proposal-1').Count -ne 0) {
        throw 'Unconfirmed proposal was incorrectly counted as a real order.'
    }
    Invoke-AccountEvent -Arguments @{
        ProjectRoot = $tempRoot
        AccountId = 'test-account'
        EventId = 'test-order-proposal-confirmed'
        EventType = 'order.created'
        RecordId = 'test-order-proposal-1'
        Status = 'open'
        OccurredAt = '2026-09-05T12:00:36Z'
        Evidence = 'user explicitly confirmed the recommended order was placed'
        Source = 'account-event-loop.Tests.ps1'
    }
    $stateAfterProposalConfirmation = Read-TestJson -Path $statePath
    $inheritedOrder = @($stateAfterProposalConfirmation.orders | Where-Object recordId -eq 'test-order-proposal-1')
    if ($inheritedOrder.Count -ne 1 -or $inheritedOrder[0].price -ne 0.25 -or $inheritedOrder[0].quoteAmount -ne 500) {
        throw 'Confirmed recommendation did not inherit its persisted price and amount.'
    }
    if (@($stateAfterProposalConfirmation.proposedOrders | Where-Object recordId -eq 'test-order-proposal-1').Count -ne 0) {
        throw 'Confirmed recommendation remained in proposedOrders.'
    }
    Invoke-AccountEvent -Arguments @{
        ProjectRoot = $tempRoot
        AccountId = 'test-account'
        EventId = 'test-order-proposal-canceled'
        EventType = 'order.canceled'
        RecordId = 'test-order-proposal-1'
        Status = 'canceled'
        OccurredAt = '2026-09-05T12:00:37Z'
        Evidence = 'test cleanup'
        Source = 'account-event-loop.Tests.ps1'
    }

    Invoke-AccountEvent -Arguments @{
        ProjectRoot = $tempRoot
        AccountId = 'test-account'
        EventId = 'test-order-deferred-1'
        EventType = 'order.deferred'
        RecordId = 'test-order-rejected'
        Market = 'spot'
        Symbol = 'REJECTEDUSDT'
        Side = 'buy'
        Type = 'limit'
        Price = '0.5'
        QuoteAmount = '100'
        Status = 'waiting_condition'
        OccurredAt = '2026-09-05T12:00:41Z'
        Evidence = 'user clarified this is a delayed plan, not a failed account action'
        Source = 'account-event-loop.Tests.ps1'
        DetailsJson = '{"reminderCondition":"notify when exchange price filter permits the target"}'
    }
    $stateAfterDeferred = Read-TestJson -Path $statePath
    if (@($stateAfterDeferred.deferredOrders | Where-Object recordId -eq 'test-order-rejected').Count -ne 1) {
        throw 'Deferred order was not projected.'
    }
    if (@($stateAfterDeferred.failedEvents | Where-Object recordId -eq 'test-order-rejected').Count -ne 0) {
        throw 'Deferred correction did not clear the obsolete failure classification.'
    }
    Invoke-AccountEvent -Arguments @{
        ProjectRoot = $tempRoot
        AccountId = 'test-account'
        EventId = 'test-order-deferred-cancel-only-created'
        EventType = 'order.deferred'
        RecordId = 'test-order-deferred-cancel-only'
        Market = 'spot'
        Symbol = 'CANCELUSDT'
        Side = 'buy'
        Type = 'limit'
        Price = '0.25'
        QuoteAmount = '50'
        Status = 'waiting_condition'
        OccurredAt = '2026-09-05T12:00:41.500Z'
        Evidence = 'test deferred plan to abandon'
        Source = 'account-event-loop.Tests.ps1'
    }
    Invoke-AccountEvent -Arguments @{
        ProjectRoot = $tempRoot
        AccountId = 'test-account'
        EventId = 'test-order-deferred-abandoned'
        EventType = 'order.canceled'
        RecordId = 'test-order-deferred-cancel-only'
        Status = 'canceled'
        OccurredAt = '2026-09-05T12:00:42Z'
        Evidence = 'user abandoned the deferred condition plan'
        Source = 'account-event-loop.Tests.ps1'
    }
    $stateAfterDeferredCancel = Read-TestJson -Path $statePath
    if (@($stateAfterDeferredCancel.deferredOrders | Where-Object recordId -eq 'test-order-deferred-cancel-only').Count -ne 0) {
        throw 'Canceled deferred order remained in deferredOrders.'
    }
    if (@($stateAfterDeferredCancel.pendingVerifications | Where-Object eventId -eq 'test-order-deferred-abandoned').Count -ne 0) {
        throw 'Canceling a known deferred order incorrectly created a pending verification.'
    }
    Invoke-AccountEvent -Arguments @{
        ProjectRoot = $tempRoot
        AccountId = 'test-account'
        EventId = 'test-order-deferred-created'
        EventType = 'order.created'
        RecordId = 'test-order-rejected'
        Market = 'spot'
        Symbol = 'REJECTEDUSDT'
        Side = 'buy'
        Type = 'limit'
        Price = '0.5'
        Quantity = '200'
        Status = 'open'
        OccurredAt = '2026-09-05T12:00:42Z'
        Evidence = 'user confirmed the delayed order was subsequently placed'
        Source = 'account-event-loop.Tests.ps1'
    }
    $stateAfterDeferredCreate = Read-TestJson -Path $statePath
    if (@($stateAfterDeferredCreate.deferredOrders | Where-Object recordId -eq 'test-order-rejected').Count -ne 0 -or
        @($stateAfterDeferredCreate.orders | Where-Object recordId -eq 'test-order-rejected').Count -ne 1) {
        throw 'Placed deferred order did not move from deferredOrders to orders.'
    }
    Invoke-AccountEvent -Arguments @{
        ProjectRoot = $tempRoot
        AccountId = 'test-account'
        EventId = 'test-order-deferred-canceled'
        EventType = 'order.canceled'
        RecordId = 'test-order-rejected'
        Status = 'canceled'
        OccurredAt = '2026-09-05T12:00:43Z'
        Evidence = 'test cleanup'
        Source = 'account-event-loop.Tests.ps1'
    }

    Invoke-AccountEvent -Arguments @{
        ProjectRoot = $tempRoot
        AccountId = 'test-account'
        EventId = 'test-local-order-created'
        EventType = 'order.created'
        RecordId = 'local:test-account:spot:LOCALUSDT:buy:2.5:1'
        Market = 'spot'
        Symbol = 'LOCALUSDT'
        Side = 'buy'
        Type = 'limit'
        Price = '2.5'
        Quantity = '4'
        Status = 'open'
        OccurredAt = '2026-09-05T12:00:45Z'
        Evidence = 'explicit user-confirmed account memory'
        Source = 'account-event-loop.Tests.ps1'
    }
    if (@((Read-TestJson -Path $statePath).orders | Where-Object recordId -eq 'local:test-account:spot:LOCALUSDT:buy:2.5:1').Count -ne 1) {
        throw 'User-confirmed order without an exchange order ID was not projected.'
    }
    Invoke-AccountEvent -Arguments @{
        ProjectRoot = $tempRoot
        AccountId = 'test-account'
        EventId = 'test-local-order-canceled'
        EventType = 'order.canceled'
        RecordId = 'local:test-account:spot:LOCALUSDT:buy:2.5:1'
        Status = 'canceled'
        OccurredAt = '2026-09-05T12:00:46Z'
        Evidence = 'explicit user-confirmed account memory'
        Source = 'account-event-loop.Tests.ps1'
    }
    if (@((Read-TestJson -Path $statePath).orders | Where-Object recordId -eq 'local:test-account:spot:LOCALUSDT:buy:2.5:1').Count -ne 0) {
        throw 'Locally identified order was not canceled.'
    }

    Invoke-AccountEvent -Arguments @{
        ProjectRoot = $tempRoot
        AccountId = 'test-account'
        EventId = 'test-order-partial-1'
        EventType = 'order.partially_filled'
        Market = 'spot'
        Symbol = 'TESTUSDT'
        OrderId = 'test-order-1'
        Side = 'buy'
        Type = 'limit'
        Price = '1.25'
        Quantity = '60'
        OriginalQuantity = '100'
        FilledQuantity = '40'
        RemainingQuantity = '60'
        Status = 'partially_filled'
        OccurredAt = '2026-09-05T12:01:00Z'
        Evidence = 'isolated test fixture'
        Source = 'account-event-loop.Tests.ps1'
    }

    $stateAfterPartial = Read-TestJson -Path $statePath
    if ($stateAfterPartial.orders[0].quantity -ne 60 -or $stateAfterPartial.orders[0].remainingQuantity -ne 60) {
        throw 'Partial fill did not update the remaining quantity.'
    }
    if ($stateAfterPartial.orders[0].filledQuantity -ne 40) { throw 'Partial fill did not update filled quantity.' }

    Invoke-AccountEvent -Arguments @{
        ProjectRoot = $tempRoot
        AccountId = 'test-account'
        EventId = 'test-balance-1'
        EventType = 'balance.updated'
        Asset = 'USDT'
        AccountBucket = 'spot'
        Quantity = '900'
        Status = 'confirmed'
        OccurredAt = '2026-09-05T12:01:10Z'
        Evidence = 'isolated test fixture'
        Source = 'account-event-loop.Tests.ps1'
    }
    Invoke-AccountEvent -Arguments @{
        ProjectRoot = $tempRoot
        AccountId = 'test-account'
        EventId = 'test-position-1'
        EventType = 'position.updated'
        Market = 'spot'
        Symbol = 'TESTUSDT'
        Quantity = '40'
        Status = 'confirmed'
        OccurredAt = '2026-09-05T12:01:11Z'
        Evidence = 'isolated test fixture'
        Source = 'account-event-loop.Tests.ps1'
    }
    Invoke-AccountEvent -Arguments @{
        ProjectRoot = $tempRoot
        AccountId = 'test-account'
        EventId = 'test-bot-started-1'
        EventType = 'bot.started'
        BotId = 'test-bot-1'
        Market = 'spot'
        Symbol = 'TESTBOTUSDT'
        Status = 'running'
        DetailsJson = '{"strategy":"grid","investment":100}'
        OccurredAt = '2026-09-05T12:01:20Z'
        Evidence = 'isolated test fixture'
        Source = 'account-event-loop.Tests.ps1'
    }
    Invoke-AccountEvent -Arguments @{
        ProjectRoot = $tempRoot
        AccountId = 'test-account'
        EventId = 'test-bot-stopped-1'
        EventType = 'bot.stopped'
        BotId = 'test-bot-1'
        Market = 'spot'
        Symbol = 'TESTBOTUSDT'
        Status = 'stopped'
        DetailsJson = '{"strategy":"grid","investment":100,"totalPnl":12.5,"positionSettlementVerified":true}'
        OccurredAt = '2026-09-05T12:01:21Z'
        Evidence = 'isolated test fixture'
        Source = 'account-event-loop.Tests.ps1'
    }
    Invoke-AccountEvent -Arguments @{
        ProjectRoot = $tempRoot
        AccountId = 'test-account'
        EventId = 'test-transfer-1'
        EventType = 'transfer.completed'
        TransferId = 'test-transfer-1'
        Asset = 'USDT'
        Status = 'completed'
        OccurredAt = '2026-09-05T12:01:22Z'
        Evidence = 'isolated test fixture'
        Source = 'account-event-loop.Tests.ps1'
    }
    $stateAfterAccountEvents = Read-TestJson -Path $statePath
    if (@($stateAfterAccountEvents.balances | Where-Object asset -eq 'USDT').Count -ne 1) { throw 'Balance update was not projected.' }
    if (@($stateAfterAccountEvents.positions | Where-Object symbol -eq 'TESTUSDT').Count -ne 1) { throw 'Position update was not projected.' }
    if (@($stateAfterAccountEvents.bots | Where-Object botId -eq 'test-bot-1').Count -ne 0) { throw 'Stopped bot remained active.' }
    if (@($stateAfterAccountEvents.stoppedBots | Where-Object botId -eq 'test-bot-1').Count -ne 1) { throw 'Stopped bot was not moved to stoppedBots.' }
    if ($stateAfterAccountEvents.stoppedBots[0].totalPnl -ne 12.5) { throw 'Stopped bot final PNL was not preserved.' }
    if (@($stateAfterAccountEvents.transfers | Where-Object transferId -eq 'test-transfer-1').Count -ne 1) { throw 'Transfer result was not projected.' }

    Invoke-AccountEvent -Arguments @{
        ProjectRoot = $tempRoot
        AccountId = 'test-account'
        EventId = 'test-order-canceled-1'
        EventType = 'order.canceled'
        Market = 'spot'
        Symbol = 'TESTUSDT'
        OrderId = 'test-order-1'
        Status = 'canceled'
        OccurredAt = '2026-09-05T12:02:00Z'
        Evidence = 'isolated test fixture'
        Source = 'account-event-loop.Tests.ps1'
    }

    $finalState = Read-TestJson -Path $statePath
    if (@($finalState.orders).Count -ne 0) { throw 'Canceled order remained in current orders.' }
    if ($finalState.lastEventAt -ne '2026-09-05T12:02:00Z') { throw 'lastEventAt does not reflect the confirmed cancellation.' }
    if ([DateTimeOffset]$finalState.observedAt -ne [DateTimeOffset]'2026-09-05T11:00:00Z') { throw 'Local account event incorrectly changed observedAt.' }
    if (@($finalState.appliedEventIds).Count -ne 21) { throw 'Applied event bookkeeping is incomplete.' }

    & $buildScript -ProjectRoot $tempRoot | Out-Null
    $overview = Get-Content -LiteralPath (Join-Path $tempRoot 'PORTFOLIO.md') -Raw
    if ($overview -match 'TESTUSDT：buy') { throw 'PORTFOLIO.md contains a canceled test order.' }
    if ($overview -notmatch '委托（0）') { throw 'PORTFOLIO.md does not show zero active test orders.' }
    if ($overview -notmatch '最后确认动作时间' -or $overview -notmatch '待核验动作' -or $overview -notmatch '延后挂单' -or $overview -notmatch '已建议、未确认执行') {
        throw 'PORTFOLIO.md is missing account event metadata.'
    }

    foreach ($relativePath in $realStateFiles) {
        $hash = (Get-FileHash -LiteralPath (Join-Path $projectRoot $relativePath) -Algorithm SHA256).Hash
        if ($hash -ne $realHashesBefore[$relativePath]) { throw "Isolated test changed $relativePath." }
    }

    Write-Output 'PASS account-event-loop'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

if (Test-Path -LiteralPath $tempRoot) { throw 'Temporary account-event test data was not removed.' }
