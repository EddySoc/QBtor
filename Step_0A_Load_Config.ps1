# Configuration Loader - Simplified
# Skip if already initialized in this session
if ($Global:EnvironmentInitialized) {
    return
}

# Load Utils first
if (-not $Global:UtilsLoaded) {
    $Global:UtilsLoaded = $true
    . "$PSScriptRoot\Step_0B_Load_Utils.ps1"
}

# Simple INI Parser
function Read-IniFile {
    param([string]$Path)
    $Config = @{}
    $section = $null
    
    foreach ($line in (Get-Content $Path -ErrorAction SilentlyContinue)) {
        $line = $line.Trim()
        
        # Skip empty and comment lines
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
            continue
        }
        
        # Section header [Name]
        if ($line -match '^\[(.+)\]$') {
            $section = $matches[1]
            $Config[$section] = @{}
            continue
        }
        
        # Key=Value
        if ($line -match '^([^=]+)=(.*)$' -and $null -ne $section) {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            $Config[$section][$key] = $value
        }
    }
    
    return $Config
}

# Load and export configuration
$configPath = Join-Path $PSScriptRoot "config.ini"
if (Test-Path $configPath) {
    $config = Read-IniFile $configPath
    
    # Export all values as globals with type conversion
    foreach ($section in $config.Keys) {
        foreach ($key in $config[$section].Keys) {
            # Skip empty or invalid keys
            if ([string]::IsNullOrWhiteSpace($key)) {
                continue
            }
            
            # Skip reserved PowerShell keywords
            $reservedWords = @('true', 'false', 'null', 'if', 'else', 'foreach', 'while', 'function')
            if ($key -in $reservedWords) {
                Write-Warning "Skipping reserved keyword in config: $key"
                continue
            }
            
            $value = $config[$section][$key]
            
            # Type conversion (case-insensitive for booleans)
            if ($value -imatch '^(true|false)$') {
                $value = [bool]::Parse($value)
            } elseif ($value -match '^\d+$') {
                $value = [int]$value
            } elseif ($value -match ',') {
                $value = @($value -split ',' | ForEach-Object {$_.Trim()})
            }
            
            Set-Variable -Name $key -Value $value -Scope Global
        }
    }
}

# Derive all paths from RootDir and $PSScriptRoot (no need to hardcode them in config.ini)
$Global:ScriptDir = $PSScriptRoot

# Path overrides: use config.ini values if specified, otherwise default to RootDir\<folder>
# This allows paths to be on different disks while keeping defaults simple

if (-not $Global:SourceDir) {
    $Global:SourceDir = Join-Path $Global:RootDir "Downloads"
}

if (-not $Global:TempDir) {
    $Global:TempDir = Join-Path $Global:RootDir "Temp"
}

if (-not $Global:LogsDir) {
    $Global:LogDir = Join-Path $Global:RootDir "Logs"
} else {
    $Global:LogDir = $Global:LogsDir
}

if (-not $Global:MediaDir) {
    $Global:MediaDir = Join-Path $Global:RootDir "Media"
}

if (-not $Global:MetadataDir) {
    $Global:MetaDir = Join-Path $Global:RootDir "Metadata"
} else {
    $Global:MetaDir = $Global:MetadataDir
}

if (-not $Global:DoneDir) {
    $Global:DoneDir = Join-Path $Global:RootDir "Done"
}

$Global:RejectDir = Join-Path $Global:RootDir "Rejected"

# Build full paths for executables
if ($Global:CheckLangExe -and -not [System.IO.Path]::IsPathRooted($Global:CheckLangExe)) {
    $Global:CheckLangExe = Join-Path $Global:ScriptDir $Global:CheckLangExe
}
if ($Global:AlassExe -and -not [System.IO.Path]::IsPathRooted($Global:AlassExe)) {
    $Global:AlassExe = Join-Path $Global:ScriptDir $Global:AlassExe
}
if ($Global:FFSubSyncExe -and -not [System.IO.Path]::IsPathRooted($Global:FFSubSyncExe)) {
    $Global:FFSubSyncExe = Join-Path $Global:ScriptDir $Global:FFSubSyncExe
}
if ($Global:TranslatorScript -and -not [System.IO.Path]::IsPathRooted($Global:TranslatorScript)) {
    $Global:TranslatorScript = Join-Path $Global:ScriptDir $Global:TranslatorScript
}
if (-not $Global:TranslatorBackend) { $Global:TranslatorBackend = 'argos' }
if (-not $Global:TranslatorOllamaModel) { $Global:TranslatorOllamaModel = 'mistral' }
if ($Global:FFmpegExe -and -not [System.IO.Path]::IsPathRooted($Global:FFmpegExe)) {
    $Global:FFmpegExe = Join-Path $Global:ScriptDir $Global:FFmpegExe
}
if ($Global:FFprobeExe -and -not [System.IO.Path]::IsPathRooted($Global:FFprobeExe)) {
    $Global:FFprobeExe = Join-Path $Global:ScriptDir $Global:FFprobeExe
}

# Script filenames for pipeline
$Global:InitScript        = "Step_01_Init_Folders.ps1"
$Global:PrepScript        = "Step_02_Copy_And_Rename.ps1"
$Global:GenMetaScript     = "Step_03_Get_Metadata.ps1"
$Global:StoreScript       = "Step_04_Extract_Subs.ps1"
$Global:DownloadScript    = "Step_05_Download_Subs.ps1"
$Global:STTScript         = "Step_06_Speech_To_Text.ps1"
$Global:ValidateScript    = "Step_07_Validate_Subs.ps1"
$Global:CleanSubsScript   = "Step_08_Clean_Subs.ps1"
$Global:ScoreScript       = "Step_09_Score_Subs.ps1"
$Global:SyncScript        = "Step_10_Sync_Subs.ps1"
$Global:TranslateScript   = "Step_11_Translate_Subs.ps1"
$Global:EmbedScript       = "Step_12_Embed_Subs.ps1"
$Global:FinalizeScript    = "Step_13_Cleanup.ps1"
$Global:CheckDiskScript   = "Step_14_Check_Disk.ps1"
$Global:VidUtilsScript    = "Utils_Video.ps1"

# Set primary language from LangKeep (first language is primary)
if ($Global:LangKeep) {
    # If LangKeep is a string (single value), use it directly
    if ($Global:LangKeep -is [string]) {
        $Global:Lang = $Global:LangKeep
    }
    # If LangKeep is an array, take the first element
    elseif ($Global:LangKeep -is [array] -and $Global:LangKeep.Count -gt 0) {
        $Global:Lang = $Global:LangKeep[0]
    }
}

# Language groupings: maps canonical code → array of all variants
# (Already defined in Utils.ps1 as $LangMap, reference it from there)
# This is available as $Global:LangMap after Utils is loaded

# Create directories if they don't exist
@($Global:SourceDir, $Global:TempDir, $Global:LogDir, $Global:MediaDir, $Global:RejectDir) | ForEach-Object {
    if (-not (Test-Path $_)) {
        New-Item -Path $_ -ItemType Directory -Force | Out-Null
    }
}

# Add ToolsDir and subdirectories to PATH for tools (ffmpeg, filebot, etc.)
if ($Global:ToolsDir -and (Test-Path $Global:ToolsDir)) {
    $currentPath = $env:PATH
    
    # Add the main ToolsDir path
    if ($currentPath -notlike "*$($Global:ToolsDir)*") {
        $env:PATH = "$($Global:ToolsDir);$env:PATH"
    }
    
    # Add all immediate subdirectories (for tools organized in subfolders like ffmpeg/, FileBot/, etc.)
    Get-ChildItem -Path $Global:ToolsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        if ($currentPath -notlike "*$($_.FullName)*") {
            $env:PATH = "$($_.FullName);$env:PATH"
        }
    }
}

# Mark as initialized
$Global:EnvironmentInitialized = $true
$Global:ConfigLoaded = $true

