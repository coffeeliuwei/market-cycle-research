param(
    [Parameter(Mandatory)][string[]]$Terms,
    [datetimeoffset]$AsOf = [datetimeoffset]::Now,
    [ValidateRange(1,50)][int]$Limit = 5
)
$ErrorActionPreference = 'Stop'
$cards = Get-Content -Raw (Join-Path $PSScriptRoot '../knowledge/research-cases.json') | ConvertFrom-Json
$keywords = @($Terms | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object -Unique)
if (!$keywords.Count) { throw 'Supply at least one non-empty search term.' }
$matches = foreach ($card in $cards) {
    if ([datetimeoffset]$card.availableBy -gt $AsOf) { continue }
    $body = ($card.tags -join ' ') + ' ' + $card.evidence
    $hits = @($keywords | Where-Object { $body.IndexOf($_,[StringComparison]::OrdinalIgnoreCase) -ge 0 })
    if ($hits.Count) {
        [pscustomobject]@{ score=$hits.Count; id=$card.id; availableBy=$card.availableBy; terms=$hits; evidence=$card.evidence }
    }
}
$result = @($matches | Sort-Object score,availableBy -Descending | Select-Object -First $Limit)
ConvertTo-Json -InputObject $result -Depth 4
