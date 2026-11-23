param(
    [Parameter(Mandatory)][string]$ProjectRoot,
    [Parameter(Mandatory)][string[]]$Symbols,
    [string[]]$CandidateSymbols,
    [string[]]$IncludeSymbols,
    [Parameter(Mandatory)][string]$ScannerPath,
    [int]$MaxSymbols = 8,
    [decimal]$BoundaryPercent = 10,
    [switch]$DeepAll
)

$ErrorActionPreference = 'Stop'
$scanner = Get-Content -Raw -LiteralPath $ScannerPath | ConvertFrom-Json
$symbols = @($Symbols | ForEach-Object { ([string]$_).Trim().ToUpperInvariant() } | Where-Object { $_ } | Select-Object -Unique)
$resultBySymbol = @{}
foreach ($item in @($scanner.results)) { $resultBySymbol[([string]$item.symbol).ToUpperInvariant()] = $item }
$selected = [Collections.Generic.List[string]]::new()
$reasonMap = [ordered]@{}

function Get-BaseAsset([string]$Value) {
    $ticker = $Value.Trim().ToUpperInvariant()
    if ($ticker.Contains(':')) { $ticker = $ticker.Split(':', 2)[1] }
    $ticker = $ticker -replace '\.P$', '' -replace '[/_\-]', ''
    foreach ($quote in @('FDUSD','USDT','USDC','BUSD','TUSD','USDE','USD')) {
        if ($ticker.EndsWith($quote, [StringComparison]::Ordinal) -and $ticker.Length -gt $quote.Length) {
            return $ticker.Substring(0, $ticker.Length - $quote.Length)
        }
    }
    return $ticker
}

function Resolve-ScopeSymbol([string]$Value, [string]$AccountId = 'binance') {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $wanted = Get-BaseAsset $Value
    $prefix = switch ($AccountId.ToLowerInvariant()) { 'gate' { 'GATEIO:' }; 'ok' { 'OKX:' }; default { 'BINANCE:' } }
    $preferred = @($symbols | Where-Object { $_.StartsWith($prefix) -and (Get-BaseAsset $_) -eq $wanted } | Select-Object -First 1)
    if ($preferred.Count) { return $preferred[0] }
    $fallback = @($symbols | Where-Object { (Get-BaseAsset $_) -eq $wanted } | Select-Object -First 1)
    if ($fallback.Count) { return $fallback[0] }
    return $null
}

function Add-Reason([string]$Symbol, [string]$Reason) {
    if (-not $Symbol -or $Symbol -notin $symbols) { return }
    if (-not $reasonMap.Contains($Symbol)) { $reasonMap[$Symbol] = [Collections.Generic.List[string]]::new() }
    if ($Reason -notin $reasonMap[$Symbol]) { $reasonMap[$Symbol].Add($Reason) }
    if ($Symbol -notin $selected -and $selected.Count -lt $MaxSymbols) { $selected.Add($Symbol) }
}

function Test-ScannerFailure([object]$Item) {
    if ($null -eq $Item) { return $true }
    if ($null -ne $Item.PSObject.Properties['error'] -and -not [string]::IsNullOrWhiteSpace([string]$Item.error)) { return $true }
    if ($null -eq $Item.PSObject.Properties['periods']) { return $true }
    foreach ($periodProperty in $Item.periods.PSObject.Properties) {
        if ($periodProperty.Value.ok -ne $true) { return $true }
    }
    return $false
}

if ($DeepAll) {
    foreach ($symbol in $symbols) { Add-Reason $symbol 'explicit_scope' }
}
else {
    foreach ($candidate in @($CandidateSymbols)) { Add-Reason (Resolve-ScopeSymbol ([string]$candidate)) 'candidate' }
    foreach ($included in @($IncludeSymbols)) { Add-Reason (Resolve-ScopeSymbol ([string]$included)) 'included' }
    Add-Reason (Resolve-ScopeSymbol 'BTC') 'market_anchor'
    foreach ($symbol in $symbols) {
        $item = $resultBySymbol[$symbol]
        if ((Test-ScannerFailure -Item $item)) { Add-Reason $symbol 'scanner_failure' }
    }

    $currentPath = Join-Path $ProjectRoot 'state\current'
    if (Test-Path -LiteralPath $currentPath -PathType Container) {
        foreach ($stateFile in Get-ChildItem -LiteralPath $currentPath -Filter '*.json' -File) {
            $state = Get-Content -Raw -LiteralPath $stateFile.FullName | ConvertFrom-Json
            $accountId = [string]$state.accountId
            foreach ($order in @($state.orders)) {
                if (([string]$order.status).ToLowerInvariant() -in @('canceled','cancelled','filled','closed','rejected','failed','expired')) { continue }
                $symbol = Resolve-ScopeSymbol ([string]$order.symbol) $accountId
                if (-not $symbol) { continue }
                $close = $resultBySymbol[$symbol].periods.D.close
                if ($null -eq $close -or $null -eq $order.price -or [decimal]$close -eq 0) { continue }
                $distance = [math]::Abs(([decimal]$close - [decimal]$order.price) / [decimal]$close * 100)
                if ($distance -le $BoundaryPercent) { Add-Reason $symbol 'near_order' }
            }
            foreach ($bot in @($state.bots)) {
                if (([string]$bot.status).ToLowerInvariant() -notin @('running','active','confirmed')) { continue }
                if (@($bot.range).Count -lt 2) { continue }
                $symbol = Resolve-ScopeSymbol ([string]$bot.symbol) $accountId
                if (-not $symbol) { continue }
                $close = $resultBySymbol[$symbol].periods.D.close
                if ($null -eq $close -or [decimal]$close -eq 0) { continue }
                $nearBoundary = $false
                foreach ($boundary in @($bot.range)) {
                    if ([math]::Abs(([decimal]$close - [decimal]$boundary) / [decimal]$close * 100) -le $BoundaryPercent) {
                        $nearBoundary = $true
                        break
                    }
                }
                if ($nearBoundary) { Add-Reason $symbol 'near_bot_boundary' }
            }
        }
    }
}

$reasons = [ordered]@{}
foreach ($entry in $reasonMap.GetEnumerator()) { $reasons[$entry.Key] = @($entry.Value) }
[ordered]@{
    schemaVersion = 1
    maxSymbols = $MaxSymbols
    boundaryPercent = $BoundaryPercent
    symbols = @($selected)
    reasons = $reasons
} | ConvertTo-Json -Depth 8 -Compress
