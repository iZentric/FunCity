[CmdletBinding()]
param(
    [string]$ServerPath = 'E:\Administrator\Desktop\FunCity\FunCity server\FunCity-Lite'
)

# Installs a checksum-verified portable Temurin JRE 8 only under FunCity-Lite.
# It does not edit eula.txt, start the server, or install anything system-wide.
$ErrorActionPreference = 'Stop'

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
if (Test-Path -LiteralPath $runtimePath) {
    if (-not (Test-Path -LiteralPath $installedJava -PathType Leaf)) { throw 'A runtime folder already exists but has no bin\java.exe; refusing to overwrite it.' }
    $existingVersion = @(& $installedJava -version 2>&1) -join ' '
    if ($existingVersion -notmatch '"1\.8\.') { throw 'The existing local runtime is not Java 8; refusing to replace it.' }
    Write-Output '::notice title=FunCity Lite Java::A local Java 8 runtime is already installed; no files were changed.'
    return
}

$downloadUrl = 'https://github.com/adoptium/temurin8-binaries/releases/download/jdk8u504-b01/OpenJDK8U-jre_x64_windows_hotspot_8u504b01.zip'
$expectedBytes = 40104826L
$expectedSha256 = '82e2cdc6693737c5998445b31f69668fa0da77c7705121053f6508ac84961123'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

$stagingPath = Join-Path $root.FullName ('.java-runtime-staging-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stagingPath -Force | Out-Null
try {
    $archivePath = Join-Path $stagingPath 'temurin-jre8.zip'
    $extractPath = Join-Path $stagingPath 'extract'
    New-Item -ItemType Directory -Path $extractPath -Force | Out-Null
    Invoke-WebRequest -Uri $downloadUrl -OutFile $archivePath -UseBasicParsing -TimeoutSec 300 -Headers @{ 'User-Agent' = 'FunCity-Engine-Lite/0.1' }

    $archiveFile = Get-Item -LiteralPath $archivePath
    Assert-Condition -Condition ($archiveFile.Length -eq $expectedBytes) -Message 'Downloaded Java archive size did not match the release metadata.'
    $actualSha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Condition -Condition ($actualSha256 -eq $expectedSha256) -Message 'Downloaded Java archive SHA-256 did not match the signed release metadata.'

    [System.IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $extractPath)
    $javaExe = Get-ChildItem -LiteralPath $extractPath -File -Filter 'java.exe' -Recurse | Where-Object { $_.Directory.Name -ieq 'bin' } | Select-Object -First 1
    Assert-Condition -Condition ($null -ne $javaExe) -Message 'The verified Java archive did not contain bin\java.exe.'
    $jreRoot = $javaExe.Directory.Parent.FullName
    Assert-Condition -Condition (Test-Path -LiteralPath (Join-Path $jreRoot 'bin\java.exe') -PathType Leaf) -Message 'The extracted JRE layout was unexpected.'

    [System.IO.Directory]::Move($jreRoot, $runtimePath)
    $installedVersionLines = @(& $installedJava -version 2>&1)
    $installedVersion = $installedVersionLines -join ' '
    Assert-Condition -Condition ($installedVersion -match '"1\.8\.') -Message 'The installed runtime did not identify itself as Java 8.'
    Set-Content -LiteralPath (Join-Path $runtimePath 'JAVA-VERSION.txt') -Value @(
        'Eclipse Temurin JRE 8u504, Windows x64, HotSpot.'
        'Downloaded from the official Adoptium GitHub release and SHA-256 verified.'
        'Archive SHA-256: ' + $expectedSha256
    ) -Encoding ASCII

    $summary = 'Installed portable Temurin JRE 8u504 x64 under FunCity-Lite\runtime; archive SHA-256 verified; EULA unchanged; server not started.'
    Write-Output "::notice title=FunCity Lite Java installation::$summary"
    Write-Output $summary
}
finally {
    if (Test-Path -LiteralPath $stagingPath -PathType Container) {
        Remove-Item -LiteralPath $stagingPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}
