[CmdletBinding()]
param(
    [string]$ProjectRoot = 'E:\Administrator\Desktop\FunCity',
    [string]$PackPath = 'E:\Administrator\Desktop\FunCity\modpack uri\Freeroam 1.0.0.mrpack',
    [string]$ReferencePath = 'E:\Administrator\Desktop\FunCity\servere referinta',
    [string]$OutputParent = 'E:\Administrator\Desktop\FunCity\FunCity server',
    [string]$OutputName = 'FunCity-Engine-Freeroam',
    [string]$RuntimeSource = 'E:\Administrator\Desktop\FunCity\FunCity server\FunCity-Lite\runtime',
    [int]$Port = 25566,
    [int]$HeapGB = 6
)

# Build a separate branded hybrid test server from every mod JAR in the exact
# requested MRPack. The existing FunCity-Lite server and all reference data are
# preserved. Mods from both the index and embedded overrides are loaded together
# for compatibility testing; the pack's original files are never modified.
$ErrorActionPreference = 'Stop'

function Get-PropertyValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Get-Sha256Text {
    param([string]$Text)
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally { $algorithm.Dispose() }
}

function Test-ClientOnlyMod {
    param([string]$FileName)
    # These client render/account-switcher mods caused Forge's dedicated-server
    # RuntimeDistCleaner failure in the first full-pack test. Preserve them in
    # the engine bundle, but never place them in the active server mods/ folder.
    return ($FileName -match '(?i)^(TextruesRubidiumOptions-|InGameAccountSwitcher-|rubidium-|oculus-|lightfallclient-|notenoughanimations-|CTM-|TRansliterationLib-)')
}

function Get-UniqueFilePath {
    param([string]$Destination, [string]$FileName, [string]$Identity)
    $candidate = Join-Path $Destination $FileName
    if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $extension = [System.IO.Path]::GetExtension($FileName)
    $suffix = (Get-Sha256Text -Text $Identity).Substring(0, 10)
    $candidate = Join-Path $Destination ($baseName + '__' + $suffix + $extension)
    $sequence = 2
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $Destination ($baseName + '__' + $suffix + '_' + $sequence + $extension)
        $sequence++
    }
    return $candidate
}

function Read-MrpackManifest {
    param([string]$Path)
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $archive.GetEntry('modrinth.index.json')
        if ($null -eq $entry) { throw 'The requested MRPack is missing modrinth.index.json.' }
        $stream = $entry.Open()
        try {
            $reader = New-Object System.IO.StreamReader($stream)
            try { return ConvertFrom-Json -InputObject $reader.ReadToEnd() -ErrorAction Stop }
            finally { $reader.Dispose() }
        }
        finally { $stream.Dispose() }
    }
    finally { $archive.Dispose() }
}

function Assert-ReadableJar {
    param([string]$Path)
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        if ($zip.Entries.Count -eq 0) { throw "JAR is empty or unreadable: $Path" }
    }
    finally { $zip.Dispose() }
}

function Download-ModFile {
    param($FileRecord, [string]$Destination, [string]$TargetDirectoryName = 'mods')
    $relativePath = ([string](Get-PropertyValue -Object $FileRecord -Name 'path')).Replace('\', '/')
    if ($relativePath -notmatch '(?i)^mods/.+\.jar$' -or $relativePath -match '(^|/)\.\.(/|$)') {
        throw "Unsafe or invalid mod path in the MRPack: $relativePath"
    }
    $fileName = [System.IO.Path]::GetFileName($relativePath)
    $targetPath = Get-UniqueFilePath -Destination $Destination -FileName $fileName -Identity ('manifest:' + $relativePath)
    $downloads = @(Get-PropertyValue -Object $FileRecord -Name 'downloads' | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($downloads.Count -eq 0) { throw "No download URL is listed for $relativePath" }
    $hashes = Get-PropertyValue -Object $FileRecord -Name 'hashes'
    $expectedSize = Get-PropertyValue -Object $FileRecord -Name 'fileSize'
    $downloaded = $false
    $lastError = $null

    foreach ($url in $downloads) {
        if (-not ([string]$url).StartsWith('https://', [System.StringComparison]::OrdinalIgnoreCase)) {
            $lastError = 'Rejected a non-HTTPS download URL.'
            continue
        }
        for ($attempt = 1; $attempt -le 3 -and -not $downloaded; $attempt++) {
            try {
                Invoke-WebRequest -Uri ([string]$url) -OutFile $targetPath -UseBasicParsing -TimeoutSec 180 -Headers @{ 'User-Agent' = 'FunCity-Freeroam-Engine/1.0' }
                $downloaded = $true
            }
            catch {
                $lastError = $_.Exception.Message
                if (Test-Path -LiteralPath $targetPath) { Remove-Item -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue }
                Start-Sleep -Seconds ([Math]::Min(2 * $attempt, 6))
            }
        }
        if ($downloaded) { break }
    }
    if (-not $downloaded) { throw "Could not download $relativePath. $lastError" }

    $info = Get-Item -LiteralPath $targetPath -ErrorAction Stop
    if ($null -ne $expectedSize -and [long]$expectedSize -gt 0 -and $info.Length -ne [long]$expectedSize) {
        throw "File-size verification failed for $relativePath."
    }
    $expectedSha512 = [string](Get-PropertyValue -Object $hashes -Name 'sha512')
    $expectedSha1 = [string](Get-PropertyValue -Object $hashes -Name 'sha1')
    if (-not [string]::IsNullOrWhiteSpace($expectedSha512)) {
        $actual = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA512).Hash.ToLowerInvariant()
        if ($actual -ne $expectedSha512.ToLowerInvariant()) { throw "SHA-512 verification failed for $relativePath." }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($expectedSha1)) {
        $actual = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA1).Hash.ToLowerInvariant()
        if ($actual -ne $expectedSha1.ToLowerInvariant()) { throw "SHA-1 verification failed for $relativePath." }
    }
    else {
        throw "No supported hash is listed for $relativePath; refusing to use an unverified mod."
    }
    Assert-ReadableJar -Path $targetPath
    return [pscustomobject]@{
        source = 'modrinth.index.json'
        packPath = $relativePath
        file = [System.IO.Path]::GetFileName($targetPath)
        relativeDestination = $TargetDirectoryName + '/' + [System.IO.Path]::GetFileName($targetPath)
        loadOnServer = ($TargetDirectoryName -eq 'mods')
        bytes = $info.Length
        sha256 = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant()
        serverEnvironment = [string](Get-PropertyValue -Object (Get-PropertyValue -Object $FileRecord -Name 'env') -Name 'server')
        clientEnvironment = [string](Get-PropertyValue -Object (Get-PropertyValue -Object $FileRecord -Name 'env') -Name 'client')
    }
}

function Copy-PackOverrides {
    param([string]$PackPath, [string]$Destination, [string]$ModsDirectory, [string]$ClientModsDirectory)
    $copiedConfig = [System.Collections.Generic.List[string]]::new()
    $embeddedMods = [System.Collections.Generic.List[object]]::new()
    $allowedRoots = @('config/', 'defaultconfigs/', 'kubejs/', 'scripts/', 'datapacks/')
    $archive = [System.IO.Compression.ZipFile]::OpenRead($PackPath)
    try {
        # Apply client overrides first, then server-overrides so server settings win.
        foreach ($prefix in @('overrides/', 'server-overrides/')) {
            foreach ($entry in $archive.Entries) {
                if ($entry.FullName.EndsWith('/')) { continue }
                if (-not $entry.FullName.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                $relative = $entry.FullName.Substring($prefix.Length).Replace('\', '/')
                if ($relative -match '(^|/)\.\.(/|$)' -or [System.IO.Path]::IsPathRooted($relative) -or $relative -match '^[A-Za-z]:') {
                    throw "Unsafe path in MRPack override: $($entry.FullName)"
                }
                if ($relative -match '(?i)^mods/.+\.jar$') {
                    $fileName = [System.IO.Path]::GetFileName($relative)
                    $clientOnly = Test-ClientOnlyMod -FileName $fileName
                    $targetFolderName = if ($clientOnly) { 'client-only-mods' } else { 'mods' }
                    $targetDirectory = if ($clientOnly) { $ClientModsDirectory } else { $ModsDirectory }
                    $serverEnvironment = if ($clientOnly) { 'client-only; preserved but not loaded by server' } else { 'embedded; loaded for full-pack test' }
                    $targetPath = Get-UniqueFilePath -Destination $targetDirectory -FileName $fileName -Identity ('override:' + $entry.FullName)
                    $input = $entry.Open()
                    $output = [System.IO.File]::Create($targetPath)
                    try { $input.CopyTo($output) }
                    finally { $output.Dispose(); $input.Dispose() }
                    Assert-ReadableJar -Path $targetPath
                    $embeddedMods.Add([pscustomobject]@{
                        source = 'embedded override'
                        packPath = $entry.FullName
                        file = [System.IO.Path]::GetFileName($targetPath)
                        relativeDestination = $targetFolderName + '/' + [System.IO.Path]::GetFileName($targetPath)
                        loadOnServer = (-not $clientOnly)
                        bytes = (Get-Item -LiteralPath $targetPath).Length
                        sha256 = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant()
                        serverEnvironment = $serverEnvironment
                        clientEnvironment = 'embedded'
                    })
                    continue
                }
                if (-not ($allowedRoots | Where-Object { $relative.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) })) { continue }
                $relativeWindows = $relative.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
                $destinationFile = [System.IO.Path]::GetFullPath((Join-Path $Destination $relativeWindows))
                $destinationPrefix = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
                if (-not $destinationFile.StartsWith($destinationPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw "Override path escaped the test engine folder: $($entry.FullName)"
                }
                $parent = Split-Path -Parent $destinationFile
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
                $input = $entry.Open()
                $output = [System.IO.File]::Create($destinationFile)
                try { $input.CopyTo($output) }
                finally { $output.Dispose(); $input.Dispose() }
                $copiedConfig.Add($relative)
            }
        }
    }
    finally { $archive.Dispose() }
    return [pscustomobject]@{
        configFiles = @($copiedConfig)
        embeddedMods = @($embeddedMods)
    }
}

$resolvedProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
$allowedRoot = $resolvedProjectRoot + '\'
$resolvedPack = [System.IO.Path]::GetFullPath($PackPath)
$resolvedReference = [System.IO.Path]::GetFullPath($ReferencePath)
$resolvedOutputParent = [System.IO.Path]::GetFullPath($OutputParent)
$resolvedRuntimeSource = [System.IO.Path]::GetFullPath($RuntimeSource)
foreach ($path in @($resolvedPack, $resolvedReference, $resolvedOutputParent, $resolvedRuntimeSource)) {
    if (-not $path.StartsWith($allowedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "All FunCity engine inputs and outputs must remain inside $resolvedProjectRoot."
    }
}
if (-not (Test-Path -LiteralPath $resolvedPack -PathType Leaf)) { throw "The exact Freeroam pack was not found: $resolvedPack" }
if (-not (Test-Path -LiteralPath $resolvedReference -PathType Container)) { throw "Reference folder is missing: $resolvedReference" }
if (-not (Test-Path -LiteralPath $resolvedOutputParent -PathType Container)) { throw "Output parent folder is missing: $resolvedOutputParent" }
if ($Port -lt 1 -or $Port -gt 65535 -or $Port -eq 25565) { throw 'Use a valid test port distinct from the existing FunCity-Lite port 25565.' }
if ($HeapGB -lt 3 -or $HeapGB -gt 8) { throw 'Full-pack test heap must be between 3 and 8 GB.' }

$finalPath = Join-Path $resolvedOutputParent $OutputName
if (Test-Path -LiteralPath $finalPath) { throw "Refusing to overwrite existing engine output: $finalPath" }
$sourceEngineFolder = Join-Path $resolvedReference 'hypecity'
$sourceEngineJar = Join-Path $sourceEngineFolder 'server.jar'
if (-not (Test-Path -LiteralPath $sourceEngineJar -PathType Leaf)) { throw 'The Hypecity reference Mohist server.jar is missing.' }
$runtimeJava = Join-Path $resolvedRuntimeSource 'bin\java.exe'
$runtimeJavaw = Join-Path $resolvedRuntimeSource 'bin\javaw.exe'
$runtimeNotePath = Join-Path $resolvedRuntimeSource 'JAVA-VERSION.txt'
if (-not (Test-Path -LiteralPath $runtimeJava -PathType Leaf) -or -not (Test-Path -LiteralPath $runtimeJavaw -PathType Leaf) -or -not (Test-Path -LiteralPath $runtimeNotePath -PathType Leaf)) {
    throw 'The existing verified server-local Java runtime is incomplete; no system-Java fallback will be used.'
}
$runtimeNote = Get-Content -LiteralPath $runtimeNotePath -Raw
if ($runtimeNote -notmatch 'Temurin JRE 11\.0\.32\.1' -or $runtimeNote -notmatch 'SHA-256 verified') {
    throw 'Only the existing SHA-256-verified Temurin JRE 11.0.32.1 may be copied into the new engine.'
}

Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
$engineArchive = [System.IO.Compression.ZipFile]::OpenRead($sourceEngineJar)
try {
    $manifestEntry = $engineArchive.GetEntry('META-INF/MANIFEST.MF')
    if ($null -eq $manifestEntry) { throw 'The reference server.jar has no Java manifest.' }
    $stream = $manifestEntry.Open()
    try {
        $reader = New-Object System.IO.StreamReader($stream)
        try { $engineManifest = $reader.ReadToEnd() }
        finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
}
finally { $engineArchive.Dispose() }
if ($engineManifest -notmatch '(?m)^Implementation-Title: Mohist\s*$' -or
    $engineManifest -notmatch '(?m)^Implementation-Version: 1\.16\.5-1242\s*$' -or
    $engineManifest -notmatch '(?m)^Implementation-Version: 36\.2\.42\s*$') {
    throw 'The reference engine is not the validated Mohist 1.16.5-1242 / Forge 36.2.42 distribution.'
}

$manifest = Read-MrpackManifest -Path $resolvedPack
$dependencies = Get-PropertyValue -Object $manifest -Name 'dependencies'
$minecraftVersion = [string](Get-PropertyValue -Object $dependencies -Name 'minecraft')
$forgeVersion = [string](Get-PropertyValue -Object $dependencies -Name 'forge')
if ($minecraftVersion -ne '1.16.5' -or $forgeVersion -ne '36.2.42') {
    throw "The pack targets Minecraft $minecraftVersion / Forge $forgeVersion, which does not match this Mohist engine."
}
$manifestMods = @()
foreach ($file in @(Get-PropertyValue -Object $manifest -Name 'files')) {
    $path = [string](Get-PropertyValue -Object $file -Name 'path')
    if ($path -match '(?i)^mods/.+\.jar$') { $manifestMods += $file }
}
if ($manifestMods.Count -eq 0) { throw 'The exact pack contains no manifest-listed mods.' }

$stagingPath = Join-Path $resolvedOutputParent ('.' + $OutputName + '-staging-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stagingPath -Force | Out-Null
$allMods = [System.Collections.Generic.List[object]]::new()
$buildNotes = [System.Collections.Generic.List[string]]::new()
$modsDirectory = Join-Path $stagingPath 'mods'
$clientModsDirectory = Join-Path $stagingPath 'client-only-mods'
New-Item -ItemType Directory -Path $modsDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $clientModsDirectory -Force | Out-Null

try {
    Copy-Item -LiteralPath $sourceEngineJar -Destination (Join-Path $stagingPath 'server.jar') -Force
    $sourceLibraries = Join-Path $sourceEngineFolder 'libraries'
    if (Test-Path -LiteralPath $sourceLibraries -PathType Container) {
        Copy-Item -LiteralPath $sourceLibraries -Destination (Join-Path $stagingPath 'libraries') -Recurse -Force
        $buildNotes.Add('Copied the matching Mohist library cache from the reference engine.')
    }
    else {
        $buildNotes.Add('No reference libraries directory was present; Mohist may bootstrap dependencies on first start.')
    }

    $runtimeDestination = Join-Path $stagingPath 'runtime'
    New-Item -ItemType Directory -Path $runtimeDestination -Force | Out-Null
    Copy-Item -Path (Join-Path $resolvedRuntimeSource '*') -Destination $runtimeDestination -Recurse -Force
    $copiedRuntimeNote = Get-Content -LiteralPath (Join-Path $runtimeDestination 'JAVA-VERSION.txt') -Raw
    if ($copiedRuntimeNote -notmatch 'Temurin JRE 11\.0\.32\.1' -or $copiedRuntimeNote -notmatch 'SHA-256 verified') {
        throw 'The copied Java runtime verification marker did not match the approved portable runtime.'
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $indexNumber = 0
    foreach ($file in $manifestMods) {
        $indexNumber++
        $sourcePath = [string](Get-PropertyValue -Object $file -Name 'path')
        $fileName = [System.IO.Path]::GetFileName($sourcePath)
        $clientOnly = Test-ClientOnlyMod -FileName $fileName
        $targetFolderName = if ($clientOnly) { 'client-only-mods' } else { 'mods' }
        $targetDirectory = if ($clientOnly) { $clientModsDirectory } else { $modsDirectory }
        Write-Host ("Downloading verified manifest mod {0}/{1}: {2} -> {3}" -f $indexNumber, $manifestMods.Count, $fileName, $targetFolderName)
        $record = Download-ModFile -FileRecord $file -Destination $targetDirectory -TargetDirectoryName $targetFolderName
        $allMods.Add($record)
    }

    $overrideResult = Copy-PackOverrides -PackPath $resolvedPack -Destination $stagingPath -ModsDirectory $modsDirectory -ClientModsDirectory $clientModsDirectory
    foreach ($record in $overrideResult.embeddedMods) { $allMods.Add($record) }
    $serverLoadedCount = @($allMods | Where-Object { $_.loadOnServer }).Count
    $clientOnlyCount = @($allMods | Where-Object { -not $_.loadOnServer }).Count
    $buildNotes.Add('Copied ' + $overrideResult.configFiles.Count + ' safe config/defaultconfig/KubeJS/script/datapack override files.')
    $buildNotes.Add("Loaded $serverLoadedCount server-compatible mod JARs in mods/; preserved $clientOnlyCount client-only JARs under client-only-mods/ after the full-pack failure identified dedicated-server-only class references.")

    $properties = @(
        '# FunCity Engine — full Freeroam modpack test instance',
        'motd=FunCity Engine | Freeroam 1.0.0 | test',
        "server-port=$Port",
        'server-ip=',
        'online-mode=true',
        'max-players=10',
        'view-distance=6',
        'network-compression-threshold=256',
        'spawn-protection=0',
        'allow-flight=true',
        'enable-status=true',
        'max-tick-time=60000'
    )
    Set-Content -LiteralPath (Join-Path $stagingPath 'server.properties') -Value $properties -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $stagingPath 'eula.txt') -Value @(
        '# The owner explicitly accepted the Minecraft EULA for this FunCity server.',
        'eula=true'
    ) -Encoding ASCII

    $javaOptions = @(
        '-Xms2G', "-Xmx${HeapGB}G", '-XX:+UseG1GC', '-XX:+ParallelRefProcEnabled',
        '-XX:MaxGCPauseMillis=200', '-XX:+UnlockExperimentalVMOptions',
        '-XX:+DisableExplicitGC', '-XX:G1NewSizePercent=30', '-XX:G1MaxNewSizePercent=40',
        '-XX:G1ReservePercent=20', '-XX:G1HeapWastePercent=5', '-XX:G1MixedGCCountTarget=4',
        '-XX:InitiatingHeapOccupancyPercent=15', '-XX:G1MixedGCLiveThresholdPercent=90',
        '-XX:G1RSetUpdatingPauseTimePercent=5'
    )
    $startBat = @"
@echo off
setlocal
cd /d "%~dp0"
set "JAVA_EXE=%~dp0runtime\bin\java.exe"
if not exist "%JAVA_EXE%" (
  echo Bundled Java 11 runtime was not found.
  pause
  exit /b 1
)
findstr /i /x /c:"eula=true" eula.txt >nul
if errorlevel 1 (
  echo EULA is not accepted. Read https://aka.ms/MinecraftEULA and set eula=true only if you agree.
  pause
  exit /b 1
)
"%JAVA_EXE%" $($javaOptions -join ' ') -Dfuncity.instance=FunCity-Freeroam-Engine -jar server.jar nogui
pause
"@
    Set-Content -LiteralPath (Join-Path $stagingPath 'start.bat') -Value $startBat -Encoding ASCII

    $inventory = [pscustomobject]@{
        pack = [System.IO.Path]::GetFileName($resolvedPack)
        packName = [string](Get-PropertyValue -Object $manifest -Name 'name')
        packVersion = [string](Get-PropertyValue -Object $manifest -Name 'versionId')
        minecraft = $minecraftVersion
        forge = $forgeVersion
        engine = 'Mohist 1.16.5-1242 / Forge 36.2.42'
        port = $Port
        heapGB = $HeapGB
        sourceModJarCount = $allMods.Count
        serverModJarCount = $serverLoadedCount
        clientOnlyModJarCount = $clientOnlyCount
        mods = @($allMods)
    }
    Set-Content -LiteralPath (Join-Path $stagingPath 'pack-mod-inventory.json') -Value (ConvertTo-Json -InputObject $inventory -Depth 8) -Encoding UTF8

    $readme = [System.Collections.Generic.List[string]]::new()
    $readme.Add('FunCity Engine — Freeroam full-pack test')
    $readme.Add('')
    $readme.Add('A branded FunCity server distribution based on the matching Hypecity Mohist hybrid engine. This is a custom packaging/configuration around Mohist/Forge, not a from-scratch replacement for Minecraft or Forge.')
    $readme.Add("Pack: $([System.IO.Path]::GetFileName($resolvedPack)); Minecraft $minecraftVersion; Forge $forgeVersion.")
    $readme.Add("Engine: Mohist 1.16.5-1242; test port $Port; heap maximum ${HeapGB} GB.")
    $readme.Add('')
    $readme.Add("All $($allMods.Count) pack mod JARs are retained in this engine. $serverLoadedCount server-compatible mods are in mods/; $clientOnlyCount render/account-switcher mods are in client-only-mods/ and are deliberately not loaded by a dedicated server because the first test reported invalid DEDICATED_SERVER client-class references.")
    $readme.Add('No additional plugins were added, so this test isolates the pack and hybrid engine.')
    $readme.Add('The server uses only the copied, checksum-verified portable Temurin JRE 11.0.32.1. start.bat has no system-Java fallback.')
    $readme.Add('The owner explicitly accepted the Minecraft EULA; eula.txt is true for this instance.')
    $readme.Add('No firewall rules, router settings, or files outside the FunCity project were changed.')
    Set-Content -LiteralPath (Join-Path $stagingPath 'README-FUNCITY-ENGINE.txt') -Value $readme -Encoding UTF8

    $report = [System.Collections.Generic.List[string]]::new()
    $report.Add('Build result: complete')
    $report.Add('Pack: ' + [System.IO.Path]::GetFileName($resolvedPack) + ' | ' + [string](Get-PropertyValue -Object $manifest -Name 'name') + ' ' + [string](Get-PropertyValue -Object $manifest -Name 'versionId'))
    $report.Add("Engine: Mohist 1.16.5-1242 / Forge 36.2.42; port=$Port; heap-max=${HeapGB} GB")
    $report.Add('Manifest mod JARs downloaded and hash-verified: ' + $manifestMods.Count)
    foreach ($record in @($allMods | Where-Object { $_.source -eq 'modrinth.index.json' })) {
        $report.Add("  mod: $($record.file) | server=$($record.serverEnvironment) | load-on-server=$($record.loadOnServer) | destination=$($record.relativeDestination) | SHA-256=$($record.sha256)")
    }
    $report.Add('Embedded override mod JARs copied and validated: ' + $overrideResult.embeddedMods.Count)
    foreach ($record in $overrideResult.embeddedMods) {
        $report.Add("  embedded mod: $($record.file) | from=$($record.packPath) | load-on-server=$($record.loadOnServer) | destination=$($record.relativeDestination) | SHA-256=$($record.sha256)")
    }
    $report.Add('All pack mod JARs retained: ' + $allMods.Count)
    $report.Add('Server-loaded JARs in mods/: ' + $serverLoadedCount)
    $report.Add('Client-only JARs preserved outside mods/: ' + $clientOnlyCount)
    $report.Add('No extra plugins were copied; this is an isolated modpack test.')
    foreach ($note in $buildNotes) { $report.Add('Note: ' + $note) }
    $report.Add('EULA: true (accepted by owner).')
    Set-Content -LiteralPath (Join-Path $stagingPath 'BUILD-REPORT.txt') -Value $report -Encoding UTF8

    [System.IO.Directory]::Move($stagingPath, $finalPath)
    Write-Host "FunCity full-pack test engine prepared at: $finalPath"
    Write-Host "Manifest mods=$($manifestMods.Count); embedded override mods=$($overrideResult.embeddedMods.Count); server-loaded=$serverLoadedCount; client-only-preserved=$clientOnlyCount; total-pack-mods=$($allMods.Count); port=$Port; Java=portable Temurin 11.0.32.1."
    Write-Output "::notice title=FunCity full-pack engine build::Output=$finalPath; manifest-mods=$($manifestMods.Count); embedded-mods=$($overrideResult.embeddedMods.Count); server-loaded=$serverLoadedCount; client-only-preserved=$clientOnlyCount; total-pack-mods=$($allMods.Count); port=$Port; engine=Mohist-1.16.5-1242/Forge-36.2.42; Java=portable-Temurin-11.0.32.1"
}
catch {
    $failureReport = Join-Path $stagingPath 'BUILD-FAILED.txt'
    Set-Content -LiteralPath $failureReport -Value $_.Exception.Message -Encoding UTF8 -ErrorAction SilentlyContinue
    throw
}
