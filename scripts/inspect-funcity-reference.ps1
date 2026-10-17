[CmdletBinding()]
param(
    [string]$ReferencePath = 'E:\Administrator\Desktop\FunCity\servere referinta',
    [string]$DestinationPath = 'E:\Administrator\Desktop\FunCity\FunCity server',
    [int]$MaxDirectories = 5000,
    [int]$MaxJarNamesPerFolder = 500
)

# Read-only inventory for the reference server. It does not start jars, extract
# archives, copy server files, or read configs that may contain secrets.
$ErrorActionPreference = 'Stop'

function Get-PropertyValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Add-UniqueString {
    param([System.Collections.Generic.List[string]]$List, [string]$Value)
    if (-not [string]::IsNullOrWhiteSpace($Value) -and -not $List.Contains($Value)) {
        $List.Add($Value)
    }
}

function Get-RelativePath {
    param([string]$Root, [string]$Path)
    $normalizedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $normalizedPath = [System.IO.Path]::GetFullPath($Path)
    if ($normalizedPath.Equals($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return '.'
    }
    $prefix = $normalizedRoot + [System.IO.Path]::DirectorySeparatorChar
    if ($normalizedPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $normalizedPath.Substring($prefix.Length)
    }
    return $normalizedPath
}

function Read-JsonFile {
    param([string]$Path)
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ConvertFrom-Json -InputObject $raw -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Get-ServerDirectories {
    param([string]$Root, [int]$Limit)

    $skipNames = @(
        '.git', '.gradle', '.idea', '.vscode', 'assets', 'backups', 'cache',
        'crash-reports', 'libraries', 'logs', 'mods', 'plugins', 'saves',
        'screenshots', 'world', 'world_nether', 'world_the_end'
    )
    $markers = @(
        'mods', 'plugins', 'manifest.json', 'modrinth.index.json',
        'mmc-pack.json', 'server.jar', 'fabric-server-launch.jar',
        'run.bat', 'start.bat', 'start.cmd'
    )

    $queue = [System.Collections.Generic.Queue[string]]::new()
    $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $found = [System.Collections.Generic.List[string]]::new()
    $queue.Enqueue($Root)

    while ($queue.Count -gt 0 -and $visited.Count -lt $Limit) {
        $current = $queue.Dequeue()
        if (-not $visited.Add($current)) { continue }

        $isServer = $false
        foreach ($marker in $markers) {
            $markerPath = Join-Path $current $marker
            if (Test-Path -LiteralPath $markerPath) {
                $isServer = $true
                break
            }
        }
        if ($isServer) { $found.Add($current) }

        $children = Get-ChildItem -LiteralPath $current -Directory -Force -ErrorAction SilentlyContinue
        foreach ($child in $children) {
            if ($skipNames -contains $child.Name) { continue }
            $queue.Enqueue($child.FullName)
        }
    }

    return @($found | Select-Object -Unique)
}

function Get-JarInventory {
    param([string]$Folder, [int]$Limit)
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) {
        return [pscustomobject]@{ count = 0; names = @(); truncated = $false }
    }
    $jars = @(Get-ChildItem -LiteralPath $Folder -File -Filter '*.jar' -ErrorAction SilentlyContinue | Sort-Object Name)
    $names = @($jars | Select-Object -First $Limit | ForEach-Object { $_.Name })
    return [pscustomobject]@{
        count = $jars.Count
        names = $names
        truncated = ($jars.Count -gt $Limit)
    }
}

function Get-ServerJarDetails {
    param([string]$JarPath, [string]$ReferenceRoot)

    $manifestFields = [System.Collections.Generic.List[string]]::new()
    $pomCoordinates = [System.Collections.Generic.List[string]]::new()
    $modIds = [System.Collections.Generic.List[string]]::new()
    $entryMarkers = [System.Collections.Generic.List[string]]::new()
    $inspectionError = $null
    $jar = Get-Item -LiteralPath $JarPath -ErrorAction Stop
    $archive = $null

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $archive = [System.IO.Compression.ZipFile]::OpenRead($JarPath)

        $manifestEntry = $archive.GetEntry('META-INF/MANIFEST.MF')
        if ($null -ne $manifestEntry) {
            $manifestStream = $manifestEntry.Open()
            try {
                $reader = New-Object System.IO.StreamReader($manifestStream)
                $text = $reader.ReadToEnd()
                $reader.Dispose()
            }
            finally { $manifestStream.Dispose() }
            foreach ($line in ($text -split "`r?`n" | Where-Object { $_ -match '^(Main-Class|Implementation-(Title|Version|Vendor)|Specification-(Title|Version)|Created-By|Build-Jdk):' })) {
                $manifestFields.Add($line.Trim())
            }
        }

        $modsTomlEntry = $archive.GetEntry('META-INF/mods.toml')
        if ($null -ne $modsTomlEntry) {
            $modsStream = $modsTomlEntry.Open()
            try {
                $reader = New-Object System.IO.StreamReader($modsStream)
                $modsText = $reader.ReadToEnd()
                $reader.Dispose()
            }
            finally { $modsStream.Dispose() }
            foreach ($match in [regex]::Matches($modsText, '(?m)^\s*modId\s*=\s*"([^"]+)"')) {
                Add-UniqueString -List $modIds -Value $match.Groups[1].Value
            }
        }

        $pomEntries = @($archive.Entries | Where-Object {
            $_.FullName -match '(?i)^META-INF/maven/.+/pom\.properties$' -and
            $_.FullName -match '(?i)(mohist|arclight|magma|forge|bukkit|spigot|paper|sponge|catserver)'
        } | Select-Object -First 20)
        foreach ($entry in $pomEntries) {
            $pomStream = $entry.Open()
            try {
                $reader = New-Object System.IO.StreamReader($pomStream)
                $pomText = $reader.ReadToEnd()
                $reader.Dispose()
            }
            finally { $pomStream.Dispose() }
            $coordinates = @($pomText -split "`r?`n" | Where-Object { $_ -match '^(groupId|artifactId|version)=' })
            if ($coordinates.Count -gt 0) {
                $pomCoordinates.Add($entry.FullName + ': ' + ($coordinates -join ', '))
            }
        }

        foreach ($entry in ($archive.Entries | Where-Object {
            $_.FullName -match '(?i)(mohist|arclight|magma|banner|cardboard|sponge|catserver|thermos|paper|spigot|bukkit)'
        } | Select-Object -First 40)) {
            Add-UniqueString -List $entryMarkers -Value $entry.FullName
        }
    }
    catch {
        $inspectionError = $_.Exception.GetType().Name
    }
    finally {
        if ($null -ne $archive) { $archive.Dispose() }
    }

    return [pscustomobject]@{
        name = $jar.Name
        path = Get-RelativePath -Root $ReferenceRoot -Path $JarPath
        sizeBytes = $jar.Length
        manifestFields = @($manifestFields)
        embeddedModIds = @($modIds)
        enginePomCoordinates = @($pomCoordinates)
        engineEntryMarkers = @($entryMarkers)
        inspectionError = $inspectionError
    }
}

function Get-ServerMetadata {
    param([string]$ServerPath, [string]$ReferenceRoot, [int]$JarLimit)

    $minecraftVersions = [System.Collections.Generic.List[string]]::new()
    $loaders = [System.Collections.Generic.List[string]]::new()
    $manifestFiles = [System.Collections.Generic.List[string]]::new()
    $metadataNames = @('manifest.json', 'modrinth.index.json', 'mmc-pack.json')

    foreach ($name in $metadataNames) {
        $path = Join-Path $ServerPath $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $manifestFiles.Add((Get-RelativePath -Root $ReferenceRoot -Path $path))
        $doc = Read-JsonFile -Path $path
        if ($null -eq $doc) { continue }

        if ($name -eq 'manifest.json') {
            $minecraft = Get-PropertyValue -Object $doc -Name 'minecraft'
            $version = Get-PropertyValue -Object $minecraft -Name 'version'
            Add-UniqueString -List $minecraftVersions -Value ([string]$version)
            $modLoaders = Get-PropertyValue -Object $minecraft -Name 'modLoaders'
            foreach ($loader in @($modLoaders)) {
                $id = Get-PropertyValue -Object $loader -Name 'id'
                Add-UniqueString -List $loaders -Value ([string]$id)
            }
        }
        elseif ($name -eq 'modrinth.index.json') {
            $dependencies = Get-PropertyValue -Object $doc -Name 'dependencies'
            if ($null -ne $dependencies) {
                foreach ($dependency in $dependencies.PSObject.Properties) {
                    if ($dependency.Name -eq 'minecraft') {
                        Add-UniqueString -List $minecraftVersions -Value ([string]$dependency.Value)
                    }
                    elseif ($dependency.Name -in @('fabric-loader', 'forge', 'neoforge', 'quilt-loader')) {
                        Add-UniqueString -List $loaders -Value ($dependency.Name + ' ' + [string]$dependency.Value)
                    }
                }
            }
        }
        elseif ($name -eq 'mmc-pack.json') {
            $components = Get-PropertyValue -Object $doc -Name 'components'
            foreach ($component in @($components)) {
                $uid = [string](Get-PropertyValue -Object $component -Name 'uid')
                $version = [string](Get-PropertyValue -Object $component -Name 'version')
                if ($uid -eq 'net.minecraft') {
                    Add-UniqueString -List $minecraftVersions -Value $version
                }
                elseif ($uid -in @('net.minecraftforge', 'net.neoforged', 'net.fabricmc.fabric-loader', 'org.quiltmc.quilt-loader')) {
                    Add-UniqueString -List $loaders -Value ($uid + ' ' + $version)
                }
            }
        }
    }

    $mods = Get-JarInventory -Folder (Join-Path $ServerPath 'mods') -Limit $JarLimit
    $plugins = Get-JarInventory -Folder (Join-Path $ServerPath 'plugins') -Limit $JarLimit
    $rootFiles = @(Get-ChildItem -LiteralPath $ServerPath -File -Force -ErrorAction SilentlyContinue)
    $serverJars = @($rootFiles | Where-Object {
        $_.Extension -ieq '.jar' -and $_.Name -match '(?i)(server|minecraft|fabric|forge|neoforge|paper|spigot|purpur|arclight|mohist|banner)'
    } | Select-Object -ExpandProperty Name)
    $serverJarDetails = @(
        foreach ($serverJar in $serverJars) {
            Get-ServerJarDetails -JarPath (Join-Path $ServerPath $serverJar) -ReferenceRoot $ReferenceRoot
        }
    )
    $startupFiles = @($rootFiles | Where-Object {
        $_.Extension -in @('.bat', '.cmd', '.ps1', '.sh') -and $_.Name -match '(?i)(run|start|server|launch)'
    } | Select-Object -ExpandProperty Name)
    $presentFolders = @('mods', 'plugins', 'config', 'defaultconfigs', 'kubejs', 'scripts' | Where-Object {
        Test-Path -LiteralPath (Join-Path $ServerPath $_) -PathType Container
    })

    return [pscustomobject]@{
        path = Get-RelativePath -Root $ReferenceRoot -Path $ServerPath
        minecraftVersions = @($minecraftVersions)
        loaders = @($loaders)
        manifests = @($manifestFiles)
        foldersPresent = $presentFolders
        modJars = $mods
        pluginJars = $plugins
        serverJars = $serverJars
        serverJarDetails = $serverJarDetails
        startupScripts = $startupFiles
    }
}

$reference = Get-Item -LiteralPath $ReferencePath -ErrorAction Stop
if (-not $reference.PSIsContainer) {
    throw "ReferencePath must be a folder: $ReferencePath"
}
$destination = Get-Item -LiteralPath $DestinationPath -ErrorAction Stop
if (-not $destination.PSIsContainer) {
    throw "DestinationPath must be a folder: $DestinationPath"
}

$serverDirectories = Get-ServerDirectories -Root $reference.FullName -Limit $MaxDirectories
$servers = @(
    foreach ($serverDirectory in $serverDirectories) {
        Get-ServerMetadata -ServerPath $serverDirectory -ReferenceRoot $reference.FullName -JarLimit $MaxJarNamesPerFolder
    }
)

# List archive names and sizes in the reference root and detected server roots;
# archive contents are deliberately not extracted or executed.
$archiveRoots = @($reference.FullName) + @($serverDirectories)
$archiveFiles = [System.Collections.Generic.List[object]]::new()
foreach ($archiveRoot in ($archiveRoots | Select-Object -Unique)) {
    $items = Get-ChildItem -LiteralPath $archiveRoot -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '(?i)\.(zip|7z|tar|tgz|tar\.gz)$' }
    foreach ($item in $items) {
        $archiveFiles.Add([pscustomobject]@{
            path = Get-RelativePath -Root $reference.FullName -Path $item.FullName
            sizeBytes = $item.Length
        })
    }
}

$report = [pscustomobject]@{
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    referenceFolder = '.'
    notes = @(
        'Inventory only: no jars were run, archives were not extracted, and config file contents were not read.'
        'Worlds, logs, libraries, assets, caches, and account data were not scanned.'
    )
    scannedServerFolders = $servers
    archives = @($archiveFiles)
}

$jsonPath = Join-Path $destination.FullName 'funcity-reference-inventory.json'
$json = ConvertTo-Json -InputObject $report -Depth 10
Set-Content -LiteralPath $jsonPath -Value $json -Encoding UTF8

$summaryPath = Join-Path $destination.FullName 'funcity-reference-inventory.txt'
$summary = [System.Collections.Generic.List[string]]::new()
$summary.Add('FunCity reference inventory')
$summary.Add('Generated UTC: ' + $report.generatedAtUtc)
$summary.Add('Server folders found: ' + $servers.Count)
foreach ($server in $servers) {
    $summary.Add('')
    $summary.Add('Folder: ' + $server.path)
    $summary.Add('Minecraft: ' + $(if ($server.minecraftVersions.Count) { $server.minecraftVersions -join ', ' } else { 'not detected' }))
    $summary.Add('Loaders: ' + $(if ($server.loaders.Count) { $server.loaders -join ', ' } else { 'not detected' }))
    $summary.Add('Mods: ' + $server.modJars.count)
    foreach ($jar in $server.modJars.names) { $summary.Add('  mod: ' + $jar) }
    $summary.Add('Plugins: ' + $server.pluginJars.count)
    foreach ($jar in $server.pluginJars.names) { $summary.Add('  plugin: ' + $jar) }
    if ($server.serverJars.Count) { $summary.Add('Server jars: ' + ($server.serverJars -join ', ')) }
    foreach ($detail in $server.serverJarDetails) {
        $summary.Add('Server jar detail: ' + $detail.path + ' (' + $detail.sizeBytes + ' bytes)')
        foreach ($field in $detail.manifestFields) { $summary.Add('  manifest: ' + $field) }
        foreach ($coordinate in $detail.enginePomCoordinates) { $summary.Add('  engine coordinate: ' + $coordinate) }
        if ($detail.embeddedModIds.Count) { $summary.Add('  embedded mod IDs: ' + ($detail.embeddedModIds -join ', ')) }
        foreach ($marker in $detail.engineEntryMarkers) { $summary.Add('  engine marker: ' + $marker) }
        if ($detail.inspectionError) { $summary.Add('  inspection error: ' + $detail.inspectionError) }
    }
    if ($server.startupScripts.Count) { $summary.Add('Startup files: ' + ($server.startupScripts -join ', ')) }
    if ($server.manifests.Count) { $summary.Add('Manifests: ' + ($server.manifests -join ', ')) }
}
$summary.Add('')
$summary.Add('Archives found: ' + $archiveFiles.Count)
foreach ($archive in $archiveFiles) {
    $summary.Add(('  {0} ({1} bytes)' -f $archive.path, $archive.sizeBytes))
}
Set-Content -LiteralPath $summaryPath -Value $summary -Encoding UTF8

Write-Host 'Read-only scan complete.'
Write-Host "JSON report: $jsonPath"
Write-Host "Text report: $summaryPath"
