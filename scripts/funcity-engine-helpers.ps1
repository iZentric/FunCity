function Get-FunCityVoiceChatServerConfigPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [string]$WorldName
    )

    $resolvedRoot = [System.IO.Path]::GetFullPath($ServerRoot)
    if ([string]::IsNullOrWhiteSpace($WorldName)) {
        $WorldName = 'world'
        $propertiesPath = Join-Path $resolvedRoot 'server.properties'
        if (Test-Path -LiteralPath $propertiesPath -PathType Leaf) {
            foreach ($line in [System.IO.File]::ReadAllLines($propertiesPath)) {
                if ($line -match '^\s*level-name\s*=\s*(.*?)\s*$' -and -not [string]::IsNullOrWhiteSpace($Matches[1])) {
                    $WorldName = $Matches[1]
                    break
                }
            }
        }
    }
    if ([System.IO.Path]::IsPathRooted($WorldName) -or $WorldName -match '(^|[\\/])\.\.([\\/]|$)') {
        throw 'The configured world name is unsafe for resolving the voice-chat config path.'
    }

    # Forge Simple Voice Chat <2.4 stores settings in the world's serverconfig TOML;
    # 2.4+ migrated to config/voicechat/voicechat-server.properties.
    $legacyTomlPath = Join-Path (Join-Path $resolvedRoot $WorldName) 'serverconfig\voicechat-server.toml'
    $propertiesPath = Join-Path $resolvedRoot 'config\voicechat\voicechat-server.properties'
    $version = $null
    $modsDirectory = Join-Path $resolvedRoot 'mods'
    if (Test-Path -LiteralPath $modsDirectory -PathType Container) {
        $voiceChatMod = Get-ChildItem -LiteralPath $modsDirectory -File -Filter 'voicechat*.jar' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 1
        if ($null -ne $voiceChatMod -and $voiceChatMod.Name -match '(?i)-(?<version>\d+\.\d+\.\d+)(?:[-+][^.]*)?\.jar$') {
            try { $version = [version]$Matches['version'] }
            catch { $version = $null }
        }
    }

    if ($null -ne $version) {
        if ($version -ge [version]'2.4.0') { return $propertiesPath }
        return $legacyTomlPath
    }
    if (Test-Path -LiteralPath $propertiesPath -PathType Leaf) { return $propertiesPath }
    if (Test-Path -LiteralPath $legacyTomlPath -PathType Leaf) { return $legacyTomlPath }
    return $legacyTomlPath
}

function Get-FunCityVoiceChatUdpPort {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ConfigPath)

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return $null }
    $isToml = [System.IO.Path]::GetExtension($ConfigPath) -ieq '.toml'
    $inVoiceChatSection = -not $isToml
    foreach ($line in [System.IO.File]::ReadAllLines($ConfigPath)) {
        if ($isToml -and $line -match '^\s*\[([^\]]+)\]\s*(?:#.*)?$') {
            $inVoiceChatSection = ($Matches[1] -ieq 'voice_chat')
            continue
        }
        if ($inVoiceChatSection -and $line -match '^\s*port\s*=\s*(-?\d+)\s*(?:#.*)?$') {
            return [int]$Matches[1]
        }
    }
    return $null
}

function Get-FunCityLocalUdpEndpoints {
    [CmdletBinding()]
    param([ValidateRange(1, 65535)][int]$Port)

    if ($null -eq (Get-Command -Name Get-NetUDPEndpoint -ErrorAction SilentlyContinue)) {
        throw 'The Windows NetTCPIP Get-NetUDPEndpoint command is unavailable; UDP listener state cannot be verified.'
    }
    Get-NetUDPEndpoint -LocalPort $Port -ErrorAction Stop
}

function Set-FunCityVoiceChatUdpPort {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [ValidateRange(1024, 65535)][int]$Port = 24455
    )

    $directory = Split-Path -Parent $ConfigPath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
    }

    $content = if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        [System.IO.File]::ReadAllText($ConfigPath)
    }
    else {
        ''
    }
    $sourceLines = if ([string]::IsNullOrEmpty($content)) { @() } else { [regex]::Split($content, "`r`n|`n|`r") }
    $lines = [System.Collections.Generic.List[string]]::new()
    $isToml = [System.IO.Path]::GetExtension($ConfigPath) -ieq '.toml'
    $inVoiceChatSection = -not $isToml
    $sectionFound = -not $isToml
    $portWritten = $false

    foreach ($line in $sourceLines) {
        if ($isToml -and $line -match '^\s*\[([^\]]+)\]\s*(?:#.*)?$') {
            if ($inVoiceChatSection -and -not $portWritten) {
                $lines.Add("port = $Port")
                $portWritten = $true
            }
            $inVoiceChatSection = ($Matches[1] -ieq 'voice_chat')
            if ($inVoiceChatSection) { $sectionFound = $true }
            $lines.Add($line)
            continue
        }
        if ($inVoiceChatSection -and $line -match '^\s*port\s*=') {
            if (-not $portWritten) {
                $lines.Add($(if ($isToml) { "port = $Port" } else { "port=$Port" }))
                $portWritten = $true
            }
            continue
        }
        $lines.Add($line)
    }

    if ($inVoiceChatSection -and -not $portWritten) {
        $lines.Add($(if ($isToml) { "port = $Port" } else { "port=$Port" }))
        $portWritten = $true
    }
    if ($isToml -and -not $sectionFound) {
        if ($lines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) { $lines.Add('') }
        $lines.Add('[voice_chat]')
        $lines.Add("port = $Port")
        $portWritten = $true
    }
    if (-not $portWritten) { $lines.Add("port=$Port") }
    while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) {
        $lines.RemoveAt($lines.Count - 1)
    }

    $serialized = [string]::Join([System.Environment]::NewLine, $lines.ToArray()) + [System.Environment]::NewLine
    [System.IO.File]::WriteAllBytes($ConfigPath, [System.Text.Encoding]::UTF8.GetBytes($serialized))
    return $Port
}
