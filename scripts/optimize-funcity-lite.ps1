[CmdletBinding()]
param(
    [string]$ServerPath = 'E:\Administrator\Desktop\FunCity\FunCity server\FunCity-Lite'
)

# Applies a conservative, repeatable G1GC profile to the already-built server.
# It writes only inside FunCity-Lite and never starts the server or edits eula.txt.
$ErrorActionPreference = 'Stop'

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$allowedRoot = [System.IO.Path]::GetFullPath('E:\Administrator\Desktop\FunCity') + [System.IO.Path]::DirectorySeparatorChar
$resolvedServerPath = [System.IO.Path]::GetFullPath($ServerPath)
Assert-Condition -Condition ($resolvedServerPath.StartsWith($allowedRoot, [System.StringComparison]::OrdinalIgnoreCase)) -Message 'Optimization target must remain inside E:\Administrator\Desktop\FunCity.'
$root = Get-Item -LiteralPath $resolvedServerPath -ErrorAction Stop
Assert-Condition -Condition $root.PSIsContainer -Message 'FunCity-Lite server folder was not found.'

$requiredFiles = @('server.jar', 'server.properties', 'eula.txt', 'start.bat', 'BUILD-REPORT.txt', 'README-FUNCITY.txt')
foreach ($name in $requiredFiles) {
    Assert-Condition -Condition (Test-Path -LiteralPath (Join-Path $root.FullName $name) -PathType Leaf) -Message "Required file is missing: $name"
}

$eulaPath = Join-Path $root.FullName 'eula.txt'
$eulaBefore = [System.IO.File]::ReadAllText($eulaPath)
$eulaAccepted = $eulaBefore -match '(?im)^\s*eula\s*=\s*true\s*$'
$eulaDeclined = $eulaBefore -match '(?im)^\s*eula\s*=\s*false\s*$'
Assert-Condition -Condition (($eulaAccepted -and -not $eulaDeclined) -or ($eulaDeclined -and -not $eulaAccepted)) -Message 'EULA state is ambiguous; optimization will not touch it.'
$eulaState = if ($eulaAccepted) { 'true (left unchanged)' } else { 'false (left unchanged)' }

Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
$serverArchive = [System.IO.Compression.ZipFile]::OpenRead((Join-Path $root.FullName 'server.jar'))
try {
    $manifestEntry = $serverArchive.GetEntry('META-INF/MANIFEST.MF')
    Assert-Condition -Condition ($null -ne $manifestEntry) -Message 'server.jar has no manifest.'
    $manifestStream = $manifestEntry.Open()
    try {
        $reader = New-Object System.IO.StreamReader($manifestStream)
        try { $engineManifest = $reader.ReadToEnd() }
        finally { $reader.Dispose() }
    }
    finally { $manifestStream.Dispose() }
}
finally { $serverArchive.Dispose() }
Assert-Condition -Condition ($engineManifest -match '(?m)^Implementation-Title: Mohist\s*$' -and $engineManifest -match '(?m)^Implementation-Version: 1\.16\.5-1242\s*$' -and $engineManifest -match '(?m)^Implementation-Version: 36\.2\.42\s*$') -Message 'Optimization target is not the expected Mohist/Forge server.'

$modFiles = @(Get-ChildItem -LiteralPath (Join-Path $root.FullName 'mods') -File -Filter '*.jar' -ErrorAction Stop)
$pluginFiles = @(Get-ChildItem -LiteralPath (Join-Path $root.FullName 'plugins') -File -Filter '*.jar' -ErrorAction Stop)
Assert-Condition -Condition ($modFiles.Count -eq 9) -Message "Expected 9 installed server mods, found $($modFiles.Count)."
Assert-Condition -Condition ($pluginFiles.Count -eq 8) -Message "Expected 8 installed plugins, found $($pluginFiles.Count)."

$baselineLine = 'java -Xms2G -Xmx4G -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -XX:+DisableExplicitGC -jar server.jar nogui'
$genericTunedLine = 'java -Xms2G -Xmx4G -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 -XX:G1RSetUpdatingPauseTimePercent=5 -jar server.jar nogui'
$tunedLine = '"%JAVA_EXE%" -Xms2G -Xmx4G -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 -XX:G1RSetUpdatingPauseTimePercent=5 -jar server.jar nogui'
$startPath = Join-Path $root.FullName 'start.bat'
$startText = [System.IO.File]::ReadAllText($startPath)
Assert-Condition -Condition ($startText -match '(?im)^findstr /i /x /c:"eula=true" eula\.txt >nul\s*$') -Message 'The existing EULA gate is missing; refusing to modify start.bat.'
$lines = @(Get-Content -LiteralPath $startPath)

$javaSetupLine = 'set "JAVA_EXE=%~dp0runtime\bin\java.exe"'
$javaSetup = @(
    $javaSetupLine,
    'if not exist "%JAVA_EXE%" (',
    '  echo Bundled Java 11 runtime was not found.',
    '  pause',
    '  exit /b 1',
    ')'
)
$findstrLine = 'findstr /i /x /c:"eula=true" eula.txt >nul'
$findstrIndex = [Array]::IndexOf($lines, $findstrLine)
Assert-Condition -Condition ($findstrIndex -gt 0) -Message 'The EULA gate line could not be located.'
$setupIndex = [Array]::IndexOf($lines, $javaSetupLine)
Assert-Condition -Condition ($setupIndex -ge 0 -and $setupIndex -lt $findstrIndex) -Message 'The local Java setup line could not be located before the EULA gate.'
$setupBlock = @($lines[$setupIndex..($findstrIndex - 1)])
$expectedSetupText = ($javaSetup -join "`n").TrimEnd()
$existingSetupText = ($setupBlock -join "`n").TrimEnd()
$setupChanged = $false
if ($existingSetupText -cne $expectedSetupText) {
    $prefix = @()
    if ($setupIndex -gt 0) { $prefix = @($lines[0..($setupIndex - 1)]) }
    $suffix = @($lines[$findstrIndex..($lines.Count - 1)])
    $lines = @($prefix) + @($javaSetup) + @('') + @($suffix)
    $setupChanged = $true
}

$launchLines = @($lines | Where-Object { $_ -match '^\s*(?:java|"%JAVA_EXE%")\s+-Xms' })
Assert-Condition -Condition ($launchLines.Count -eq 1) -Message "Expected one Java launch line, found $($launchLines.Count)."
$lineChanged = $false
if ($launchLines[0] -ceq $baselineLine -or $launchLines[0] -ceq $genericTunedLine) {
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -ceq $launchLines[0]) { $lines[$i] = $tunedLine }
    }
    $lineChanged = $true
}
elseif ($launchLines[0] -cne $tunedLine) {
    throw 'start.bat has an unrecognized Java command; it was left untouched.'
}
$changed = $setupChanged -or $lineChanged
if ($changed) { Set-Content -LiteralPath $startPath -Value $lines -Encoding ASCII }

$startAfter = [System.IO.File]::ReadAllText($startPath)
Assert-Condition -Condition ($startAfter.Contains($javaSetupLine)) -Message 'Local Java preference did not verify.'
Assert-Condition -Condition ($startAfter -notmatch '(?im)^\s*where java >nul 2>&1\s*$' -and $startAfter -notmatch '(?im)^\s*set "JAVA_EXE=java"\s*$') -Message 'start.bat still permits a system Java fallback.'
Assert-Condition -Condition ($startAfter.Contains($tunedLine)) -Message 'The tuned G1GC launch command did not verify.'
Assert-Condition -Condition ($startAfter -match '(?im)^findstr /i /x /c:"eula=true" eula\.txt >nul\s*$') -Message 'The EULA gate changed unexpectedly.'
$eulaAfter = [System.IO.File]::ReadAllText($eulaPath)
Assert-Condition -Condition ($eulaAfter -ceq $eulaBefore) -Message 'eula.txt changed unexpectedly.'

$performanceNote = 'Performance profile: G1GC low-pause tuning for a 2-4 GB heap; view-distance=6; use spark to measure live MSPT after owner-approved startup.'
$oldJavaNote = 'start.bat prefers the portable runtime\bin\java.exe and falls back to Java on PATH.'
$javaNote = 'start.bat uses only the bundled runtime\bin\java.exe; system Java is not used.'
$reportPath = Join-Path $root.FullName 'BUILD-REPORT.txt'
$readmePath = Join-Path $root.FullName 'README-FUNCITY.txt'
foreach ($documentPath in @($reportPath, $readmePath)) {
    $documentText = [System.IO.File]::ReadAllText($documentPath)
    $updatedText = $documentText.Replace($oldJavaNote, $javaNote)
    if (-not $updatedText.Contains($performanceNote)) {
        $updatedText = $updatedText.TrimEnd() + [Environment]::NewLine + $performanceNote + [Environment]::NewLine
    }
    if (-not $updatedText.Contains($javaNote)) {
        $updatedText = $updatedText.TrimEnd() + [Environment]::NewLine + $javaNote + [Environment]::NewLine
    }
    if ($updatedText -cne $documentText) {
        [System.IO.File]::WriteAllText($documentPath, $updatedText, [System.Text.Encoding]::UTF8)
    }
}

$properties = Get-Content -LiteralPath (Join-Path $root.FullName 'server.properties')
$viewDistance = [int](($properties | Where-Object { $_ -match '^\s*view-distance\s*=' } | Select-Object -First 1) -replace '^\s*view-distance\s*=\s*', '')
Assert-Condition -Condition ($viewDistance -eq 6) -Message "Unexpected view-distance: $viewDistance"
$changeState = if ($changed) { 'applied' } else { 'already applied; no duplicate edits' }
$summary = "G1GC low-pause profile=$changeState; Java=portable-only; heap=2-4 GB; view-distance=6; mods=9; plugins=8; EULA=$eulaState; server=not started"
Write-Output "::notice title=FunCity Lite PC optimization::$summary"
Write-Output $summary
