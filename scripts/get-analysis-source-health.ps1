param(
    [string]$CryptoSnapshotPath,
    [string]$AshareSnapshotPath
)

$ErrorActionPreference = 'Stop'
if (-not $CryptoSnapshotPath -and -not $AshareSnapshotPath) { throw 'Supply at least one snapshot path.' }
$report = [ordered]@{ schemaVersion = 1 }
if ($CryptoSnapshotPath) {
    $crypto = Get-Content -LiteralPath $CryptoSnapshotPath -Raw | ConvertFrom-Json
    $report.crypto = [ordered]@{
        snapshot = (Resolve-Path -LiteralPath $CryptoSnapshotPath).Path
        capturedAt = $crypto.capturedAt
        marketComplete = $crypto.complete
        failures = @($crypto.failures | Where-Object { $_ })
        x = [ordered]@{
            assetEvidenceAvailable = [bool]($crypto.x.queries | Where-Object { $_.PSObject.Properties['matchedAssets'] })
            reason = $crypto.x.reason
            queries = @($crypto.x.queries | Where-Object { $_ } | Select-Object kind,ready,reason,provenance,degraded,capturedAt,cacheAgeMinutes,cacheSourceProvenance,itemCount,assets,matchedAssets,coveredAssets,uncoveredAssets,searchDiagnostics)
        }
        coinGlass = @($crypto.coinGlass | Where-Object { $_ } | Select-Object route,requested,ready,reason,checkedAt,provenance,cacheAgeMinutes,cacheSnapshot,dataDate)
        polymarket = $crypto.polymarket | Select-Object ready,reason,checkedAt,errors,failedEndpoints
        deferredRuleFailures = @($crypto.deferredOrderRuleCheck.failures | Where-Object { $_ })
        deferredExclusions = @($crypto.deferredOrderRuleCheck.excluded | Where-Object { $_ })
        okxSpotValuation = @($crypto.tradingViewScreener.results | Where-Object symbol -like 'OKX:*' | ForEach-Object {
            [ordered]@{
                symbol = $_.symbol
                scannerSymbol = $_.scannerSymbol
                capturedAt = $_.capturedAt
                source = 'tradingview_screener'
                status = if ($_.scannerSymbol -eq $_.symbol -and $_.symbol -notlike '*.P' -and $_.periods.D.ok -and $_.periods.D.close -gt 0) { 'exact_spot_quote' } else { 'unavailable' }
            }
        })
    }
}
if ($AshareSnapshotPath) {
    $ashare = Get-Content -LiteralPath $AshareSnapshotPath -Raw | ConvertFrom-Json
    $report.ashare = [ordered]@{
        snapshot = (Resolve-Path -LiteralPath $AshareSnapshotPath).Path
        capturedAt = $ashare.capturedAt
        marketComplete = $ashare.complete
        enrichmentComplete = $ashare.enrichmentComplete
        fundFlow = @($ashare.fundFlow | Where-Object { $_ } | Select-Object symbol,source,dataDate,publicationStatus)
        fundFlowAttempts = @($ashare.fundFlowAttempts | Where-Object { $_ } | Select-Object symbol,source,status,recoveredBy)
        enrichmentPublication = $ashare.enrichmentPublication
        failures = @($ashare.failures | Where-Object { $_ })
    }
}
$report | ConvertTo-Json -Depth 12 -Compress
