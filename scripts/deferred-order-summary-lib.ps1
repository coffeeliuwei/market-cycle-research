function Get-CompactDeferredOrderView {
    param(
        [object]$RuleCheck,
        [object[]]$Alerts
    )

    $allAlerts = @($Alerts)
    $levels = [ordered]@{
        current_executable = 0
        prepare = 0
        waiting = 0
        blocked = 0
        unavailable = 0
    }
    foreach ($alert in $allAlerts) {
        $level = [string]$alert.alertLevel
        if ($levels.Contains($level)) { $levels[$level]++ }
        elseif (-not [string]::IsNullOrWhiteSpace($level)) { $levels[$level] = 1 }
    }

    $actionable = @($allAlerts | Where-Object { $_.alertLevel -eq 'current_executable' } | ForEach-Object {
        $item = [ordered]@{}
        foreach ($name in @('accountId','recordId','market','symbol','side','type','price','quantity','quoteAmount','checkedAt','currentExecutable','alertLevel','ruleCheckStatus','source')) {
            $property = $_.PSObject.Properties[$name]
            if ($null -ne $property -and $null -ne $property.Value) { $item[$name] = $property.Value }
        }
        [pscustomobject]$item
    })

    $compactCheck = [ordered]@{}
    foreach ($name in @('schemaVersion','checkedAt','deferredOrdersCount','checkedCount','complete')) {
        $property = if ($null -ne $RuleCheck) { $RuleCheck.PSObject.Properties[$name] } else { $null }
        if ($null -ne $property -and $null -ne $property.Value) { $compactCheck[$name] = $property.Value }
    }
    $compactCheck['failures'] = @($RuleCheck.failures | ForEach-Object {
        [pscustomobject][ordered]@{ accountId=$_.accountId; symbol=$_.symbol; reason=$_.reason }
    })
    $compactCheck['excludedCount'] = @($RuleCheck.excluded | Where-Object { $_ }).Count

    [pscustomobject][ordered]@{
        ruleCheck = [pscustomobject]$compactCheck
        summary = [pscustomobject][ordered]@{
            total = $allAlerts.Count
            byLevel = [pscustomobject]$levels
            detailsReturned = $actionable.Count
            omittedDetails = $allAlerts.Count - $actionable.Count
        }
        actionableAlerts = $actionable
    }
}
