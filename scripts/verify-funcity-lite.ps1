[CmdletBinding()]
param(
    [string]$ServerPath = 'E:\Administrator\Desktop\FunCity\FunCity server\FunCity-Lite'
)

# Read-only smoke verification of the generated server folder. This script never
# starts the server, accepts the EULA, or reads outside the FunCity project tree.
$ErrorActionPreference = 'Stop'

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Test-ReadableJar {
    param([string]$Path)
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try { return ($archive.Entries.Count -gt 0) }
    finally { $archive.Dispose() }
}

$allowedRoot = [System.IO.Path]::GetFullPath('E:\Administrator\Desktop\FunCity') + [System.IO.Path]::DirectorySeparatorChar
$resolvedServerPath = [System.IO.Path]::GetFullPath($ServerPath)
Assert-Condition -Condition ($resolvedServerPath.StartsWith($allowedRoot, [System.StringComparison]::OrdinalIgnoreCase)) -Message 'Verification path must remain inside E:\Administrator\Desktop\FunCity.'
$root = Get-Item -LiteralPath $resolvedServerPath -ErrorAction Stop
Assert-Condition -Condition $root.PSIsContainer -Message 'The FunCity-Lite output path is not a directory.'

$requiredFiles = @('server.jar', 'server.properties', 'eula.txt', 'start.bat', 'BUILD-REPORT.txt', 'README-FUNCITY.txt')
foreach ($name in $requiredFiles) {
    Assert-Condition -Condition (Test-Path -LiteralPath (Join-Path $root.FullName $name) -PathType Leaf) -Message "Required server file is missing: $name"
}

Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
$serverJar = Join-Path $root.FullName 'server.jar'
$serverArchive = [System.IO.Compression.ZipFile]::OpenRead($serverJar)
try {
    $manifestEntry = $serverArchive.GetEntry('META-INF/MANIFEST.MF')
    Assert-Condition -Condition ($null -ne $manifestEntry) -Message 'server.jar has no Java manifest.'
    $manifestStream = $manifestEntry.Open()
    try {
        $reader = New-Object System.IO.StreamReader($manifestStream)
        try { $engineManifest = $reader.ReadToEnd() }
        finally { $reader.Dispose() }
    }
    finally { $manifestStream.Dispose() }
}
finally { $serverArchive.Dispose() }
Assert-Condition -Condition ($engineManifest -match '(?m)^Implementation-Title: Mohist\s*$') -Message 'server.jar is not identified as Mohist.'
Assert-Condition -Condition ($engineManifest -match '(?m)^Implementation-Version: 1\.16\.5-1242\s*$') -Message 'Mohist version is not 1.16.5-1242.'
Assert-Condition -Condition ($engineManifest -match '(?m)^Implementation-Version: 36\.2\.42\s*$') -Message 'Embedded Forge version is not 36.2.42.'

$modsPath = Join-Path $root.FullName 'mods'
$modFiles = @(Get-ChildItem -LiteralPath $modsPath -File -Filter '*.jar' -ErrorAction Stop | Sort-Object Name)
Assert-Condition -Condition ($modFiles.Count -eq 9) -Message "Expected 9 server mods, found $($modFiles.Count)."
foreach ($jar in $modFiles) {
    Assert-Condition -Condition ($jar.Length -gt 0) -Message "Empty mod JAR: $($jar.Name)"
    Assert-Condition -Condition (Test-ReadableJar -Path $jar.FullName) -Message "Unreadable mod JAR: $($jar.Name)"
}

$expectedPlugins = @(
    'LuckPerms-Bukkit-5.4.131.jar',
    'EssentialsX-2.20.1.jar',
    'EssentialsXChat-2.20.1.jar',
    'EssentialsXSpawn-2.20.1.jar',
    'Vault.jar',
    'PlaceholderAPI-2.11.6.jar',
    'spark-1.10.92-bukkit.jar',
    'Chunky-1.2.164.jar'
)
$pluginsPath = Join-Path $root.FullName 'plugins'
foreach ($name in $expectedPlugins) {
    $pluginPath = Join-Path $pluginsPath $name
    Assert-Condition -Condition (Test-Path -LiteralPath $pluginPath -PathType Leaf) -Message "Expected plugin is missing: $name"
    Assert-Condition -Condition (Test-ReadableJar -Path $pluginPath) -Message "Unreadable plugin JAR: $name"
}

$eulaText = Get-Content -LiteralPath (Join-Path $root.FullName 'eula.txt') -Raw
$eulaAccepted = $eulaText -match '(?im)^\s*eula\s*=\s*true\s*$'
$eulaDeclined = $eulaText -match '(?im)^\s*eula\s*=\s*false\s*$'
Assert-Condition -Condition ($eulaDeclined -and -not $eulaAccepted) -Message 'EULA state is not false; verification refuses to change or accept it.'

$properties = Get-Content -LiteralPath (Join-Path $root.FullName 'server.properties')
$viewDistance = [int](($properties | Where-Object { $_ -match '^\s*view-distance\s*=' } | Select-Object -First 1) -replace '^\s*view-distance\s*=\s*', '')
$onlineMode = ($properties | Where-Object { $_ -match '^\s*online-mode\s*=' } | Select-Object -First 1) -replace '^\s*online-mode\s*=\s*', ''
Assert-Condition -Condition ($viewDistance -eq 6) -Message "Unexpected view-distance: $viewDistance"
Assert-Condition -Condition ($onlineMode -eq 'true') -Message 'online-mode must remain enabled.'

$startBat = Get-Content -LiteralPath (Join-Path $root.FullName 'start.bat') -Raw
Assert-Condition -Condition ($startBat -match '(?im)^findstr /i /x /c:"eula=true" eula\.txt >nul\s*$') -Message 'start.bat is missing its exact EULA gate.'
Assert-Condition -Condition ($startBat -match '(?im)^java .*\-XX:\+UseG1GC') -Message 'start.bat is missing G1GC tuning.'

$unexpectedRuntimeData = @('world', 'world_nether', 'world_the_end', 'logs') | Where-Object { Test-Path -LiteralPath (Join-Path $root.FullName $_) }
Assert-Condition -Condition ($unexpectedRuntimeData.Count -eq 0) -Message ('Runtime data appeared before owner-approved startup: ' + ($unexpectedRuntimeData -join ', '))

$libraryState = if (Test-Path -LiteralPath (Join-Path $root.FullName 'libraries') -PathType Container) { 'present' } else { 'not-copied; Mohist may bootstrap it on first approved start' }
$summary = "Mohist=1.16.5-1242; Forge=36.2.42; mods=$($modFiles.Count)/9 valid; plugins=$($expectedPlugins.Count)/8 valid; view-distance=$viewDistance; online-mode=$onlineMode; EULA=false; libraries=$libraryState; server-not-started=true"
Write-Output "::notice title=FunCity Lite PC verification::$summary"
Write-Output $summary
