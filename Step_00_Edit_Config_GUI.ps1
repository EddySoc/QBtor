# ============================================================================
# Config.ini Editor GUI
# PowerShell script met Windows Forms GUI voor het bewerken van config.ini
# ============================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$configFile = Join-Path $scriptPath "config.ini"
$configDefaultsFile = Join-Path $scriptPath "config.example.ini"

# Functie om config.ini te lezen
function Read-ConfigFile {
    param([string]$filePath)
    
    $config = @{}
    $disabledConfig = @{}  # Houdt bij welke keys uitgeschakeld zijn
    $currentSection = ""
    
    if (Test-Path $filePath) {
        Get-Content $filePath -Encoding UTF8 | ForEach-Object {
            $line = $_.Trim()
            
            # Skip lege regels
            if ($line -eq "") {
                return
            }
            
            # Check of regel gecommentarieerd is
            $isDisabled = $line.StartsWith("#")
            $workLine = if ($isDisabled) { $line.Substring(1).Trim() } else { $line }
            
            # Skip echte commentaren (geen key-value)
            if ($isDisabled -and $workLine -notmatch '^([^=]+)=') {
                return
            }
            
            # Section header
            if ($workLine -match '^\[(.+)\]$') {
                $currentSection = $matches[1]
                if (-not $config.ContainsKey($currentSection)) {
                    $config[$currentSection] = @{}
                    $disabledConfig[$currentSection] = @()
                }
                return
            }
            
            # Key-value paar
            if ($workLine -match '^([^=]+)=(.*)$' -and $currentSection) {
                $key = $matches[1].Trim()
                $value = $matches[2].Trim()
                $config[$currentSection][$key] = $value
                
                # Markeer als uitgeschakeld als regel met # begint
                if ($isDisabled) {
                    $disabledConfig[$currentSection] += $key
                }
            }
        }
    }
    
    return @{Config = $config; Disabled = $disabledConfig}
}

# Functie om config.ini te schrijven
function Write-ConfigFile {
    param(
        [string]$filePath,
        [hashtable]$config,
        [hashtable]$disabledKeys = @{}  # Keys die uitgeschakeld zijn (krijgen #)
    )
    
    # Backup maken
    if (Test-Path $filePath) {
        Copy-Item $filePath "$filePath.backup" -Force
    }
    
    # Lees originele bestand om commentaren en formatting te behouden
    $originalLines = Get-Content $filePath -Encoding UTF8
    $newLines = @()
    $currentSection = ""
    $sectionHeadersSeen = @{}
    $sectionKeysSeen = @{}

    function Add-MissingKeysForSection {
        param(
            [string]$sectionName,
            [hashtable]$configData,
            [hashtable]$disabledMap,
            [hashtable]$seenMap,
            [ref]$lineBuffer
        )

        if (-not $sectionName) { return }
        if (-not $configData.ContainsKey($sectionName)) { return }

        if (-not $seenMap.ContainsKey($sectionName)) {
            $seenMap[$sectionName] = @{}
        }

        $missingKeys = @($configData[$sectionName].Keys | Where-Object { -not $seenMap[$sectionName].ContainsKey($_) })
        foreach ($missingKey in $missingKeys) {
            $missingValue = $configData[$sectionName][$missingKey]
            $shouldDisable = $disabledMap.ContainsKey($sectionName) -and $disabledMap[$sectionName] -contains $missingKey

            if ($shouldDisable) {
                $lineBuffer.Value += "# $missingKey=$missingValue"
            } else {
                $lineBuffer.Value += "$missingKey=$missingValue"
            }

            $seenMap[$sectionName][$missingKey] = $true
        }
    }
    
    foreach ($line in $originalLines) {
        $trimmed = $line.Trim()
        
        # Check of het een gecommentarieerde key-value is
        $isCommented = $trimmed.StartsWith("#")
        if ($isCommented) {
            $trimmed = $trimmed.Substring(1).Trim()
        }
        
        # Behoud commentaren (die niet key-value zijn) en lege regels
        if ($trimmed -eq "" -or ($isCommented -and $trimmed -notmatch '^([^=]+)=')) {
            $newLines += $line
            continue
        }
        
        # Section header
        if ($trimmed -match '^\[(.+)\]$') {
            Add-MissingKeysForSection -sectionName $currentSection -configData $config -disabledMap $disabledKeys -seenMap $sectionKeysSeen -lineBuffer ([ref]$newLines)

            $currentSection = $matches[1]
            $sectionHeadersSeen[$currentSection] = $true
            if (-not $sectionKeysSeen.ContainsKey($currentSection)) {
                $sectionKeysSeen[$currentSection] = @{}
            }
            $newLines += $line
            continue
        }
        
        # Key-value paar - update met nieuwe waarde
        if ($trimmed -match '^([^=]+)=(.*)$' -and $currentSection) {
            $key = $matches[1].Trim()
            if (-not $sectionKeysSeen.ContainsKey($currentSection)) {
                $sectionKeysSeen[$currentSection] = @{}
            }
            $sectionKeysSeen[$currentSection][$key] = $true

            if ($config.ContainsKey($currentSection) -and $config[$currentSection].ContainsKey($key)) {
                $newValue = $config[$currentSection][$key]
                
                # Check of deze key uitgeschakeld moet zijn
                $shouldDisable = $disabledKeys.ContainsKey($currentSection) -and $disabledKeys[$currentSection] -contains $key
                
                if ($shouldDisable) {
                    # Voeg # toe
                    $newLines += "# $key=$newValue"
                } else {
                    # Normale key-value zonder #
                    $newLines += "$key=$newValue"
                }
            } else {
                $newLines += $line
            }
        } else {
            $newLines += $line
        }
    }

    # Flush missing keys for the final section in the file
    Add-MissingKeysForSection -sectionName $currentSection -configData $config -disabledMap $disabledKeys -seenMap $sectionKeysSeen -lineBuffer ([ref]$newLines)

    # Add missing sections (and their keys) that do not exist in the original file
    foreach ($section in $config.Keys) {
        if ($sectionHeadersSeen.ContainsKey($section)) { continue }

        $newLines += ""
        $newLines += "[$section]"

        foreach ($key in $config[$section].Keys) {
            $value = $config[$section][$key]
            $shouldDisable = $disabledKeys.ContainsKey($section) -and $disabledKeys[$section] -contains $key

            if ($shouldDisable) {
                $newLines += "# $key=$value"
            } else {
                $newLines += "$key=$value"
            }
        }
    }
    
    # Schrijf naar bestand (UTF8 zonder BOM)
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllLines($filePath, $newLines, $utf8NoBom)
}

# Merge ontbrekende keys/secties vanuit defaults in actieve config
function Merge-ConfigDefaults {
    param(
        [hashtable]$targetConfig,
        [hashtable]$defaultsConfig,
        [hashtable]$disabledConfig
    )

    $stats = [ordered]@{
        AddedSections = 0
        AddedKeys = 0
        AddedItems = @()
    }

    if (-not $defaultsConfig) {
        return $stats
    }

    foreach ($section in $defaultsConfig.Keys) {
        if (-not $targetConfig.ContainsKey($section)) {
            $targetConfig[$section] = @{}
            $stats.AddedSections++
        }

        if (-not $disabledConfig.ContainsKey($section)) {
            $disabledConfig[$section] = @()
        }

        foreach ($key in $defaultsConfig[$section].Keys) {
            if (-not $targetConfig[$section].ContainsKey($key)) {
                $targetConfig[$section][$key] = $defaultsConfig[$section][$key]
                $stats.AddedKeys++
                $stats.AddedItems += "$section.$key"
            }
        }
    }

    return $stats
}

# Lees config
$configData = Read-ConfigFile -filePath $configFile
$config = $configData.Config
$disabledKeys = $configData.Disabled
$defaultsMergeStats = [ordered]@{ AddedSections = 0; AddedKeys = 0; AddedItems = @(); DefaultsFound = $false }

# Vul automatisch ontbrekende keys/secties aan vanuit config.example.ini.
# Hierdoor verschijnen nieuwe instellingen automatisch in config.ini na opslaan.
if (Test-Path $configDefaultsFile) {
    $defaultsData = Read-ConfigFile -filePath $configDefaultsFile
    $mergeStats = Merge-ConfigDefaults -targetConfig $config -defaultsConfig $defaultsData.Config -disabledConfig $disabledKeys
    $defaultsMergeStats = [ordered]@{
        AddedSections = $mergeStats.AddedSections
        AddedKeys = $mergeStats.AddedKeys
        AddedItems = $mergeStats.AddedItems
        DefaultsFound = $true
    }
    Write-Host "DEBUG: Defaults merged from config.example.ini (sections: $($mergeStats.AddedSections), keys: $($mergeStats.AddedKeys))"
}

# Debug output - verwijder dit later
Write-Host "DEBUG: Config loaded"
Write-Host "DEBUG: Subtitles section exists: $($config.ContainsKey('Subtitles'))"
if ($config.ContainsKey('Subtitles')) {
    Write-Host "DEBUG: EmbedOnlyPrimary = '$($config['Subtitles']['EmbedOnlyPrimary'])'"
    Write-Host "DEBUG: EmbedDefault = '$($config['Subtitles']['EmbedDefault'])'"
    Write-Host "DEBUG: EmbedForced = '$($config['Subtitles']['EmbedForced'])'"
}

# NOTE: GUI vult nu ontbrekende defaults aan vanuit config.example.ini.
# Hierdoor kunnen nieuwe keys automatisch in config.ini terechtkomen na opslaan.

# Maak globale tooltip provider
$globalToolTip = New-Object System.Windows.Forms.ToolTip
$globalToolTip.AutoPopDelay = 5000
$globalToolTip.InitialDelay = 500
$globalToolTip.ReshowDelay = 100

# Globale variabele om wijzigingen te tracken
$script:hasUnsavedChanges = $false
$script:saveButton = $null

# Functie om Opslaan knop te updaten
function Update-SaveButton {
    if ($script:saveButton -and $script:hasUnsavedChanges) {
        $script:saveButton.BackColor = [System.Drawing.Color]::Orange
        $script:saveButton.ForeColor = [System.Drawing.Color]::White
        $script:saveButton.Text = "Opslaan *"
        $globalToolTip.SetToolTip($script:saveButton, "Er zijn niet-opgeslagen wijzigingen!")
    } elseif ($script:saveButton) {
        $script:saveButton.BackColor = [System.Drawing.SystemColors]::Control
        $script:saveButton.ForeColor = [System.Drawing.SystemColors]::ControlText
        $script:saveButton.Text = "Opslaan"
        $globalToolTip.SetToolTip($script:saveButton, "Configuratie opslaan")
    }
}

# Functie om wijziging te markeren
function Mark-Changed {
    $script:hasUnsavedChanges = $true
    Update-SaveButton
}

# Maak form
$form = New-Object System.Windows.Forms.Form
$form.Text = "Config.ini Editor"
$form.Size = New-Object System.Drawing.Size(800, 700)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false

# TabControl
$tabControl = New-Object System.Windows.Forms.TabControl
$tabControl.Location = New-Object System.Drawing.Point(10, 10)
$tabControl.Size = New-Object System.Drawing.Size(760, 600)
$form.Controls.Add($tabControl)

# Helper functie voor het maken van een label en textbox
function Add-ConfigField {
    param(
        [System.Windows.Forms.Panel]$panel,
        [int]$y,
        [string]$labelText,
        [string]$value,
        [string]$tooltip = "",
        [int]$width = 500
    )
    
    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point(10, $y)
    $label.Size = New-Object System.Drawing.Size(200, 20)
    $label.Text = $labelText
    $panel.Controls.Add($label)
    
    $textbox = New-Object System.Windows.Forms.TextBox
    $textbox.Location = New-Object System.Drawing.Point(220, $y)
    $textbox.Size = New-Object System.Drawing.Size($width, 20)
    $textbox.Text = $value
    $textbox.Add_TextChanged({ Mark-Changed })
    $panel.Controls.Add($textbox)
    
    if ($tooltip) {
        $globalToolTip.SetToolTip($textbox, $tooltip)
    }
    
    return $textbox
}

# Helper functie voor combobox
function Add-ConfigCombo {
    param(
        [System.Windows.Forms.Panel]$panel,
        [int]$y,
        [string]$labelText,
        [string]$value,
        [string[]]$items,
        [string]$tooltip = ""
    )
    
    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point(10, $y)
    $label.Size = New-Object System.Drawing.Size(200, 20)
    $label.Text = $labelText
    $panel.Controls.Add($label)
    
    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.Location = New-Object System.Drawing.Point(220, $y)
    $combo.Size = New-Object System.Drawing.Size(200, 20)
    $combo.DropDownStyle = 'DropDownList'
    $items | ForEach-Object { $combo.Items.Add($_) | Out-Null }
    
    # Only set selected item if value exists in items, or if value is empty and empty option exists
    if ($value -in $items) {
        $combo.SelectedItem = $value
    } elseif ([string]::IsNullOrEmpty($value) -and ('' -in $items)) {
        $combo.SelectedItem = ''
    } elseif ($combo.Items.Count -gt 0) {
        # Only default to first item if no empty option exists and value is not null/empty
        if (-not [string]::IsNullOrEmpty($value)) {
            $combo.SelectedIndex = 0
        }
    }
    
    $combo.Add_SelectedIndexChanged({ Mark-Changed })
    $panel.Controls.Add($combo)
    
    if ($tooltip) {
        $globalToolTip.SetToolTip($combo, $tooltip)
    }
    
    return $combo
}

# Helper functie voor checkbox
function Add-ConfigCheckbox {
    param(
        [System.Windows.Forms.Panel]$panel,
        [int]$y,
        [string]$labelText,
        [string]$value,
        [string]$tooltip = ""
    )
    
    # Maak checkbox MET tekst (zoals in werkende test)
    $checkbox = New-Object System.Windows.Forms.CheckBox
    $checkbox.Location = New-Object System.Drawing.Point(220, $y)
    $checkbox.Size = New-Object System.Drawing.Size(500, 24)
    $checkbox.Text = $labelText
    $checkbox.Checked = ($value -eq "true")
    $checkbox.UseVisualStyleBackColor = $true
    $checkbox.Add_CheckedChanged({ Mark-Changed })
    $panel.Controls.Add($checkbox)
    
    if ($tooltip) {
        $globalToolTip.SetToolTip($checkbox, $tooltip)
    }
    
    return $checkbox
}

# Helper functie voor textbox met enable checkbox
function Add-ConfigFieldWithCheckbox {
    param(
        [System.Windows.Forms.Panel]$panel,
        [int]$y,
        [string]$labelText,
        [string]$value,
        [bool]$enabled,
        [string]$tooltip = "",
        [int]$width = 400
    )
    
    # Checkbox om aan te geven of veld gebruikt wordt
    $checkbox = New-Object System.Windows.Forms.CheckBox
    $checkbox.Location = New-Object System.Drawing.Point(10, $y)
    $checkbox.Size = New-Object System.Drawing.Size(20, 24)
    $checkbox.Checked = $enabled
    $checkbox.UseVisualStyleBackColor = $true
    $checkbox.Add_CheckedChanged({ Mark-Changed })
    $panel.Controls.Add($checkbox)
    
    # Label
    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point(35, $y)
    $label.Size = New-Object System.Drawing.Size(175, 20)
    $label.Text = $labelText
    $panel.Controls.Add($label)
    
    # Textbox - altijd de waarde tonen, niet afhankelijk van enabled
    $textbox = New-Object System.Windows.Forms.TextBox
    $textbox.Location = New-Object System.Drawing.Point(220, $y)
    $textbox.Size = New-Object System.Drawing.Size($width, 20)
    $textbox.Text = $value
    $textbox.Add_TextChanged({ Mark-Changed })
    $panel.Controls.Add($textbox)
    
    # GEEN koppeling tussen checkbox en textbox.Enabled
    # Textbox blijft altijd bewerkbaar
    
    if ($tooltip) {
        $globalToolTip.SetToolTip($textbox, $tooltip)
        $globalToolTip.SetToolTip($label, $tooltip)
        $globalToolTip.SetToolTip($checkbox, "Vink aan om dit pad te gebruiken, vink uit om RootDir\<mapnaam> te gebruiken")
    }
    
    return @{Checkbox = $checkbox; Textbox = $textbox}
}

# Hashtable om controles op te slaan
$controls = @{}

# ============================================================================
# TAB 1: Paths
# ============================================================================
$tabPaths = New-Object System.Windows.Forms.TabPage
$tabPaths.Text = "Paths"
$tabControl.Controls.Add($tabPaths)

$panelPaths = New-Object System.Windows.Forms.Panel
$panelPaths.AutoScroll = $true
$panelPaths.Dock = 'Fill'
$tabPaths.Controls.Add($panelPaths)

$y = 10
$controls['Paths_RootDir'] = Add-ConfigField $panelPaths $y "RootDir:" $config['Paths']['RootDir'] "Hoofdmap voor alle mappen (standaard)"
$y += 30
$controls['Paths_ToolsDir'] = Add-ConfigField $panelPaths $y "ToolsDir:" $config['Paths']['ToolsDir'] "Map met ffmpeg, FileBot, etc."

$y += 40
$labelOverrides = New-Object System.Windows.Forms.Label
$labelOverrides.Location = New-Object System.Drawing.Point(10, $y)
$labelOverrides.Size = New-Object System.Drawing.Size(700, 20)
$labelOverrides.Text = "Map Overrides (leeg laten voor RootDir\<mapnaam>):"
$labelOverrides.Font = New-Object System.Drawing.Font("Arial", 10, [System.Drawing.FontStyle]::Bold)
$panelPaths.Controls.Add($labelOverrides)

$y += 30
# Enabled als key NIET in disabled lijst zit
$controls['Paths_SourceDir'] = Add-ConfigFieldWithCheckbox $panelPaths $y "SourceDir:" $config['Paths']['SourceDir'] (-not ($disabledKeys['Paths'] -contains 'SourceDir')) "Downloads map (uitgeschakeld = RootDir\Downloads)" 500
$y += 30
$controls['Paths_DoneDir'] = Add-ConfigFieldWithCheckbox $panelPaths $y "DoneDir:" $config['Paths']['DoneDir'] (-not ($disabledKeys['Paths'] -contains 'DoneDir')) "Done map (bijv. E:\USB\Done)" 500
$y += 30
$controls['Paths_MediaDir'] = Add-ConfigFieldWithCheckbox $panelPaths $y "MediaDir:" $config['Paths']['MediaDir'] (-not ($disabledKeys['Paths'] -contains 'MediaDir')) "Media map (bijv. E:\USB\Media)" 500
$y += 30
$controls['Paths_LogsDir'] = Add-ConfigFieldWithCheckbox $panelPaths $y "LogsDir:" $config['Paths']['LogsDir'] (-not ($disabledKeys['Paths'] -contains 'LogsDir')) "Logs map (uitgeschakeld = RootDir\Logs)" 500
$y += 30
$controls['Paths_MetadataDir'] = Add-ConfigFieldWithCheckbox $panelPaths $y "MetadataDir:" $config['Paths']['MetadataDir'] (-not ($disabledKeys['Paths'] -contains 'MetadataDir')) "Metadata map (uitgeschakeld = RootDir\Metadata)" 500
$y += 30
$controls['Paths_TempDir'] = Add-ConfigFieldWithCheckbox $panelPaths $y "TempDir:" $config['Paths']['TempDir'] (-not ($disabledKeys['Paths'] -contains 'TempDir')) "Temp map (uitgeschakeld = RootDir\Temp)" 500

# ============================================================================
# TAB 2: Files
# ============================================================================
$tabFiles = New-Object System.Windows.Forms.TabPage
$tabFiles.Text = "Files"
$tabControl.Controls.Add($tabFiles)

$panelFiles = New-Object System.Windows.Forms.Panel
$panelFiles.AutoScroll = $true
$panelFiles.Dock = 'Fill'
$tabFiles.Controls.Add($panelFiles)

$y = 10
$controls['Files_MFormat'] = Add-ConfigField $panelFiles $y "MFormat:" $config['Files']['MFormat'] "Movie format"
$y += 30
$controls['Files_SFormat'] = Add-ConfigField $panelFiles $y "SFormat:" $config['Files']['SFormat'] "Series format"
$y += 30
$controls['Files_delext'] = Add-ConfigField $panelFiles $y "Delete extensies:" $config['Files']['delext'] "Bestandsextensies om te verwijderen (comma-separated)"
$y += 30
$controls['Files_Originals'] = Add-ConfigCombo $panelFiles $y "Originelen:" $config['Files']['Originals'] @('keep', 'remove') "keep = verplaats naar \Done, remove = verwijder"
$y += 30
$controls['Files_Rejected'] = Add-ConfigCombo $panelFiles $y "Rejected:" $config['Files']['Rejected'] @('keep', 'remove') "keep = behoud afgewezen bestanden, remove = ruim Rejected op en verwijder bronmappen"
$y += 30
$controls['Files_LogHistory'] = Add-ConfigCombo $panelFiles $y "Log History:" $config['Files']['LogHistory'] @('keep', 'remove') "keep = behoud logs, remove = wis logs bij start"
$y += 30
$controls['Files_TempFolder'] = Add-ConfigCombo $panelFiles $y "Temp Folder:" $config['Files']['TempFolder'] @('keep', 'remove') "keep = behoud Temp folder, remove = wis na voltooiing"
$y += 30
$y += 30
$controls['Files_MetadataFolder'] = Add-ConfigCombo $panelFiles $y "Metadata Folder:" $config['Files']['MetadataFolder'] @('keep', 'remove') "keep = behoud Metadata folder, remove = wis na voltooiing"

# ============================================================================
# TAB 3: Subtitles (Basis)
# ============================================================================
$tabSubs = New-Object System.Windows.Forms.TabPage
$tabSubs.Text = "Subtitles"
$tabControl.Controls.Add($tabSubs)

$panelSubs = New-Object System.Windows.Forms.Panel
$panelSubs.AutoScroll = $true
$panelSubs.Dock = 'Fill'
$tabSubs.Controls.Add($panelSubs)

$y = 10
$controls['Lang_LangKeep'] = Add-ConfigField $panelSubs $y "Talen:" $config['Lang']['LangKeep'] "Comma-separated lijst van talen om te behouden (bijv. dut,eng)" 300
$y += 30
$controls['Lang_LangFallback'] = Add-ConfigField $panelSubs $y "Vertaal van taal:" $config['Lang']['LangFallback'] "Brontaal voor Argos-vertaling indien geen sub gevonden (bijv. eng). Leeglaten om vertaling uit te schakelen." 300
$y += 30
$controls['Lang_TranslateMode'] = Add-ConfigCombo $panelSubs $y "Vertaalmodus:" $config['Lang']['TranslateMode'] @('fallback', 'force', 'off') "fallback = alleen vertalen als geen sub gevonden | force = altijd vertalen | off = nooit vertalen"
$y += 40

$labelTranslateHelp = New-Object System.Windows.Forms.Label
$labelTranslateHelp.Location = New-Object System.Drawing.Point(10, $y)
$labelTranslateHelp.Size = New-Object System.Drawing.Size(700, 55)
$labelTranslateHelp.Text = "Vertaalmodus uitleg (Argos Translate):`n• fallback = vertaal alleen als geen ondertitel in doeltaal gevonden wordt`n• force    = vertaal altijd vanuit de brontaal, ook als er al een ondertitel bestaat`n• off      = vertaling volledig uitschakelen"
$labelTranslateHelp.ForeColor = [System.Drawing.Color]::DarkGreen
$labelTranslateHelp.Font = New-Object System.Drawing.Font("Arial", 9)
$panelSubs.Controls.Add($labelTranslateHelp)
$y += 65

# Debug voor checkbox waarden
Write-Host "DEBUG: Creating checkboxes with values:"
Write-Host "  EmbedOnlyPrimary: '$($config['Subtitles']['EmbedOnlyPrimary'])'"
Write-Host "  EmbedDefault: '$($config['Subtitles']['EmbedDefault'])'"
Write-Host "  EmbedForced: '$($config['Subtitles']['EmbedForced'])'"

$controls['Subtitles_DownloadSubs'] = Add-ConfigCheckbox $panelSubs $y "Ondertitels downloaden (FileBot)" $config['Subtitles']['DownloadSubs'] "Uitvinken = stap 05 downloaden overslaan (handig als je subs al manueel hebt)"
$y += 40

$controls['Subtitles_StrictSubtitleDownload'] = Add-ConfigCheckbox $panelSubs $y "Strikte subtitle download" $config['Subtitles']['StrictSubtitleDownload'] "Aanvinken = alleen strikte titelmatch accepteren; bij geen match volgt STT + vertaling en wordt sync overgeslagen"
$y += 40

$controls['Subtitles_EmbedOnlyPrimary'] = Add-ConfigCheckbox $panelSubs $y "Alleen primaire taal embedden" $config['Subtitles']['EmbedOnlyPrimary'] "true = alleen eerste taal, false = alle talen"
$y += 30
$controls['Subtitles_EmbedDefault'] = Add-ConfigCheckbox $panelSubs $y "Primaire taal als default markeren" $config['Subtitles']['EmbedDefault'] "Stel eerste taal in als standaard ondertiteling"
$y += 30
$controls['Subtitles_EmbedForced'] = Add-ConfigCheckbox $panelSubs $y "Niet-primaire talen als 'forced' markeren" $config['Subtitles']['EmbedForced'] "Markeer andere talen met forced flag"

# ============================================================================
# TAB 3b: Audio
# ============================================================================
$tabAudio = New-Object System.Windows.Forms.TabPage
$tabAudio.Text = "Audio"
$tabControl.Controls.Add($tabAudio)

$panelAudio = New-Object System.Windows.Forms.Panel
$panelAudio.AutoScroll = $true
$panelAudio.Dock = 'Fill'
$tabAudio.Controls.Add($panelAudio)

$y = 10
$labelAudioInfo = New-Object System.Windows.Forms.Label
$labelAudioInfo.Location = New-Object System.Drawing.Point(10, $y)
$labelAudioInfo.Size = New-Object System.Drawing.Size(700, 60)
$labelAudioInfo.Text = "Audio track filtering verwijdert automatisch ongewenste audio talen.`nBijvoorbeeld: behoud alleen Engels en verwijder Italiaans, Frans, etc.`n`nWICHTIG: Schakel 'Audio filtering inschakelen' aan om deze functie te activeren!"
$labelAudioInfo.ForeColor = [System.Drawing.Color]::DarkBlue
$labelAudioInfo.Font = New-Object System.Drawing.Font("Arial", 9, [System.Drawing.FontStyle]::Bold)
$panelAudio.Controls.Add($labelAudioInfo)

$y += 70
$controls['Audio_AudioFilterEnabled'] = Add-ConfigCheckbox $panelAudio $y "Audio filtering inschakelen (verwijder ongewenste audio talen)" $config['Audio']['AudioFilterEnabled'] "Schakel dit IN om automatisch audio tracks te filteren op basis van taal"
$y += 40

$controls['Audio_AudioLangKeep'] = Add-ConfigField $panelAudio $y "Audio talen behouden:" $config['Audio']['AudioLangKeep'] "Comma-separated lijst van audio talen (bijv. eng,dut). Alleen deze talen worden behouden!" 300
$y += 40

$controls['Audio_AudioFallbackFirst'] = Add-ConfigCheckbox $panelAudio $y "Eerste track behouden als fallback" $config['Audio']['AudioFallbackFirst'] "Als geen enkele track matcht, behoud dan de eerste audio track"

$y += 50
$labelAudioExample = New-Object System.Windows.Forms.Label
$labelAudioExample.Location = New-Object System.Drawing.Point(10, $y)
$labelAudioExample.Size = New-Object System.Drawing.Size(700, 60)
$labelAudioExample.Text = "Voorbeelden:`n  AudioLangKeep=eng          → Behoud alleen Engels`n  AudioLangKeep=eng,dut      → Behoud Engels EN Nederlands`n  AudioFilterEnabled=false   → Schakel filtering uit (behoud alle audio)"
$labelAudioExample.Font = New-Object System.Drawing.Font("Consolas", 9)
$panelAudio.Controls.Add($labelAudioExample)

# ============================================================================
# TAB 4: Sync (met sub-tabs voor elke tool)
# ============================================================================
$tabSync = New-Object System.Windows.Forms.TabPage
$tabSync.Text = "Sync"
$tabControl.Controls.Add($tabSync)

# Sub-TabControl binnen Sync tab
$syncTabControl = New-Object System.Windows.Forms.TabControl
$syncTabControl.Location = New-Object System.Drawing.Point(5, 5)
$syncTabControl.Size = New-Object System.Drawing.Size(760, 450)
$tabSync.Controls.Add($syncTabControl)

# --- Sub-Tab 1: Algemeen ---
$tabSyncGeneral = New-Object System.Windows.Forms.TabPage
$tabSyncGeneral.Text = "Algemeen"
$syncTabControl.Controls.Add($tabSyncGeneral)

$panelSyncGeneral = New-Object System.Windows.Forms.Panel
$panelSyncGeneral.AutoScroll = $true
$panelSyncGeneral.Dock = 'Fill'
$tabSyncGeneral.Controls.Add($panelSyncGeneral)

$y = 10
$labelSyncSettings = New-Object System.Windows.Forms.Label
$labelSyncSettings.Location = New-Object System.Drawing.Point(10, $y)
$labelSyncSettings.Size = New-Object System.Drawing.Size(700, 20)
$labelSyncSettings.Text = "Synchronisatie Instellingen:"
$labelSyncSettings.Font = New-Object System.Drawing.Font("Arial", 10, [System.Drawing.FontStyle]::Bold)
$panelSyncGeneral.Controls.Add($labelSyncSettings)

$y += 30
$runCleanDefault = if ($config['Subtitles']['RunClean']) { $config['Subtitles']['RunClean'] } elseif ($config['Subtitles']['SkipClean'] -eq "true") { "false" } else { "true" }
$controls['Subtitles_RunClean'] = Add-ConfigCheckbox $panelSyncGeneral $y "Subtitle cleaning uitvoeren" $runCleanDefault "Aanvinken = HTML tags en SDH markers verwijderen | Uitvinken = cleaning overslaan"
$y += 40

$controls['Subtitles_SyncEnabled'] = Add-ConfigCheckbox $panelSyncGeneral $y "Synchronisatie uitvoeren" ($config['Subtitles']['SyncEnabled'] -eq 'true' -or $config['Subtitles']['SyncMode'] -eq 'always') "Aanvinken = ondertitels synchroniseren, uitvinken = direct embedden zonder sync"
$y += 40

# Vinkjes voor ALASS en FFSubSync
$y += 30
$y += 40
$controls['Subtitles_SyncDebug'] = Add-ConfigCheckbox $panelSyncGeneral $y "Debug Output" $config['Subtitles']['SyncDebug'] "Toon sync parameters in console (nuttig voor troubleshooting)"

$y += 40
$labelSyncModeHelp = New-Object System.Windows.Forms.Label
$labelSyncModeHelp.Location = New-Object System.Drawing.Point(10, $y)
$labelSyncModeHelp.Size = New-Object System.Drawing.Size(700, 60)
$labelSyncModeHelp.Text = "Synchronisatie opties:\n• ALASS gebruiken: alleen ALASS\n• FFSubSync gebruiken: alleen FFSubSync\n• Beide: eerst ALASS, dan FFSubSync (meest robuust)\n• Geen van beide: synchronisatie mislukt, vink minstens één optie aan!"
$labelSyncModeHelp.ForeColor = [System.Drawing.Color]::DarkGreen
$labelSyncModeHelp.Font = New-Object System.Drawing.Font("Arial", 9)
$panelSyncGeneral.Controls.Add($labelSyncModeHelp)

$y += 70
$labelSyncNote = New-Object System.Windows.Forms.Label
$labelSyncNote.Location = New-Object System.Drawing.Point(10, $y)
$labelSyncNote.Size = New-Object System.Drawing.Size(700, 80)
$labelSyncNote.Text = "Stel hieronder je sync mode in.`nGa naar de bijbehorende tab voor tool-specifieke instellingen:`n• ALASS tab voor ALASS parameters`n• FFSubSync tab voor FFSubSync parameters"
$labelSyncNote.ForeColor = [System.Drawing.Color]::DarkBlue
$labelSyncNote.Font = New-Object System.Drawing.Font("Arial", 9, [System.Drawing.FontStyle]::Italic)
$panelSyncGeneral.Controls.Add($labelSyncNote)


# --- Sub-Tab 3: ALASS ---
$tabAlass = New-Object System.Windows.Forms.TabPage
$tabAlass.Text = "ALASS"
$syncTabControl.Controls.Add($tabAlass)

$panelAlass = New-Object System.Windows.Forms.Panel
$panelAlass.AutoScroll = $true
$panelAlass.Dock = 'Fill'
$tabAlass.Controls.Add($panelAlass)

$y = 10
$labelAlass = New-Object System.Windows.Forms.Label
$labelAlass.Location = New-Object System.Drawing.Point(10, $y)
$labelAlass.Size = New-Object System.Drawing.Size(700, 20)
$labelAlass.Text = "ALASS Parameters (leeg = AUTO-DETECTIE):"
$labelAlass.Font = New-Object System.Drawing.Font("Arial", 10, [System.Drawing.FontStyle]::Bold)
$panelAlass.Controls.Add($labelAlass)

$y += 30
$controls['ALASS_AlassSplitPenalty'] = Add-ConfigField $panelAlass $y "Split Penalty:" $config['ALASS']['AlassSplitPenalty'] "Leeg=auto (<15min->3, <1h->7, >1h->12), handmatig: 1-20" 100
$y += 30
$controls['ALASS_AlassInterval'] = Add-ConfigField $panelAlass $y "Interval (ms):" $config['ALASS']['AlassInterval'] "Leeg=auto (<30min->1, <1h->2, >1h->3ms), lager=nauwkeuriger" 100
$y += 30
$controls['ALASS_AlassSpeedOptimization'] = Add-ConfigField $panelAlass $y "Speed Optimization:" $config['ALASS']['AlassSpeedOptimization'] "Leeg=auto (0-2), 0=max nauwkeurig, 2=max snel" 100
$y += 30
$controls['ALASS_AlassDisableFpsGuessing'] = Add-ConfigCheckbox $panelAlass $y "Disable FPS Guessing" $config['ALASS']['AlassDisableFpsGuessing'] "Leeg/false=auto FPS correctie, true=geen FPS correctie"
$y += 30
$controls['ALASS_AlassNoSplit'] = Add-ConfigCheckbox $panelAlass $y "No Split Mode" $config['ALASS']['AlassNoSplit'] "Leeg/false=detecteer splits, true=snellere sync zonder splits"
$y += 30
$controls['ALASS_AlassEncodingInc'] = Add-ConfigField $panelAlass $y "Sub Encoding:" $config['ALASS']['AlassEncodingInc'] "Leeg=auto, bijv. utf-8, latin-1" 100
$y += 30
$controls['ALASS_AlassEncodingRef'] = Add-ConfigField $panelAlass $y "Ref Encoding:" $config['ALASS']['AlassEncodingRef'] "Leeg=auto, bijv. utf-8, latin-1" 100

$y += 50
$labelAlassNote = New-Object System.Windows.Forms.Label
$labelAlassNote.Location = New-Object System.Drawing.Point(10, $y)
$labelAlassNote.Size = New-Object System.Drawing.Size(700, 40)
$labelAlassNote.Text = "ALASS (Automatic Language-Agnostic Subtitle Synchronization) is snel en nauwkeurig.`nLaat velden leeg voor intelligente auto-detectie op basis van video metadata."
$labelAlassNote.ForeColor = [System.Drawing.Color]::DarkBlue
$labelAlassNote.Font = New-Object System.Drawing.Font("Arial", 9, [System.Drawing.FontStyle]::Italic)
$panelAlass.Controls.Add($labelAlassNote)

# --- Sub-Tab 4: FFSubSync ---
$tabFFSubSync = New-Object System.Windows.Forms.TabPage
$tabFFSubSync.Text = "FFSubSync"
$syncTabControl.Controls.Add($tabFFSubSync)

$panelFFSubSync = New-Object System.Windows.Forms.Panel
$panelFFSubSync.AutoScroll = $true
$panelFFSubSync.Dock = 'Fill'
$tabFFSubSync.Controls.Add($panelFFSubSync)

$y = 10
$labelFFSubSync = New-Object System.Windows.Forms.Label
$labelFFSubSync.Location = New-Object System.Drawing.Point(10, $y)
$labelFFSubSync.Size = New-Object System.Drawing.Size(700, 20)
$labelFFSubSync.Text = "FFSubSync Parameters (leeg = AUTO-DETECTIE):"
$labelFFSubSync.Font = New-Object System.Drawing.Font("Arial", 10, [System.Drawing.FontStyle]::Bold)
$panelFFSubSync.Controls.Add($labelFFSubSync)

$y += 30
$controls['FFSubSync_FFSubSyncMaxOffset'] = Add-ConfigField $panelFFSubSync $y "Max Offset (sec):" $config['FFSubSync']['FFSubSyncMaxOffset'] "Leeg=auto (<15min->120, <1h->300, >1h->600)" 100
$y += 30
$controls['FFSubSync_FFSubSyncMaxSubtitleSeconds'] = Add-ConfigField $panelFFSubSync $y "Max Subtitle Sec:" $config['FFSubSync']['FFSubSyncMaxSubtitleSeconds'] "Max lengte ondertitelregel (default 10s)" 100
$y += 30
$controls['FFSubSync_FFSubSyncStartSeconds'] = Add-ConfigField $panelFFSubSync $y "Start Seconds:" $config['FFSubSync']['FFSubSyncStartSeconds'] "Start sync op tijdstip (bijv. 120 om intro over te slaan)" 100
$y += 30
$controls['FFSubSync_FFSubSyncVAD'] = Add-ConfigCombo $panelFFSubSync $y "VAD Method:" $config['FFSubSync']['FFSubSyncVAD'] @('', 'subs_then_webrtc', 'webrtc', 'auditok', 'silero', 'subs_then_auditok', 'subs_then_silero') "Leeg=auto (afhankelijk van audio codec)"
$y += 30
$controls['FFSubSync_FFSubSyncFrameRate'] = Add-ConfigField $panelFFSubSync $y "Frame Rate:" $config['FFSubSync']['FFSubSyncFrameRate'] "Leeg=AANBEVOLEN (ffsubsync detecteert zelf), forceer alleen bij problemen: 24, 25, 30" 100
$y += 30
$controls['FFSubSync_FFSubSyncNoFixFramerate'] = Add-ConfigCheckbox $panelFFSubSync $y "No Fix Framerate" $config['FFSubSync']['FFSubSyncNoFixFramerate'] "Schakel framerate correctie uit"
$y += 30
$controls['FFSubSync_FFSubSyncEncoding'] = Add-ConfigField $panelFFSubSync $y "Sub Encoding:" $config['FFSubSync']['FFSubSyncEncoding'] "Leeg=auto, bijv. utf-8, latin-1" 100
$y += 30
$controls['FFSubSync_FFSubSyncOutputEncoding'] = Add-ConfigField $panelFFSubSync $y "Output Encoding:" $config['FFSubSync']['FFSubSyncOutputEncoding'] "Output encoding (default utf-8)" 100

$y += 50
$labelFFSubSyncNote = New-Object System.Windows.Forms.Label
$labelFFSubSyncNote.Location = New-Object System.Drawing.Point(10, $y)
$labelFFSubSyncNote.Size = New-Object System.Drawing.Size(700, 40)
$labelFFSubSyncNote.Text = "FFSubSync gebruikt audio analyse voor nauwkeurige synchronisatie.`nLaat velden leeg voor intelligente auto-detectie op basis van video metadata."
$labelFFSubSyncNote.ForeColor = [System.Drawing.Color]::DarkBlue
$labelFFSubSyncNote.Font = New-Object System.Drawing.Font("Arial", 9, [System.Drawing.FontStyle]::Italic)
$panelFFSubSync.Controls.Add($labelFFSubSyncNote)

# ============================================================================
# TAB 5: Validatie
# ============================================================================
$tabValidation = New-Object System.Windows.Forms.TabPage
$tabValidation.Text = "Validatie"
$tabControl.Controls.Add($tabValidation)

$panelValidation = New-Object System.Windows.Forms.Panel
$panelValidation.AutoScroll = $true
$panelValidation.Dock = 'Fill'
$tabValidation.Controls.Add($panelValidation)

$y = 10
$labelValidationInfo = New-Object System.Windows.Forms.Label
$labelValidationInfo.Location = New-Object System.Drawing.Point(10, $y)
$labelValidationInfo.Size = New-Object System.Drawing.Size(700, 40)
$labelValidationInfo.Text = "Timing Validatie Thresholds:`nMAX = sync vereist (rood), WARN = waarschuwing maar acceptabel (geel)"
$labelValidationInfo.Font = New-Object System.Drawing.Font("Arial", 9, [System.Drawing.FontStyle]::Italic)
$labelValidationInfo.ForeColor = [System.Drawing.Color]::DarkBlue
$panelValidation.Controls.Add($labelValidationInfo)

$y += 50
$labelGaps = New-Object System.Windows.Forms.Label
$labelGaps.Location = New-Object System.Drawing.Point(10, $y)
$labelGaps.Size = New-Object System.Drawing.Size(700, 20)
$labelGaps.Text = "Gap Thresholds (stilte voor/na ondertitels, in milliseconden):"
$labelGaps.Font = New-Object System.Drawing.Font("Arial", 10, [System.Drawing.FontStyle]::Bold)
$panelValidation.Controls.Add($labelGaps)

$y += 30
$controls['Timing_MAX_GAP_START'] = Add-ConfigField $panelValidation $y "MAX_GAP_START:" $config['Timing']['MAX_GAP_START'] "Max stilte aan start (ms) - overschrijding = sync vereist" 150
$y += 30
$controls['Timing_WARN_GAP_START'] = Add-ConfigField $panelValidation $y "WARN_GAP_START:" $config['Timing']['WARN_GAP_START'] "Waarschuwing stilte start (ms) - trigger gele warning" 150
$y += 30
$controls['Timing_MAX_GAP_END'] = Add-ConfigField $panelValidation $y "MAX_GAP_END:" $config['Timing']['MAX_GAP_END'] "Max stilte aan einde (ms) - overschrijding = sync vereist" 150
$y += 30
$controls['Timing_WARN_GAP_END'] = Add-ConfigField $panelValidation $y "WARN_GAP_END:" $config['Timing']['WARN_GAP_END'] "Waarschuwing stilte einde (ms) - trigger gele warning" 150

$y += 40
$labelDrift = New-Object System.Windows.Forms.Label
$labelDrift.Location = New-Object System.Drawing.Point(10, $y)
$labelDrift.Size = New-Object System.Drawing.Size(700, 20)
$labelDrift.Text = "Drift Thresholds (timing verschuiving binnen ondertitels, in milliseconden):"
$labelDrift.Font = New-Object System.Drawing.Font("Arial", 10, [System.Drawing.FontStyle]::Bold)
$panelValidation.Controls.Add($labelDrift)

$y += 30
$controls['Timing_MAX_DRIFT'] = Add-ConfigField $panelValidation $y "MAX_DRIFT:" $config['Timing']['MAX_DRIFT'] "Max drift tussen ondertitels (ms) - overschrijding = sync vereist" 150
$y += 30
$controls['Timing_WARN_DRIFT'] = Add-ConfigField $panelValidation $y "WARN_DRIFT:" $config['Timing']['WARN_DRIFT'] "Waarschuwing drift (ms) - trigger gele warning" 150

$y += 50
$labelExplanation = New-Object System.Windows.Forms.Label
$labelExplanation.Location = New-Object System.Drawing.Point(10, $y)
$labelExplanation.Size = New-Object System.Drawing.Size(700, 80)
$labelExplanation.Text = "Hoe het werkt:`n• START/END GAP: Stilte voor eerste/na laatste ondertitel`n• DRIFT: Timing inconsistentie tussen opeenvolgende ondertitels`n• MAX waarden: Overschrijding vereist synchronisatie (rood)`n• WARN waarden: Waarschuwing maar acceptabel (geel)"
$labelExplanation.Font = New-Object System.Drawing.Font("Arial", 9)
$labelExplanation.ForeColor = [System.Drawing.Color]::DarkGreen
$panelValidation.Controls.Add($labelExplanation)

# ============================================================================
# TAB 6: Video
# ============================================================================
$tabVideo = New-Object System.Windows.Forms.TabPage
$tabVideo.Text = "Video"
$tabControl.Controls.Add($tabVideo)

$panelVideo = New-Object System.Windows.Forms.Panel
$panelVideo.AutoScroll = $true
$panelVideo.Dock = 'Fill'
$tabVideo.Controls.Add($panelVideo)

$y = 10
$controls['Video_H265Action'] = Add-ConfigCombo $panelVideo $y "H265 Actie:" $config['Video']['H265Action'] @('convert', 'downscale', 'reject', 'skip') "convert=H.264, downscale=8-bit H.265, reject=afwijzen, skip=negeren"
$y += 30
$controls['Video_H265Encoder'] = Add-ConfigCombo $panelVideo $y "H265 Encoder:" $config['Video']['H265Encoder'] @('cpu', 'nvidia', 'amd') "Hardware encoder voor H.265"
$y += 30
$controls['Video_H265Preset'] = Add-ConfigField $panelVideo $y "H265 Preset:" $config['Video']['H265Preset'] "ultrafast, fast, medium, slow" 200
$y += 30
$controls['Video_H265CRF'] = Add-ConfigField $panelVideo $y "H265 CRF:" $config['Video']['H265CRF'] "Kwaliteit (18=hoog, 28=normaal, 32=laag)" 100

$y += 40
$labelDownscale = New-Object System.Windows.Forms.Label
$labelDownscale.Location = New-Object System.Drawing.Point(10, $y)
$labelDownscale.Size = New-Object System.Drawing.Size(700, 20)
$labelDownscale.Text = "Downscale Instellingen (10-bit/12-bit naar 8-bit):"
$labelDownscale.Font = New-Object System.Drawing.Font("Arial", 10, [System.Drawing.FontStyle]::Bold)
$panelVideo.Controls.Add($labelDownscale)

$y += 30
$controls['Video_DownscaleMinResolution'] = Add-ConfigField $panelVideo $y "Min Resolutie:" $config['Video']['DownscaleMinResolution'] "1080, 960, 720, of 0 (alles)" 100
$y += 30
$controls['Video_DownscaleResolution'] = Add-ConfigCombo $panelVideo $y "Doel Resolutie:" $config['Video']['DownscaleResolution'] @('keep', '1080p', '720p') "keep=behoud resolutie, 1080p/720p=schaal naar resolutie"
$y += 30
$controls['Video_DownscaleEncoder'] = Add-ConfigCombo $panelVideo $y "Downscale Encoder:" $config['Video']['DownscaleEncoder'] @('nvidia', 'amd', 'cpu') "nvidia=snelst, cpu=beste kwaliteit"
$y += 30
$controls['Video_DownscaleCRF'] = Add-ConfigField $panelVideo $y "Downscale CRF:" $config['Video']['DownscaleCRF'] "18=hoog, 28=normaal, 32=laag" 100
$y += 30
$controls['Video_DownscalePreset'] = Add-ConfigField $panelVideo $y "Downscale Preset:" $config['Video']['DownscalePreset'] "NVIDIA: p1-p7, CPU: ultrafast-slow" 150
$y += 30
$controls['Video_DownscaleScaling'] = Add-ConfigCombo $panelVideo $y "Schaling Algoritme:" $config['Video']['DownscaleScaling'] @('bilinear', 'lanczos') "bilinear=snel, lanczos=beste kwaliteit"
$y += 30
$controls['Video_DownscaleAudio'] = Add-ConfigCombo $panelVideo $y "Audio Handling:" $config['Video']['DownscaleAudio'] @('copy', 'aac') "copy=behoud origineel, aac=encode naar AAC"
$y += 30
$controls['Video_DownscaleBitrate'] = Add-ConfigField $panelVideo $y "Bitrate:" $config['Video']['DownscaleBitrate'] "bijv. 5M voor 1080p, 3M voor 720p, leeg voor CRF" 150
$y += 30
$controls['Video_DownscaleMaxWidth'] = Add-ConfigField $panelVideo $y "Max Width:" $config['Video']['DownscaleMaxWidth'] "TV-safe max breedte bij keep (1920 aanbevolen, 0=uit)" 120
$y += 30
$controls['Video_DownscaleFallbackToH264'] = Add-ConfigCheckbox $panelVideo $y "H.264 fallback inschakelen (alleen bij tv-risky brede video)" $config['Video']['DownscaleFallbackToH264'] "true=gebruik fallback, false=alleen normale downscale"
$y += 40
$controls['Video_DownscaleFallbackH264Mode'] = Add-ConfigCombo $panelVideo $y "Fallback Mode:" $config['Video']['DownscaleFallbackH264Mode'] @('direct', 'separate', 'replace') "direct=skip HEVC en direct H.264 | separate=HEVC + extra H.264 | replace=HEVC vervangen door H.264"
$y += 30
$controls['Video_DownscaleFallbackH264Encoder'] = Add-ConfigCombo $panelVideo $y "Fallback H.264 Encoder:" $config['Video']['DownscaleFallbackH264Encoder'] @('nvidia', 'amd', 'cpu') "Encoder voor H.264 fallback"
$y += 30
$controls['Video_DownscaleFallbackH264Preset'] = Add-ConfigCombo $panelVideo $y "Fallback H.264 Preset:" $config['Video']['DownscaleFallbackH264Preset'] @('ultrafast', 'fast', 'medium', 'slow') "Preset voor H.264 fallback"
$y += 30
$controls['Video_DownscaleFallbackH264CRF'] = Add-ConfigField $panelVideo $y "Fallback H.264 CRF:" $config['Video']['DownscaleFallbackH264CRF'] "18=hoog, 23=aanbevolen, 28=kleiner bestand" 120
$y += 30
$controls['Video_ForceAspectRatio'] = Add-ConfigCombo $panelVideo $y "Aspect Ratio:" $config['Video']['ForceAspectRatio'] @('', '16:9', '4:3', 'keep') "(leeg)=auto-detect (AANBEVOLEN), 16:9=breedbeeld, 4:3=vierkant, keep=behoud origineel"

# ============================================================================
# TAB 7: Tools & Executables
# ============================================================================
$tabTools = New-Object System.Windows.Forms.TabPage
$tabTools.Text = "Tools"
$tabControl.Controls.Add($tabTools)

$panelTools = New-Object System.Windows.Forms.Panel
$panelTools.AutoScroll = $true
$panelTools.Dock = 'Fill'
$tabTools.Controls.Add($panelTools)

$y = 10
$labelExe = New-Object System.Windows.Forms.Label
$labelExe.Location = New-Object System.Drawing.Point(10, $y)
$labelExe.Size = New-Object System.Drawing.Size(700, 20)
$labelExe.Text = "Executables (laat leeg voor default):"
$labelExe.Font = New-Object System.Drawing.Font("Arial", 10, [System.Drawing.FontStyle]::Bold)
$panelTools.Controls.Add($labelExe)

$y += 30
$controls['Executables_CheckLangExe'] = Add-ConfigField $panelTools $y "LangCheck Exe:" $config['Executables']['CheckLangExe'] "LangCheck.exe (language detection)" 300
$y += 30
$controls['Executables_AutoSubSyncExe'] = Add-ConfigField $panelTools $y "AutoSubSync Exe:" $config['Executables']['AutoSubSyncExe'] "autosubsync.exe (AANBEVOLEN - bevat alles!)" 300
$y += 30
$controls['Executables_AlassExe'] = Add-ConfigField $panelTools $y "ALASS Exe (optioneel):" $config['Executables']['AlassExe'] "alass-cli.exe (niet nodig met AutoSubSync)" 300
$y += 30
$controls['Executables_FFSubSyncExe'] = Add-ConfigField $panelTools $y "FFSubSync (optioneel):" $config['Executables']['FFSubSyncExe'] "ffsubsync (niet nodig met AutoSubSync)" 300
$y += 30
$controls['Executables_TranslatorExe'] = Add-ConfigField $panelTools $y "Translator Python Exe:" $config['Executables']['TranslatorExe'] "C:\Python\311\python.exe" 300
$y += 30
$controls['Executables_TranslatorScript'] = Add-ConfigField $panelTools $y "Translator Script (.py):" $config['Executables']['TranslatorScript'] "C:\QBtor\translate_srt_argos.py" 300
$y += 30
$controls['Executables_TranslatorPackagesDir'] = Add-ConfigField $panelTools $y "Translator Packages Dir:" $config['Executables']['TranslatorPackagesDir'] "C:\Video\translate_srt_argos\argos-packages" 300
$y += 30
$controls['Executables_TranslatorBackend'] = Add-ConfigCombo $panelTools $y "Translator Backend:" $config['Executables']['TranslatorBackend'] @('auto', 'argos', 'ollama') "auto=probeer Argos eerst, anders Ollama | ollama=alleen Ollama | argos=alleen Argos" 300
$y += 30
$controls['Executables_TranslatorOllamaModel'] = Add-ConfigField $panelTools $y "Translator Ollama Model:" $config['Executables']['TranslatorOllamaModel'] "mistral" 300
$y += 30
$controls['Executables_STTExe'] = Add-ConfigField $panelTools $y "Whisper STT Exe:" $config['Executables']['STTExe'] "C:\Video\whisper\whisper.exe" 300

$y += 40
$labelNote = New-Object System.Windows.Forms.Label
$labelNote.Location = New-Object System.Drawing.Point(10, $y)
$labelNote.Size = New-Object System.Drawing.Size(700, 60)
$labelNote.Text = "TIP: AutoSubSync bevat alle sync methodes (autosubsync, ffsubsync, alass) in één .exe!`nDownload: https://github.com/lukaskroepfl/autosubsync/releases`nZet SyncTool op 'autosubsync' in Subtitles tab voor beste resultaten."
$labelNote.ForeColor = [System.Drawing.Color]::DarkBlue
$panelTools.Controls.Add($labelNote)

# ============================================================================
# TAB: STT (Speech-to-Text)
# ============================================================================
$tabSTT = New-Object System.Windows.Forms.TabPage
$tabSTT.Text = "STT"
$tabControl.Controls.Add($tabSTT)

$panelSTT = New-Object System.Windows.Forms.Panel
$panelSTT.AutoScroll = $true
$panelSTT.Dock = 'Fill'
$tabSTT.Controls.Add($panelSTT)

$y = 10
$labelSTTInfo = New-Object System.Windows.Forms.Label
$labelSTTInfo.Location = New-Object System.Drawing.Point(10, $y)
$labelSTTInfo.Size = New-Object System.Drawing.Size(700, 45)
$labelSTTInfo.Text = "Speech-to-Text genereert automatisch een ondertitel via Whisper als er geen sub gevonden is.`nDe gegenereerde sub wordt daarna (indien nodig) vertaald via Argos (stap 11)."
$labelSTTInfo.ForeColor = [System.Drawing.Color]::DarkBlue
$labelSTTInfo.Font = New-Object System.Drawing.Font("Arial", 9, [System.Drawing.FontStyle]::Bold)
$panelSTT.Controls.Add($labelSTTInfo)

$y += 55
$controls['STT_STTEnabled'] = Add-ConfigCheckbox $panelSTT $y "STT inschakelen (Whisper)" $config['STT']['STTEnabled'] "true = genereer sub met Whisper als er geen sub gevonden is"
$y += 35
$controls['STT_STTModel'] = Add-ConfigCombo $panelSTT $y "Whisper model:" $config['STT']['STTModel'] @('tiny','base','small','medium','large') "tiny/base = snel maar minder nauwkeurig | medium/large = beter maar trager"
$y += 35
$controls['STT_STTLanguage'] = Add-ConfigField $panelSTT $y "Audiotaal:" $config['STT']['STTLanguage'] "Taalcode van de audio: auto (automatisch detecteren) of bijv. eng, nl, fr" 150
$y += 35
$controls['STT_STTMultilingual'] = Add-ConfigCombo $panelSTT $y "Meertalig (multilingual):" $config['STT']['STTMultilingual'] @('auto','true','false') "auto = aan bij STTLanguage=auto, uit bij vaste taal  |  true = altijd per segment detecteren (traagst)  |  false = nooit, één detectie aan het begin (snelst)"
$y += 35
$controls['STT_STTDetectionSegments'] = Add-ConfigField $panelSTT $y "Detectie-segmenten:" $config['STT']['STTDetectionSegments'] "Aantal ~30s segmenten dat Whisper bij 'auto' gebruikt voor taaldetectie. Verhoog dit als de video begint met een andere taal (bijv. 5 = eerste 2,5 min). Standaard: 5" 80
$y += 35
$controls['STT_STTOutputLang'] = Add-ConfigField $panelSTT $y "Outputtaal sub:" $config['STT']['STTOutputLang'] "Taalcode van de gegenereerde SRT (leeg = zelfde als audiotaal, bijv. eng voor vertaling via Argos)" 150
$y += 35
$controls['STT_STTModelDir'] = Add-ConfigField $panelSTT $y "Model map:" $config['STT']['STTModelDir'] "Map waar Whisper modellen opslaat/zoekt. Leeg = standaard cache (%USERPROFILE%\.cache\huggingface\hub). Bijv. C:\Video\Faster-Whisper-XXL\_models" 450

$y += 45
$labelSTTHelp = New-Object System.Windows.Forms.Label
$labelSTTHelp.Location = New-Object System.Drawing.Point(10, $y)
$labelSTTHelp.Size = New-Object System.Drawing.Size(700, 145)
$labelSTTHelp.Text = "Meertalig (multilingual) uitleg:`n  false = Whisper detecteert de taal eenmalig aan het begin → snel, maar een Russische cold open maakt alles Russisch`n  auto  = bij STTLanguage=auto detecteert Whisper de taal per segment (~30s) → correct bij gemengde talen, licht trager`n  true  = per-segment detectie altijd aan, ook bij vaste STTLanguage → zelden nodig`n`nAanbevolen voor Engelstalige series (bijv. X-Files):`n  STTLanguage  = eng   → geen detectie, maximale snelheid, cold opens worden fonetisch Engels`n  STTMultilingual = false`n`nAanbevolen voor onbekende taal:`n  STTLanguage  = auto  |  STTMultilingual = auto"
$labelSTTHelp.ForeColor = [System.Drawing.Color]::DarkGreen
$labelSTTHelp.Font = New-Object System.Drawing.Font("Arial", 9)
$panelSTT.Controls.Add($labelSTTHelp)

# ============================================================================
# TAB 8: Debug & Monitoring
# ============================================================================
$tabDebug = New-Object System.Windows.Forms.TabPage
$tabDebug.Text = "Debug"
$tabControl.Controls.Add($tabDebug)

$panelDebug = New-Object System.Windows.Forms.Panel
$panelDebug.AutoScroll = $true
$panelDebug.Dock = 'Fill'
$tabDebug.Controls.Add($panelDebug)

$y = 10
$controls['Debug_DEBUGMode'] = Add-ConfigCheckbox $panelDebug $y "Debug Mode" $config['Debug']['DEBUGMode'] "Schakel debug mode in/uit"
$y += 30
$controls['Debug_DrvMax'] = Add-ConfigField $panelDebug $y "DrvMax:" $config['Debug']['DrvMax'] "" 100
$y += 30
$controls['Debug_DrvMin'] = Add-ConfigField $panelDebug $y "DrvMin:" $config['Debug']['DrvMin'] "" 100

$y += 40
$labelMonitoring = New-Object System.Windows.Forms.Label
$labelMonitoring.Location = New-Object System.Drawing.Point(10, $y)
$labelMonitoring.Size = New-Object System.Drawing.Size(700, 20)
$labelMonitoring.Text = "Resource Monitoring:"
$labelMonitoring.Font = New-Object System.Drawing.Font("Arial", 10, [System.Drawing.FontStyle]::Bold)
$panelDebug.Controls.Add($labelMonitoring)

$y += 30
$controls['Monitoring_ResourceMonitoring'] = Add-ConfigCheckbox $panelDebug $y "Resource Monitoring inschakelen" $config['Monitoring']['ResourceMonitoring'] "Log CPU en geheugen gebruik"
$y += 30
$controls['Monitoring_MonitoringInterval'] = Add-ConfigField $panelDebug $y "Interval (seconden):" $config['Monitoring']['MonitoringInterval'] "Hoe vaak loggen (30-60 aanbevolen)" 100

# ============================================================================
# Buttons
# ============================================================================
$labelDefaultsStatus = New-Object System.Windows.Forms.Label
$labelDefaultsStatus.Location = New-Object System.Drawing.Point(10, 627)
$labelDefaultsStatus.Size = New-Object System.Drawing.Size(560, 20)
$labelDefaultsStatus.ForeColor = [System.Drawing.Color]::DarkSlateGray
$labelDefaultsStatus.Font = New-Object System.Drawing.Font("Arial", 8)

if ($defaultsMergeStats.DefaultsFound) {
    $labelDefaultsStatus.Text = "Auto-defaults: +$($defaultsMergeStats.AddedKeys) key(s), +$($defaultsMergeStats.AddedSections) sectie(s) uit config.example.ini"
} else {
    $labelDefaultsStatus.Text = "Auto-defaults: config.example.ini niet gevonden"
}

$form.Controls.Add($labelDefaultsStatus)

$buttonDefaultsDetails = New-Object System.Windows.Forms.Button
$buttonDefaultsDetails.Location = New-Object System.Drawing.Point(490, 620)
$buttonDefaultsDetails.Size = New-Object System.Drawing.Size(80, 30)
$buttonDefaultsDetails.Text = "Details"

if (-not $defaultsMergeStats.DefaultsFound -or $defaultsMergeStats.AddedKeys -eq 0) {
    $buttonDefaultsDetails.Enabled = $false
    $globalToolTip.SetToolTip($buttonDefaultsDetails, "Geen toegevoegde defaults om te tonen")
} else {
    $globalToolTip.SetToolTip($buttonDefaultsDetails, "Toon welke secties/keys automatisch zijn toegevoegd")
}

$buttonDefaultsDetails.Add_Click({
    if (-not $defaultsMergeStats.DefaultsFound) {
        [System.Windows.Forms.MessageBox]::Show("config.example.ini niet gevonden.", "Auto-defaults details", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }

    if (-not $defaultsMergeStats.AddedItems -or $defaultsMergeStats.AddedItems.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Geen nieuwe defaults toegevoegd in deze sessie.", "Auto-defaults details", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }

    $detailsHeader = "Toegevoegde defaults uit config.example.ini:`n"
    $detailsBody = ($defaultsMergeStats.AddedItems | Sort-Object | ForEach-Object { " - $_" }) -join "`n"
    $detailsText = "$detailsHeader`n$detailsBody"

    [System.Windows.Forms.MessageBox]::Show($detailsText, "Auto-defaults details", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
})

$form.Controls.Add($buttonDefaultsDetails)

$buttonSave = New-Object System.Windows.Forms.Button
$buttonSave.Location = New-Object System.Drawing.Point(580, 620)
$buttonSave.Size = New-Object System.Drawing.Size(90, 30)
$buttonSave.Text = "Opslaan"
$script:saveButton = $buttonSave
$buttonSave.Add_Click({
    # Update config hashtable met waarden uit controls
    $newDisabledKeys = @{}
    
    foreach ($key in $controls.Keys) {
        $parts = $key -split '_', 2
        $section = $parts[0]
        $setting = $parts[1]
        $control = $controls[$key]

        # Forceer AutoSubSync settings naar juiste sectie
        if ($section -eq 'AutoSubSync') {
            if (-not $config.ContainsKey('AutoSubSync')) { $config['AutoSubSync'] = @{} }
            if ($control -is [System.Windows.Forms.TextBox]) {
                $config['AutoSubSync'][$setting] = $control.Text
            } elseif ($control -is [System.Windows.Forms.ComboBox]) {
                $config['AutoSubSync'][$setting] = $control.SelectedItem
            } elseif ($control -is [System.Windows.Forms.CheckBox]) {
                $config['AutoSubSync'][$setting] = if ($control.Checked) { "true" } else { "false" }
            } elseif ($control -is [hashtable]) {
                $config['AutoSubSync'][$setting] = $control.Textbox.Text
                if (-not $control.Checkbox.Checked) {
                    if (-not $newDisabledKeys.ContainsKey('AutoSubSync')) { $newDisabledKeys['AutoSubSync'] = @() }
                    $newDisabledKeys['AutoSubSync'] += $setting
                }
            }
            continue
        }

        # Standaard gedrag voor andere secties
        if (-not $config.ContainsKey($section)) {
            $config[$section] = @{}
        }

        if ($control -is [System.Windows.Forms.TextBox]) {
            $config[$section][$setting] = $control.Text
        } elseif ($control -is [System.Windows.Forms.ComboBox]) {
            $config[$section][$setting] = $control.SelectedItem
        } elseif ($control -is [System.Windows.Forms.CheckBox]) {
            $config[$section][$setting] = if ($control.Checked) { "true" } else { "false" }
        } elseif ($control -is [hashtable]) {
            $config[$section][$setting] = $control.Textbox.Text
            if (-not $control.Checkbox.Checked) {
                if (-not $newDisabledKeys.ContainsKey($section)) { $newDisabledKeys[$section] = @() }
                $newDisabledKeys[$section] += $setting
            }
        }
    }
    
    # Schrijf config met disabled keys
    Write-ConfigFile -filePath $configFile -config $config -disabledKeys $newDisabledKeys
    
    # Reset wijzigingen status
    $script:hasUnsavedChanges = $false
    Update-SaveButton
    
    [System.Windows.Forms.MessageBox]::Show("Configuratie succesvol opgeslagen!`n`nBackup: config.ini.backup", "Opgeslagen", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
})
$form.Controls.Add($buttonSave)

$buttonCancel = New-Object System.Windows.Forms.Button
$buttonCancel.Location = New-Object System.Drawing.Point(680, 620)
$buttonCancel.Size = New-Object System.Drawing.Size(90, 30)
$buttonCancel.Text = "Sluiten"
$buttonCancel.Add_Click({
    # Waarschuw als er niet-opgeslagen wijzigingen zijn
    if ($script:hasUnsavedChanges) {
        $result = [System.Windows.Forms.MessageBox]::Show(
            "Er zijn niet-opgeslagen wijzigingen.`n`nWilt u deze wijzigingen opslaan?",
            "Niet-opgeslagen wijzigingen",
            [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        
        if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
            # Trigger save button click
            $buttonSave.PerformClick()
        } elseif ($result -eq [System.Windows.Forms.DialogResult]::Cancel) {
            # Niet sluiten
            return
        }
        # Bij No: gewoon sluiten zonder opslaan
    }
    $form.Close()
})
$form.Controls.Add($buttonCancel)

# Toon form
$form.ShowDialog() | Out-Null
