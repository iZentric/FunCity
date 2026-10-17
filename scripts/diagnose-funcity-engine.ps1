[CmdletBinding()]
param(
    [string]$ServerPath = 'E:\Administrator\Desktop\FunCity\FunCity server\FunCity-Engine-Freeroam'
)

# Read-only diagnosis of the full-pack start failure. It never starts/stops tasks,
# edits the output, or reads beyond the requested engine folder.
$ErrorActionPreference = 'Stop'

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
if (-not $resolved.StartsWith($allowedRoot, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Diagnostic target must remain inside E:\Administrator\Desktop\FunCity.' }
$root = Get-Item -LiteralPath $resolved -ErrorAction Stop
$inventory = ConvertFrom-Json -InputObject (Get-Content -LiteralPath (Join-Path $root.FullName 'pack-mod-inventory.json') -Raw) -ErrorAction Stop
$mods = @(Get-ChildItem -LiteralPath (Join-Path $root.FullName 'mods') -File -Filter '*.jar' -ErrorAction SilentlyContinue)
$taskName = 'FunCity-Freeroam-Mohist-Test'
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$pidPath = Join-Path $root.FullName 'server.pid'
$pidValue = if (Test-Path -LiteralPath $pidPath -PathType Leaf) { (Get-Content -LiteralPath $pidPath -Raw).Trim() } else { 'none' }
$processSummary = 'not found'
if ($pidValue -match '^\d+$') {
    $process = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $pidValue" -ErrorAction SilentlyContinue
    if ($null -ne $process) { $processSummary = "$($process.Name)/$($process.ProcessId)" }
}
$properties = Get-Content -LiteralPath (Join-Path $root.FullName 'server.properties')
$portLine = $properties | Where-Object { $_ -match '^\s*server-port\s*=' } | Select-Object -First 1
$port = if ($null -eq $portLine) { 25566 } else { [int](($portLine -replace '^\s*server-port\s*=\s*', '').Trim()) }
$portState = if (Test-LocalTcpPort -Port $port) { 'open' } else { 'closed' }

$interesting = [System.Collections.Generic.List[string]]::new()
$latest = Join-Path $root.FullName 'logs\latest.log'
if (Test-Path -LiteralPath $latest -PathType Leaf) {
    $logLines = @(Get-Content -LiteralPath $latest -Tail 600 -ErrorAction SilentlyContinue)
    foreach ($line in $logLines) {
        if ($line -match '(?i)(FATAL|ERROR|Exception|Caused by:|NoClassDefFoundError|ClassNotFoundException|wrong side|invalid dist|client class|failed to load|modloadingexception|mixin apply failed|crash report)') {
            $interesting.Add('latest.log: ' + $line.Trim())
        }
    }
    foreach ($line in ($logLines | Select-Object -Last 35)) { $interesting.Add('tail: ' + $line.Trim()) }
}
$crashDirectory = Join-Path $root.FullName 'crash-reports'
$crashName = 'none'
if (Test-Path -LiteralPath $crashDirectory -PathType Container) {
    $crash = Get-ChildItem -LiteralPath $crashDirectory -File -Filter '*.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -ne $crash) {
        $crashName = $crash.Name
        $crashLines = @(Get-Content -LiteralPath $crash.FullName -ErrorAction SilentlyContinue)
        foreach ($line in $crashLines) {
            if ($line -match '(?i)(Description:|Failure message:|Mod File:|Exception|Caused by:|NoClassDefFoundError|ClassNotFoundException|wrong side|invalid dist|client class|Suspected Mods:|Mod List:)') {
                $interesting.Add('crash-report: ' + $line.Trim())
            }
        }
        foreach ($line in ($crashLines | Select-Object -Last 45)) { $interesting.Add('crash-tail: ' + $line.Trim()) }
    }
}
$uniqueLines = @($interesting | Select-Object -Unique)
$details = $uniqueLines -join ' | '
if ($details.Length -gt 9000) { $details = $details.Substring(0, 9000) }
$eula = Get-Content -LiteralPath (Join-Path $root.FullName 'eula.txt') -Raw
$logTimestamp = if (Test-Path -LiteralPath $latest -PathType Leaf) { (Get-Item -LiteralPath $latest).LastWriteTime.ToString('s') } else { 'missing' }
$summary = "Task=$($task.State); PID-file=$pidValue; process=$processSummary; port=$port/$portState; mods=$($mods.Count)/$($inventory.sourceModJarCount); EULA=$([bool]($eula -match '(?im)^\s*eula\s*=\s*true\s*$')); latest-log-time=$logTimestamp; crash-report=$crashName; diagnostics=$details"
Write-Output "::notice title=FunCity Freeroam startup diagnosis::$summary"
Write-Output $summary
