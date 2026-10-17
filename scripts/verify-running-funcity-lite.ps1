[CmdletBinding()]
param(
    [string]$ServerPath = 'E:\Administrator\Desktop\FunCity\FunCity server\FunCity-Lite'
)

# Read-only check that the detached server survived the GitHub Actions launch job.
$ErrorActionPreference = 'Stop'

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
$resolvedServerPath = [System.IO.Path]::GetFullPath($ServerPath)
Assert-Condition -Condition ($resolvedServerPath.StartsWith($allowedRoot, [System.StringComparison]::OrdinalIgnoreCase)) -Message 'Verification path must remain inside E:\Administrator\Desktop\FunCity.'
$root = Get-Item -LiteralPath $resolvedServerPath -ErrorAction Stop
$eula = Get-Content -LiteralPath (Join-Path $root.FullName 'eula.txt') -Raw
Assert-Condition -Condition ($eula -match '(?im)^\s*eula\s*=\s*true\s*$') -Message 'EULA is not accepted in the installed server folder.'
$javaVersionNotePath = Join-Path $root.FullName 'runtime\JAVA-VERSION.txt'
Assert-Condition -Condition (Test-Path -LiteralPath $javaVersionNotePath -PathType Leaf) -Message 'The local Java runtime verification marker is missing.'
$javaVersionNote = Get-Content -LiteralPath $javaVersionNotePath -Raw
Assert-Condition -Condition ($javaVersionNote -match 'Temurin JRE 11\.0\.32\.1' -and $javaVersionNote -match 'SHA-256 verified') -Message 'The server-local Java runtime is not the checksum-verified Temurin JRE 11.0.32.1.'

$pidPath = Join-Path $root.FullName 'server.pid'
Assert-Condition -Condition (Test-Path -LiteralPath $pidPath -PathType Leaf) -Message 'server.pid is missing.'
$serverPid = [int](Get-Content -LiteralPath $pidPath -Raw).Trim()
$processInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $serverPid" -ErrorAction SilentlyContinue
Assert-Condition -Condition ($null -ne $processInfo -and $processInfo.Name -match '^java\.exe$') -Message 'The recorded Java server process is not running.'
Assert-Condition -Condition ($processInfo.CommandLine -match '(?i)-Dfuncity\.instance=FunCity-Lite' -and $processInfo.CommandLine -match '(?i)-jar\s+server\.jar') -Message 'The recorded process is not the FunCity Lite server.'

$properties = Get-Content -LiteralPath (Join-Path $root.FullName 'server.properties')
$portSetting = $properties | Where-Object { $_ -match '^\s*server-port\s*=' } | Select-Object -First 1
$port = if ($null -eq $portSetting) { 25565 } else { [int](($portSetting -replace '^\s*server-port\s*=\s*', '').Trim()) }
Assert-Condition -Condition (Test-LocalTcpPort -Port $port) -Message "FunCity Lite is not accepting local TCP connections on port $port."

$latestLog = Join-Path $root.FullName 'logs\latest.log'
Assert-Condition -Condition (Test-Path -LiteralPath $latestLog -PathType Leaf) -Message 'logs/latest.log was not created.'
$logText = [System.IO.File]::ReadAllText($latestLog)
Assert-Condition -Condition ($logText -match '(?i)Done \([^)]+\)!') -Message 'Minecraft has not reported a ready state yet.'

$summary = "Running=true; PID=$serverPid; Java=Temurin JRE 11.0.32.1; port=$port listening locally; startup=Done; EULA=true; logs remain in FunCity-Lite"
Write-Output "::notice title=FunCity Lite running check::$summary"
Write-Output $summary
