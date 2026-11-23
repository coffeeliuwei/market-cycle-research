function Get-TradingViewCdpRecoveryAction {
    [CmdletBinding()]
    param(
        [object[]]$Processes,
        [int]$Port = 9222
    )

    $mainProcesses = @($Processes | Where-Object {
        $commandLine = [string]$_.CommandLine
        $commandLine -and $commandLine -notmatch '(?i)(?:^|\s)--type='
    })
    if ($mainProcesses.Count -eq 0) {
        return [pscustomobject]@{ Action = 'launch'; ProcessIds = @() }
    }

    $escapedPort = [regex]::Escape([string]$Port)
    $cdpProcesses = @($mainProcesses | Where-Object {
        ([string]$_.CommandLine) -match "(?i)(?:^|\s)--remote-debugging-port(?:=|\s+)$escapedPort(?:\s|$)"
    })
    if ($cdpProcesses.Count -gt 0) {
        return [pscustomobject]@{
            Action = 'wait'
            ProcessIds = @($cdpProcesses | ForEach-Object { [int]$_.ProcessId })
        }
    }

    [pscustomobject]@{
        Action = 'restart'
        ProcessIds = @($mainProcesses | ForEach-Object { [int]$_.ProcessId })
    }
}
