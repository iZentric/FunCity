[CmdletBinding()]
param(
    [string]$ServerPath = 'E:\Administrator\Desktop\FunCity\FunCity server\FunCity-Lite'
)

# Read-only local preflight; it does not edit EULA, launch Java, or touch files
# outside the specified FunCity project folder.
$ErrorActionPreference = 'Stop'

trap {
    $failure = ($_.Exception.Message -replace '[\r\n]+', ' ').Trim()
    Write-Output "::error title=FunCity Lite startup diagnosis::$failure"
    throw
}

function Test-LocalTcpPort {
    param([int]$Port)
    $client = New-Object System.Net.Sockets.TcpClient
    $async = $null
    try {
        $async = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(1000, $false)) { return $false }
        $client.EndConnect($async)
        return $true
    }
    catch { return $false }
    finally {
        if ($null -ne $async) { $async.AsyncWaitHandle.Close() }
        $client.Close()
    }
}

$allowedRoot = [System.IO.Path]::GetFullPath('E:\Administrator\Desktop\FunCity') + [System.IO.Path]::DirectorySeparatorChar
$resolved = [System.IO.Path]::GetFullPath($ServerPath)
if (-not $resolved.StartsWith($allowedRoot, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Diagnostic path must remain inside E:\Administrator\Desktop\FunCity.' }
$root = Get-Item -LiteralPath $resolved -ErrorAction Stop
$eulaText = Get-Content -LiteralPath (Join-Path $root.FullName 'eula.txt') -Raw
$eula = if ($eulaText -match '(?im)^\s*eula\s*=\s*true\s*$') { 'true' } elseif ($eulaText -match '(?im)^\s*eula\s*=\s*false\s*$') { 'false' } else { 'unknown' }

$javaCommand = Get-Command -Name java -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$javaVersion = if ($null -ne $javaCommand) { 'system Java found on PATH' } else { 'not found on PATH' }
$localJava = Join-Path $root.FullName 'runtime\bin\java.exe'
$localJavaVersion = 'not installed'
$localJavaCompatibility = 'not verified'
if (Test-Path -LiteralPath $localJava -PathType Leaf) {
    $versionNote = Join-Path $root.FullName 'runtime\JAVA-VERSION.txt'
    if (Test-Path -LiteralPath $versionNote -PathType Leaf) {
        $localJavaNote = Get-Content -LiteralPath $versionNote -Raw
        $localJavaVersion = ($localJavaNote -split "`r?`n" | Select-Object -First 1).Trim()
        $localJavaCompatibility = if ($localJavaNote -match 'Temurin JRE 11\.0\.32\.1' -and $localJavaNote -match 'SHA-256 verified') { 'verified for this Mohist build' } else { 'wrong or unverified version' }
    }
    else { $localJavaVersion = 'local runtime files present' }
}
$stagingDirs = @(Get-ChildItem -LiteralPath $root.FullName -Directory -Force -Filter '.java*-runtime-staging-*' -ErrorAction SilentlyContinue)
$taskCmdlet = Get-Command -Name Get-ScheduledTask -ErrorAction SilentlyContinue | Select-Object -First 1
$runnerIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$taskSupport = if ($null -eq $taskCmdlet) { 'cmdlets-unavailable' } elseif ($runnerIdentity.User.Value -eq 'S-1-5-18') { 'runner-is-system' } else { 'user-scoped-ready' }
$managedTaskState = 'none'
$taskDefinitionSupport = 'not-tested'
if ($null -ne $taskCmdlet) {
    $managedTask = Get-ScheduledTask -TaskName 'FunCity-Lite-Mohist-Server' -ErrorAction SilentlyContinue
    if ($null -ne $managedTask) { $managedTaskState = [string]$managedTask.State }
}
if ($taskSupport -eq 'user-scoped-ready') {
    try {
        $probeAction = New-ScheduledTaskAction -Execute (Join-Path $env:WINDIR 'System32\cmd.exe') -Argument '/c exit 0' -WorkingDirectory $root.FullName
        $probePrincipal = New-ScheduledTaskPrincipal -UserId $runnerIdentity.Name -LogonType S4U -RunLevel Limited
        $probeSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Days 3650) -MultipleInstances IgnoreNew
        $null = New-ScheduledTask -Action $probeAction -Principal $probePrincipal -Settings $probeSettings -Description 'Unregistered FunCity Lite compatibility probe.'
        $taskDefinitionSupport = 'S4U-definition-ready'
    }
    catch { $taskDefinitionSupport = 'S4U-definition-failed' }
}

$mods = @(Get-ChildItem -LiteralPath (Join-Path $root.FullName 'mods') -File -Filter '*.jar' -ErrorAction SilentlyContinue)
$plugins = @(Get-ChildItem -LiteralPath (Join-Path $root.FullName 'plugins') -File -Filter '*.jar' -ErrorAction SilentlyContinue)
$properties = Get-Content -LiteralPath (Join-Path $root.FullName 'server.properties')
$portLine = $properties | Where-Object { $_ -match '^\s*server-port\s*=' } | Select-Object -First 1
$port = if ($null -eq $portLine) { 25565 } else { [int](($portLine -replace '^\s*server-port\s*=\s*', '').Trim()) }
$portState = if (Test-LocalTcpPort -Port $port) { 'open' } else { 'closed' }
$startText = [System.IO.File]::ReadAllText((Join-Path $root.FullName 'start.bat'))
$gate = if ($startText -match '(?im)^findstr /i /x /c:"eula=true" eula\.txt >nul\s*$') { 'valid' } else { 'missing' }
$javaLine = @($startText -split "`r?`n" | Where-Object { $_ -match '^\s*(?:java|"%JAVA_EXE%")\s+-Xms' })
$tuning = if ($javaLine.Count -eq 1 -and $javaLine[0] -match 'G1NewSizePercent=30.*G1MaxNewSizePercent=40.*G1RSetUpdatingPauseTimePercent=5') { 'tuned' } else { 'baseline-or-unknown' }
$localJavaLauncher = $startText -match '(?im)^set "JAVA_EXE=%~dp0runtime\\bin\\java\.exe"\s*$'
$systemJavaFallback = $startText -match '(?im)^\s*where java >nul 2>&1\s*$' -or $startText -match '(?im)^\s*set "JAVA_EXE=java"\s*$'
$javaLauncherPolicy = if ($localJavaLauncher -and -not $systemJavaFallback) { 'portable-only' } else { 'fallback-or-unknown' }
$pidFile = Join-Path $root.FullName 'server.pid'
$pidState = if (Test-Path -LiteralPath $pidFile) { (Get-Content -LiteralPath $pidFile -Raw).Trim() } else { 'none' }
$processState = 'not-started'
$processIdentity = 'none'
if ($pidState -match '^\d+$') {
    $trackedProcess = Get-Process -Id ([int]$pidState) -ErrorAction SilentlyContinue
    $processState = if ($null -ne $trackedProcess) { 'running' } else { 'exited' }
    if ($null -ne $trackedProcess) {
        $processIdentity = $trackedProcess.ProcessName
        $cimProcess = Get-CimInstance Win32_Process -Filter "ProcessId = $pidState" -ErrorAction SilentlyContinue
        if ($null -ne $cimProcess) {
            $isFunCityProcess = $cimProcess.CommandLine -match '(?i)-Dfuncity\.instance=FunCity-Lite' -and $cimProcess.CommandLine -match '(?i)-jar\s+server\.jar'
            $processIdentity = "$($cimProcess.Name)/FunCity=$isFunCityProcess"
        }
    }
}
$startupState = if ($processState -eq 'running' -and $portState -eq 'open') { 'process-alive+port-open' } elseif ($processState -eq 'running') { 'process-alive+port-closed' } elseif ($portState -eq 'open') { 'port-open-without-tracked-process' } else { 'stopped' }

function Get-SafeLogLines {
    param([string]$Path, [int]$Limit = 4, [switch]$TailOnly)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $lines = @(Get-Content -LiteralPath $Path -Tail 500 -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($TailOnly) { $important = @($lines | Select-Object -Last $Limit) }
    else { $important = @($lines | Where-Object { $_ -match '(?i)(ERROR|FATAL|Exception|Caused by:|Unrecognized VM option|Could not find|UnsupportedClassVersion|Done \()' } | Select-Object -Last $Limit) }
    if ($important.Count -eq 0) { $important = @($lines | Select-Object -Last $Limit) }
    return @($important | ForEach-Object {
        $safe = [string]$_
        $safe = $safe -replace '(?i)E:\\Administrator\\Desktop\\FunCity[^\s]*', '<FunCity-path>'
        $safe = $safe -replace '[A-Z]:\\[^\s"'']+', '<path>'
        $safe = $safe -replace '\b(?:\d{1,3}\.){3}\d{1,3}\b', '<ip>'
        $safe = $safe -replace '[\r\n]+', ' '
        if ($safe.Length -gt 240) { $safe = $safe.Substring(0, 240) }
        $safe
    })
}

$logsPath = Join-Path $root.FullName 'logs'
$latestLog = Join-Path $logsPath 'latest.log'
$stdoutFiles = @(Get-ChildItem -LiteralPath $logsPath -File -Filter 'funcity-console-*.out.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
$stderrFiles = @(Get-ChildItem -LiteralPath $logsPath -File -Filter 'funcity-console-*.err.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
$failureLines = @()
if ($stderrFiles.Count -gt 0) { $failureLines += Get-SafeLogLines -Path $stderrFiles[0].FullName -Limit 3 }
if (Test-Path -LiteralPath $latestLog -PathType Leaf) { $failureLines += Get-SafeLogLines -Path $latestLog -Limit 5 }
if ($failureLines.Count -eq 0 -and $stdoutFiles.Count -gt 0) { $failureLines += Get-SafeLogLines -Path $stdoutFiles[0].FullName -Limit 3 }
$failureSummary = if ($failureLines.Count -gt 0) { ($failureLines -join ' | ') } else { 'no error details found' }
$latestTailLines = @(Get-SafeLogLines -Path $latestLog -Limit 7 -TailOnly)
$latestTail = if ($latestTailLines.Count -gt 0) { ($latestTailLines -join ' | ') } else { 'latest log unavailable or empty' }
$startupSummary = "signals=$failureSummary; latest-tail=$latestTail"
if ($startupSummary.Length -gt 2400) { $startupSummary = $startupSummary.Substring(0, 2400) }

$summary = "EULA=$eula; Java=$javaVersion; local-Java=$localJavaVersion ($localJavaCompatibility); java-staging=$($stagingDirs.Count); TaskScheduler=$taskSupport/$managedTaskState/$taskDefinitionSupport; mods=$($mods.Count); plugins=$($plugins.Count); port=$port/$portState; EULA-gate=$gate; Java-launcher=$javaLauncherPolicy; GC-profile=$tuning; PID-file=$pidState/$processState ($processIdentity); startup-state=$startupState; startup=$startupSummary"
Write-Output "::notice title=FunCity Lite PC preflight::$summary"
Write-Output "::notice title=FunCity Lite task scheduler preflight::TaskScheduler=$taskSupport; managed-task=$managedTaskState; task-definition=$taskDefinitionSupport"
Write-Output $summary
