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
if (Test-Path -LiteralPath $localJava -PathType Leaf) {
    $versionNote = Join-Path $root.FullName 'runtime\JAVA-VERSION.txt'
    if (Test-Path -LiteralPath $versionNote -PathType Leaf) { $localJavaVersion = (Get-Content -LiteralPath $versionNote -TotalCount 1).Trim() }
    else { $localJavaVersion = 'local runtime files present' }
}
$stagingDirs = @(Get-ChildItem -LiteralPath $root.FullName -Directory -Force -Filter '.java-runtime-staging-*' -ErrorAction SilentlyContinue)

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
$pidFile = Join-Path $root.FullName 'server.pid'
$pidState = if (Test-Path -LiteralPath $pidFile) { (Get-Content -LiteralPath $pidFile -Raw).Trim() } else { 'none' }
$processState = 'not-started'
if ($pidState -match '^\d+$') {
    $trackedProcess = Get-Process -Id ([int]$pidState) -ErrorAction SilentlyContinue
    $processState = if ($null -ne $trackedProcess) { 'running' } else { 'exited' }
}

function Get-SafeLogLines {
    param([string]$Path, [int]$Limit = 4)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $lines = @(Get-Content -LiteralPath $Path -Tail 120 -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $important = @($lines | Where-Object { $_ -match '(?i)(ERROR|FATAL|Exception|Caused by:|Unrecognized VM option|Could not find|UnsupportedClassVersion|Done \()' } | Select-Object -Last $Limit)
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
$failureSummary = if ($failureLines.Count -gt 0) { ($failureLines -join ' | ') } else { 'no startup log details yet' }
if ($failureSummary.Length -gt 1500) { $failureSummary = $failureSummary.Substring(0, 1500) }

$summary = "EULA=$eula; Java=$javaVersion; local-Java=$localJavaVersion; java-staging=$($stagingDirs.Count); mods=$($mods.Count); plugins=$($plugins.Count); port=$port/$portState; EULA-gate=$gate; GC-profile=$tuning; PID-file=$pidState/$processState; startup=$failureSummary"
Write-Output "::notice title=FunCity Lite PC preflight::$summary"
Write-Output $summary
