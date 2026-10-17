[CmdletBinding()]
param(
    [string]$ServerPath = 'E:\Administrator\Desktop\FunCity\FunCity server\FunCity-Engine-Freeroam'
)

# Starts the separate full-pack test instance with the accepted EULA. The
# existing FunCity-Lite instance remains untouched and uses port 25565.
$ErrorActionPreference = 'Stop'
$root = $null

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
        if (-not $async.AsyncWaitHandle.WaitOne(1500, $false)) { return $false }
        $client.EndConnect($async)
        return $true
    }
    catch { return $false }
    finally {
        if ($null -ne $async) { $async.AsyncWaitHandle.Close() }
        $client.Close()
    }
}

function Get-FunCityEngineProcess {
    param([string]$ServerRoot)
    $resolvedRoot = [System.IO.Path]::GetFullPath($ServerRoot)
    $rootPattern = [regex]::Escape($resolvedRoot)
    $localJavaPath = [System.IO.Path]::GetFullPath((Join-Path $resolvedRoot 'runtime\bin')) + [System.IO.Path]::DirectorySeparatorChar
    $matches = @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $localExecutable = ($null -ne $_.ExecutablePath -and $_.ExecutablePath.StartsWith($localJavaPath, [System.StringComparison]::OrdinalIgnoreCase))
        $localCommand = ($null -ne $_.CommandLine -and $_.CommandLine -match $rootPattern)
        $_.Name -match '^javaw?\.exe$' -and ($localExecutable -or $localCommand) -and
        $_.CommandLine -match '(?i)-Dfuncity\.instance=FunCity-Freeroam-Engine' -and
        $_.CommandLine -match '(?i)-jar\s+server\.jar'
    } | Sort-Object CreationDate -Descending)
    if ($matches.Count -gt 0) { return $matches[0] }
    return $null
}

function Get-RecentStartupLog {
    param([string]$ServerRoot)
    $latest = Join-Path $ServerRoot 'logs\latest.log'
    $lines = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $latest -PathType Leaf) {
        try {
            foreach ($line in @(Get-Content -LiteralPath $latest -Tail 35 -ErrorAction Stop)) { $lines.Add($line) }
        }
        catch { $lines.Add('latest.log exists but could not be read while the process was active.') }
    }
    $crashDirectory = Join-Path $ServerRoot 'crash-reports'
    if (Test-Path -LiteralPath $crashDirectory -PathType Container) {
        $newestCrash = Get-ChildItem -LiteralPath $crashDirectory -File -Filter '*.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($null -ne $newestCrash) {
            $lines.Add('Newest crash report: ' + $newestCrash.Name)
            try { foreach ($line in @(Get-Content -LiteralPath $newestCrash.FullName -Tail 20 -ErrorAction Stop)) { $lines.Add($line) } }
            catch { $lines.Add('Crash report could not be read.') }
        }
    }
    $text = ($lines -join ' | ')
    if ($text.Length -gt 2600) { $text = $text.Substring($text.Length - 2600) }
    return $text
}

trap {
    $failure = ($_.Exception.Message -replace '[\r\n]+', ' ').Trim()
    $logTail = if ($null -ne $root) { Get-RecentStartupLog -ServerRoot $root.FullName } else { '' }
    Write-Output "::error title=FunCity full-pack engine startup::$failure; recent-log=$logTail"
    throw
}

$allowedRoot = [System.IO.Path]::GetFullPath('E:\Administrator\Desktop\FunCity') + [System.IO.Path]::DirectorySeparatorChar
$resolvedServerPath = [System.IO.Path]::GetFullPath($ServerPath)
Assert-Condition -Condition ($resolvedServerPath.StartsWith($allowedRoot, [System.StringComparison]::OrdinalIgnoreCase)) -Message 'Startup target must remain inside E:\Administrator\Desktop\FunCity.'
$root = Get-Item -LiteralPath $resolvedServerPath -ErrorAction Stop
Assert-Condition -Condition $root.PSIsContainer -Message 'Full-pack FunCity Engine output was not found.'

$required = @('server.jar', 'server.properties', 'eula.txt', 'start.bat', 'BUILD-REPORT.txt', 'README-FUNCITY-ENGINE.txt', 'pack-mod-inventory.json', 'runtime\JAVA-VERSION.txt', 'runtime\bin\java.exe', 'runtime\bin\javaw.exe')
foreach ($relative in $required) { Assert-Condition -Condition (Test-Path -LiteralPath (Join-Path $root.FullName $relative) -PathType Leaf) -Message "Required engine file is missing: $relative" }
$inventory = ConvertFrom-Json -InputObject (Get-Content -LiteralPath (Join-Path $root.FullName 'pack-mod-inventory.json') -Raw) -ErrorAction Stop
$expectedTotal = [int]$inventory.sourceModJarCount
$expectedServer = [int]$inventory.serverModJarCount
$expectedClientOnly = [int]$inventory.clientOnlyModJarCount
$mods = @(Get-ChildItem -LiteralPath (Join-Path $root.FullName 'mods') -File -Filter '*.jar' -ErrorAction Stop)
$clientMods = @(Get-ChildItem -LiteralPath (Join-Path $root.FullName 'client-only-mods') -File -Filter '*.jar' -ErrorAction Stop)
Assert-Condition -Condition ($mods.Count -eq $expectedServer -and $clientMods.Count -eq $expectedClientOnly -and $mods.Count + $clientMods.Count -eq $expectedTotal -and $expectedTotal -eq @($inventory.mods).Count) -Message "Full pack mod count changed: server=$($mods.Count)/$expectedServer; client-only=$($clientMods.Count)/$expectedClientOnly; total=$expectedTotal."
$clientOnlyPattern = '(?i)^(TextruesRubidiumOptions-|InGameAccountSwitcher-|rubidium-|oculus-|lightfallclient-|notenoughanimations-|CTM-)'
$unsafeActiveMods = @($mods | Where-Object { $_.Name -match $clientOnlyPattern })
Assert-Condition -Condition ($unsafeActiveMods.Count -eq 0) -Message ('A client-only mod is still in the active server mods folder: ' + ($unsafeActiveMods.Name -join ', '))
$eula = Get-Content -LiteralPath (Join-Path $root.FullName 'eula.txt') -Raw
Assert-Condition -Condition ($eula -match '(?im)^\s*eula\s*=\s*true\s*$') -Message 'The accepted EULA setting is not true; server was not started.'
$properties = Get-Content -LiteralPath (Join-Path $root.FullName 'server.properties')
$portLine = $properties | Where-Object { $_ -match '^\s*server-port\s*=' } | Select-Object -First 1
$port = if ($null -eq $portLine) { 0 } else { [int](($portLine -replace '^\s*server-port\s*=\s*', '').Trim()) }
Assert-Condition -Condition ($port -eq 25566) -Message "Test instance must use port 25566, found $port."
$heapGB = [int]$inventory.heapGB
Assert-Condition -Condition ($heapGB -ge 3 -and $heapGB -le 8) -Message "Invalid recorded heap size: $heapGB GB."

$javaExe = Join-Path $root.FullName 'runtime\bin\java.exe'
$javawExe = Join-Path $root.FullName 'runtime\bin\javaw.exe'
$runtimeNote = Get-Content -LiteralPath (Join-Path $root.FullName 'runtime\JAVA-VERSION.txt') -Raw
Assert-Condition -Condition ($runtimeNote -match 'Temurin JRE 11\.0\.32\.1' -and $runtimeNote -match 'SHA-256 verified') -Message 'The approved portable Java 11 verification marker is missing.'
$startText = Get-Content -LiteralPath (Join-Path $root.FullName 'start.bat') -Raw
Assert-Condition -Condition ($startText -match '(?im)^set "JAVA_EXE=%~dp0runtime\\bin\\java\.exe"\s*$' -and $startText -notmatch '(?im)^\s*where java >nul 2>&1\s*$' -and $startText -notmatch '(?im)^\s*set "JAVA_EXE=java"\s*$') -Message 'start.bat must use only the server-local Java runtime.'
$taskName = 'FunCity-Freeroam-Mohist-Test'
$taskDescription = 'Managed by FunCity Freeroam Engine; manual-only; no logon or reboot trigger.'
$portOpen = Test-LocalTcpPort -Port $port
$existingProcess = Get-FunCityEngineProcess -ServerRoot $root.FullName
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($portOpen) {
    Assert-Condition -Condition ($null -ne $existingProcess) -Message "Port $port is occupied but is not the FunCity Freeroam engine; no process was started."
    Assert-Condition -Condition ($null -ne $task -and $task.Description -like 'Managed by FunCity Freeroam Engine;*' -and $task.State -eq 'Running') -Message 'The current Freeroam process is not owned by the expected running manual-only task.'
    $serverPid = [int]$existingProcess.ProcessId
    Set-Content -LiteralPath (Join-Path $root.FullName 'server.pid') -Value $serverPid -Encoding ASCII
    $summary = "Server=already-running; PID=$serverPid; port=$port; server-loaded-mods=$($mods.Count); all-pack-mods=$expectedTotal; client-only-preserved=$expectedClientOnly; Task=$taskName; Java=Temurin-11.0.32.1"
    Write-Output "::notice title=FunCity full-pack engine start::$summary"
    Write-Output $summary
    return
}

if ($null -ne $task -and $task.Description -notlike 'Managed by FunCity Freeroam Engine;*') {
    throw 'A task with the FunCity Freeroam task name already exists but is not owned by this engine; it was not modified.'
}
if ($null -ne $task -and $task.State -eq 'Running' -and $null -eq $existingProcess) {
    throw 'The managed task reports Running but its Java server process was not identified; refusing to create a duplicate.'
}

$currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
Assert-Condition -Condition ($null -ne $currentIdentity -and $currentIdentity.User.Value -ne 'S-1-5-18') -Message 'The Actions runner is LocalSystem; refusing to create a task under a different account.'
$launchArguments = @(
    '-Xms2G', "-Xmx${heapGB}G", '-XX:+UseG1GC', '-XX:+ParallelRefProcEnabled',
    '-XX:MaxGCPauseMillis=200', '-XX:+UnlockExperimentalVMOptions', '-XX:+DisableExplicitGC',
    '-XX:G1NewSizePercent=30', '-XX:G1MaxNewSizePercent=40', '-XX:G1ReservePercent=20',
    '-XX:G1HeapWastePercent=5', '-XX:G1MixedGCCountTarget=4', '-XX:InitiatingHeapOccupancyPercent=15',
    '-XX:G1MixedGCLiveThresholdPercent=90', '-XX:G1RSetUpdatingPauseTimePercent=5',
    '-Dfuncity.instance=FunCity-Freeroam-Engine', '-jar', 'server.jar', 'nogui'
)
$taskAction = New-ScheduledTaskAction -Execute $javawExe -Argument ($launchArguments -join ' ') -WorkingDirectory $root.FullName
$taskPrincipal = New-ScheduledTaskPrincipal -UserId $currentIdentity.Name -LogonType S4U -RunLevel Limited
$taskSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Days 3650) -MultipleInstances IgnoreNew
$taskDefinition = New-ScheduledTask -Action $taskAction -Principal $taskPrincipal -Settings $taskSettings -Description $taskDescription
Register-ScheduledTask -TaskName $taskName -InputObject $taskDefinition -Force -ErrorAction Stop | Out-Null
$registeredTask = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
Assert-Condition -Condition ($registeredTask.Triggers.Count -eq 0) -Message 'The managed task unexpectedly has an automatic trigger; it will not be started.'
Start-ScheduledTask -TaskName $taskName -ErrorAction Stop

$launchStartedAt = Get-Date
$pidPath = Join-Path $root.FullName 'server.pid'
Set-Content -LiteralPath $pidPath -Value 'starting' -Encoding ASCII
$reportPath = Join-Path $root.FullName 'BUILD-REPORT.txt'
$reportLines = @(Get-Content -LiteralPath $reportPath | Where-Object { $_ -notmatch '^Server status:' -and $_ -notmatch '^Server process management:' })
$reportLines += "Server status: startup pending; task $taskName; port $port; mods $($mods.Count)."
Set-Content -LiteralPath $reportPath -Value $reportLines -Encoding UTF8

$deadline = (Get-Date).AddMinutes(15)
$ready = $false
$serverPid = $null
$stablePortChecks = 0
$portReadyWithoutLogChecks = 0
$latestLog = Join-Path $root.FullName 'logs\latest.log'
while ((Get-Date) -lt $deadline) {
    $processInfo = Get-FunCityEngineProcess -ServerRoot $root.FullName
    if ($null -ne $processInfo) {
        $serverPid = [int]$processInfo.ProcessId
        Set-Content -LiteralPath $pidPath -Value $serverPid -Encoding ASCII
        if ($null -eq (Get-Process -Id $serverPid -ErrorAction SilentlyContinue)) {
            throw "The full-pack Java process $serverPid exited during startup."
        }
        $logReady = $false
        if (Test-Path -LiteralPath $latestLog -PathType Leaf) {
            try {
                $logInfo = Get-Item -LiteralPath $latestLog -ErrorAction Stop
                if ($logInfo.LastWriteTime -ge $launchStartedAt) {
                    $tail = @(Get-Content -LiteralPath $latestLog -Tail 100 -ErrorAction Stop)
                    $logReady = @($tail | Where-Object { $_ -match '(?i)Done \([^)]+\)!' }).Count -gt 0
                }
            }
            catch { $logReady = $false }
        }
        if (Test-LocalTcpPort -Port $port) {
            $stablePortChecks++
            if (-not $logReady) { $portReadyWithoutLogChecks++ }
            if (($logReady -and $stablePortChecks -ge 2) -or $portReadyWithoutLogChecks -ge 6) {
                $ready = $true
                break
            }
        }
        else {
            $stablePortChecks = 0
            $portReadyWithoutLogChecks = 0
        }
    }
    else {
        $taskState = (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State
        if (((Get-Date) - $launchStartedAt).TotalSeconds -gt 60 -and $taskState -ne 'Running') {
            throw "The task stopped before a FunCity Java process appeared (task state=$taskState)."
        }
        if (Test-LocalTcpPort -Port $port) {
            throw "Port $port opened, but the FunCity engine process could not be identified."
        }
    }
    Start-Sleep -Seconds 5
}
if (-not $ready) {
    $lastLog = Get-RecentStartupLog -ServerRoot $root.FullName
    throw "The full-pack engine did not hold port $port ready within 15 minutes; PID=$serverPid; recent-log=$lastLog"
}

$runningTask = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
Assert-Condition -Condition ($runningTask.State -eq 'Running' -and $runningTask.Triggers.Count -eq 0) -Message 'The manual-only task is not running or has an unexpected automatic trigger.'
$reportLines = @(Get-Content -LiteralPath $reportPath | Where-Object { $_ -notmatch '^Server status:' -and $_ -notmatch '^Server process management:' })
$reportLines += "Server status: running; PID $serverPid; port $port; server-loaded-mods=$($mods.Count); all-pack-mods=$expectedTotal; client-only-preserved=$expectedClientOnly."
$reportLines += 'Server process management: manual-only Windows Scheduled Task ' + $taskName + ' (no logon or reboot trigger).'
Set-Content -LiteralPath $reportPath -Value $reportLines -Encoding UTF8

$logTail = Get-RecentStartupLog -ServerRoot $root.FullName
if ($logTail.Length -gt 1200) { $logTail = $logTail.Substring($logTail.Length - 1200) }
$summary = "Server=ready; PID=$serverPid; Mohist=1.16.5-1242; Forge=36.2.42; server-loaded-mods=$($mods.Count); all-pack-mods=$expectedTotal; client-only-preserved=$expectedClientOnly; Java=portable-Temurin-11.0.32.1; port=$port; EULA=true; Task=$taskName/Running/manual-only; startup-log=$logTail"
Write-Output "::notice title=FunCity full-pack engine started::$summary"
Write-Output $summary
