param()
$ErrorActionPreference='Stop'
$root=(Resolve-Path "$PSScriptRoot/..").Path
$w=@(Import-Csv "$root/state/cycle-weekly/v1/BTC.csv")
$r=Get-Content "$root/state/runtime/btc-daily-prices.json" -Raw|ConvertFrom-Json
$d=@{}; $vals=[Collections.Generic.List[double]]::new()
for($i=0;$i -lt $r.timestamp.Count;$i++){
 if($null -eq $r.indicators.quote[0].close[$i]){continue}
 $date=[DateTimeOffset]::FromUnixTimeSeconds($r.timestamp[$i]).UtcDateTime
 $p=[double]$r.indicators.quote[0].close[$i];$vals.Add($p)
 if($vals.Count -lt 350){continue}
 $n=$vals.Count;$s111=0.;$s350=0.;$log200=0.
 for($j=1;$j -le 350;$j++){$x=$vals[$n-$j];$s350+=$x;if($j -le 111){$s111+=$x};if($j -le 200){$log200+=[math]::Log($x)}}
 $age=($date.Date-[datetime]'2009-01-03').Days
 $d[$date.ToString('yyyy-MM-dd')]=@(($p/$([math]::Exp($log200/200))*$p/[math]::Pow(10,5.84*[math]::Log10($age)-17.01)),(($s111/111)/(2*$s350/350)))
}
$rat=@($w|ForEach-Object {[math]::Log([double]$_.price/[double]$_.benchmark)})
$rows=@();$side='';$episode=$null
for($i=156;$i -lt $w.Count;$i++){
 $hist=$rat[($i-156)..($i-1)];$mean=($hist|Measure-Object -Average).Average;$ss=0.;foreach($x in $hist){$ss+=($x-$mean)*($x-$mean)}
 $z=($rat[$i]-$mean)/[math]::Sqrt($ss/155)
 $s=if($z -le 0.3){'low'}elseif($z -ge 2.2){'high'}else{''}
 if($s -ne $side -and $s){$episode=[pscustomobject]@{side=$s;start=$i;confirm=-1};$rows+=$episode}
 $side=$s
 if($s -and $episode.confirm -lt 0){$ind=$d[$w[$i].week];if(!$ind){throw 'missing date'};if(($s -eq 'low' -and $ind[0] -lt .45) -or ($s -eq 'high' -and $ind[1] -ge 1)){$episode.confirm=$i}}
}
$out=foreach($e in $rows){$a=$e.start+1;$c=$e.confirm+1
 $row=[ordered]@{side=$e.side;signal=$w[$e.start].week;confirmation=if($c){$w[$c-1].week}else{'none'}}
 foreach($h in 13,52){$b=$a+$h;$delta=$null
 if($b -lt $w.Count){$k=if($c -gt 0){[math]::Min($c,$b)}else{$b}
 $btc=[double]$w[$k].price/[double]$w[$a].price;$cash=[double]$w[$k].benchmark/[double]$w[$a].benchmark
 $multiple=if($e.side -eq 'low'){$cash/$btc}else{$btc/$cash}
 $delta=[math]::Round(100*($multiple-1),2)}
 $row["relative_${h}w_pct"]=$delta}
 [pscustomobject]$row}
$out|Export-Csv "$root/state/runtime/btc-paired.csv" -NoTypeInformation
$out|Format-Table


