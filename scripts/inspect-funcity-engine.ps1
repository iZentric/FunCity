[CmdletBinding()]
param(
    [string]$ProjectRoot = 'E:\Administrator\Desktop\FunCity',
    [string]$PackPath = 'E:\Administrator\Desktop\FunCity\modpack uri\Freeroam 1.0.0.mrpack',
    [string]$ReferencePath = 'E:\Administrator\Desktop\FunCity\servere referinta',
    [string]$EngineOutputPath = 'E:\Administrator\Desktop\FunCity\FunCity server\FunCity-Engine-Freeroam'
)

# Read-only preflight for the requested full-pack test engine. It reads only the
# named MRPack, the named reference engine/runtime, and machine capacity.
$ErrorActionPreference = 'Stop'

function Get-PropertyValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

$allowedRoot = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\') + '\'
$resolvedPackPath = [System.IO.Path]::GetFullPath($PackPath)
if (-not $resolvedPackPath.StartsWith($allowedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'PackPath must remain inside E:\Administrator\Desktop\FunCity.'
}
if (-not (Test-Path -LiteralPath $resolvedPackPath -PathType Leaf)) {
    throw "The exact requested pack was not found: $resolvedPackPath"
}
if (-not (Test-Path -LiteralPath $ReferencePath -PathType Container)) {
    throw 'The FunCity reference folder is missing.'
}
if (Test-Path -LiteralPath $EngineOutputPath) {
    throw "The separate full-engine output already exists; it will not be overwritten: $EngineOutputPath"
}

Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
$archive = [System.IO.Compression.ZipFile]::OpenRead($resolvedPackPath)
try {
    $index = $archive.GetEntry('modrinth.index.json')
    if ($null -eq $index) { throw 'The MRPack is missing modrinth.index.json.' }
    $stream = $index.Open()
    try {
        $reader = New-Object System.IO.StreamReader($stream)
        try { $manifest = ConvertFrom-Json -InputObject $reader.ReadToEnd() -ErrorAction Stop }
        finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }

    $dependencies = Get-PropertyValue -Object $manifest -Name 'dependencies'
    $minecraft = [string](Get-PropertyValue -Object $dependencies -Name 'minecraft')
    $forge = [string](Get-PropertyValue -Object $dependencies -Name 'forge')
    $mods = @()
    foreach ($file in @(Get-PropertyValue -Object $manifest -Name 'files')) {
        $path = [string](Get-PropertyValue -Object $file -Name 'path')
        if ($path -notmatch '(?i)^mods/.+\.jar$') { continue }
        $envInfo = Get-PropertyValue -Object $file -Name 'env'
        $serverEnv = [string](Get-PropertyValue -Object $envInfo -Name 'server')
        $clientEnv = [string](Get-PropertyValue -Object $envInfo -Name 'client')
        if ([string]::IsNullOrWhiteSpace($serverEnv)) { $serverEnv = 'unspecified (server-compatible by default)' }
        if ([string]::IsNullOrWhiteSpace($clientEnv)) { $clientEnv = 'unspecified' }
        $mods += [pscustomobject]@{
            name = [System.IO.Path]::GetFileName($path)
            path = $path
            server = $serverEnv
            client = $clientEnv
            size = [long](Get-PropertyValue -Object $file -Name 'fileSize')
        }
    }
    $embeddedServerMods = @($archive.Entries | Where-Object { $_.FullName -match '(?i)^server-overrides/mods/.+\.jar$' })
    $embeddedClientMods = @($archive.Entries | Where-Object { $_.FullName -match '(?i)^overrides/mods/.+\.jar$' })
    $configOverrides = @($archive.Entries | Where-Object {
        -not $_.FullName.EndsWith('/') -and
        ($_.FullName -match '(?i)^overrides/(config|defaultconfigs|kubejs|scripts)/' -or
         $_.FullName -match '(?i)^server-overrides/(config|defaultconfigs|kubejs|scripts)/')
    })
}
finally {
    $archive.Dispose()
}

$serverMods = @($mods | Where-Object { $_.server -ne 'unsupported' })
$clientOnlyMods = @($mods | Where-Object { $_.server -eq 'unsupported' })
$unmarkedMods = @($mods | Where-Object { $_.server -like 'unspecified*' })
$engineJar = Join-Path (Join-Path $ReferencePath 'hypecity') 'server.jar'
if (-not (Test-Path -LiteralPath $engineJar -PathType Leaf)) {
    throw 'The Hypecity reference server.jar was not found.'
}
$runtimeVersionPath = 'E:\Administrator\Desktop\FunCity\FunCity server\FunCity-Lite\runtime\JAVA-VERSION.txt'
$runtimeNote = if (Test-Path -LiteralPath $runtimeVersionPath -PathType Leaf) { (Get-Content -LiteralPath $runtimeVersionPath -Raw).Trim() } else { 'bundled Java runtime note missing' }

$computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
$os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
$totalMemoryGB = [Math]::Round(([double]$computer.TotalPhysicalMemory / 1GB), 1)
$freeMemoryGB = [Math]::Round(([double]$os.FreePhysicalMemory / 1MB), 1)
$drive = Get-PSDrive -Name E -ErrorAction Stop
$freeDiskGB = [Math]::Round(([double]$drive.Free / 1GB), 1)

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("Pack=$([System.IO.Path]::GetFileName($resolvedPackPath)); Minecraft=$minecraft; Forge=$forge; manifest-mods=$($mods.Count); server-compatible=$($serverMods.Count); client-only=$($clientOnlyMods.Count); unmarked=$($unmarkedMods.Count); embedded-server-mods=$($embeddedServerMods.Count); embedded-client-mods=$($embeddedClientMods.Count); configs=$($configOverrides.Count)")
$lines.Add("PC capacity: RAM=$totalMemoryGB GB; available-RAM=$freeMemoryGB GB; E-drive-free=$freeDiskGB GB")
$lines.Add("Reference engine: $engineJar")
$lines.Add("Bundled Java note: $runtimeNote")
foreach ($mod in $mods) {
    $lines.Add("manifest-mod: $($mod.name) | server=$($mod.server) | client=$($mod.client) | bytes=$($mod.size)")
}
foreach ($entry in $embeddedServerMods) { $lines.Add('embedded-server-override: ' + $entry.FullName) }
foreach ($entry in $embeddedClientMods) { $lines.Add('embedded-client-override: ' + $entry.FullName) }

$manifestModList = ($mods | ForEach-Object { $_.name + ' [server=' + $_.server + '; client=' + $_.client + ']' }) -join ' | '
$embeddedServerList = ($embeddedServerMods | ForEach-Object { [System.IO.Path]::GetFileName($_.FullName) }) -join ' | '
$embeddedClientList = ($embeddedClientMods | ForEach-Object { [System.IO.Path]::GetFileName($_.FullName) }) -join ' | '
$summary = "Minecraft=$minecraft; Forge=$forge; manifest-mods=$($mods.Count); server-compatible=$($serverMods.Count); client-only=$($clientOnlyMods.Count); unmarked=$($unmarkedMods.Count); embedded-server-mods=$($embeddedServerMods.Count); embedded-client-mods=$($embeddedClientMods.Count); RAM=$totalMemoryGB/$freeMemoryGB GB free; E-drive-free=$freeDiskGB GB; full-engine-output=absent; manifest-files=$manifestModList; embedded-server=$embeddedServerList; embedded-client=$embeddedClientList"
Write-Output "::notice title=FunCity Freeroam engine preflight::$summary"
foreach ($line in $lines) { Write-Output $line }
