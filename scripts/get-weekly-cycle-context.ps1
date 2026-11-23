param(
    [datetimeoffset]$AsOf = [datetimeoffset]::UtcNow,
    [string]$HistoryRoot = (Join-Path $PSScriptRoot '../state/cycle-weekly/v1')
)
$ErrorActionPreference = 'Stop'
# All three markets share the last Friday that has fully elapsed in UTC.
$day = $AsOf.UtcDateTime.Date.AddDays(-1)
$cut = $day.AddDays(-(([int]$day.DayOfWeek + 2) % 7))
$result = foreach ($market in 'CSI300TR','SPY','BTC') {
    try {
        $file = Join-Path $HistoryRoot "$market.csv"
        $rows = @(Import-Csv -LiteralPath $file | Where-Object { $_.week -cle $cut.ToString('yyyy-MM-dd') } | Select-Object -Last 313)
        if ($rows.Count -lt 161) { throw 'insufficient weekly history' }
        $prices = @()
        $ratios = @()
        $prev = $null
        foreach ($row in $rows) {
            $date = [datetime]::ParseExact($row.week,'yyyy-MM-dd',[cultureinfo]::InvariantCulture)
            $p = [double]$row.price
            $b = [double]$row.benchmark
            if ($date.DayOfWeek -ne 'Friday' -or ($prev -and ($date -le $prev -or ($date-$prev).Days -gt 14)) -or ![double]::IsFinite($p) -or ![double]::IsFinite($b) -or $p -le 0 -or $b -le 0) { throw 'invalid weekly history' }
            $prices += $p
            $ratios += [math]::Log($p/$b)
            $prev = $date
        }
        $n = $prices.Count - 1
        function Get-Z([int]$index) {
            $m = $ratios[($index-156)..($index-1)] | Measure-Object -Average -StandardDeviation
            if (!$m.StandardDeviation) { throw 'zero benchmark-relative variance' }
            [math]::Round(($ratios[$index]-$m.Average)/$m.StandardDeviation,3)
        }
        $year = $prices[($n-51)..$n]
        $peak = ($year | Measure-Object -Maximum).Maximum
        $rank = @($year | Where-Object { $_ -le $prices[$n] }).Count/52
        $z = Get-Z $n
        $pivots = [ordered]@{}
        foreach ($side in 'high','low') {
            for ($i=$n-4; $i -ge 156; $i--) {
                $range = $prices[($i-4)..($i+4)] | Measure-Object -Minimum -Maximum
                $extreme = if ($side -eq 'high') { $range.Maximum } else { $range.Minimum }
                if ($prices[$i] -ne $extreme) { continue }
                $priorZ = Get-Z $i
                $between = $prices[($i+1)..($n-1)] | Measure-Object -Minimum -Maximum
                $pivots[$side] = @{
                    week=$rows[$i].week; price=$prices[$i]; z=$priorZ
                    divergence=if ($side -eq 'high') { $prices[$n] -ge $extreme -and $z -lt $priorZ } else { $prices[$n] -le $extreme -and $z -gt $priorZ }
                    interveningLevel=if ($side -eq 'high') { $between.Minimum } else { $between.Maximum }
                }
                break
            }
        }
        [ordered]@{market=$market; status=if ($prev -eq $cut) {'ready'} else {'stale'}; week=$rows[-1].week; observations=$rows.Count; price=$prices[$n]; percentile52=[math]::Round(100*$rank,1); drawdown52Pct=[math]::Round(100*($prices[$n]/$peak-1),2); z=$z; zFourWeeksAgo=(Get-Z ($n-4)); pivots=$pivots}
    } catch { @{market=$market;status='unavailable';reason=$_.Exception.Message} }
}
[ordered]@{version='v1'; expectedWeek=$cut.ToString('yyyy-MM-dd'); markets=@($result)} | ConvertTo-Json -Depth 6
