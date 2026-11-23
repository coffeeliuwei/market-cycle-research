param(
    [int]$Port = 9222,
    [int]$StartupTimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
$mutexName = 'Local\CodexTradingViewCdp9222'
$mutex = [System.Threading.Mutex]::new($false, $mutexName)
$acquired = $false
$libraryPath = Join-Path $PSScriptRoot 'tradingview-cdp-lib.ps1'
. $libraryPath

function Test-TradingViewCdp {
    param([int]$CdpPort)
    try {
        $version = Invoke-RestMethod -Uri "http://127.0.0.1:$CdpPort/json/version" -TimeoutSec 2
        return [bool]$version.webSocketDebuggerUrl
    }
    catch {
        return $false
    }
}

function Resolve-TradingViewExecutable {
    $running = Get-CimInstance Win32_Process -Filter "Name='TradingView.exe'" |
        Where-Object { $_.ExecutablePath } |
        Select-Object -First 1
    if ($running -and (Test-Path -LiteralPath $running.ExecutablePath)) {
        return $running.ExecutablePath
    }

    $package = Get-AppxPackage -Name 'TradingView.Desktop' -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($package) {
        $candidate = Join-Path $package.InstallLocation 'TradingView.exe'
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw 'TradingView Desktop executable was not found.'
}

function Get-TradingViewProcesses {
    @(Get-CimInstance Win32_Process -Filter "Name='TradingView.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath })
}

function Stop-TradingViewMainProcesses {
    param([int[]]$ProcessIds)

    foreach ($processId in @($ProcessIds)) {
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if (-not $process) { continue }
        try { $null = $process.CloseMainWindow() } catch { }
    }

    $graceDeadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $remaining = @($ProcessIds | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
        if ($remaining.Count -eq 0) { return }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $graceDeadline)

    foreach ($processId in $remaining) {
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
    }
}

try {
    $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(35))
    if (-not $acquired) {
        throw 'Timed out waiting for the TradingView CDP startup mutex.'
    }
    if (Test-TradingViewCdp -CdpPort $Port) {
        exit 0
    }

    $executable = Resolve-TradingViewExecutable
    $recovery = Get-TradingViewCdpRecoveryAction -Processes (Get-TradingViewProcesses) -Port $Port
    if ($recovery.Action -eq 'restart') {
        Stop-TradingViewMainProcesses -ProcessIds @($recovery.ProcessIds)
        Start-Sleep -Milliseconds 500
    }
    $logDirectory = Join-Path $env:LOCALAPPDATA 'TradingView\CodexLogs'
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    $stdoutLog = Join-Path $logDirectory 'tradingview-cdp-stdout.log'
    $stderrLog = Join-Path $logDirectory 'tradingview-cdp-stderr.log'

    # Electron must not inherit Codex's short-lived stdout/stderr pipes. If it
    # does, a later console.debug write terminates TradingView with EPIPE.
    $process = $null
    if ($recovery.Action -ne 'wait') {
        # ELECTRON_RUN_AS_NODE is exported by some agent hosts so their own
        # bundled Electron CLIs behave like Node. When it leaks into this
        # launch, TradingView runs as a plain Node process: there is no
        # browser, no CDP endpoint, and Node's option parser rejects
        # --remote-debugging-port with "bad option". Drop it for the child.
        if ($env:ELECTRON_RUN_AS_NODE) { Remove-Item env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue }
        # A separate GPU process can die with an access violation in a
        # sandboxed or remote session, which takes the whole app down with
        # "GPU process isn't usable. Goodbye." Running GPU in-process keeps
        # the browser alive long enough to serve CDP.
        $debugPortArg = '--remote-debugging-port=' + $Port
        $process = Start-Process -FilePath $executable `
            -ArgumentList $debugPortArg, '--remote-debugging-address=127.0.0.1', '--in-process-gpu' `
            -RedirectStandardOutput $stdoutLog `
            -RedirectStandardError $stderrLog `
            -WindowStyle Hidden `
            -PassThru
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($StartupTimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-TradingViewCdp -CdpPort $Port) {
            exit 0
        }
        Start-Sleep -Milliseconds 500
    }
    $details = if (Test-Path -LiteralPath $stderrLog) {
        (Get-Content -LiteralPath $stderrLog -Tail 20 -ErrorAction SilentlyContinue) -join "`n"
    }
    else { '' }
    throw "TradingView CDP did not become ready on port $Port within $StartupTimeoutSeconds seconds. $details"
}
finally {
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
