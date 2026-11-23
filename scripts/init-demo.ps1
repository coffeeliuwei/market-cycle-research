$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$state = Join-Path $root 'state'
if (Test-Path $state) { throw 'state already exists. Run the demo in a fresh checkout.' }
Copy-Item (Join-Path $root 'examples/state') $state -Recurse
foreach ($directory in 'runtime','cycle-weekly/v1','forecasts','snapshots') {
    New-Item -ItemType Directory -Force (Join-Path $state $directory) | Out-Null
}
# Deterministic synthetic Friday closes, kept separate from live market data.
foreach ($market in 'SPY','BTC','CSI300TR') {
    $scale, $amplitude, $phase = switch ($market) {
        BTC { 4, 16, 0 }
        SPY { 2, 8, 2.1 }
        default { 1, 12, 4.2 }
    }
    $rows = for ($i=0; $i -lt 360; $i++) {
        [pscustomobject]@{
            week=([datetime]'2013-01-04').AddDays(7*$i).ToString('yyyy-MM-dd')
            price=[math]::Round($scale*(80+$i/7+$amplitude*[math]::Sin($i/14+$phase)),4)
            benchmark=[math]::Round(75+$i/20,4)
        }
    }
    $rows | Export-Csv (Join-Path $state "cycle-weekly/v1/$market.csv") -NoTypeInformation
}
$first=[datetimeoffset]'2013-01-04T00:00:00Z'
$times=[Collections.Generic.List[long]]::new()
$closes=[Collections.Generic.List[double]]::new()
for ($day=0; $day -le 359*7; $day++) {
    $week=$day/7
    $times.Add($first.AddDays($day).ToUnixTimeSeconds())
    $closes.Add([math]::Round(4*(80+$week/7+16*[math]::Sin($week/14)),4))
}
@{timestamp=$times;indicators=@{quote=@(@{close=$closes})}} | ConvertTo-Json -Depth 6 -Compress | Set-Content (Join-Path $state 'runtime/btc-daily-prices.json')
& (Join-Path $root 'scripts/validate-account-state.ps1')
& (Join-Path $root 'scripts/build-account-overview.ps1')
