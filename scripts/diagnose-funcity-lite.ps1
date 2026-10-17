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
$javaVersion = 'not found on PATH'
if ($null -ne $javaCommand) {
    $javaPath = $javaCommand.Source
    if ([string]::IsNullOrWhiteSpace($javaPath)) { $javaPath = $javaCommand.Path }
    $versionOutput = @(& $javaPath -version 2>&1)
    if ($versionOutput.Count -gt 0) { $javaVersion = (($versionOutput[0].ToString()) -replace '[\r\n]+', ' ').Trim() }
}
$localJava = Join-Path $root.FullName 'runtime\bin\java.exe'
$localJavaVersion = 'not installed'
if (Test-Path -LiteralPath $localJava -PathType Leaf) {
    $localVersionOutput = @(& $localJava -version 2>&1)
    if ($localVersionOutput.Count -gt 0) { $localJavaVersion = (($localVersionOutput[0].ToString()) -replace '[\r\n]+', ' ').Trim() }
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
$javaLine = @($startText -split "`r?`n" | Where-Object { $_ -match '^\s*java\s+-Xms' })
$tuning = if ($javaLine.Count -eq 1 -and $javaLine[0] -match 'G1NewSizePercent=30.*G1MaxNewSizePercent=40.*G1RSetUpdatingPauseTimePercent=5') { 'tuned' } else { 'baseline-or-unknown' }
$pidFile = Join-Path $root.FullName 'server.pid'
$pidState = if (Test-Path -LiteralPath $pidFile) { (Get-Content -LiteralPath $pidFile -Raw).Trim() } else { 'none' }

$summary = "EULA=$eula; Java=$javaVersion; local-Java=$localJavaVersion; java-staging=$($stagingDirs.Count); mods=$($mods.Count); plugins=$($plugins.Count); port=$port/$portState; EULA-gate=$gate; GC-profile=$tuning; PID-file=$pidState"
Write-Output "::notice title=FunCity Lite PC preflight::$summary"
Write-Output $summary
