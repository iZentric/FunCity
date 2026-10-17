[CmdletBinding()]
param(
    [string]$ServerPath = 'E:\Administrator\Desktop\FunCity\FunCity server\FunCity-Engine-Freeroam'
)

# Keep every jar from the pack while moving mods proven/known to depend on
# Minecraft client classes out of the dedicated server's active mods/ folder.
# This script never deletes a mod and refuses to edit a running test instance.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

trap {
    $failure = ($_.Exception.Message -replace '[\r\n]+', ' ').Trim()
    Write-Output "::error title=FunCity full-pack mod classification::$failure"
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
Assert-Condition -Condition ($resolved.StartsWith($allowedRoot, [System.StringComparison]::OrdinalIgnoreCase)) -Message 'Classification path must stay inside E:\Administrator\Desktop\FunCity.'
$root = Get-Item -LiteralPath $resolved -ErrorAction Stop
Assert-Condition -Condition $root.PSIsContainer -Message 'The full-pack test engine folder is missing.'

$task = Get-ScheduledTask -TaskName 'FunCity-Freeroam-Mohist-Test' -ErrorAction SilentlyContinue
Assert-Condition -Condition ($null -eq $task -or $task.State -ne 'Running') -Message 'The full-pack server task is running; refusing to move mod files.'
$properties = Get-Content -LiteralPath (Join-Path $root.FullName 'server.properties')
$portLine = $properties | Where-Object { $_ -match '^\s*server-port\s*=' } | Select-Object -First 1
$port = if ($null -eq $portLine) { 25566 } else { [int](($portLine -replace '^\s*server-port\s*=\s*', '').Trim()) }
$client = New-Object System.Net.Sockets.TcpClient
$portOpen = $false
try {
    $client.Connect('127.0.0.1', $port)
    $portOpen = $true
}
catch { $portOpen = $false }
finally { $client.Close() }
Assert-Condition -Condition (-not $portOpen) -Message "Port $port is open; refusing to modify a live server."

$inventoryPath = Join-Path $root.FullName 'pack-mod-inventory.json'
$inventory = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $inventoryPath -Raw) -ErrorAction Stop
$allRecords = @($inventory.mods)
Assert-Condition -Condition ($allRecords.Count -eq [int]$inventory.sourceModJarCount -and $allRecords.Count -eq 28) -Message "Expected the intact 28-mod Freeroam bundle, found $($allRecords.Count)."
$modsDirectory = Join-Path $root.FullName 'mods'
$clientDirectory = Join-Path $root.FullName 'client-only-mods'
New-Item -ItemType Directory -Path $clientDirectory -Force | Out-Null
$clientPattern = '(?i)^(TextruesRubidiumOptions-|InGameAccountSwitcher-|rubidium-|oculus-|lightfallclient-|notenoughanimations-|CTM-)'
$separated = [System.Collections.Generic.List[string]]::new()
$classificationByFile = @{}

foreach ($record in $allRecords) {
    $fileName = [string]$record.file
    Assert-Condition -Condition (-not [string]::IsNullOrWhiteSpace($fileName) -and $fileName -match '(?i)\.jar$') -Message 'The pack inventory has an invalid mod record.'
    $isClientOnly = $fileName -match $clientPattern
    $activePath = Join-Path $modsDirectory $fileName
    $clientPath = Join-Path $clientDirectory $fileName
    if ($isClientOnly) {
        if ([string]$record.relativeDestination -like 'client-only-mods/*') {
            Assert-Condition -Condition (Test-Path -LiteralPath $clientPath -PathType Leaf) -Message "Previously classified client-only mod is missing: $fileName"
        }
        elseif (Test-Path -LiteralPath $activePath -PathType Leaf) {
            Assert-Condition -Condition (-not (Test-Path -LiteralPath $clientPath)) -Message "Both active and client-only copies exist for $fileName; refusing to overwrite either copy."
            Move-Item -LiteralPath $activePath -Destination $clientPath -ErrorAction Stop
        }
        elseif (-not (Test-Path -LiteralPath $clientPath -PathType Leaf)) {
            throw "Client-only mod is missing from both folders: $fileName"
        }
        $record.relativeDestination = 'client-only-mods/' + $fileName
        $record.serverEnvironment = 'client-only; dedicated-server class references confirmed by first test'
        $classificationByFile[$fileName] = $false
        $separated.Add($fileName)
    }
    else {
        Assert-Condition -Condition (Test-Path -LiteralPath $activePath -PathType Leaf) -Message "Server mod is missing: $fileName"
        $record.relativeDestination = 'mods/' + $fileName
        $classificationByFile[$fileName] = $true
    }
    $finalPath = Join-Path $root.FullName ([string]$record.relativeDestination)
    Assert-Condition -Condition (Test-Path -LiteralPath $finalPath -PathType Leaf) -Message "Mod was not preserved: $fileName"
    Assert-Condition -Condition (Test-ReadableJar -Path $finalPath) -Message "Mod JAR is unreadable after classification: $fileName"
    $actualHash = (Get-FileHash -LiteralPath $finalPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Condition -Condition ($actualHash -eq ([string]$record.sha256).ToLowerInvariant()) -Message "Mod hash changed during classification: $fileName"
}

$activeFiles = @(Get-ChildItem -LiteralPath $modsDirectory -File -Filter '*.jar' -ErrorAction Stop)
$clientFiles = @(Get-ChildItem -LiteralPath $clientDirectory -File -Filter '*.jar' -ErrorAction Stop)
Assert-Condition -Condition ($activeFiles.Count + $clientFiles.Count -eq $allRecords.Count) -Message 'Not all modpack JARs are retained across the active and client-only folders.'
Assert-Condition -Condition ($separated.Count -gt 0) -Message 'No known client-only jars were separated despite the dedicated-server crash.'
$updatedRecords = [System.Collections.Generic.List[object]]::new()
foreach ($record in $allRecords) {
    $recordData = [ordered]@{}
    foreach ($property in $record.PSObject.Properties) { $recordData[$property.Name] = $property.Value }
    $recordData['loadOnServer'] = [bool]$classificationByFile[[string]$record.file]
    $updatedRecords.Add([pscustomobject]$recordData)
}
$allRecords = @($updatedRecords)
$inventory = [pscustomobject]@{
    pack = $inventory.pack
    packName = $inventory.packName
    packVersion = $inventory.packVersion
    minecraft = $inventory.minecraft
    forge = $inventory.forge
    engine = $inventory.engine
    port = $inventory.port
    heapGB = $inventory.heapGB
    sourceModJarCount = $allRecords.Count
    serverModJarCount = $activeFiles.Count
    clientOnlyModJarCount = $clientFiles.Count
    mods = $allRecords
}
Set-Content -LiteralPath $inventoryPath -Value (ConvertTo-Json -InputObject $inventory -Depth 8) -Encoding UTF8

$readmePath = Join-Path $root.FullName 'README-FUNCITY-ENGINE.txt'
$readme = [System.Collections.Generic.List[string]]::new()
$readme.Add('FunCity Engine — Freeroam full-pack test')
$readme.Add('')
$readme.Add('Branded FunCity packaging around the matching Hypecity Mohist hybrid engine; this is not a from-scratch replacement for Minecraft/Forge.')
$readme.Add('Pack: Freeroam 1.0.0.mrpack | Minecraft 1.16.5 | Forge 36.2.42 | Mohist 1.16.5-1242.')
$readme.Add("All $($allRecords.Count) mod JARs from the pack remain present and checksum-verified. $($activeFiles.Count) server-compatible mods are active in mods/; $($clientFiles.Count) client-only mods are retained in client-only-mods/ and intentionally not loaded by a dedicated server.")
$readme.Add('The first all-mod server test correctly exposed client-side classes in Oculus, In-Game Account Switcher, LightfallClient, and related render/account-switcher mods. These files have been preserved rather than deleted.')
$readme.Add('No additional plugins are installed, isolating the pack/hybrid-engine compatibility test.')
$readme.Add('The server uses only the copied, SHA-256-verified portable Temurin JRE 11.0.32.1. No system-Java fallback is allowed.')
$readme.Add('The owner accepted the Minecraft EULA; eula.txt remains true.')
$readme.Add('Test port is 25566; the existing FunCity-Lite server on 25565 is untouched.')
$readme.Add('No firewall rules, router settings, or files outside the FunCity project were changed.')
Set-Content -LiteralPath $readmePath -Value $readme -Encoding UTF8

$reportPath = Join-Path $root.FullName 'BUILD-REPORT.txt'
$report = [System.Collections.Generic.List[string]]::new()
$report.Add('Build result: complete; full-pack test profile corrected after first server-side compatibility attempt.')
$report.Add('Pack: Freeroam 1.0.0.mrpack | Minecraft 1.16.5 | Forge 36.2.42 | Mohist 1.16.5-1242.')
$report.Add('All pack mod JARs retained and SHA-256 checked: ' + $allRecords.Count)
$report.Add('Server-loaded JARs in mods/: ' + $activeFiles.Count)
$report.Add('Client-only JARs preserved under client-only-mods/: ' + $clientFiles.Count)
foreach ($record in $allRecords) {
    $report.Add("  $($record.relativeDestination) | load-on-server=$($record.loadOnServer) | SHA-256=$($record.sha256)")
}
$report.Add('First full activation failed because client-only mods referenced net.minecraft.client classes on DEDICATED_SERVER. See crash-reports/ for the original evidence; no mod files were deleted.')
$report.Add('Port: 25566; heap maximum: 6 GB; Java: portable Temurin JRE 11.0.32.1; EULA=true.')
$report.Add('Server status: not running; ready for a retry with the dedicated-server-compatible set.')
$report.Add('No extra plugins were copied.')
Set-Content -LiteralPath $reportPath -Value $report -Encoding UTF8
Set-Content -LiteralPath (Join-Path $root.FullName 'server.pid') -Value 'not-running-after-client-side-crash' -Encoding ASCII

$clientSummary = $separated -join ', '
$summary = "All-pack-mods=$($allRecords.Count); server-loaded=$($activeFiles.Count); client-only-preserved=$($clientFiles.Count); client-only=$clientSummary; port=$port/closed; no mods deleted"
Write-Output "::notice title=FunCity client-only mod classification::$summary"
Write-Output $summary
