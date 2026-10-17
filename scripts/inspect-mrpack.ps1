[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [int]$MaxNamesPerCategory = 500
)

# Read-only reader for a Modrinth .mrpack. It extracts no files and follows no
# download URLs; output contains pack metadata and file names only.
$ErrorActionPreference = 'Stop'

function Get-PropertyValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Get-LimitedNames {
    param([object[]]$Items, [int]$Limit)
    $names = @($Items | Select-Object -First $Limit)
    return [pscustomobject]@{
        count = $Items.Count
        names = $names
        truncated = ($Items.Count -gt $Limit)
    }
}

$pack = Get-Item -LiteralPath $PackPath -ErrorAction Stop
if ($pack.PSIsContainer) { throw "PackPath must be a file: $PackPath" }
if ($pack.Extension -ine '.mrpack') { throw "Expected a .mrpack file, got: $($pack.Name)" }
if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($pack.FullName)
try {
    $entry = $archive.GetEntry('modrinth.index.json')
    if ($null -eq $entry) { throw 'The .mrpack does not contain modrinth.index.json.' }

    $stream = $entry.Open()
    try {
        $reader = New-Object System.IO.StreamReader($stream)
        try {
            $manifest = ConvertFrom-Json -InputObject $reader.ReadToEnd() -ErrorAction Stop
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }

    $dependencies = Get-PropertyValue -Object $manifest -Name 'dependencies'
    $minecraftVersion = [string](Get-PropertyValue -Object $dependencies -Name 'minecraft')
    $loaders = [System.Collections.Generic.List[string]]::new()
    foreach ($loaderName in @('fabric-loader', 'forge', 'neoforge', 'quilt-loader')) {
        $loaderVersion = Get-PropertyValue -Object $dependencies -Name $loaderName
        if (-not [string]::IsNullOrWhiteSpace([string]$loaderVersion)) {
            $loaders.Add($loaderName + ' ' + [string]$loaderVersion)
        }
    }

    $serverMods = [System.Collections.Generic.List[string]]::new()
    $clientOnlyMods = [System.Collections.Generic.List[string]]::new()
    $performanceMods = [System.Collections.Generic.List[string]]::new()
    $files = @(Get-PropertyValue -Object $manifest -Name 'files')
    foreach ($file in $files) {
        $path = [string](Get-PropertyValue -Object $file -Name 'path')
        if ($path -notmatch '(?i)^mods/.+\.jar$') { continue }
        $name = [System.IO.Path]::GetFileName($path)
        $environment = Get-PropertyValue -Object $file -Name 'env'
        $serverEnvironment = [string](Get-PropertyValue -Object $environment -Name 'server')
        if ($serverEnvironment -eq 'unsupported') {
            $clientOnlyMods.Add($name)
        }
        else {
            $serverMods.Add($name)
        }
        if ($name -match '(?i)(lithium|ferritecore|modernfix|canary|radium|servercore|krypton|noisium|c2me|chunky|spark|alternate[-_ ]?current|starlight)') {
            $performanceMods.Add($name)
        }
    }

    $serverOverrideEntries = @($archive.Entries | Where-Object { $_.FullName -like 'server-overrides/*' -and -not $_.FullName.EndsWith('/') })
    $clientOverrideEntries = @($archive.Entries | Where-Object { $_.FullName -like 'overrides/*' -and -not $_.FullName.EndsWith('/') })

    $report = [pscustomobject]@{
        packFile = $pack.Name
        packSizeBytes = $pack.Length
        packName = [string](Get-PropertyValue -Object $manifest -Name 'name')
        packVersion = [string](Get-PropertyValue -Object $manifest -Name 'versionId')
        formatVersion = Get-PropertyValue -Object $manifest -Name 'formatVersion'
        minecraftVersion = $minecraftVersion
        loaders = @($loaders)
        serverModJars = Get-LimitedNames -Items @($serverMods) -Limit $MaxNamesPerCategory
        clientOnlyModJars = Get-LimitedNames -Items @($clientOnlyMods) -Limit $MaxNamesPerCategory
        performanceModsAlreadyIncluded = @($performanceMods | Select-Object -Unique)
        serverOverrideFileCount = $serverOverrideEntries.Count
        clientOverrideFileCount = $clientOverrideEntries.Count
        notes = @(
            'Only modrinth.index.json and archive entry names were read.'
            'No files were extracted, no URLs were downloaded, and no jars were executed.'
        )
    }
}
finally {
    $archive.Dispose()
}

$jsonPath = Join-Path $OutputDirectory 'freeroam-pack-info.json'
$textPath = Join-Path $OutputDirectory 'freeroam-pack-info.txt'
Set-Content -LiteralPath $jsonPath -Value (ConvertTo-Json -InputObject $report -Depth 8) -Encoding UTF8

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('Freeroam Modrinth pack inventory')
$lines.Add('Pack: ' + $report.packName + ' ' + $report.packVersion + ' (' + $report.packFile + ')')
$lines.Add('Minecraft: ' + $(if ($report.minecraftVersion) { $report.minecraftVersion } else { 'not detected' }))
$lines.Add('Loader: ' + $(if ($report.loaders.Count) { $report.loaders -join ', ' } else { 'not detected' }))
$lines.Add('Server mods: ' + $report.serverModJars.count)
foreach ($name in $report.serverModJars.names) { $lines.Add('  server mod: ' + $name) }
$lines.Add('Client-only mods: ' + $report.clientOnlyModJars.count)
foreach ($name in $report.clientOnlyModJars.names) { $lines.Add('  client-only: ' + $name) }
$lines.Add('Performance mods already included: ' + $(if ($report.performanceModsAlreadyIncluded.Count) { $report.performanceModsAlreadyIncluded -join ', ' } else { 'none detected by name' }))
$lines.Add('Server override files: ' + $report.serverOverrideFileCount)
$lines.Add('Client override files: ' + $report.clientOverrideFileCount)
Set-Content -LiteralPath $textPath -Value $lines -Encoding UTF8

Write-Host 'Read-only .mrpack inspection complete.'
Write-Host "Text report: $textPath"
Write-Host "JSON report: $jsonPath"
