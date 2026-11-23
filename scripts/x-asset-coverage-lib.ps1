function Get-XMatchedAssets {
    param([string[]]$Assets, [object[]]$Items)

    foreach ($asset in $Assets) {
        if ([string]::IsNullOrWhiteSpace($asset)) { continue }
        $terms = switch ($asset) {
            'BTC' { 'BTC'; 'Bitcoin' }
            'ALGO' { 'ALGO'; 'Algorand' }
            default { $asset }
        }
        $alternatives = ($terms | ForEach-Object { [regex]::Escape($_) }) -join '|'
        $pattern = "(?i)(?<![A-Z0-9_])(?:$alternatives)(?![A-Z0-9_])"
        if ($Items | Where-Object { ([string]$_.text) -match $pattern } | Select-Object -First 1) { $asset }
    }
}
