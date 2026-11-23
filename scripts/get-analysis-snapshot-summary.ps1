param([Parameter(Mandatory)][string]$SnapshotPath,[string[]]$Symbols,[string[]]$IncludeSources,[int]$MaxChars=0)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
if($MaxChars-le 0){$MaxChars=[int](Get-Content -Raw (Join-Path $root 'config\analysis-budget.json')|ConvertFrom-Json).snapshotSummaryMaxChars}
$resolved=[IO.Path]::GetFullPath($SnapshotPath)
$s=Get-Content -Raw -LiteralPath $resolved|ConvertFrom-Json
. (Join-Path $root 'scripts\deferred-order-summary-lib.ps1')
function Select-PeriodFields([object]$Period,[string[]]$Names){$out=[ordered]@{};if(-not $Period){return $out};foreach($name in $Names){$property=$Period.PSObject.Properties[$name];if($null-ne$property-and$null-ne$property.Value){$out[$name]=$property.Value}};return $out}
$deepBySymbol=@{}; foreach($item in @($s.tradingView.results)){$deepBySymbol[[string]$item.symbol]=$item}
$fastBySymbol=@{}; foreach($item in @($s.tradingViewScreener.results)){$fastBySymbol[[string]$item.symbol]=$item}
$summarySymbols=if($s.symbolsRequested){@($s.symbolsRequested)}else{@($deepBySymbol.Keys)}
$periodFields=if($Symbols){@('ok','count','time','open','high','low','close','changePct','volume','recommendation','rsi','macd','macdSignal','ema20','ema50','ema200','atr','last4','last12','error')}else{@('ok','close','changePct','recommendation','rsi','ema20','ema50','ema200','error')}
$items=@($summarySymbols|Where-Object{-not $Symbols -or $_ -in $Symbols}|ForEach-Object{
  $symbol=[string]$_;$deep=$deepBySymbol[$symbol];$fast=$fastBySymbol[$symbol];$chosen=if($deep){$deep}else{$fast}
  $periods=[ordered]@{}
  $periodNames=@(@($fast.periods.PSObject.Properties.Name)+@($deep.periods.PSObject.Properties.Name)|Where-Object{$_}|Sort-Object -Unique)
  foreach($name in $periodNames){
    $merged=[ordered]@{}
    foreach($sourcePeriod in @($fast.periods.$name,$deep.periods.$name)){
      $selected=Select-PeriodFields $sourcePeriod $periodFields
      foreach($key in $selected.Keys){$merged[$key]=$selected[$key]}
    }
    $periods[$name]=$merged
  }
  $item=[ordered]@{symbol=$symbol;coverage=if($deep){'deep_ohlcv'}elseif($fast){'screener'}else{'missing'};periods=$periods}
  if($fast.scannerSymbol -and ($symbol -like 'OKX:*' -or $fast.scannerSymbol -ne $symbol)){$item.scannerSymbol=$fast.scannerSymbol}
  if(-not $chosen){$item.error='missing_symbol_result'}elseif($chosen.error){$item.error=$chosen.error}
  $item
})
$slow=[ordered]@{}
if(-not $IncludeSources -or 'coinGlass' -in $IncludeSources){$slow.coinGlass=@($s.coinGlass|ForEach-Object{[ordered]@{requested=$_.requested;checkedAt=$_.checkedAt;ready=$_.ready;reason=$_.reason;label=$_.label;provenance=$_.provenance;cacheAgeMinutes=$_.cacheAgeMinutes;cacheSnapshot=$_.cacheSnapshot;dataDate=$_.dataDate;value=$_.value}})}
if(-not $IncludeSources -or 'x' -in $IncludeSources){$slow.x=[ordered]@{ready=$s.x.ready;reason=$s.x.reason;provenance=$s.x.provenance;degraded=$s.x.degraded;checkedAt=$s.x.checkedAt;queryCount=@($s.x.queries).Count;readyQueryCount=@($s.x.queries|Where-Object ready).Count;coveredAssets=@($s.x.coveredAssets);uncoveredAssets=@($s.x.uncoveredAssets)}}
if(-not $IncludeSources -or 'binanceSquare' -in $IncludeSources){$slow.binanceSquare=[ordered]@{status='agent_enrichment_required';marketOverview=$s.socialIntelligence.binanceSquare.marketOverview;hotCoin=$s.socialIntelligence.binanceSquare.hotCoin;deepAssets=@($s.socialIntelligence.binanceSquare.deepAssets);required=$s.socialIntelligence.binanceSquare.required}}
if(-not $IncludeSources -or 'polymarket' -in $IncludeSources){$slow.polymarket=[ordered]@{ready=$s.polymarket.ready;reason=$s.polymarket.reason;checkedAt=$s.polymarket.checkedAt}}
$deferred=Get-CompactDeferredOrderView -RuleCheck $s.deferredOrderRuleCheck -Alerts @($s.deferredOrderAlerts)
$r=[ordered]@{schemaVersion=2;snapshotPath=$resolved;capturedAt=$s.capturedAt;complete=$s.complete;scope=[ordered]@{symbolsRequested=@($s.symbolsRequested);requiredTimeframes=@($s.requiredTimeframes);deepSymbols=@($s.tradingViewDeepScope.symbols);deepReasons=$s.tradingViewDeepScope.reasons};failures=@($s.failures);symbols=$items;slowSources=$slow;deferredOrderRuleCheck=$deferred.ruleCheck;deferredOrderAlertSummary=$deferred.summary;deferredOrderAlerts=@($deferred.actionableAlerts);truncated=$false;omitted=[ordered]@{}}
$json=$r|ConvertTo-Json -Depth 12 -Compress
if($json.Length-gt$MaxChars){$r.slowSources=[ordered]@{};$r.truncated=$true;$r.omitted.slowSources=$true;$json=$r|ConvertTo-Json -Depth 12 -Compress}
if($json.Length-gt$MaxChars){throw "Essential snapshot summary exceeds MaxChars=$MaxChars."}
$r.outputChars=$json.Length
$r|ConvertTo-Json -Depth 12 -Compress
