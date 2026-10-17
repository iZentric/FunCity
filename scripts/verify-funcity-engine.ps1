[CmdletBinding()]
param(
    [string]$ServerPath = 'E:\Administrator\Desktop\FunCity\FunCity server\FunCity-Engine-Freeroam'
)

# Read-only structural check for the isolated full-pack test engine.
$ErrorActionPreference = 'Stop'

trap {
    $failure = ($_.Exception.Message -replace '[\r\n]+', ' ').Trim()
    Write-Output "::error title=FunCity full-pack verification::$failure"
    throw
}

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
$resolved = [System.IO.Path]::GetFullPath($ServerPath)
Assert-Condition -Condition ($resolved.StartsWith($allowedRoot, [System.StringComparison]::OrdinalIgnoreCase)) -Message 'Test engine path must stay inside E:\Administrator\Desktop\FunCity.'
$root = Get-Item -LiteralPath $resolved -ErrorAction Stop
Assert-Condition -Condition $root.PSIsContainer -Message 'Full-pack FunCity Engine directory is missing.'

$requiredFiles = @('server.jar', 'server.properties', 'eula.txt', 'start.bat', 'BUILD-REPORT.txt', 'README-FUNCITY-ENGINE.txt', 'pack-mod-inventory.json', 'runtime\JAVA-VERSION.txt', 'runtime\bin\java.exe', 'runtime\bin\javaw.exe')
foreach ($relative in $requiredFiles) {
    Assert-Condition -Condition (Test-Path -LiteralPath (Join-Path $root.FullName $relative) -PathType Leaf) -Message "Required full-pack engine file is missing: $relative"
}

Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
$serverArchive = [System.IO.Compression.ZipFile]::OpenRead((Join-Path $root.FullName 'server.jar'))
try {
    $manifestEntry = $serverArchive.GetEntry('META-INF/MANIFEST.MF')
    Assert-Condition -Condition ($null -ne $manifestEntry) -Message 'Hybrid server.jar has no Java manifest.'
    $stream = $manifestEntry.Open()
    try {
        $reader = New-Object System.IO.StreamReader($stream)
        try { $engineManifest = $reader.ReadToEnd() }
        finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
}
finally { $serverArchive.Dispose() }
Assert-Condition -Condition ($engineManifest -match '(?m)^Implementation-Title: Mohist\s*$' -and $engineManifest -match '(?m)^Implementation-Version: 1\.16\.5-1242\s*$' -and $engineManifest -match '(?m)^Implementation-Version: 36\.2\.42\s*$') -Message 'The test engine is not the expected Mohist 1.16.5-1242 / Forge 36.2.42 build.'

$inventoryPath = Join-Path $root.FullName 'pack-mod-inventory.json'
$inventory = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $inventoryPath -Raw) -ErrorAction Stop
$inventoryMods = @($inventory.mods)
$expectedTotal = [int]$inventory.sourceModJarCount
$expectedServer = [int]$inventory.serverModJarCount
$expectedClientOnly = [int]$inventory.clientOnlyModJarCount
Assert-Condition -Condition ($inventory.pack -eq 'Freeroam 1.0.0.mrpack' -and $inventory.minecraft -eq '1.16.5' -and $inventory.forge -eq '36.2.42') -Message 'The manifest record is not the requested Freeroam 1.0.0 Forge 1.16.5 pack.'
Assert-Condition -Condition ($inventoryMods.Count -eq $expectedTotal -and $expectedTotal -gt 0 -and $expectedServer + $expectedClientOnly -eq $expectedTotal) -Message "Pack inventory counts are inconsistent: all=$($inventoryMods.Count); server=$expectedServer; client-only=$expectedClientOnly."
$modsDirectory = Join-Path $root.FullName 'mods'
$clientModsDirectory = Join-Path $root.FullName 'client-only-mods'
$modFiles = @(Get-ChildItem -LiteralPath $modsDirectory -File -Filter '*.jar' -ErrorAction Stop)
$clientFiles = @(Get-ChildItem -LiteralPath $clientModsDirectory -File -Filter '*.jar' -ErrorAction Stop)
Assert-Condition -Condition ($modFiles.Count -eq $expectedServer) -Message "Server-compatible mods/ count is $($modFiles.Count), expected $expectedServer."
Assert-Condition -Condition ($clientFiles.Count -eq $expectedClientOnly -and $modFiles.Count + $clientFiles.Count -eq $expectedTotal) -Message "Pack JARs were not all retained: server=$($modFiles.Count), client-only=$($clientFiles.Count), total=$expectedTotal."
foreach ($record in $inventoryMods) {
    $path = Join-Path $root.FullName ([string]$record.relativeDestination)
    Assert-Condition -Condition (Test-Path -LiteralPath $path -PathType Leaf) -Message "Pack mod was not staged: $($record.packPath)"
    Assert-Condition -Condition (Test-ReadableJar -Path $path) -Message "Pack mod is not a readable JAR: $($record.file)"
    $actualSha = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Condition -Condition ($actualSha -eq ([string]$record.sha256).ToLowerInvariant()) -Message "Staged mod checksum does not match the build inventory: $($record.file)"
    if ($record.loadOnServer) {
        Assert-Condition -Condition ([string]$record.relativeDestination -like 'mods/*') -Message "A server mod is outside the active mods/ folder: $($record.file)"
    }
    else {
        Assert-Condition -Condition ([string]$record.relativeDestination -like 'client-only-mods/*') -Message "A client-only mod was not kept outside the active mods/ folder: $($record.file)"
    }
}

$eula = Get-Content -LiteralPath (Join-Path $root.FullName 'eula.txt') -Raw
Assert-Condition -Condition ($eula -match '(?im)^\s*eula\s*=\s*true\s*$') -Message 'EULA must remain true as previously accepted by the owner.'
$properties = Get-Content -LiteralPath (Join-Path $root.FullName 'server.properties')
$portLine = $properties | Where-Object { $_ -match '^\s*server-port\s*=' } | Select-Object -First 1
$port = if ($null -eq $portLine) { 0 } else { [int](($portLine -replace '^\s*server-port\s*=\s*', '').Trim()) }
$viewLine = $properties | Where-Object { $_ -match '^\s*view-distance\s*=' } | Select-Object -First 1
$onlineLine = $properties | Where-Object { $_ -match '^\s*online-mode\s*=' } | Select-Object -First 1
Assert-Condition -Condition ($port -eq 25566) -Message "Full test engine must use port 25566, found $port."
Assert-Condition -Condition ($null -ne $viewLine -and [int](($viewLine -replace '^\s*view-distance\s*=\s*', '').Trim()) -eq 6) -Message 'Unexpected full-pack test view distance.'
Assert-Condition -Condition ($null -ne $onlineLine -and ($onlineLine -replace '^\s*online-mode\s*=\s*', '').Trim() -eq 'true') -Message 'online-mode must stay enabled.'

$runtimeNote = Get-Content -LiteralPath (Join-Path $root.FullName 'runtime\JAVA-VERSION.txt') -Raw
Assert-Condition -Condition ($runtimeNote -match 'Temurin JRE 11\.0\.32\.1' -and $runtimeNote -match 'SHA-256 verified') -Message 'Bundled portable Java runtime is not the approved verified Temurin 11 runtime.'
$startText = Get-Content -LiteralPath (Join-Path $root.FullName 'start.bat') -Raw
Assert-Condition -Condition ($startText -match '(?im)^set "JAVA_EXE=%~dp0runtime\\bin\\java\.exe"\s*$' -and $startText -notmatch '(?im)^\s*where java >nul 2>&1\s*$' -and $startText -notmatch '(?im)^\s*set "JAVA_EXE=java"\s*$') -Message 'start.bat must require only the engine-local runtime.'
Assert-Condition -Condition ($startText -match '(?im)^findstr /i /x /c:"eula=true" eula\.txt >nul\s*$' -and $startText -match '(?i)-Dfuncity\.instance=FunCity-Freeroam-Engine.*-jar server\.jar nogui') -Message 'start.bat is missing the EULA safety check or engine identity.'

$pluginsDirectory = Join-Path $root.FullName 'plugins'
$extraPlugins = if (Test-Path -LiteralPath $pluginsDirectory -PathType Container) { @(Get-ChildItem -LiteralPath $pluginsDirectory -File -Filter '*.jar') } else { @() }
Assert-Condition -Condition ($extraPlugins.Count -eq 0) -Message 'The isolated modpack test must not add extra plugins.'

$summary = "Engine=verified; Mohist=1.16.5-1242; Forge=36.2.42; pack=Freeroam-1.0.0; server-loaded=$($modFiles.Count)/$expectedServer; client-only-preserved=$($clientFiles.Count)/$expectedClientOnly; all-pack-mods=$expectedTotal checksummed; port=$port; Java=portable-Temurin-11.0.32.1; EULA=true; extra-plugins=0; server-not-started-by-this-check=true"
Write-Output "::notice title=FunCity full-pack engine verification::$summary"
Write-Output $summary
