[CmdletBinding()]
param(
    [string]$ServerPath = 'E:\Administrator\Desktop\FunCity\FunCity server\FunCity-Engine-Freeroam'
)

# Read-only post-job persistence verification; this script never starts/stops a task.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'funcity-engine-helpers.ps1')

trap {
    $failure = ($_.Exception.Message -replace '[\r\n]+', ' ').Trim()
    Write-Output "::error title=FunCity full-pack persistence verification::$failure"
    throw
}

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Test-LocalTcpPort {
    param([int]$Port)
    $client = New-Object System.Net.Sockets.TcpClient
    $async = $null
    try {
        $async = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(2000, $false)) { return $false }
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
$resolvedPath = [System.IO.Path]::GetFullPath($ServerPath)
Assert-Condition -Condition ($resolvedPath.StartsWith($allowedRoot, [System.StringComparison]::OrdinalIgnoreCase)) -Message 'Verification target must remain inside E:\Administrator\Desktop\FunCity.'
$root = Get-Item -LiteralPath $resolvedPath -ErrorAction Stop
$taskName = 'FunCity-Freeroam-Mohist-Test'
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
Assert-Condition -Condition ($null -ne $task) -Message 'The full-pack test Scheduled Task is missing.'
Assert-Condition -Condition ($task.Description -like 'Managed by FunCity Freeroam Engine;*') -Message 'The Scheduled Task ownership description does not match this engine.'
Assert-Condition -Condition ($task.State -eq 'Running') -Message "The full-pack server task is not running (state=$($task.State))."
Assert-Condition -Condition ($task.Triggers.Count -eq 0) -Message 'The test task has an unexpected logon/reboot or other automatic trigger.'

$eula = Get-Content -LiteralPath (Join-Path $root.FullName 'eula.txt') -Raw
Assert-Condition -Condition ($eula -match '(?im)^\s*eula\s*=\s*true\s*$') -Message 'EULA acceptance is not set in the test engine.'
$runtimeNote = Get-Content -LiteralPath (Join-Path $root.FullName 'runtime\JAVA-VERSION.txt') -Raw
Assert-Condition -Condition ($runtimeNote -match 'Temurin JRE 11\.0\.32\.1' -and $runtimeNote -match 'SHA-256 verified') -Message 'The test engine is not using the approved local Java runtime.'

$pidPath = Join-Path $root.FullName 'server.pid'
Assert-Condition -Condition (Test-Path -LiteralPath $pidPath -PathType Leaf) -Message 'server.pid is missing.'
$serverPid = [int](Get-Content -LiteralPath $pidPath -Raw).Trim()
$processInfo = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $serverPid" -ErrorAction SilentlyContinue
Assert-Condition -Condition ($null -ne $processInfo -and $processInfo.Name -match '^javaw?\.exe$') -Message 'The recorded full-pack Java process is not running.'
Assert-Condition -Condition ($processInfo.CommandLine -match '(?i)-Dfuncity\.instance=FunCity-Freeroam-Engine' -and $processInfo.CommandLine -match '(?i)-jar\s+server\.jar') -Message 'The recorded process is not the full Freeroam test engine.'

$properties = Get-Content -LiteralPath (Join-Path $root.FullName 'server.properties')
$portLine = $properties | Where-Object { $_ -match '^\s*server-port\s*=' } | Select-Object -First 1
$port = if ($null -eq $portLine) { 0 } else { [int](($portLine -replace '^\s*server-port\s*=\s*', '').Trim()) }
Assert-Condition -Condition ($port -eq 25566) -Message "Unexpected full-pack test port: $port"
Assert-Condition -Condition (Test-LocalTcpPort -Port $port) -Message "Full-pack server is not accepting local TCP connections on port $port."

$inventory = ConvertFrom-Json -InputObject (Get-Content -LiteralPath (Join-Path $root.FullName 'pack-mod-inventory.json') -Raw) -ErrorAction Stop
$expectedTotal = [int]$inventory.sourceModJarCount
$expectedServer = [int]$inventory.serverModJarCount
$expectedClientOnly = [int]$inventory.clientOnlyModJarCount
$voiceChatUdpPort = if ($null -ne $inventory.PSObject.Properties['voiceChatUdpPort']) { [int]$inventory.voiceChatUdpPort } else { 24455 }
$voiceChatConfigPath = Get-FunCityVoiceChatServerConfigPath -ServerRoot $root.FullName
Assert-Condition -Condition ((Get-FunCityVoiceChatUdpPort -ConfigPath $voiceChatConfigPath) -eq $voiceChatUdpPort) -Message "Simple Voice Chat is not configured for the dedicated UDP port $voiceChatUdpPort."
$voiceChatEndpoints = @(Get-FunCityLocalUdpEndpoints -Port $voiceChatUdpPort | Where-Object { [int]$_.OwningProcess -eq $serverPid })
Assert-Condition -Condition ($voiceChatEndpoints.Count -gt 0) -Message "The running FunCity server process is not listening on voice-chat UDP port $voiceChatUdpPort."
$modFiles = @(Get-ChildItem -LiteralPath (Join-Path $root.FullName 'mods') -File -Filter '*.jar' -ErrorAction Stop)
$clientFiles = @(Get-ChildItem -LiteralPath (Join-Path $root.FullName 'client-only-mods') -File -Filter '*.jar' -ErrorAction Stop)
Assert-Condition -Condition ($modFiles.Count -eq $expectedServer -and $clientFiles.Count -eq $expectedClientOnly -and $modFiles.Count + $clientFiles.Count -eq $expectedTotal -and $expectedTotal -eq @($inventory.mods).Count) -Message "Mod inventory changed: server=$($modFiles.Count)/$expectedServer; client-only=$($clientFiles.Count)/$expectedClientOnly; total=$expectedTotal."

$latestLog = Join-Path $root.FullName 'logs\latest.log'
Assert-Condition -Condition (Test-Path -LiteralPath $latestLog -PathType Leaf) -Message 'logs/latest.log is missing after the test server launch.'
$logInfo = Get-Item -LiteralPath $latestLog -ErrorAction Stop
Assert-Condition -Condition ($logInfo.Length -gt 0) -Message 'logs/latest.log is empty.'
$tail = @(Get-Content -LiteralPath $latestLog -Tail 160 -ErrorAction Stop)
$readyLine = $tail | Where-Object { $_ -match '(?i)Done \([^)]+\)!' } | Select-Object -Last 1
Assert-Condition -Condition ($null -ne $readyLine) -Message ('Server process/port are active but the log has no Done (...)! readiness marker. Tail: ' + ($tail -join ' | '))

$errors = @($tail | Where-Object { $_ -match '(?i)\b(ERROR|FATAL|Exception|NoClassDefFoundError|ClassNotFoundException|Mixin apply failed)\b' })
$errorSummary = if ($errors.Count -eq 0) { 'none in recent log tail' } else { ($errors | Select-Object -Last 8) -join ' | ' }
if ($errorSummary.Length -gt 1800) { $errorSummary = $errorSummary.Substring($errorSummary.Length - 1800) }
$summary = "Running=true; PID=$serverPid; Task=$taskName/Running/manual-only; game-TCP=$port/open-locally; voice-chat-UDP=$voiceChatUdpPort/listening; server-loaded-mods=$($modFiles.Count)/$expectedServer; client-only-preserved=$($clientFiles.Count)/$expectedClientOnly; all-pack-mods=$expectedTotal; Java=portable-Temurin-11.0.32.1; ready=$readyLine; recent-errors=$errorSummary"
Write-Output "::notice title=FunCity full-pack engine persistence check::$summary"
Write-Output $summary
