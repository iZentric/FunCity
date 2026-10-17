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

$javaPath = Join-Path $root.FullName 'runtime\bin\java.exe'
Assert-Condition -Condition (Test-Path -LiteralPath $javaPath -PathType Leaf) -Message 'The bundled Java 8 runtime is missing; EULA remains unchanged and the server was not started.'
$javaMajor = 8
$javaLabel = 'Temurin 8u504 (server-local runtime)'

$properties = Get-Content -LiteralPath (Join-Path $root.FullName 'server.properties')
$portSetting = $properties | Where-Object { $_ -match '^\s*server-port\s*=' } | Select-Object -First 1
$port = if ($null -eq $portSetting) { 25565 } else { [int](($portSetting -replace '^\s*server-port\s*=\s*', '').Trim()) }
Assert-Condition -Condition ($port -ge 1 -and $port -le 65535) -Message "Invalid server-port value: $port"
if (Test-LocalTcpPort -Port $port) {
    throw "Port $port is already accepting connections. No duplicate server was launched; check whether FunCity is already running."
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
$reportLines = @($reportText -split "`r?`n" | Where-Object { $_ -notmatch '^Server status:' })
$reportLines += 'Server status: startup pending; Java launch not yet confirmed.'
Set-Content -LiteralPath $reportPath -Value $reportLines -Encoding UTF8

$readmePath = Join-Path $root.FullName 'README-FUNCITY.txt'
$readmeText = [System.IO.File]::ReadAllText($readmePath)
$readmeText = $readmeText.Replace('EULA is deliberately false. Set eula=true yourself only after reading and accepting the Minecraft EULA.', 'EULA: owner explicitly accepted the Minecraft EULA; eula.txt is true for this server installation.')
Set-Content -LiteralPath $readmePath -Value $readmeText -Encoding UTF8

$logsPath = Join-Path $root.FullName 'logs'
New-Item -ItemType Directory -Path $logsPath -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$stdoutPath = Join-Path $logsPath ("funcity-console-$stamp.out.log")
$stderrPath = Join-Path $logsPath ("funcity-console-$stamp.err.log")
$launchArguments = @(
    '-Xms2G', '-Xmx4G', '-XX:+UseG1GC', '-XX:+ParallelRefProcEnabled',
    '-XX:MaxGCPauseMillis=200', '-XX:+UnlockExperimentalVMOptions',
    '-XX:+DisableExplicitGC', '-XX:G1NewSizePercent=30', '-XX:G1MaxNewSizePercent=40',
    '-XX:G1ReservePercent=20', '-XX:G1HeapWastePercent=5', '-XX:G1MixedGCCountTarget=4',
    '-XX:InitiatingHeapOccupancyPercent=15', '-XX:G1MixedGCLiveThresholdPercent=90',
    '-XX:G1RSetUpdatingPauseTimePercent=5', '-Dfuncity.instance=FunCity-Lite',
    '-jar', 'server.jar', 'nogui'
)
$serverProcess = Start-Process -FilePath $javaPath -ArgumentList $launchArguments -WorkingDirectory $root.FullName -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
Set-Content -LiteralPath (Join-Path $root.FullName 'server.pid') -Value $serverProcess.Id -Encoding ASCII
$reportLines = @(Get-Content -LiteralPath $reportPath | Where-Object { $_ -notmatch '^Server status:' })
$reportLines += "Server status: startup pending; PID $($serverProcess.Id); port $port."
Set-Content -LiteralPath $reportPath -Value $reportLines -Encoding UTF8

$latestLog = Join-Path $logsPath 'latest.log'
$deadline = (Get-Date).AddMinutes(10)
$ready = $false
while ((Get-Date) -lt $deadline) {
    $runningProcess = Get-Process -Id $serverProcess.Id -ErrorAction SilentlyContinue
    if ($null -eq $runningProcess) { throw 'The Java process exited before the server became ready. Inspect logs/latest.log inside FunCity-Lite.' }
    $logReady = $false
    if (Test-Path -LiteralPath $latestLog -PathType Leaf) {
        $currentLog = [System.IO.File]::ReadAllText($latestLog)
        $logReady = $currentLog -match '(?i)Done \([^)]+\)!'
    }
    if ($logReady -and (Test-LocalTcpPort -Port $port)) { $ready = $true; break }
    Start-Sleep -Seconds 5
}
if (-not $ready) { throw "Server process $($serverProcess.Id) is still alive but not confirmed ready after 10 minutes. Inspect logs/latest.log inside FunCity-Lite." }

$reportLines = @(Get-Content -LiteralPath $reportPath | Where-Object { $_ -notmatch '^Server status:' })
$reportLines += "Server status: running; PID $($serverProcess.Id); port $port."
Set-Content -LiteralPath $reportPath -Value $reportLines -Encoding UTF8

$summary = "Server=ready; Mohist=1.16.5-1242; Forge=36.2.42; Java=$javaLabel; mods=$($mods.Count); plugins=$($plugins.Count); port=$port; PID=$($serverProcess.Id); EULA=true"
Write-Output "::notice title=FunCity Lite server start::$summary"
Write-Output $summary
