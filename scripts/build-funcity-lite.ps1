[CmdletBinding()]
param(
    [string]$ProjectRoot = 'E:\Administrator\Desktop\FunCity',
    [string]$ReferencePath = 'E:\Administrator\Desktop\FunCity\servere referinta',
    [string]$OutputParent = 'E:\Administrator\Desktop\FunCity\FunCity server',
    [string]$OutputName = 'FunCity-Lite'
)

# Builds a clean, separate FunCity Lite server. The reference folders are read
# only. The new server is staged first and moved into place only after success.
$ErrorActionPreference = 'Stop'

function Get-PropertyValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Find-FreeroamPack {
    param([string[]]$Roots)
    $skipNames = @('.git', 'assets', 'backups', 'cache', 'crash-reports', 'libraries', 'logs', 'mods', 'plugins', 'saves', 'world', 'world_nether', 'world_the_end')
    $matches = [System.Collections.Generic.List[string]]::new()
    foreach ($root in ($Roots | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $queue = [System.Collections.Generic.Queue[string]]::new()
        $queue.Enqueue($root)
        $visited = 0
        while ($queue.Count -gt 0 -and $visited -lt 5000) {
            $current = $queue.Dequeue()
            $visited++
            foreach ($file in @(Get-ChildItem -LiteralPath $current -File -Filter 'Freeroam 1.0.0.mrpack' -ErrorAction SilentlyContinue)) {
                if (-not $matches.Contains($file.FullName)) { $matches.Add($file.FullName) }
            }
            foreach ($child in (Get-ChildItem -LiteralPath $current -Directory -Force -ErrorAction SilentlyContinue)) {
                if ($skipNames -notcontains $child.Name) { $queue.Enqueue($child.FullName) }
            }
        }
    }
    if ($matches.Count -eq 0) { throw 'Freeroam 1.0.0.mrpack was not found in the project/reference folders.' }
    if ($matches.Count -gt 1) { throw 'More than one Freeroam 1.0.0.mrpack was found; keep one copy in the project folder.' }
    return $matches[0]
}

function Read-MrpackManifest {
    param([string]$PackPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $zip = [System.IO.Compression.ZipFile]::OpenRead($PackPath)
    try {
        $entry = $zip.GetEntry('modrinth.index.json')
        if ($null -eq $entry) { throw 'The .mrpack is missing modrinth.index.json.' }
        $stream = $entry.Open()
        try {
            $reader = New-Object System.IO.StreamReader($stream)
            try { return ConvertFrom-Json -InputObject $reader.ReadToEnd() -ErrorAction Stop }
            finally { $reader.Dispose() }
        }
        finally { $stream.Dispose() }
    }
    finally { $zip.Dispose() }
}

function Copy-PackServerOverrides {
    param([string]$PackPath, [string]$Destination)
    $copied = [System.Collections.Generic.List[string]]::new()
    $allowedRoots = @('config/', 'defaultconfigs/', 'kubejs/', 'scripts/')
    $zip = [System.IO.Compression.ZipFile]::OpenRead($PackPath)
    try {
        # Apply regular overrides first, then server-overrides so the server-specific
        # values win. Client options, shaders, and resource packs are not copied.
        foreach ($prefix in @('overrides/', 'server-overrides/')) {
            foreach ($entry in $zip.Entries) {
                if ($entry.FullName.EndsWith('/')) { continue }
                if (-not $entry.FullName.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                $relative = $entry.FullName.Substring($prefix.Length).Replace('\', '/')
                if ($relative -match '(^|/)\.\.(/|$)' -or [System.IO.Path]::IsPathRooted($relative)) { throw 'Unsafe path in pack override.' }
                if (-not ($allowedRoots | Where-Object { $relative.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) })) { continue }
                $relativeWindows = $relative.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
                $destinationFile = [System.IO.Path]::GetFullPath((Join-Path $Destination $relativeWindows))
                $destinationPrefix = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
                if (-not $destinationFile.StartsWith($destinationPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Override path escaped the server directory.' }
                $parent = Split-Path -Parent $destinationFile
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
                $input = $entry.Open()
                $output = [System.IO.File]::Create($destinationFile)
                try { $input.CopyTo($output) }
                finally { $output.Dispose(); $input.Dispose() }
                $copied.Add($relative)
            }
        }
    }
    finally { $zip.Dispose() }
    return @($copied)
}

function Download-ModFile {
    param($FileRecord, [string]$Destination)
    $path = [string](Get-PropertyValue -Object $FileRecord -Name 'path')
    $fileName = [System.IO.Path]::GetFileName($path)
    if ([string]::IsNullOrWhiteSpace($fileName) -or $fileName -notmatch '(?i)\.jar$') { throw "Invalid mod filename in pack: $path" }

    $downloads = @(Get-PropertyValue -Object $FileRecord -Name 'downloads')
    if ($downloads.Count -eq 0) { throw "No download URL is listed for $fileName" }
    $hashes = Get-PropertyValue -Object $FileRecord -Name 'hashes'
    $expectedSize = Get-PropertyValue -Object $FileRecord -Name 'fileSize'
    $destinationFile = Join-Path $Destination $fileName
    $lastError = $null
    $downloaded = $false

    foreach ($url in $downloads) {
        if (-not ([string]$url).StartsWith('https://', [System.StringComparison]::OrdinalIgnoreCase)) {
            $lastError = 'Rejected a non-HTTPS mod URL.'
            continue
        }
        for ($attempt = 1; $attempt -le 3 -and -not $downloaded; $attempt++) {
            try {
                Invoke-WebRequest -Uri ([string]$url) -OutFile $destinationFile -UseBasicParsing -TimeoutSec 180 -Headers @{ 'User-Agent' = 'FunCity-Engine-Lite/0.1' }
                $downloaded = $true
            }
            catch {
                $lastError = $_.Exception.Message
                if (Test-Path -LiteralPath $destinationFile) { Remove-Item -LiteralPath $destinationFile -Force -ErrorAction SilentlyContinue }
                Start-Sleep -Seconds ([Math]::Min(2 * $attempt, 6))
            }
        }
        if ($downloaded) { break }
    }
    if (-not $downloaded) { throw "Could not download $fileName. $lastError" }

    $downloadedFile = Get-Item -LiteralPath $destinationFile
    if ($null -ne $expectedSize -and [long]$expectedSize -gt 0 -and $downloadedFile.Length -ne [long]$expectedSize) {
        throw "File size verification failed for $fileName."
    }
    $expectedSha512 = [string](Get-PropertyValue -Object $hashes -Name 'sha512')
    $expectedSha1 = [string](Get-PropertyValue -Object $hashes -Name 'sha1')
    if (-not [string]::IsNullOrWhiteSpace($expectedSha512)) {
        $actual = (Get-FileHash -LiteralPath $destinationFile -Algorithm SHA512).Hash.ToLowerInvariant()
        if ($actual -ne $expectedSha512.ToLowerInvariant()) { throw "SHA-512 verification failed for $fileName." }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($expectedSha1)) {
        $actual = (Get-FileHash -LiteralPath $destinationFile -Algorithm SHA1).Hash.ToLowerInvariant()
        if ($actual -ne $expectedSha1.ToLowerInvariant()) { throw "SHA-1 verification failed for $fileName." }
    }
    else {
        throw "No supported hash is present for $fileName; refusing an unverified download."
    }
    return $fileName
}

$reference = Get-Item -LiteralPath $ReferencePath -ErrorAction Stop
if (-not $reference.PSIsContainer) { throw "ReferencePath must be a folder: $ReferencePath" }
$sourceEngineFolder = Join-Path $reference.FullName 'hypecity'
$sourceEngineJar = Join-Path $sourceEngineFolder 'server.jar'
if (-not (Test-Path -LiteralPath $sourceEngineJar -PathType Leaf)) { throw 'The matching Hypecity Mohist server.jar was not found.' }

$projectRootResolved = (Get-Item -LiteralPath $ProjectRoot -ErrorAction Stop).FullName
$outputParentResolved = (Get-Item -LiteralPath $OutputParent -ErrorAction Stop).FullName
$finalPath = Join-Path $outputParentResolved $OutputName
if (Test-Path -LiteralPath $finalPath) { throw "Refusing to overwrite existing server folder: $finalPath" }

$packPath = Find-FreeroamPack -Roots @($projectRootResolved, $reference.FullName, $outputParentResolved)
$manifest = Read-MrpackManifest -PackPath $packPath
$dependencies = Get-PropertyValue -Object $manifest -Name 'dependencies'
$minecraftVersion = [string](Get-PropertyValue -Object $dependencies -Name 'minecraft')
$forgeVersion = [string](Get-PropertyValue -Object $dependencies -Name 'forge')
if ($minecraftVersion -ne '1.16.5' -or $forgeVersion -ne '36.2.42') {
    throw "Unexpected pack target $minecraftVersion / Forge $forgeVersion; the selected Mohist engine is only validated for 1.16.5 / 36.2.42."
}

Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
$engineZip = [System.IO.Compression.ZipFile]::OpenRead($sourceEngineJar)
try {
    $manifestEntry = $engineZip.GetEntry('META-INF/MANIFEST.MF')
    if ($null -eq $manifestEntry) { throw 'The Hypecity server.jar has no manifest; refusing to use it as the engine.' }
    $stream = $manifestEntry.Open()
    try {
        $reader = New-Object System.IO.StreamReader($stream)
        try { $engineManifest = $reader.ReadToEnd() }
        finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
}
finally { $engineZip.Dispose() }
if ($engineManifest -notmatch '(?m)^Implementation-Title: Mohist\s*$' -or
    $engineManifest -notmatch '(?m)^Implementation-Version: 1\.16\.5-1242\s*$' -or
    $engineManifest -notmatch '(?m)^Implementation-Version: 36\.2\.42\s*$') {
    throw 'Hypecity server.jar is not the expected Mohist 1.16.5-1242 / Forge 36.2.42 build.'
}

$stagingPath = Join-Path $outputParentResolved ('.' + $OutputName + '-staging-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stagingPath -Force | Out-Null
$buildNotes = [System.Collections.Generic.List[string]]::new()
$downloadedMods = [System.Collections.Generic.List[string]]::new()
$excludedClientMods = [System.Collections.Generic.List[string]]::new()
$copiedPlugins = [System.Collections.Generic.List[string]]::new()
$missingPlugins = [System.Collections.Generic.List[string]]::new()

try {
    Copy-Item -LiteralPath $sourceEngineJar -Destination (Join-Path $stagingPath 'server.jar') -Force
    $buildNotes.Add('Engine: Mohist 1.16.5-1242; embedded Forge 36.2.42 (copied from the matching Hypecity reference server).')
    $sourceLibraries = Join-Path $sourceEngineFolder 'libraries'
    if (Test-Path -LiteralPath $sourceLibraries -PathType Container) {
        Copy-Item -LiteralPath $sourceLibraries -Destination (Join-Path $stagingPath 'libraries') -Recurse -Force
        $buildNotes.Add('Copied the engine library cache from the reference server.')
    }
    else {
        $buildNotes.Add('No libraries directory was present beside the reference engine jar.')
    }

    $modsDirectory = Join-Path $stagingPath 'mods'
    New-Item -ItemType Directory -Path $modsDirectory -Force | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $clientOnlyPattern = '(?i)(rubidium|oculus|textruesrubidiumoptions|ingameaccountswitcher)'
    foreach ($file in @(Get-PropertyValue -Object $manifest -Name 'files')) {
        $relativePath = [string](Get-PropertyValue -Object $file -Name 'path')
        if ($relativePath -notmatch '(?i)^mods/.+\.jar$') { continue }
        $fileEnvironment = Get-PropertyValue -Object $file -Name 'env'
        $serverEnvironment = [string](Get-PropertyValue -Object $fileEnvironment -Name 'server')
        $fileName = [System.IO.Path]::GetFileName($relativePath)
        if ($serverEnvironment -eq 'unsupported' -or $fileName -match $clientOnlyPattern) {
            $excludedClientMods.Add($fileName)
            continue
        }
        $downloadedName = Download-ModFile -FileRecord $file -Destination $modsDirectory
        $downloadedMods.Add($downloadedName)
    }
    if ($downloadedMods.Count -eq 0) { throw 'No server-compatible mods were downloaded from the pack.' }

    $copiedOverrides = Copy-PackServerOverrides -PackPath $packPath -Destination $stagingPath
    $buildNotes.Add('Applied ' + $copiedOverrides.Count + ' server-safe config/override files from the pack.')

    $pluginsDirectory = Join-Path $stagingPath 'plugins'
    New-Item -ItemType Directory -Path $pluginsDirectory -Force | Out-Null
    $sourcePlugins = Join-Path $sourceEngineFolder 'plugins'
    $preferredPlugins = @(
        'LuckPerms-Bukkit-5.4.131.jar',
        'EssentialsX-2.20.1.jar',
        'EssentialsXChat-2.20.1.jar',
        'EssentialsXSpawn-2.20.1.jar',
        'Vault.jar',
        'PlaceholderAPI-2.11.6.jar',
        'spark-1.10.92-bukkit.jar',
        'Chunky-1.2.164.jar'
    )
    foreach ($pluginName in $preferredPlugins) {
        $pluginSource = Join-Path $sourcePlugins $pluginName
        if (Test-Path -LiteralPath $pluginSource -PathType Leaf) {
            Copy-Item -LiteralPath $pluginSource -Destination (Join-Path $pluginsDirectory $pluginName) -Force
            $copiedPlugins.Add($pluginName)
        }
        else {
            $missingPlugins.Add($pluginName)
        }
    }

    $properties = @(
        '# FunCity Engine Lite — tuned for a small Forge 1.16.5 server',
        'motd=FunCity Lite | Minecraft 1.16.5',
        'server-port=25565',
        'server-ip=',
        'online-mode=true',
        'max-players=20',
        'view-distance=6',
        'network-compression-threshold=256',
        'spawn-protection=0',
        'allow-flight=true',
        'enable-status=true',
        'max-tick-time=60000'
    )
    Set-Content -LiteralPath (Join-Path $stagingPath 'server.properties') -Value $properties -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $stagingPath 'eula.txt') -Value @(
        '# Read https://aka.ms/MinecraftEULA. Set eula=true only if you agree.',
        'eula=false'
    ) -Encoding ASCII

    $startBat = @'
@echo off
setlocal
cd /d "%~dp0"
where java >nul 2>&1
if errorlevel 1 (
  echo Java 8 or newer was not found on PATH. Install a 64-bit Java runtime, then retry.
  pause
  exit /b 1
)
findstr /i /x /c:"eula=true" eula.txt >nul
if errorlevel 1 (
  echo EULA is not accepted. Read https://aka.ms/MinecraftEULA and set eula=true in eula.txt only if you agree.
  pause
  exit /b 1
)
java -Xms2G -Xmx4G -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 -XX:G1RSetUpdatingPauseTimePercent=5 -jar server.jar nogui
pause
'@
    Set-Content -LiteralPath (Join-Path $stagingPath 'start.bat') -Value $startBat -Encoding ASCII

    $readme = [System.Collections.Generic.List[string]]::new()
    $readme.Add('FunCity Engine Lite')
    $readme.Add('')
    $readme.Add('Minecraft 1.16.5 | Forge 36.2.42 | hybrid core: Mohist 1.16.5-1242')
    $readme.Add('Base pack: Freeroam 1.0.0.mrpack (PL2 Gambo 1.0.0).')
    $readme.Add('This is a custom FunCity distribution around the matching Mohist hybrid engine, not a from-scratch replacement for Minecraft/Forge.')
    $readme.Add('')
    $readme.Add('Server mods installed (' + $downloadedMods.Count + '):')
    foreach ($name in $downloadedMods) { $readme.Add('  ' + $name) }
    $readme.Add('Client-only/rendering mods intentionally omitted from the server (' + $excludedClientMods.Count + '):')
    foreach ($name in $excludedClientMods) { $readme.Add('  ' + $name) }
    $readme.Add('')
    $readme.Add('Minimal plugin set copied from Hypecity (' + $copiedPlugins.Count + '):')
    foreach ($name in $copiedPlugins) { $readme.Add('  ' + $name) }
    if ($missingPlugins.Count) {
        $readme.Add('Plugins not present in the reference folder:')
        foreach ($name in $missingPlugins) { $readme.Add('  ' + $name) }
    }
    $readme.Add('')
    $readme.Add('Performance baseline: FerriteCore and ModernFix are included by the pack; view-distance is 6; start.bat uses a 2-4 GB G1GC low-pause profile with heap-occupancy tuning. Measure live MSPT with spark after owner-approved startup.')
    $readme.Add('No world, logs, old configs, account data, or old plugin configs were copied.')
    $readme.Add('EULA is deliberately false. Set eula=true yourself only after reading and accepting the Minecraft EULA.')
    $readme.Add('No firewall rules or router port forwarding were changed.')
    Set-Content -LiteralPath (Join-Path $stagingPath 'README-FUNCITY.txt') -Value $readme -Encoding UTF8

    $report = [System.Collections.Generic.List[string]]::new()
    $report.Add('Build result: complete')
    $report.Add('Pack: ' + [System.IO.Path]::GetFileName($packPath) + ' | Minecraft ' + $minecraftVersion + ' | Forge ' + $forgeVersion)
    $report.Add('Engine: Mohist 1.16.5-1242')
    $report.Add('Performance profile: G1GC tuned for a 2-4 GB heap; view-distance=6; live MSPT still requires a running, owner-approved server.')
    foreach ($note in $buildNotes) { $report.Add('Note: ' + $note) }
    $report.Add('Server mods downloaded and hash-verified: ' + $downloadedMods.Count)
    foreach ($name in $downloadedMods) { $report.Add('  mod: ' + $name) }
    $report.Add('Client-only mods omitted: ' + ($excludedClientMods -join ', '))
    $report.Add('Plugins copied: ' + ($copiedPlugins -join ', '))
    if ($missingPlugins.Count) { $report.Add('Plugin files absent from the reference folder: ' + ($missingPlugins -join ', ')) }
    $report.Add('EULA: false (awaiting owner acceptance)')
    Set-Content -LiteralPath (Join-Path $stagingPath 'BUILD-REPORT.txt') -Value $report -Encoding UTF8

    [System.IO.Directory]::Move($stagingPath, $finalPath)
    Write-Host "FunCity Lite server prepared at: $finalPath"
    Write-Host "Mods installed: $($downloadedMods.Count); plugins copied: $($copiedPlugins.Count)."
    Write-Host 'Server was not started because eula.txt remains eula=false until the owner accepts the EULA.'
}
catch {
    $failureReport = Join-Path $stagingPath 'BUILD-FAILED.txt'
    Set-Content -LiteralPath $failureReport -Value $_.Exception.Message -Encoding UTF8 -ErrorAction SilentlyContinue
    throw
}
