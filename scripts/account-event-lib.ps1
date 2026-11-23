$script:AccountEventTypes = @(
    'account.snapshot',
    'order.proposed',
    'order.created',
    'order.partially_filled',
    'order.filled',
    'order.canceled',
    'order.rejected',
    'order.deferred',
    'order.unknown',
    'position.updated',
    'balance.updated',
    'bot.started',
    'bot.stopped',
    'transfer.created',
    'transfer.completed',
    'transfer.failed',
    'transfer.unknown'
)

$script:AccountEventStatuses = @(
    'proposed',
    'confirmed',
    'open',
    'partially_filled',
    'filled',
    'canceled',
    'rejected',
    'deferred',
    'waiting_condition',
    'failed',
    'unknown',
    'pending_verification',
    'created',
    'completed',
    'running',
    'stopped'
)

$script:ReservedEventDetailFields = @(
    'schemaVersion', 'eventId', 'accountId', 'eventType', 'status', 'occurredAt', 'evidence', 'source',
    'market', 'symbol', 'recordId', 'orderId', 'clientOrderId', 'botId', 'transferId', 'side', 'type',
    'price', 'quantity', 'quoteAmount', 'originalQuantity', 'filledQuantity', 'remainingQuantity',
    'asset', 'accountBucket', 'updatedAt', 'stoppedAt'
)

function Test-Property {
    param(
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    return $null -ne $Object.PSObject.Properties[$Name]
}

function Set-ObjectProperty {
    param(
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter()][object]$Value
    )

    if (Test-Property -Object $Object -Name $Name) {
        $Object.$Name = $Value
    }
    else {
        Add-Member -InputObject $Object -MemberType NoteProperty -Name $Name -Value $Value | Out-Null
    }
}

function Get-ProjectRoot {
    param([string]$ProjectRoot)

    if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
        return [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
    }

    return [IO.Path]::GetFullPath($ProjectRoot)
}

function Get-AccountConfig {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$AccountId
    )

    $accountsPath = Join-Path $ProjectRoot 'config\accounts.json'
    $accounts = Read-JsonDocument -Path $accountsPath
    $account = @($accounts.accounts | Where-Object { $_.id -eq $AccountId })
    if ($account.Count -ne 1) {
        throw "Account '$AccountId' is not configured exactly once in $accountsPath."
    }

    return $account[0]
}

function Read-JsonDocument {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "JSON file does not exist: $Path"
    }

    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        throw "Invalid JSON in $Path. $($_.Exception.Message)"
    }
}

function Write-JsonDocumentAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Value
    )

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = $Value | ConvertTo-Json -Depth 100
        [IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Get-EventsPath {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    return Join-Path $ProjectRoot 'state\events\account-events.jsonl'
}

function Read-AccountEvents {
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $path = Get-EventsPath -ProjectRoot $ProjectRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return @()
    }

    $events = [Collections.Generic.List[object]]::new()
    foreach ($line in @(Get-Content -LiteralPath $path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $events.Add(($line | ConvertFrom-Json))
        }
        catch {
            throw "Invalid account event JSON in $path. $($_.Exception.Message)"
        }
    }

    return @($events)
}

function Append-AccountEvent {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][object]$Event,
        [object[]]$ExistingEvents = @()
    )

    $path = Get-EventsPath -ProjectRoot $ProjectRoot
    $parent = Split-Path -Parent $path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($existing in $ExistingEvents) {
        $lines.Add(($existing | ConvertTo-Json -Compress -Depth 100))
    }
    $lines.Add(($Event | ConvertTo-Json -Compress -Depth 100))
    $temporary = Join-Path $parent ('.account-events-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllLines($temporary, $lines, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Convert-EventParameters {
    param([Parameter(Mandatory)][hashtable]$Parameters)

    $event = [ordered]@{
        schemaVersion = 1
        eventId = $Parameters.EventId.Trim()
        accountId = $Parameters.AccountId.Trim()
        eventType = $Parameters.EventType.Trim()
        status = $Parameters.Status.Trim()
        occurredAt = ([DateTimeOffset]$Parameters.OccurredAt).ToString('o')
        evidence = $Parameters.Evidence.Trim()
        source = $Parameters.Source.Trim()
    }

    $textFields = @(
        'Market', 'Symbol', 'RecordId', 'OrderId', 'ClientOrderId', 'BotId', 'TransferId',
        'Side', 'Type', 'Asset', 'AccountBucket'
    )
    foreach ($name in $textFields) {
        if ($Parameters.ContainsKey($name) -and $null -ne $Parameters[$name] -and -not [string]::IsNullOrWhiteSpace([string]$Parameters[$name])) {
            $event[$name.Substring(0, 1).ToLowerInvariant() + $name.Substring(1)] = ([string]$Parameters[$name]).Trim()
        }
    }

    $numericFields = @(
        'Price', 'Quantity', 'QuoteAmount', 'OriginalQuantity', 'FilledQuantity', 'RemainingQuantity'
    )
    foreach ($name in $numericFields) {
        if (-not $Parameters.ContainsKey($name) -or $null -eq $Parameters[$name] -or [string]::IsNullOrWhiteSpace([string]$Parameters[$name])) {
            continue
        }
        $parsed = [decimal]0
        if (-not [decimal]::TryParse(
                [string]$Parameters[$name],
                [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$parsed)) {
            throw "Parameter $name must be a decimal number."
        }
        if ($parsed -lt 0) { throw "Parameter $name cannot be negative." }
        $event[$name.Substring(0, 1).ToLowerInvariant() + $name.Substring(1)] = $parsed
    }

    if ($Parameters.ContainsKey('DetailsJson') -and -not [string]::IsNullOrWhiteSpace([string]$Parameters.DetailsJson)) {
        try {
            $details = ([string]$Parameters.DetailsJson | ConvertFrom-Json)
        }
        catch {
            throw "DetailsJson must contain valid JSON."
        }
        if ($null -eq $details -or $details -isnot [pscustomobject]) {
            throw 'DetailsJson must contain a JSON object.'
        }
        $conflicts = @($details.PSObject.Properties.Name | Where-Object { $script:ReservedEventDetailFields -contains $_ })
        if ($conflicts.Count -gt 0) {
            throw "DetailsJson cannot override reserved event fields: $($conflicts -join ', ')."
        }
        $event.details = $details
    }

    return [pscustomobject]$event
}

function Assert-AccountEvent {
    param(
        [Parameter(Mandatory)][object]$Event,
        [Parameter(Mandatory)][string]$ExpectedAccountId
    )

    if (-not (Test-Property -Object $Event -Name 'schemaVersion') -or $Event.schemaVersion -ne 1) {
        throw 'Account event schemaVersion must be 1.'
    }
    foreach ($required in @('eventId', 'accountId', 'eventType', 'status', 'occurredAt', 'evidence', 'source')) {
        if (-not (Test-Property -Object $Event -Name $required) -or [string]::IsNullOrWhiteSpace([string]$Event.$required)) {
            throw "Account event field '$required' is required."
        }
    }
    if ($Event.accountId -ne $ExpectedAccountId) { throw 'Event accountId does not match the target account.' }
    if ($script:AccountEventTypes -notcontains $Event.eventType) { throw "Unsupported account event type: $($Event.eventType)" }
    if ($script:AccountEventStatuses -notcontains $Event.status) { throw "Unsupported account event status: $($Event.status)" }
    $allowedStatuses = @{
        'account.snapshot' = @('confirmed')
        'order.proposed' = @('proposed')
        'order.created' = @('open', 'confirmed')
        'order.partially_filled' = @('partially_filled')
        'order.filled' = @('filled')
        'order.canceled' = @('canceled')
        'order.rejected' = @('rejected', 'failed')
        'order.deferred' = @('deferred', 'waiting_condition')
        'order.unknown' = @('unknown', 'pending_verification')
        'position.updated' = @('confirmed')
        'balance.updated' = @('confirmed')
        'bot.started' = @('running', 'confirmed')
        'bot.stopped' = @('stopped', 'confirmed')
        'transfer.created' = @('created', 'confirmed')
        'transfer.completed' = @('completed', 'confirmed')
        'transfer.failed' = @('failed', 'rejected')
        'transfer.unknown' = @('unknown', 'pending_verification')
    }
    if ($allowedStatuses[$Event.eventType] -notcontains $Event.status) {
        throw "Status '$($Event.status)' is not valid for event type '$($Event.eventType)'."
    }
    try { $null = [DateTimeOffset]$Event.occurredAt }
    catch { throw "Invalid occurredAt: $($Event.occurredAt)" }
    if (Test-Property -Object $Event -Name 'details') {
        if ($null -eq $Event.details -or $Event.details -isnot [pscustomobject]) {
            throw 'Event details must be a JSON object.'
        }
        $conflicts = @($Event.details.PSObject.Properties.Name | Where-Object { $script:ReservedEventDetailFields -contains $_ })
        if ($conflicts.Count -gt 0) { throw "Event details override reserved fields: $($conflicts -join ', ')." }
    }

    if ($Event.eventType -like 'order.*') {
        if ((-not (Test-Property -Object $Event -Name 'recordId')) -and (-not (Test-Property -Object $Event -Name 'orderId')) -and (-not (Test-Property -Object $Event -Name 'clientOrderId'))) {
            throw 'Order events require recordId, orderId, or clientOrderId.'
        }
        if ($Event.eventType -eq 'order.partially_filled') {
            foreach ($required in @('originalQuantity', 'filledQuantity', 'remainingQuantity')) {
                if (-not (Test-Property -Object $Event -Name $required)) { throw "Partial fill requires $required." }
            }
            if ($Event.remainingQuantity -gt $Event.originalQuantity) { throw 'Partial fill remaining quantity exceeds original quantity.' }
            if (($Event.filledQuantity + $Event.remainingQuantity) -ne $Event.originalQuantity) {
                throw 'Partial fill quantities must satisfy filledQuantity + remainingQuantity = originalQuantity.'
            }
            if ($Event.quantity -ne $Event.remainingQuantity) {
                throw 'Partial fill quantity must equal remainingQuantity.'
            }
        }
        $termsVerificationRequired = (Test-Property -Object $Event -Name 'details') -and
            (Test-Property -Object $Event.details -Name 'termsVerificationRequired') -and [bool]$Event.details.termsVerificationRequired
        if ($Event.eventType -eq 'order.partially_filled' -and (-not (Test-Property -Object $Event -Name 'quantity'))) {
            throw 'order.partially_filled requires quantity.'
        }
        if ($Event.eventType -eq 'order.created' -and (-not (Test-Property -Object $Event -Name 'quantity')) -and
            (-not (Test-Property -Object $Event -Name 'quoteAmount')) -and -not $termsVerificationRequired) {
            throw 'order.created requires quantity, quoteAmount, or details.termsVerificationRequired=true.'
        }
        if ($Event.eventType -in @('order.proposed', 'order.created', 'order.partially_filled', 'order.deferred')) {
            foreach ($required in @('market', 'symbol', 'side', 'type')) {
                if (-not (Test-Property -Object $Event -Name $required) -or [string]::IsNullOrWhiteSpace([string]$Event.$required)) {
                    throw "$($Event.eventType) requires $required."
                }
            }
            if ($Event.type -eq 'limit' -and -not (Test-Property -Object $Event -Name 'price') -and -not $termsVerificationRequired) {
                throw "$($Event.eventType) for a limit order requires price."
            }
            if ($Event.eventType -in @('order.proposed', 'order.deferred') -and (-not (Test-Property -Object $Event -Name 'quantity')) -and (-not (Test-Property -Object $Event -Name 'quoteAmount')) -and -not $termsVerificationRequired) {
                throw "$($Event.eventType) requires quantity or quoteAmount."
            }
        }
    }
    if ($Event.eventType -like 'bot.*' -and (-not (Test-Property -Object $Event -Name 'botId')) -and (-not (Test-Property -Object $Event -Name 'recordId'))) {
        throw 'Bot events require botId or recordId.'
    }
    if ($Event.eventType -eq 'bot.started') {
        foreach ($required in @('market', 'symbol')) {
            if (-not (Test-Property -Object $Event -Name $required) -or [string]::IsNullOrWhiteSpace([string]$Event.$required)) {
                throw "bot.started requires $required."
            }
        }
    }
    if ($Event.eventType -eq 'balance.updated') {
        if (-not (Test-Property -Object $Event -Name 'asset') -or -not (Test-Property -Object $Event -Name 'quantity')) {
            throw 'Balance updates require asset and quantity.'
        }
    }
    if ($Event.eventType -eq 'position.updated') {
        if (-not (Test-Property -Object $Event -Name 'symbol') -or -not (Test-Property -Object $Event -Name 'quantity')) {
            throw 'Position updates require symbol and quantity.'
        }
    }
    if ($Event.eventType -eq 'account.snapshot') {
        if (-not (Test-Property -Object $Event -Name 'details')) {
            throw 'Account snapshots require details.'
        }
        foreach ($required in @('snapshotScope', 'balances', 'positions', 'reservedFunds')) {
            if (-not (Test-Property -Object $Event.details -Name $required)) {
                throw "Account snapshot details require $required."
            }
        }
    }
}

function Assert-EquivalentAccountEvent {
    param(
        [Parameter(Mandatory)][object]$Expected,
        [Parameter(Mandatory)][object]$Actual
    )

    $numericFields = @('price', 'quantity', 'quoteAmount', 'originalQuantity', 'filledQuantity', 'remainingQuantity')
    $fields = @(
        'schemaVersion', 'eventId', 'accountId', 'eventType', 'status', 'market', 'symbol', 'recordId', 'orderId',
        'clientOrderId', 'botId', 'transferId', 'side', 'type', 'price', 'quantity', 'quoteAmount',
        'originalQuantity', 'filledQuantity', 'remainingQuantity', 'asset', 'accountBucket', 'occurredAt',
        'evidence', 'source'
    )
    foreach ($field in $fields) {
        $expectedHas = Test-Property -Object $Expected -Name $field
        $actualHas = Test-Property -Object $Actual -Name $field
        if ($expectedHas -ne $actualHas) { throw "Existing event differs at field '$field'." }
        if (-not $expectedHas) { continue }
        if ($field -eq 'occurredAt') {
            if ([DateTimeOffset]$Expected.$field -ne [DateTimeOffset]$Actual.$field) { throw "Existing event differs at field '$field'." }
        }
        elseif ($numericFields -contains $field) {
            if ([decimal]$Expected.$field -ne [decimal]$Actual.$field) { throw "Existing event differs at field '$field'." }
        }
        elseif ([string]$Expected.$field -ne [string]$Actual.$field) {
            throw "Existing event differs at field '$field'."
        }
    }
    $expectedDetails = if (Test-Property -Object $Expected -Name 'details') { $Expected.details | ConvertTo-Json -Compress -Depth 100 } else { $null }
    $actualDetails = if (Test-Property -Object $Actual -Name 'details') { $Actual.details | ConvertTo-Json -Compress -Depth 100 } else { $null }
    if ($expectedDetails -ne $actualDetails) { throw "Existing event differs at field 'details'." }
}

function Get-StableObjectKey {
    param(
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][ValidateSet('order', 'position', 'balance', 'bot', 'transfer')][string]$Kind
    )

    switch ($Kind) {
        'order' {
            if ((Test-Property -Object $Object -Name 'recordId') -and -not [string]::IsNullOrWhiteSpace([string]$Object.recordId)) { return "record-order:$($Object.recordId)" }
            if ((Test-Property -Object $Object -Name 'orderId') -and -not [string]::IsNullOrWhiteSpace([string]$Object.orderId)) { return "order:$($Object.orderId)" }
            if ((Test-Property -Object $Object -Name 'clientOrderId') -and -not [string]::IsNullOrWhiteSpace([string]$Object.clientOrderId)) { return "client-order:$($Object.clientOrderId)" }
            return "legacy-order:$($Object.market)|$($Object.symbol)|$($Object.side)|$($Object.type)|$($Object.price)|$($Object.quantity)"
        }
        'position' { return "position:$($Object.market)|$($Object.symbol)" }
        'balance' { return "balance:$($Object.asset)|$($Object.accountBucket)" }
        'bot' {
            if ((Test-Property -Object $Object -Name 'recordId') -and -not [string]::IsNullOrWhiteSpace([string]$Object.recordId)) { return "record-bot:$($Object.recordId)" }
            if ((Test-Property -Object $Object -Name 'botId') -and -not [string]::IsNullOrWhiteSpace([string]$Object.botId)) { return "bot:$($Object.botId)" }
            $capital = if (Test-Property -Object $Object -Name 'investment') { $Object.investment } else { $Object.margin }
            $range = if (Test-Property -Object $Object -Name 'range') { ($Object.range -join ',') } else { '' }
            return "legacy-bot:$($Object.market)|$($Object.symbol)|$($Object.strategy)|$capital|$range"
        }
        'transfer' {
            if ((Test-Property -Object $Object -Name 'transferId') -and -not [string]::IsNullOrWhiteSpace([string]$Object.transferId)) { return "transfer:$($Object.transferId)" }
            return "event-transfer:$($Object.eventId)"
        }
    }
}

function Test-CompatibleTextField {
    param(
        [Parameter(Mandatory)][object]$Left,
        [Parameter(Mandatory)][object]$Right,
        [Parameter(Mandatory)][string]$Name,
        [switch]$AllowMissing
    )
    $leftValue = if (Test-Property -Object $Left -Name $Name) { [string]$Left.$Name } else { '' }
    $rightValue = if (Test-Property -Object $Right -Name $Name) { [string]$Right.$Name } else { '' }
    if ($AllowMissing -and ([string]::IsNullOrWhiteSpace($leftValue) -or [string]::IsNullOrWhiteSpace($rightValue))) { return $true }
    return -not [string]::IsNullOrWhiteSpace($leftValue) -and -not [string]::IsNullOrWhiteSpace($rightValue) -and $leftValue -eq $rightValue
}

function Test-StateObjectMatch {
    param(
        [Parameter(Mandatory)][object]$Left,
        [Parameter(Mandatory)][object]$Right,
        [Parameter(Mandatory)][ValidateSet('order', 'position', 'balance', 'bot', 'transfer')][string]$Kind
    )

    switch ($Kind) {
        'order' {
            foreach ($name in @('recordId', 'orderId', 'clientOrderId')) {
                if ((Test-Property -Object $Left -Name $name) -and (Test-Property -Object $Right -Name $name) -and
                    -not [string]::IsNullOrWhiteSpace([string]$Left.$name) -and [string]$Left.$name -eq [string]$Right.$name) { return $true }
            }
            $leftHasId = ((Test-Property -Object $Left -Name 'recordId') -and -not [string]::IsNullOrWhiteSpace([string]$Left.recordId)) -or
                ((Test-Property -Object $Left -Name 'orderId') -and -not [string]::IsNullOrWhiteSpace([string]$Left.orderId)) -or
                ((Test-Property -Object $Left -Name 'clientOrderId') -and -not [string]::IsNullOrWhiteSpace([string]$Left.clientOrderId))
            $rightHasId = ((Test-Property -Object $Right -Name 'recordId') -and -not [string]::IsNullOrWhiteSpace([string]$Right.recordId)) -or
                ((Test-Property -Object $Right -Name 'orderId') -and -not [string]::IsNullOrWhiteSpace([string]$Right.orderId)) -or
                ((Test-Property -Object $Right -Name 'clientOrderId') -and -not [string]::IsNullOrWhiteSpace([string]$Right.clientOrderId))
            if ($leftHasId -and $rightHasId) { return $false }
            if (-not (Test-CompatibleTextField -Left $Left -Right $Right -Name 'symbol')) { return $false }
            foreach ($name in @('market', 'side', 'type')) {
                if (-not (Test-CompatibleTextField -Left $Left -Right $Right -Name $name -AllowMissing)) { return $false }
            }
            if ((Test-Property -Object $Left -Name 'price') -and (Test-Property -Object $Right -Name 'price') -and [decimal]$Left.price -ne [decimal]$Right.price) { return $false }
            return $true
        }
        'position' {
            return (Test-CompatibleTextField -Left $Left -Right $Right -Name 'symbol') -and
                (Test-CompatibleTextField -Left $Left -Right $Right -Name 'market' -AllowMissing)
        }
        'balance' {
            return (Test-CompatibleTextField -Left $Left -Right $Right -Name 'asset') -and
                (Test-CompatibleTextField -Left $Left -Right $Right -Name 'accountBucket' -AllowMissing)
        }
        'bot' {
            if ((Test-Property -Object $Left -Name 'recordId') -and (Test-Property -Object $Right -Name 'recordId') -and
                -not [string]::IsNullOrWhiteSpace([string]$Left.recordId) -and [string]$Left.recordId -eq [string]$Right.recordId) { return $true }
            if ((Test-Property -Object $Left -Name 'botId') -and (Test-Property -Object $Right -Name 'botId') -and
                -not [string]::IsNullOrWhiteSpace([string]$Left.botId) -and [string]$Left.botId -eq [string]$Right.botId) { return $true }
            $leftHasId = ((Test-Property -Object $Left -Name 'recordId') -and -not [string]::IsNullOrWhiteSpace([string]$Left.recordId)) -or
                ((Test-Property -Object $Left -Name 'botId') -and -not [string]::IsNullOrWhiteSpace([string]$Left.botId))
            $rightHasId = ((Test-Property -Object $Right -Name 'recordId') -and -not [string]::IsNullOrWhiteSpace([string]$Right.recordId)) -or
                ((Test-Property -Object $Right -Name 'botId') -and -not [string]::IsNullOrWhiteSpace([string]$Right.botId))
            if ($leftHasId -and $rightHasId) { return $false }
            if (-not (Test-CompatibleTextField -Left $Left -Right $Right -Name 'symbol')) { return $false }
            foreach ($name in @('market', 'strategy')) {
                if (-not (Test-CompatibleTextField -Left $Left -Right $Right -Name $name -AllowMissing)) { return $false }
            }
            $leftCapital = if (Test-Property -Object $Left -Name 'investment') { $Left.investment } elseif (Test-Property -Object $Left -Name 'margin') { $Left.margin } else { $null }
            $rightCapital = if (Test-Property -Object $Right -Name 'investment') { $Right.investment } elseif (Test-Property -Object $Right -Name 'margin') { $Right.margin } else { $null }
            if ($null -ne $leftCapital -and $null -ne $rightCapital -and [decimal]$leftCapital -ne [decimal]$rightCapital) { return $false }
            if ((Test-Property -Object $Left -Name 'range') -and (Test-Property -Object $Right -Name 'range') -and
                (($Left.range -join ',') -ne ($Right.range -join ','))) { return $false }
            return $true
        }
        'transfer' {
            if ((Test-Property -Object $Left -Name 'transferId') -and (Test-Property -Object $Right -Name 'transferId') -and
                -not [string]::IsNullOrWhiteSpace([string]$Left.transferId) -and [string]$Left.transferId -eq [string]$Right.transferId) { return $true }
            return (Test-Property -Object $Left -Name 'eventId') -and (Test-Property -Object $Right -Name 'eventId') -and $Left.eventId -eq $Right.eventId
        }
    }
}

function Merge-StateObject {
    param([Parameter(Mandatory)][object]$Existing, [Parameter(Mandatory)][object]$Update)
    $merged = [ordered]@{}
    foreach ($property in $Existing.PSObject.Properties) { $merged[$property.Name] = $property.Value }
    foreach ($property in $Update.PSObject.Properties) { $merged[$property.Name] = $property.Value }
    return [pscustomobject]$merged
}

function Get-MatchingStateObjectIndices {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][ValidateSet('order', 'position', 'balance', 'bot', 'transfer')][string]$Kind
    )
    $matches = @()
    for ($index = 0; $index -lt $Items.Count; $index++) {
        if (Test-StateObjectMatch -Left $Items[$index] -Right $Object -Kind $Kind) { $matches += $index }
    }
    return @($matches)
}

function Test-ObjectUpdateIsStale {
    param([Parameter(Mandatory)][object]$Existing, [Parameter(Mandatory)][object]$Update)
    if (-not (Test-Property -Object $Existing -Name 'updatedAt') -or [string]::IsNullOrWhiteSpace([string]$Existing.updatedAt)) { return $false }
    if (-not (Test-Property -Object $Update -Name 'updatedAt') -or [string]::IsNullOrWhiteSpace([string]$Update.updatedAt)) { return $false }
    return ([DateTimeOffset]$Update.updatedAt) -lt ([DateTimeOffset]$Existing.updatedAt)
}

function Test-OrderHasTerminalRecordAtOrAfter {
    param([Parameter(Mandatory)][object]$State, [Parameter(Mandatory)][object]$Order)
    foreach ($record in @($State.executionEvents)) {
        if ($null -eq $record -or -not (Test-StateObjectMatch -Left $record -Right $Order -Kind order)) { continue }
        if ((Test-Property -Object $record -Name 'occurredAt') -and -not [string]::IsNullOrWhiteSpace([string]$record.occurredAt) -and
            ([DateTimeOffset]$record.occurredAt) -ge ([DateTimeOffset]$Order.updatedAt)) { return $true }
    }
    return $false
}

function Add-EventRecord {
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string]$PropertyName,
        [Parameter(Mandatory)][object]$Event,
        [Parameter(Mandatory)][string]$Reason
    )

    $records = @($State.$PropertyName)
    if (@($records | Where-Object { $_.eventId -eq $Event.eventId }).Count -gt 0) { return }
    $record = [ordered]@{
        eventId = $Event.eventId
        eventType = $Event.eventType
        status = $Event.status
        occurredAt = $Event.occurredAt
        reason = $Reason
    }
    foreach ($name in @('market', 'symbol', 'recordId', 'orderId', 'clientOrderId', 'botId', 'transferId', 'side', 'type', 'price')) {
        if (Test-Property -Object $Event -Name $name) { $record[$name] = $Event.$name }
    }
    Set-ObjectProperty -Object $State -Name $PropertyName -Value @($records + [pscustomobject]$record)
}

function Remove-MatchingOrderRecords {
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string]$PropertyName,
        [Parameter(Mandatory)][object]$OrderIdentity
    )
    $kept = @()
    foreach ($record in @($State.$PropertyName)) {
        if ($null -eq $record -or -not (Test-StateObjectMatch -Left $record -Right $OrderIdentity -Kind order)) {
            $kept += $record
        }
    }
    Set-ObjectProperty -Object $State -Name $PropertyName -Value @($kept)
}

function Add-AppliedEventId {
    param([Parameter(Mandatory)][object]$State, [Parameter(Mandatory)][string]$EventId)
    $ids = @($State.appliedEventIds)
    if ($ids -notcontains $EventId) { Set-ObjectProperty -Object $State -Name 'appliedEventIds' -Value @($ids + $EventId) }
}

function Update-LastEventAt {
    param([Parameter(Mandatory)][object]$State, [Parameter(Mandatory)][object]$Event)
    if ($Event.status -in @('unknown', 'pending_verification', 'proposed') -or $Event.eventType -in @('order.proposed', 'account.snapshot')) { return }
    if (-not (Test-Property -Object $State -Name 'lastEventAt') -or [string]::IsNullOrWhiteSpace([string]$State.lastEventAt)) {
        Set-ObjectProperty -Object $State -Name 'lastEventAt' -Value $Event.occurredAt
        return
    }
    if (([DateTimeOffset]$Event.occurredAt) -gt ([DateTimeOffset]$State.lastEventAt)) {
        Set-ObjectProperty -Object $State -Name 'lastEventAt' -Value $Event.occurredAt
    }
}

function Add-CommonObjectFields {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Target, [Parameter(Mandatory)][object]$Event)

    foreach ($name in @(
        'eventId', 'market', 'symbol', 'recordId', 'orderId', 'clientOrderId', 'botId', 'transferId', 'side', 'type',
        'price', 'quantity', 'quoteAmount', 'originalQuantity', 'filledQuantity', 'remainingQuantity',
        'asset', 'accountBucket'
    )) {
        if (Test-Property -Object $Event -Name $name) { $Target[$name] = $Event.$name }
    }
    if (Test-Property -Object $Event -Name 'details') {
        foreach ($property in $Event.details.PSObject.Properties) {
            $Target[$property.Name] = $property.Value
        }
    }
    $Target.updatedAt = $Event.occurredAt
}

function Upsert-StateObject {
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string]$PropertyName,
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][ValidateSet('order', 'position', 'balance', 'bot', 'transfer')][string]$Kind
    )

    $items = @($State.$PropertyName)
    $matches = @(Get-MatchingStateObjectIndices -Items $items -Object $Object -Kind $Kind)
    if ($matches.Count -gt 1) { throw "Ambiguous $Kind identity matches $($matches.Count) current objects." }
    if ($matches.Count -eq 1) {
        $index = $matches[0]
        if (-not (Test-ObjectUpdateIsStale -Existing $items[$index] -Update $Object)) {
            $items[$index] = Merge-StateObject -Existing $items[$index] -Update $Object
        }
    }
    else { $items += [pscustomobject]$Object }
    $State.$PropertyName = @($items)
}

function Remove-StateObject {
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string]$PropertyName,
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][ValidateSet('order', 'position', 'balance', 'bot', 'transfer')][string]$Kind
    )

    $items = @($State.$PropertyName)
    $matches = @(Get-MatchingStateObjectIndices -Items $items -Object $Object -Kind $Kind)
    if ($matches.Count -gt 1) { throw "Ambiguous $Kind identity matches $($matches.Count) current objects." }
    if ($matches.Count -eq 0) { return $false }
    $index = $matches[0]
    if (Test-ObjectUpdateIsStale -Existing $items[$index] -Update $Object) { return $false }
    $remaining = @()
    for ($itemIndex = 0; $itemIndex -lt $items.Count; $itemIndex++) {
        if ($itemIndex -ne $index) { $remaining += $items[$itemIndex] }
    }
    $State.$PropertyName = @($remaining)
    return $true
}

function New-ProjectedObject {
    param([Parameter(Mandatory)][object]$Event)
    $object = [ordered]@{}
    Add-CommonObjectFields -Target $object -Event $Event
    return [pscustomobject]$object
}

function Complete-CreatedOrderFromProposal {
    param(
        [Parameter(Mandatory)][object]$Event,
        [Parameter(Mandatory)][object]$State
    )

    if ($Event.eventType -ne 'order.created') { return $Event }
    $proposals = if ((Test-Property -Object $State -Name 'proposedOrders') -and $null -ne $State.proposedOrders) { @($State.proposedOrders) } else { @() }
    if ($proposals.Count -eq 0) { return $Event }
    $matches = @(Get-MatchingStateObjectIndices -Items $proposals -Object $Event -Kind order)
    if ($matches.Count -gt 1) { throw 'Ambiguous proposed order identity.' }
    if ($matches.Count -eq 0) { return $Event }

    $proposal = $proposals[$matches[0]]
    $completed = [ordered]@{}
    foreach ($property in $Event.PSObject.Properties) { $completed[$property.Name] = $property.Value }
    foreach ($name in @('market', 'symbol', 'recordId', 'orderId', 'clientOrderId', 'side', 'type', 'price', 'quantity', 'quoteAmount')) {
        if (-not $completed.Contains($name) -and (Test-Property -Object $proposal -Name $name)) {
            $completed[$name] = $proposal.$name
        }
    }
    if (-not $completed.Contains('details')) { $completed.details = [pscustomobject]@{} }
    if ($null -ne $completed.details -and $completed.details -is [pscustomobject]) {
        Set-ObjectProperty -Object $completed.details -Name 'inheritedFromProposalEventId' -Value $proposal.eventId
    }
    return [pscustomobject]$completed
}

function Apply-AccountEvent {
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][object]$Event
    )

    foreach ($property in @('orders', 'proposedOrders', 'deferredOrders', 'positions', 'balances', 'reservedFunds', 'bots', 'stoppedBots', 'executionEvents', 'pendingVerifications', 'failedEvents', 'transfers', 'appliedEventIds')) {
        if (-not (Test-Property -Object $State -Name $property) -or $null -eq $State.$property) {
            Set-ObjectProperty -Object $State -Name $property -Value @()
        }
    }
    if ($State.appliedEventIds -contains $Event.eventId) { return $State }

    if ($Event.status -in @('unknown', 'pending_verification') -or $Event.eventType -in @('order.unknown', 'transfer.unknown')) {
        Add-EventRecord -State $State -PropertyName 'pendingVerifications' -Event $Event -Reason 'result_requires_verification'
        Add-AppliedEventId -State $State -EventId $Event.eventId
        return $State
    }

    if ($Event.status -in @('failed', 'rejected') -and $Event.eventType -ne 'order.rejected' -and $Event.eventType -notlike 'transfer.*') {
        Add-EventRecord -State $State -PropertyName 'failedEvents' -Event $Event -Reason 'action_failed'
        Add-AppliedEventId -State $State -EventId $Event.eventId
        Update-LastEventAt -State $State -Event $Event
        return $State
    }

    switch ($Event.eventType) {
        'account.snapshot' {
            Set-ObjectProperty -Object $State -Name 'observedAt' -Value $Event.occurredAt
            Set-ObjectProperty -Object $State -Name 'source' -Value $Event.source
            foreach ($field in @(
                'verificationRequired', 'reportedTotalAssetValueUsd', 'reportedTotalAssetValueCny',
                'reportedSecurityMarketValueCny', 'availableCny', 'withdrawableCny', 'positionRatioPct',
                'holdingPnlCny', 'dailyPnlUsd', 'dailyPnlCny', 'dailyPnlPct',
                'reportedRobotAssetValueUsd', 'robotDailyPnlUsd', 'robotDailyPnlPct', 'snapshotScope',
                'accountBreakdown', 'notes'
            )) {
                if (Test-Property -Object $Event.details -Name $field) {
                    Set-ObjectProperty -Object $State -Name $field -Value $Event.details.$field
                }
            }
            foreach ($collection in @('balances', 'positions', 'reservedFunds')) {
                $projected = @()
                foreach ($item in @($Event.details.$collection)) {
                    Set-ObjectProperty -Object $item -Name 'eventId' -Value $Event.eventId
                    Set-ObjectProperty -Object $item -Name 'snapshotObservedAt' -Value $Event.occurredAt
                    Set-ObjectProperty -Object $item -Name 'updatedAt' -Value $Event.occurredAt
                    $projected += $item
                }
                Set-ObjectProperty -Object $State -Name $collection -Value $projected
            }
        }
        'order.proposed' {
            $order = New-ProjectedObject -Event $Event
            Set-ObjectProperty -Object $order -Name 'status' -Value 'proposed'
            Upsert-StateObject -State $State -PropertyName 'proposedOrders' -Object $order -Kind order
        }
        'order.created' {
            $order = New-ProjectedObject -Event $Event
            Set-ObjectProperty -Object $order -Name 'status' -Value 'open'
            if (Test-Property -Object $order -Name 'quantity') {
                if (-not (Test-Property -Object $order -Name 'originalQuantity')) { Set-ObjectProperty -Object $order -Name 'originalQuantity' -Value $order.quantity }
                if (-not (Test-Property -Object $order -Name 'filledQuantity')) { Set-ObjectProperty -Object $order -Name 'filledQuantity' -Value ([decimal]0) }
                if (-not (Test-Property -Object $order -Name 'remainingQuantity')) { Set-ObjectProperty -Object $order -Name 'remainingQuantity' -Value $order.quantity }
            }
            if (-not (Test-OrderHasTerminalRecordAtOrAfter -State $State -Order $order)) {
                $null = Remove-StateObject -State $State -PropertyName 'proposedOrders' -Object $order -Kind order
                $null = Remove-StateObject -State $State -PropertyName 'deferredOrders' -Object $order -Kind order
                Remove-MatchingOrderRecords -State $State -PropertyName 'failedEvents' -OrderIdentity $order
                Upsert-StateObject -State $State -PropertyName 'orders' -Object $order -Kind order
            }
        }
        'order.partially_filled' {
            $order = New-ProjectedObject -Event $Event
            Set-ObjectProperty -Object $order -Name 'status' -Value 'partially_filled'
            if (-not (Test-OrderHasTerminalRecordAtOrAfter -State $State -Order $order)) {
                Upsert-StateObject -State $State -PropertyName 'orders' -Object $order -Kind order
            }
        }
        'order.filled' {
            $orderIdentity = New-ProjectedObject -Event $Event
            $removed = Remove-StateObject -State $State -PropertyName 'orders' -Object $orderIdentity -Kind order
            Add-EventRecord -State $State -PropertyName 'executionEvents' -Event $Event -Reason 'order_filled'
            if (-not $removed) {
                Add-EventRecord -State $State -PropertyName 'pendingVerifications' -Event $Event -Reason 'filled_order_target_not_found_or_newer'
            }
            elseif (-not (Test-Property -Object $Event -Name 'asset')) {
                Add-EventRecord -State $State -PropertyName 'pendingVerifications' -Event $Event -Reason 'fill_asset_state_not_supplied'
            }
        }
        'order.canceled' {
            $orderIdentity = New-ProjectedObject -Event $Event
            $removedOpen = Remove-StateObject -State $State -PropertyName 'orders' -Object $orderIdentity -Kind order
            $removedProposed = Remove-StateObject -State $State -PropertyName 'proposedOrders' -Object $orderIdentity -Kind order
            $removedDeferred = Remove-StateObject -State $State -PropertyName 'deferredOrders' -Object $orderIdentity -Kind order
            $removed = $removedOpen -or $removedProposed -or $removedDeferred
            Add-EventRecord -State $State -PropertyName 'executionEvents' -Event $Event -Reason 'order_canceled'
            if (-not $removed) {
                Add-EventRecord -State $State -PropertyName 'pendingVerifications' -Event $Event -Reason 'canceled_order_target_not_found_or_newer'
            }
        }
        'order.rejected' {
            $orderIdentity = New-ProjectedObject -Event $Event
            # A rejection can terminate either an exchange submission or an
            # unsubmitted recommendation that the user explicitly declined.
            # The identity must not remain actionable in any order bucket.
            $null = Remove-StateObject -State $State -PropertyName 'orders' -Object $orderIdentity -Kind order
            $null = Remove-StateObject -State $State -PropertyName 'proposedOrders' -Object $orderIdentity -Kind order
            $null = Remove-StateObject -State $State -PropertyName 'deferredOrders' -Object $orderIdentity -Kind order
            Add-EventRecord -State $State -PropertyName 'failedEvents' -Event $Event -Reason 'order_rejected'
        }
        'order.deferred' {
            $order = New-ProjectedObject -Event $Event
            Set-ObjectProperty -Object $order -Name 'status' -Value 'deferred'
            $null = Remove-StateObject -State $State -PropertyName 'orders' -Object $order -Kind order
            $null = Remove-StateObject -State $State -PropertyName 'proposedOrders' -Object $order -Kind order
            Remove-MatchingOrderRecords -State $State -PropertyName 'failedEvents' -OrderIdentity $order
            Upsert-StateObject -State $State -PropertyName 'deferredOrders' -Object $order -Kind order
        }
        'position.updated' {
            $position = New-ProjectedObject -Event $Event
            Upsert-StateObject -State $State -PropertyName 'positions' -Object $position -Kind position
        }
        'balance.updated' {
            $balance = New-ProjectedObject -Event $Event
            $isReservedBucket = (Test-Property -Object $State -Name 'reservedFunds') -and
                (Test-Property -Object $balance -Name 'accountBucket') -and
                @($State.reservedFunds | Where-Object {
                    (Test-Property -Object $_ -Name 'asset') -and $_.asset -eq $balance.asset -and
                    (Test-Property -Object $_ -Name 'accountBucket') -and $_.accountBucket -eq $balance.accountBucket
                }).Count -gt 0
            if ($isReservedBucket) {
                Upsert-StateObject -State $State -PropertyName 'reservedFunds' -Object $balance -Kind balance
            }
            else {
                Upsert-StateObject -State $State -PropertyName 'balances' -Object $balance -Kind balance
            }
        }
        'bot.started' {
            $bot = New-ProjectedObject -Event $Event
            Set-ObjectProperty -Object $bot -Name 'status' -Value 'running'
            # A confirmed bot may reuse the stable recordId of its earlier
            # order.proposed recommendation. Once the bot is running, that
            # proposal is no longer pending and must not remain in the
            # proposed-order inventory.
            $null = Remove-StateObject -State $State -PropertyName 'proposedOrders' -Object $bot -Kind order
            $stoppedMatches = @(Get-MatchingStateObjectIndices -Items @($State.stoppedBots) -Object $bot -Kind bot)
            if ($stoppedMatches.Count -gt 1) { throw 'Ambiguous bot identity in stoppedBots.' }
            if ($stoppedMatches.Count -eq 0 -or -not (Test-ObjectUpdateIsStale -Existing $State.stoppedBots[$stoppedMatches[0]] -Update $bot)) {
                $null = Remove-StateObject -State $State -PropertyName 'stoppedBots' -Object $bot -Kind bot
                Upsert-StateObject -State $State -PropertyName 'bots' -Object $bot -Kind bot
            }
        }
        'bot.stopped' {
            $bot = New-ProjectedObject -Event $Event
            Set-ObjectProperty -Object $bot -Name 'status' -Value 'stopped'
            Set-ObjectProperty -Object $bot -Name 'stoppedAt' -Value $Event.occurredAt
            $activeMatches = @(Get-MatchingStateObjectIndices -Items @($State.bots) -Object $bot -Kind bot)
            if ($activeMatches.Count -gt 1) { throw 'Ambiguous bot identity in bots.' }
            if ($activeMatches.Count -eq 0 -or -not (Test-ObjectUpdateIsStale -Existing $State.bots[$activeMatches[0]] -Update $bot)) {
                $null = Remove-StateObject -State $State -PropertyName 'bots' -Object $bot -Kind bot
                Upsert-StateObject -State $State -PropertyName 'stoppedBots' -Object $bot -Kind bot
            }
        }
        { $_ -like 'transfer.*' } {
            $transfer = New-ProjectedObject -Event $Event
            Set-ObjectProperty -Object $transfer -Name 'status' -Value $Event.status
            Upsert-StateObject -State $State -PropertyName 'transfers' -Object $transfer -Kind transfer
            if ($Event.status -in @('failed', 'rejected')) {
                Add-EventRecord -State $State -PropertyName 'failedEvents' -Event $Event -Reason 'transfer_failed'
            }
        }
    }

    Add-AppliedEventId -State $State -EventId $Event.eventId
    Update-LastEventAt -State $State -Event $Event
    return $State
}

function Assert-AccountState {
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string]$ExpectedAccountId
    )

    if ($State.accountId -ne $ExpectedAccountId) { throw 'Current state accountId does not match the configured account.' }
    foreach ($property in @('orders', 'proposedOrders', 'deferredOrders', 'positions', 'balances', 'reservedFunds', 'bots', 'stoppedBots', 'appliedEventIds', 'pendingVerifications', 'failedEvents', 'transfers')) {
        if (-not (Test-Property -Object $State -Name $property)) { continue }
        if ($null -eq $State.$property) { throw "State property '$property' cannot be null." }
    }
    $collectionKinds = @(
        [pscustomobject]@{ Property = 'orders'; Kind = 'order' }
        [pscustomobject]@{ Property = 'proposedOrders'; Kind = 'order' }
        [pscustomobject]@{ Property = 'deferredOrders'; Kind = 'order' }
        [pscustomobject]@{ Property = 'positions'; Kind = 'position' }
        [pscustomobject]@{ Property = 'balances'; Kind = 'balance' }
        [pscustomobject]@{ Property = 'reservedFunds'; Kind = 'balance' }
        [pscustomobject]@{ Property = 'bots'; Kind = 'bot' }
        [pscustomobject]@{ Property = 'stoppedBots'; Kind = 'bot' }
        [pscustomobject]@{ Property = 'transfers'; Kind = 'transfer' }
    )
    foreach ($kindProperty in $collectionKinds) {
        $seen = @{}
        foreach ($item in @($State.($kindProperty.Property))) {
            if ($null -eq $item) { continue }
            $key = Get-StableObjectKey -Object $item -Kind $kindProperty.Kind
            if ($seen.ContainsKey($key)) { throw "Duplicate $($kindProperty.Kind) identity in $($kindProperty.Property): $key" }
            $seen[$key] = $true
            if ($kindProperty.Kind -eq 'order' -and $item.status -in @('filled', 'canceled', 'rejected', 'failed')) {
                throw "Terminal order remains in current orders: $key"
            }
            if ((Test-Property -Object $item -Name 'updatedAt') -and -not [string]::IsNullOrWhiteSpace([string]$item.updatedAt)) {
                try { $null = [DateTimeOffset]$item.updatedAt } catch { throw "Invalid object updatedAt in $($kindProperty.Property): $key" }
            }
        }
        $items = @($State.($kindProperty.Property))
        for ($leftIndex = 0; $leftIndex -lt $items.Count; $leftIndex++) {
            for ($rightIndex = $leftIndex + 1; $rightIndex -lt $items.Count; $rightIndex++) {
                if (Test-StateObjectMatch -Left $items[$leftIndex] -Right $items[$rightIndex] -Kind $kindProperty.Kind) {
                    throw "Overlapping $($kindProperty.Kind) identities in $($kindProperty.Property)."
                }
            }
        }
    }
    foreach ($activeBot in @($State.bots)) {
        foreach ($stoppedBot in @($State.stoppedBots)) {
            if ($null -ne $activeBot -and $null -ne $stoppedBot -and (Test-StateObjectMatch -Left $activeBot -Right $stoppedBot -Kind bot)) {
                throw 'Bot identity exists in both bots and stoppedBots.'
            }
        }
    }
    foreach ($activeOrder in @($State.orders)) {
        foreach ($proposedOrder in @($State.proposedOrders)) {
            if ($null -ne $activeOrder -and $null -ne $proposedOrder -and (Test-StateObjectMatch -Left $activeOrder -Right $proposedOrder -Kind order)) {
                throw 'Order identity exists in both orders and proposedOrders.'
            }
        }
        foreach ($deferredOrder in @($State.deferredOrders)) {
            if ($null -ne $activeOrder -and $null -ne $deferredOrder -and (Test-StateObjectMatch -Left $activeOrder -Right $deferredOrder -Kind order)) {
                throw 'Order identity exists in both orders and deferredOrders.'
            }
        }
    }
    $eventIds = if (Test-Property -Object $State -Name 'appliedEventIds') { @($State.appliedEventIds) } else { @() }
    if (@($eventIds | Group-Object | Where-Object Count -gt 1).Count -gt 0) { throw 'appliedEventIds contains duplicates.' }
    if (@($eventIds | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) { throw 'appliedEventIds contains an empty ID.' }
    foreach ($timestampProperty in @('observedAt', 'lastEventAt')) {
        if ((Test-Property -Object $State -Name $timestampProperty) -and -not [string]::IsNullOrWhiteSpace([string]$State.$timestampProperty)) {
            try { $null = [DateTimeOffset]$State.$timestampProperty } catch { throw "Invalid state timestamp: $timestampProperty" }
        }
    }
}

function Assert-AccountEventLog {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$AccountId
    )

    $events = Read-AccountEvents -ProjectRoot $ProjectRoot
    $seen = @{}
    foreach ($event in $events) {
        $null = Get-AccountConfig -ProjectRoot $ProjectRoot -AccountId $event.accountId
        Assert-AccountEvent -Event $event -ExpectedAccountId $event.accountId
        $scopedEventId = "$($event.accountId)`:$($event.eventId)"
        if ($seen.ContainsKey($scopedEventId)) { throw "Duplicate account event ID within account: $scopedEventId" }
        $seen[$scopedEventId] = $true
    }
    return $events
}
