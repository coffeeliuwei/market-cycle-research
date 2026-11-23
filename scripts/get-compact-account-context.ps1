param(
    [string]$ProjectRoot,
    [string[]]$AccountId,
    [string[]]$Symbols,
    [switch]$IncludeDecisions,
    [switch]$IncludeRecordIds,
    [int]$MaxChars = 0
)
$ErrorActionPreference = 'Stop'
if (-not $ProjectRoot) { $ProjectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)) }
$budget = Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'config\analysis-budget.json') | ConvertFrom-Json
if ($MaxChars -le 0) { $MaxChars = [int]$budget.contextMaxChars }

function Pick([object]$item, [string[]]$names) {
    $out = [ordered]@{}
    foreach ($name in $names) {
        if ($null -ne $item.PSObject.Properties[$name] -and $null -ne $item.$name) { $out[$name] = $item.$name }
    }
    [pscustomobject]$out
}
function Matches([object]$item) {
    if (-not $Symbols) { return $true }
    $candidate = ([string]$item.symbol).Replace('/','').ToUpperInvariant()
    return @($Symbols | Where-Object { $_.Replace('/','').ToUpperInvariant() -eq $candidate }).Count -gt 0
}

$fields = @{
    balances=@('asset','quantity','reportedValueUsd','reportedValueCny')
    positions=@('symbol','quantity','reportedValueUsd','reportedValueCny','unrealizedPnlUsd','unrealizedPnlPct')
    # Current-state orders are open by definition; omitting the repeated status saves context without losing information.
    orders=@('symbol','side','price','quantity')
    bots=@('symbol','strategy','status','investment','range','totalPnl','totalPnlPct','reportedTotalPnlUsd','reportedTotalPnlPct')
    proposedOrders=@('symbol','side','price','quantity','quoteAmount')
    deferredOrders=@('symbol','side','price','quantity','quoteAmount')
    pendingVerifications=@('symbol','status')
    failedEvents=@('symbol','status')
}
if ($IncludeRecordIds) {
    foreach ($collection in @('orders','bots','proposedOrders','deferredOrders')) {
        $fields[$collection] = @('recordId') + @($fields[$collection])
    }
}
$accounts = [Collections.Generic.List[object]]::new()
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'state\current') -Filter '*.json' -File | Sort-Object Name) {
    $state = Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json
    if ($AccountId -and [string]$state.accountId -notin $AccountId) { continue }
    $a = [ordered]@{
        accountId = $state.accountId; observedAt = $state.observedAt; lastEventAt = $state.lastEventAt
        verificationRequired = $state.verificationRequired; ownership = $state.ownership
        reportedTotalAssetValueUsd = $state.reportedTotalAssetValueUsd; reportedTotalAssetValueCny = $state.reportedTotalAssetValueCny
        dailyPnlUsd = $state.dailyPnlUsd; dailyPnlCny = $state.dailyPnlCny
    }
    foreach ($key in @($a.Keys)) { if ($null -eq $a[$key]) { $a.Remove($key) } }
    foreach ($collection in @('balances','positions','orders','bots','proposedOrders','deferredOrders','pendingVerifications','failedEvents')) {
        $a[$collection] = @($state.$collection | Where-Object { Matches $_ } | ForEach-Object { Pick $_ $fields[$collection] })
    }
    foreach ($collection in @('pendingVerifications','failedEvents')) {
        $a[$collection] = @($a[$collection] | Group-Object symbol,status | ForEach-Object {
            [pscustomobject][ordered]@{ symbol=$_.Group[0].symbol; status=$_.Group[0].status; count=$_.Count }
        })
    }
    $accounts.Add([pscustomobject]$a)
}
$decisions = @()
if ($IncludeDecisions) {
    $decisionRaw = & (Join-Path $ProjectRoot 'scripts\get-effective-decisions.ps1')
    $decisions = try { @(($decisionRaw -join "`n") | ConvertFrom-Json) } catch { @() }
}
$result = [ordered]@{
    schemaVersion = 1; generatedAt = [DateTimeOffset]::UtcNow.ToString('o')
    filters = [ordered]@{ accountId=@($AccountId); symbols=@($Symbols) }
    accounts = @($accounts); decisions = @($decisions | Where-Object status -eq 'active' | ForEach-Object { Pick $_ @('scope','statement') })
    truncated = $false; omitted = [ordered]@{}
}
$json = $result | ConvertTo-Json -Depth 12 -Compress
if ($json.Length -gt $MaxChars) {
    $result.omitted.balances = @($result.accounts.balances).Count
    foreach ($account in $result.accounts) { $account.balances = @() }
    $result.truncated = $true
    $json = $result | ConvertTo-Json -Depth 12 -Compress
}
if ($json.Length -gt $MaxChars) { throw "Essential compact account context exceeds MaxChars=$MaxChars." }
$result | Add-Member -NotePropertyName outputChars -NotePropertyValue $json.Length
$result | ConvertTo-Json -Depth 12 -Compress
