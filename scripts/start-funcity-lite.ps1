[CmdletBinding()]
param(
    [string]$ServerPath = 'E:\Administrator\Desktop\FunCity\FunCity server\FunCity-Lite'
)

# The owner explicitly accepted the Minecraft EULA in this conversation. This
# script enables it only for this server, starts it, and writes all runtime files
# under the FunCity-Lite folder. It does not change firewall or router settings.
$ErrorActionPreference = 'Stop'

trap {
    $failure = ($_.Exception.Message -replace '[\r\n]+', ' ').Trim()
    Write-Output "::error title=FunCity Lite server start::$failure"
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

function Get-FunCityJavaProcess {
    param([string]$ServerRoot)
    $serverRootPath = [System.IO.Path]::GetFullPath($ServerRoot)
    $serverRootPattern = [regex]::Escape($serverRootPath)
    $javaBinPath = [System.IO.Path]::GetFullPath((Join-Path $serverRootPath 'runtime\bin')) + [System.IO.Path]::DirectorySeparatorChar
    $javaProcesses = @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $localExecutable = ($null -ne $_.ExecutablePath -and $_.ExecutablePath.StartsWith($javaBinPath, [System.StringComparison]::OrdinalIgnoreCase))
        $localCommandLine = ($null -ne $_.CommandLine -and $_.CommandLine -match $serverRootPattern)
        $_.Name -match '^javaw?\.exe$' -and
        ($localExecutable -or $localCommandLine) -and
        $_.CommandLine -match '(?i)-Dfuncity\.instance=FunCity-Lite' -and
        $_.CommandLine -match '(?i)-jar\s+server\.jar'
    } | Sort-Object CreationDate -Descending)
    if ($javaProcesses.Count -gt 0) { return $javaProcesses[0] }
    return $null
}

$allowedRoot = [System.IO.Path]::GetFullPath('E:\Administrator\Desktop\FunCity') + [System.IO.Path]::DirectorySeparatorChar
$resolvedServerPath = [System.IO.Path]::GetFullPath($ServerPath)
Assert-Condition -Condition ($resolvedServerPath.StartsWith($allowedRoot, [System.StringComparison]::OrdinalIgnoreCase)) -Message 'Startup target must remain inside E:\Administrator\Desktop\FunCity.'
$root = Get-Item -LiteralPath $resolvedServerPath -ErrorAction Stop
Assert-Condition -Condition $root.PSIsContainer -Message 'FunCity-Lite server folder was not found.'

$requiredFiles = @('server.jar', 'server.properties', 'eula.txt', 'start.bat', 'BUILD-REPORT.txt', 'README-FUNCITY.txt')
foreach ($name in $requiredFiles) {
    Assert-Condition -Condition (Test-Path -LiteralPath (Join-Path $root.FullName $name) -PathType Leaf) -Message "Required file is missing: $name"
}
$mods = @(Get-ChildItem -LiteralPath (Join-Path $root.FullName 'mods') -File -Filter '*.jar' -ErrorAction Stop)
$plugins = @(Get-ChildItem -LiteralPath (Join-Path $root.FullName 'plugins') -File -Filter '*.jar' -ErrorAction Stop)
Assert-Condition -Condition ($mods.Count -eq 9) -Message "Expected 9 server mods, found $($mods.Count)."
Assert-Condition -Condition ($plugins.Count -eq 8) -Message "Expected 8 plugins, found $($plugins.Count)."

Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
$serverArchive = [System.IO.Compression.ZipFile]::OpenRead((Join-Path $root.FullName 'server.jar'))
try {
    $manifestEntry = $serverArchive.GetEntry('META-INF/MANIFEST.MF')
    Assert-Condition -Condition ($null -ne $manifestEntry) -Message 'server.jar has no manifest.'
    $manifestStream = $manifestEntry.Open()
    try {
        $reader = New-Object System.IO.StreamReader($manifestStream)
        try { $engineManifest = $reader.ReadToEnd() }
        finally { $reader.Dispose() }
    }
    finally { $manifestStream.Dispose() }
}
finally { $serverArchive.Dispose() }
Assert-Condition -Condition ($engineManifest -match '(?m)^Implementation-Title: Mohist\s*$' -and $engineManifest -match '(?m)^Implementation-Version: 1\.16\.5-1242\s*$' -and $engineManifest -match '(?m)^Implementation-Version: 36\.2\.42\s*$') -Message 'The server engine is not the verified Mohist 1.16.5-1242 / Forge 36.2.42 build.'

$startPath = Join-Path $root.FullName 'start.bat'
$startText = [System.IO.File]::ReadAllText($startPath)
Assert-Condition -Condition ($startText -match '(?im)^findstr /i /x /c:"eula=true" eula\.txt >nul\s*$') -Message 'start.bat is missing the EULA safety gate.'
Assert-Condition -Condition ($startText -match '(?im)^"%JAVA_EXE%" .*\-XX:\+UseG1GC.*\-jar server\.jar nogui\s*$') -Message 'start.bat does not contain the expected local-runtime G1GC launch command.'
Assert-Condition -Condition ($startText -match '(?im)^set "JAVA_EXE=%~dp0runtime\\bin\\java\.exe"\s*$') -Message 'start.bat does not prefer the server-local Java runtime.'
Assert-Condition -Condition ($startText -notmatch '(?im)^\s*where java >nul 2>&1\s*$' -and $startText -notmatch '(?im)^\s*set "JAVA_EXE=java"\s*$') -Message 'start.bat still permits a system Java fallback.'

$javaExePath = Join-Path $root.FullName 'runtime\bin\java.exe'
$javaPath = Join-Path $root.FullName 'runtime\bin\javaw.exe'
$javaVersionNotePath = Join-Path $root.FullName 'runtime\JAVA-VERSION.txt'
Assert-Condition -Condition ((Test-Path -LiteralPath $javaExePath -PathType Leaf) -and (Test-Path -LiteralPath $javaPath -PathType Leaf)) -Message 'The bundled Java 11 runtime is incomplete; EULA remains unchanged and the server was not started.'
Assert-Condition -Condition (Test-Path -LiteralPath $javaVersionNotePath -PathType Leaf) -Message 'The bundled Java runtime verification marker is missing; EULA remains unchanged and the server was not started.'
$javaVersionNote = Get-Content -LiteralPath $javaVersionNotePath -Raw
Assert-Condition -Condition ($javaVersionNote -match 'Temurin JRE 11\.0\.32\.1' -and $javaVersionNote -match 'SHA-256 verified') -Message 'The bundled Java runtime is not the checksum-verified Temurin JRE 11.0.32.1; EULA remains unchanged and the server was not started.'
$javaLabel = 'Temurin JRE 11.0.32.1 (server-local runtime)'
$taskName = 'FunCity-Lite-Mohist-Server'

$properties = Get-Content -LiteralPath (Join-Path $root.FullName 'server.properties')
$portSetting = $properties | Where-Object { $_ -match '^\s*server-port\s*=' } | Select-Object -First 1
$port = if ($null -eq $portSetting) { 25565 } else { [int](($portSetting -replace '^\s*server-port\s*=\s*', '').Trim()) }
Assert-Condition -Condition ($port -ge 1 -and $port -le 65535) -Message "Invalid server-port value: $port"
if (Test-LocalTcpPort -Port $port) {
    $existingServer = Get-FunCityJavaProcess -ServerRoot $root.FullName
    if ($null -eq $existingServer) { throw "Port $port is already accepting connections, but no FunCity-Lite Java process was identified; no duplicate server was launched." }
    $existingEula = Get-Content -LiteralPath (Join-Path $root.FullName 'eula.txt') -Raw
    Assert-Condition -Condition ($existingEula -match '(?im)^\s*eula\s*=\s*true\s*$') -Message 'An existing FunCity process is listening, but eula.txt does not confirm acceptance.'
    $existingPid = [int]$existingServer.ProcessId
    Set-Content -LiteralPath (Join-Path $root.FullName 'server.pid') -Value $existingPid -Encoding ASCII
    $reportPath = Join-Path $root.FullName 'BUILD-REPORT.txt'
    $reportLines = @(Get-Content -LiteralPath $reportPath | Where-Object { $_ -notmatch '^Server status:' -and $_ -notmatch '^Java runtime:' -and $_ -notmatch '^Server process management:' })
    $reportLines += "Server status: running; PID $existingPid; port $port."
    $reportLines += 'Java runtime: ' + $javaLabel
    $reportLines += 'Server process management: Windows Scheduled Task ' + $taskName + ' (manual-only; no automatic triggers).'
    Set-Content -LiteralPath $reportPath -Value $reportLines -Encoding UTF8
    $summary = "Server=already-running; Mohist=1.16.5-1242; Forge=36.2.42; Java=$javaLabel; mods=$($mods.Count); plugins=$($plugins.Count); port=$port; PID=$existingPid; EULA=true; Task=$taskName"
    Write-Output "::notice title=FunCity Lite server start::$summary"
    Write-Output $summary
    return
}

# EULA was explicitly accepted by the owner. Change only the one active setting.
$eulaPath = Join-Path $root.FullName 'eula.txt'
$eulaLines = @(Get-Content -LiteralPath $eulaPath)
$settingIndices = @()
for ($i = 0; $i -lt $eulaLines.Count; $i++) {
    if ($eulaLines[$i] -match '^\s*eula\s*=') { $settingIndices += $i }
}
Assert-Condition -Condition ($settingIndices.Count -eq 1) -Message 'eula.txt must contain exactly one active EULA setting.'
$settingIndex = $settingIndices[0]
if ($eulaLines[$settingIndex] -match '^\s*eula\s*=\s*false\s*$') {
    $eulaLines[$settingIndex] = 'eula=true'
    Set-Content -LiteralPath $eulaPath -Value $eulaLines -Encoding ASCII
}
elseif ($eulaLines[$settingIndex] -notmatch '^\s*eula\s*=\s*true\s*$') {
    throw 'The EULA setting is not a recognized true/false value; no server process was started.'
}
$eulaAfter = Get-Content -LiteralPath $eulaPath -Raw
Assert-Condition -Condition ($eulaAfter -match '(?im)^\s*eula\s*=\s*true\s*$') -Message 'EULA acceptance did not verify; server not started.'

$reportPath = Join-Path $root.FullName 'BUILD-REPORT.txt'
$reportText = [System.IO.File]::ReadAllText($reportPath)
$reportText = $reportText.Replace('EULA: false (awaiting owner acceptance)', 'EULA: true (owner explicitly accepted; server startup authorized)')
$reportLines = @($reportText -split "`r?`n" | Where-Object { $_ -notmatch '^Server status:' -and $_ -notmatch '^Java runtime:' -and $_ -notmatch '^Server process management:' })
$reportLines += 'Server status: startup pending; Java launch not yet confirmed.'
Set-Content -LiteralPath $reportPath -Value $reportLines -Encoding UTF8

$readmePath = Join-Path $root.FullName 'README-FUNCITY.txt'
$readmeText = [System.IO.File]::ReadAllText($readmePath)
$readmeText = $readmeText.Replace('EULA is deliberately false. Set eula=true yourself only after reading and accepting the Minecraft EULA.', 'EULA: owner explicitly accepted the Minecraft EULA; eula.txt is true for this server installation.')
$readmeLines = @($readmeText -split "`r?`n" | Where-Object { $_ -notmatch '^Server process management:' })
$readmeLines += 'Server process management: Windows Scheduled Task ' + $taskName + '; manual-only with no automatic startup trigger.'
Set-Content -LiteralPath $readmePath -Value $readmeLines -Encoding UTF8

$logsPath = Join-Path $root.FullName 'logs'
New-Item -ItemType Directory -Path $logsPath -Force | Out-Null
$launchArguments = @(
    '-Xms2G', '-Xmx4G', '-XX:+UseG1GC', '-XX:+ParallelRefProcEnabled',
    '-XX:MaxGCPauseMillis=200', '-XX:+UnlockExperimentalVMOptions',
    '-XX:+DisableExplicitGC', '-XX:G1NewSizePercent=30', '-XX:G1MaxNewSizePercent=40',
    '-XX:G1ReservePercent=20', '-XX:G1HeapWastePercent=5', '-XX:G1MixedGCCountTarget=4',
    '-XX:InitiatingHeapOccupancyPercent=15', '-XX:G1MixedGCLiveThresholdPercent=90',
    '-XX:G1RSetUpdatingPauseTimePercent=5', '-Dfuncity.instance=FunCity-Lite',
    '-jar', 'server.jar', 'nogui'
)

# GitHub Actions cleans up child processes when a job ends. Run Java from a
# manual-only Task Scheduler entry so the server can outlive the Actions job.
# The task has no logon or reboot trigger and uses only the current PC account.
$taskDescription = 'Managed by FunCity Lite; manual launch only; no logon or reboot trigger.'
$currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
Assert-Condition -Condition ($null -ne $currentIdentity -and $currentIdentity.User.Value -ne 'S-1-5-18') -Message 'The runner is running as LocalSystem; refusing to create a server task under a different account.'
$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($null -ne $existingTask -and $existingTask.Description -notmatch '^Managed by FunCity Lite;') {
    throw 'A Windows Scheduled Task with the FunCity Lite task name already exists but is not managed by this workflow; it was not changed.'
}
if ($null -eq $existingTask -or $existingTask.State -ne 'Running') {
    $taskAction = New-ScheduledTaskAction -Execute $javaPath -Argument ($launchArguments -join ' ') -WorkingDirectory $root.FullName
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId $currentIdentity.Name -LogonType S4U -RunLevel Limited
    $taskSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Days 3650) -MultipleInstances IgnoreNew
    $taskDefinition = New-ScheduledTask -Action $taskAction -Principal $taskPrincipal -Settings $taskSettings -Description $taskDescription
    Register-ScheduledTask -TaskName $taskName -InputObject $taskDefinition -Force -ErrorAction Stop | Out-Null
    Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
}
else {
    Write-Output '::notice title=FunCity Lite server::The managed server task is already running; waiting for its process and port.'
}

$pidPath = Join-Path $root.FullName 'server.pid'
Set-Content -LiteralPath $pidPath -Value 'starting' -Encoding ASCII
$reportLines = @(Get-Content -LiteralPath $reportPath | Where-Object { $_ -notmatch '^Server status:' -and $_ -notmatch '^Java runtime:' -and $_ -notmatch '^Server process management:' })
$reportLines += "Server status: startup pending; task $taskName; port $port."
Set-Content -LiteralPath $reportPath -Value $reportLines -Encoding UTF8

$deadline = (Get-Date).AddMinutes(10)
$ready = $false
$serverProcess = $null
$serverPid = $null
$stablePortChecks = 0
$latestLog = Join-Path $logsPath 'latest.log'
$launchStartedAt = Get-Date
$portReadyWithoutLogChecks = 0
while ((Get-Date) -lt $deadline) {
    $candidateProcess = Get-FunCityJavaProcess -ServerRoot $root.FullName
    if ($null -ne $candidateProcess) {
        $serverProcess = $candidateProcess
        $serverPid = [int]$candidateProcess.ProcessId
        Set-Content -LiteralPath $pidPath -Value $serverPid -Encoding ASCII
        $runningProcess = Get-Process -Id $serverPid -ErrorAction SilentlyContinue
        if ($null -eq $runningProcess) { throw 'The scheduled Java process exited before the server port became ready. Inspect logs inside FunCity-Lite.' }
        $logReady = $false
        if (Test-Path -LiteralPath $latestLog -PathType Leaf) {
            try {
                $latestLogInfo = Get-Item -LiteralPath $latestLog -ErrorAction Stop
                if ($latestLogInfo.LastWriteTime -ge $launchStartedAt) {
                    $serverLogLines = @(Get-Content -LiteralPath $latestLog -Tail 40 -ErrorAction Stop)
                    $logReady = @($serverLogLines | Where-Object { $_ -match '(?i)Done \([^)]+\)!' }).Count -gt 0
                }
            }
            catch { $logReady = $false }
        }
        if (Test-LocalTcpPort -Port $port) {
            $stablePortChecks++
            if (-not $logReady) { $portReadyWithoutLogChecks++ }
            if (($stablePortChecks -ge 2 -and $logReady) -or $portReadyWithoutLogChecks -ge 6) { $ready = $true; break }
        }
        else {
            $stablePortChecks = 0
            $portReadyWithoutLogChecks = 0
        }
    }
    elseif (Test-LocalTcpPort -Port $port) {
        throw "Port $port opened, but the scheduled FunCity Java process could not be identified; no second process was launched."
    }
    Start-Sleep -Seconds 5
}
if (-not $ready) { throw "The scheduled FunCity process $serverPid did not hold port $port ready within 10 minutes. Inspect logs inside FunCity-Lite." }

$reportLines = @(Get-Content -LiteralPath $reportPath | Where-Object { $_ -notmatch '^Server status:' -and $_ -notmatch '^Java runtime:' -and $_ -notmatch '^Server process management:' })
$reportLines += "Server status: running; PID $serverPid; port $port."
$reportLines += 'Java runtime: ' + $javaLabel
$reportLines += 'Server process management: Windows Scheduled Task ' + $taskName + ' (manual-only; no automatic triggers).'
Set-Content -LiteralPath $reportPath -Value $reportLines -Encoding UTF8

$legacyRuntimePath = Join-Path $root.FullName 'runtime-java8-backup'
$legacyRuntimeCleaned = $false
if (Test-Path -LiteralPath $legacyRuntimePath -PathType Container) {
    $legacyVersionNote = Join-Path $legacyRuntimePath 'JAVA-VERSION.txt'
    if ((Test-Path -LiteralPath $legacyVersionNote -PathType Leaf) -and (Get-Content -LiteralPath $legacyVersionNote -Raw) -match 'Temurin JRE 8u504') {
        Remove-Item -LiteralPath $legacyRuntimePath -Recurse -Force -ErrorAction SilentlyContinue
        $legacyRuntimeCleaned = -not (Test-Path -LiteralPath $legacyRuntimePath)
    }
}

$summary = "Server=ready; Mohist=1.16.5-1242; Forge=36.2.42; Java=$javaLabel; mods=$($mods.Count); plugins=$($plugins.Count); port=$port; PID=$serverPid; EULA=true; Task=$taskName; old-runtime-cleaned=$legacyRuntimeCleaned"
Write-Output "::notice title=FunCity Lite server start::$summary"
Write-Output $summary
