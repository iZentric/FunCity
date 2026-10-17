[CmdletBinding()]
param(
    [string]$ServerPath = 'E:\Administrator\Desktop\FunCity\FunCity server\FunCity-Lite'
)

# Installs a checksum-verified portable Temurin JRE 11 only under FunCity-Lite.
# Replaces the earlier local JRE 8 installed by this workflow, preserving it as
# an in-folder rollback until the server reaches a confirmed ready state. This
# script does not edit eula.txt, start the server, or install anything system-wide.
$ErrorActionPreference = 'Stop'

trap {
    $failure = ($_.Exception.Message -replace '[\r\n]+', ' ').Trim()
    Write-Output "::error title=FunCity Lite Java installation::$failure"
    throw
}

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$allowedRoot = [System.IO.Path]::GetFullPath('E:\Administrator\Desktop\FunCity') + [System.IO.Path]::DirectorySeparatorChar
$resolvedServerPath = [System.IO.Path]::GetFullPath($ServerPath)
Assert-Condition -Condition ($resolvedServerPath.StartsWith($allowedRoot, [System.StringComparison]::OrdinalIgnoreCase)) -Message 'Java installation target must remain inside E:\Administrator\Desktop\FunCity.'
$root = Get-Item -LiteralPath $resolvedServerPath -ErrorAction Stop
Assert-Condition -Condition $root.PSIsContainer -Message 'FunCity-Lite server folder was not found.'
Assert-Condition -Condition (Test-Path -LiteralPath (Join-Path $root.FullName 'server.jar') -PathType Leaf) -Message 'server.jar is missing; refusing to install Java into an unrelated folder.'

$runtimePath = Join-Path $root.FullName 'runtime'
$installedJava = Join-Path $runtimePath 'bin\java.exe'
$versionNotePath = Join-Path $runtimePath 'JAVA-VERSION.txt'
$backupPath = Join-Path $root.FullName 'runtime-java8-backup'
$backupAlreadyPresent = Test-Path -LiteralPath $backupPath -PathType Container
if ($backupAlreadyPresent) {
    $backupVersionNote = Join-Path $backupPath 'JAVA-VERSION.txt'
    Assert-Condition -Condition (Test-Path -LiteralPath $backupVersionNote -PathType Leaf) -Message 'An unverified runtime-java8-backup folder already exists; refusing to continue.'
    Assert-Condition -Condition ((Get-Content -LiteralPath $backupVersionNote -Raw) -match 'Temurin JRE 8u504') -Message 'The runtime-java8-backup folder is not the previous workflow-installed Java 8; refusing to replace or remove it.'
}
$replaceRuntime8 = $false
if (Test-Path -LiteralPath $runtimePath -PathType Container) {
    Assert-Condition -Condition (Test-Path -LiteralPath $installedJava -PathType Leaf) -Message 'A runtime folder exists but has no bin\java.exe; refusing to overwrite it.'
    Assert-Condition -Condition (Test-Path -LiteralPath $versionNotePath -PathType Leaf) -Message 'The runtime version marker is missing; refusing to replace an unverified runtime.'
    $currentRuntimeNote = Get-Content -LiteralPath $versionNotePath -Raw
    if ($currentRuntimeNote -match 'Temurin JRE 11\.0\.32\.1') {
        Write-Output '::notice title=FunCity Lite Java::Temurin JRE 11.0.32.1 is already installed; no files were changed.'
        return
    }
    if ($currentRuntimeNote -notmatch 'Temurin JRE 8u504') { throw 'The existing runtime is not the Java 8 installation created by this workflow; refusing to replace it.' }
    Assert-Condition -Condition (-not (Test-Path -LiteralPath $backupPath)) -Message 'The Java 8 rollback folder already exists; refusing to overwrite it.'
    $replaceRuntime8 = $true
}

$downloadUrl = 'https://github.com/adoptium/temurin11-binaries/releases/download/jdk-11.0.32.1%2B1/OpenJDK11U-jre_x64_windows_hotspot_11.0.32.1_1.zip'
$expectedBytes = 43578373L
$expectedSha256 = 'f8c7da672f5dba36b6f870608820b6b598cfae91296929f1b8f21ef2f1e8a0dd'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

$stagingPath = Join-Path $root.FullName ('.java11-runtime-staging-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stagingPath -Force | Out-Null
$backupCreated = $backupAlreadyPresent
try {
    $archivePath = Join-Path $stagingPath 'temurin-jre11.zip'
    $extractPath = Join-Path $stagingPath 'extract'
    New-Item -ItemType Directory -Path $extractPath -Force | Out-Null
    Invoke-WebRequest -Uri $downloadUrl -OutFile $archivePath -UseBasicParsing -TimeoutSec 300 -Headers @{ 'User-Agent' = 'FunCity-Engine-Lite/0.1' }
    Write-Output '::notice title=FunCity Lite Java::Downloaded the official Temurin JRE 11 archive inside the server folder.'

    $archiveFile = Get-Item -LiteralPath $archivePath
    Assert-Condition -Condition ($archiveFile.Length -eq $expectedBytes) -Message 'Downloaded Java 11 archive size did not match the release metadata.'
    $actualSha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Condition -Condition ($actualSha256 -eq $expectedSha256) -Message 'Downloaded Java 11 archive SHA-256 did not match the GitHub release metadata.'
    Write-Output '::notice title=FunCity Lite Java::Java 11 archive size and SHA-256 verified.'

    [System.IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $extractPath)
    $javaExe = Get-ChildItem -LiteralPath $extractPath -File -Filter 'java.exe' -Recurse | Where-Object { $_.Directory.Name -ieq 'bin' } | Select-Object -First 1
    Assert-Condition -Condition ($null -ne $javaExe) -Message 'The verified Java 11 archive did not contain bin\java.exe.'
    $jreRoot = $javaExe.Directory.Parent.FullName
    Assert-Condition -Condition (Test-Path -LiteralPath (Join-Path $jreRoot 'bin\java.exe') -PathType Leaf) -Message 'The extracted Java 11 layout was unexpected.'

    Set-Content -LiteralPath (Join-Path $jreRoot 'JAVA-VERSION.txt') -Value @(
        'Eclipse Temurin JRE 11.0.32.1, Windows x64, HotSpot.'
        'Downloaded from the official Adoptium GitHub release and SHA-256 verified.'
        'Archive SHA-256: ' + $expectedSha256
    ) -Encoding ASCII

    if ($replaceRuntime8) {
        [System.IO.Directory]::Move($runtimePath, $backupPath)
        $backupCreated = $true
    }
    try {
        [System.IO.Directory]::Move($jreRoot, $runtimePath)
    }
    catch {
        if ($backupCreated -and -not (Test-Path -LiteralPath $runtimePath)) {
            [System.IO.Directory]::Move($backupPath, $runtimePath)
            $backupCreated = $false
        }
        throw
    }

    $summary = if ($backupCreated) {
        'Installed checksum-verified Temurin JRE 11.0.32.1 under FunCity-Lite\runtime; earlier local JRE 8 preserved temporarily for rollback; EULA unchanged; server not started.'
    }
    else {
        'Installed checksum-verified Temurin JRE 11.0.32.1 under FunCity-Lite\runtime; EULA unchanged; server not started.'
    }
    Write-Output "::notice title=FunCity Lite Java installation::$summary"
    Write-Output $summary
}
finally {
    if (Test-Path -LiteralPath $stagingPath -PathType Container) {
        Remove-Item -LiteralPath $stagingPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}
