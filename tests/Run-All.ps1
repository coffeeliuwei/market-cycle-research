$ErrorActionPreference = 'Stop'

$tests = Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' |
    Sort-Object Name

$passed = 0
$failures = [System.Collections.Generic.List[string]]::new()
foreach ($test in $tests) {
    try {
        & $test.FullName | Out-Host
        $passed += 1
    }
    catch {
        $failures.Add("FAILED $($test.Name): $($_.Exception.Message)")
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    throw "$($failures.Count) test file(s) failed; $passed passed."
}

"PASS test-files=$passed"
