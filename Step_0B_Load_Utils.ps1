# Utils.ps1

# ─── GUARD: voorkom directe uitvoering ────────────────────────────────
if ($MyInvocation.InvocationName -eq $MyInvocation.MyCommand.Name) {
    Show-Format "ERROR" "Don't run Utils.ps1 directly - dot-source it from your main script." -NameColor "Red"
}

# Automatic add of UTF8 coding for console
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8


$ScreenWidth = $Host.UI.RawUI.WindowSize.Width

#*********************************************************************************************
#      Constanten
#*********************************************************************************************
$Global:LangMap = @{
    dut = @("nl", "nld", "dut")
    eng = @("en", "eng")
    fra = @("fr", "fre", "fra")
    deu = @("de", "ger", "deu")
    spa = @("es", "spa")
    por = @("pt", "por")
    ita = @("it", "ita")
    pol = @("pl", "pol")
    swe = @("sv", "swe")
    nor = @("no", "nor")
    dan = @("da", "dan")
    fin = @("fi", "fin")
    est = @("et", "est")
    lav = @("lv", "lav")
    lit = @("lt", "lit")
    cze = @("cs", "cze")
    slv = @("sl", "slv")
    slk = @("sk", "slo", "slk")
    rus = @("ru", "rus")
    ukr = @("uk", "ukr")
    bul = @("bg", "bul")
    gre = @("el", "gre")
    tur = @("tr", "tur")
    ara = @("ar", "ara")
    heb = @("he", "heb")
    hin = @("hi", "hin")
    jpn = @("ja", "jpn")
    kor = @("ko", "kor")
    chi = @("zh", "chi")
    vie = @("vi", "vie")
    may = @("ms", "may", "msa")
    ind = @("id", "ind")
    tam = @("ta", "tam")
    tel = @("te", "tel")
    tha = @("th", "tha")
}

#*********************************************************************************************
#      Text Formatting Utils
#*********************************************************************************************

function Show-Warning { param ($msg) Write-Host "[WARNING   ] $msg" -ForegroundColor Yellow }
function Show-Error   { param ($msg) Write-Host "[ERROR     ] $msg" -ForegroundColor Red }
function Show-Info    { param ($msg) Write-Host "[INFO      ] $msg" -ForegroundColor Cyan }
function Show-Debug   { param ($msg) Write-Host "[DEBUG     ] $msg" -ForegroundColor DarkGray }

function Write-LogEntry {
    param(
        [string]$LogFile,
        [string]$Message
    )

    if ([string]::IsNullOrWhiteSpace($LogFile) -or [string]::IsNullOrWhiteSpace($Message)) {
        return
    }

    # Step logs are transcript files and can be locked for direct Add-Content.
    if ($Global:CurrentStepLogFile -and ($LogFile -eq $Global:CurrentStepLogFile)) {
        Write-Host $Message
        return
    }

    try {
        Add-Content -Path $LogFile -Value $Message -ErrorAction Stop
    } catch {
        try {
            Start-Sleep -Milliseconds 120
            Add-Content -Path $LogFile -Value $Message -ErrorAction Stop
        } catch {
            # Ignore log write failures; do not break conversion flow.
        }
    }
}

#*********************************************************************************************
#      Resource Monitoring
#*********************************************************************************************

function Start-ResourceMonitoring {
    param(
        [int]$IntervalSeconds = 30,
        [string]$LogFile = ""
    )
    
    if (-not $LogFile) {
        $LogFile = Join-Path $Global:LogDir "resource_monitor_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    }
    
    # Create monitoring job
    $monitorJob = Start-Job -ScriptBlock {
        param($interval, $logPath)
        
        $header = "Timestamp,CPU%,Memory(MB),MemoryAvailable(MB),ActiveProcesses"
        Add-Content -Path $logPath -Value $header
        
        while ($true) {
            try {
                $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                
                # CPU usage - use WMI for more reliable measurement
                $cpuPercent = 0
                try {
                    # Method 1: Try performance counter first
                    $cpuCounter = Get-Counter '\Processor(_Total)\% Processor Time' -ErrorAction Stop
                    $cpuPercent = [math]::Round($cpuCounter.CounterSamples.CookedValue, 2)
                } catch {
                    # Method 2: Fallback to WMI if counter fails
                    $cpu = Get-WmiObject Win32_Processor -ErrorAction SilentlyContinue
                    if ($cpu) {
                        $cpuPercent = [math]::Round($cpu.LoadPercentage, 2)
                    }
                }
                
                # If still 0, calculate from process CPU usage
                if ($cpuPercent -eq 0) {
                    $allProcs = Get-Process -ErrorAction SilentlyContinue
                    $totalCpu = ($allProcs | Measure-Object -Property CPU -Sum -ErrorAction SilentlyContinue).Sum
                    if ($totalCpu -gt 0) {
                        # Estimate based on process activity
                        $cpuPercent = [math]::Min(100, [math]::Round($totalCpu / 10, 2))
                    }
                }
                
                # Memory usage
                $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
                if (-not $os) {
                    $os = Get-WmiObject Win32_OperatingSystem -ErrorAction SilentlyContinue
                }
                $totalMemMB = [math]::Round($os.TotalVisibleMemorySize / 1KB, 2)
                $freeMemMB = [math]::Round($os.FreePhysicalMemory / 1KB, 2)
                $usedMemMB = [math]::Round($totalMemMB - $freeMemMB, 2)
                
                # Active video processing tools
                $activeProcesses = @()
                $processNames = @('ffmpeg', 'ffprobe', 'filebot', 'mkvmerge', 'mkvextract', 'java', 'alass-cli', 'python')
                
                foreach ($procName in $processNames) {
                    $procs = Get-Process -Name $procName -ErrorAction SilentlyContinue
                    if ($procs) {
                        foreach ($proc in $procs) {
                            $procCpu = try { [math]::Round($proc.CPU, 1) } catch { 0 }
                            $procMem = [math]::Round($proc.WorkingSet64 / 1MB, 1)
                            $activeProcesses += "${procName}(CPU:${procCpu}s,MEM:${procMem}MB,PID:$($proc.Id))"
                        }
                    }
                }
                
                $procString = if ($activeProcesses.Count -gt 0) { $activeProcesses -join '; ' } else { 'none' }
                
                # Log entry
                $entry = "$timestamp,$cpuPercent,$usedMemMB,$freeMemMB,$procString"
                Add-Content -Path $logPath -Value $entry
                
                # Check for high CPU and log warning
                if ($cpuPercent -gt 90) {
                    $warning = "$timestamp,WARNING,High CPU usage: ${cpuPercent}%,$procString"
                    Add-Content -Path $logPath -Value $warning
                }
                
            } catch {
                $errorMsg = "$timestamp,ERROR,Monitoring failed: $_"
                Add-Content -Path $logPath -Value $errorMsg
            }
            
            Start-Sleep -Seconds $interval
        }
    } -ArgumentList $IntervalSeconds, $LogFile
    
    $Global:ResourceMonitorJob = $monitorJob
    $Global:ResourceMonitorLogFile = $LogFile
    
    Show-Format "MONITOR" "Resource monitoring started" "Interval: ${IntervalSeconds}s | Log: $LogFile" -NameColor "Cyan"
}

function Stop-ResourceMonitoring {
    if ($Global:ResourceMonitorJob) {
        Stop-Job -Job $Global:ResourceMonitorJob
        Remove-Job -Job $Global:ResourceMonitorJob
        
        if ($Global:ResourceMonitorLogFile -and (Test-Path $Global:ResourceMonitorLogFile)) {
            Show-Format "MONITOR" "Resource monitoring stopped" "Log saved: $Global:ResourceMonitorLogFile" -NameColor "Cyan"
        }
        
        $Global:ResourceMonitorJob = $null
        $Global:ResourceMonitorLogFile = $null
    }
}

function Get-ResourceSnapshot {
    # Quick snapshot without starting continuous monitoring
    try {
        $cpuCounter = Get-Counter '\Processor(_Total)\% Processor Time' -ErrorAction SilentlyContinue
        $cpuPercent = [math]::Round($cpuCounter.CounterSamples.CookedValue, 2)
        
        $os = Get-CimInstance Win32_OperatingSystem
        $totalMemMB = [math]::Round($os.TotalVisibleMemorySize / 1KB, 2)
        $freeMemMB = [math]::Round($os.FreePhysicalMemory / 1KB, 2)
        $usedMemMB = [math]::Round($totalMemMB - $freeMemMB, 2)
        
        $processNames = @('ffmpeg', 'ffprobe', 'filebot', 'mkvmerge', 'java', 'alass-cli', 'python')
        $activeProcs = @()
        
        foreach ($procName in $processNames) {
            $procs = Get-Process -Name $procName -ErrorAction SilentlyContinue
            if ($procs) {
                $activeProcs += "$procName($($procs.Count))"
            }
        }
        
        $snapshot = @{
            Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            CPUPercent = $cpuPercent
            MemoryUsedMB = $usedMemMB
            MemoryFreeMB = $freeMemMB
            ActiveProcesses = $activeProcs -join ', '
        }
        
        return $snapshot
    } catch {
        return @{ Error = $_.Exception.Message }
    }
}

#*********************************************************************************************
#      Per-Step Logging
#*********************************************************************************************

function Start-StepLog {
    param (
        [Parameter(Mandatory=$true)]
        [string]$StepNumber,
        
        [Parameter(Mandatory=$true)]
        [string]$StepName
    )
    
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $logFileName = "Step_${StepNumber}_${StepName}_${timestamp}.log"
    $Global:CurrentStepLogFile = Join-Path $Global:LogDir $logFileName
    
    # Start transcript
    Start-Transcript -Path $Global:CurrentStepLogFile -Append
    
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "STEP $StepNumber - $StepName" -ForegroundColor Cyan
    Write-Host "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
    Write-Host "Log file: $logFileName" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
}

function Stop-StepLog {
    param (
        [string]$Status = "COMPLETED"
    )
    
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "Status: $Status" -ForegroundColor $(if ($Status -eq "COMPLETED") { "Green" } else { "Yellow" })
    Write-Host "Ended: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
    
    Stop-Transcript
    $Global:CurrentStepLogFile = $null
}

function Set-StepRunResult {
    param(
        [Parameter(Mandatory=$true)][string]$Step,
        [Parameter(Mandatory=$true)][int]$Success,
        [Parameter(Mandatory=$true)][int]$Failed,
        [string[]]$FailedItems = @(),
        [string]$Note = ""
    )

    if (-not $Global:StepRunResults) {
        $Global:StepRunResults = [ordered]@{}
    }

    $cleanFailed = @()
    foreach ($item in $FailedItems) {
        if ($item -and $item.Trim().Length -gt 0) {
            $cleanFailed += $item.Trim()
        }
    }

    $Global:StepRunResults[$Step] = [ordered]@{
        Success = $Success
        Failed = $Failed
        FailedItems = $cleanFailed
        Note = $Note
    }
}

function Get-StepSummaryLabel {
    param(
        [string]$Step,
        [string]$Mode = ""
    )

    switch ($Step) {
        "02" { return 'Copy Rename Transform' }
        "03" {
            if ($Mode) {
                switch -Regex ($Mode.ToLower()) {
                    'high_bitdepth_to_h265_8bit' { return 'h265_8bit' }
                    'h265_to_h264|convert' { return 'h264 conversion' }
                    'reject' { return 'Reject H265' }
                    default { return $Mode }
                }
            }
            return 'Get Metadata'
        }
        "04" { return 'Extract and Store' }
        "05" { return 'Download Subs' }
        "06" { return 'Speech to Text' }
        "07" { return 'Validate SRT' }
        "08" { return 'Clean SRT' }
        "09" { return 'Score Subs' }
        "10" { return 'Sync Subs' }
        "11" { return 'Translate Subs' }
        "12" { return 'Embed and Move' }
        "13" { return 'Finalize Cleanup' }
        default { return "Step $Step" }
    }
}

function Get-StepNoteData {
    param([string]$Note)

    $data = @{}
    if ([string]::IsNullOrWhiteSpace($Note)) {
        return $data
    }

    $data['_text'] = $Note.Trim()
    foreach ($part in ($Note -split '\s*,\s*')) {
        if ($part -match '^\s*([^=]+?)\s*=\s*(.*)\s*$') {
            $data[$matches[1].Trim()] = $matches[2].Trim()
        }
    }

    return $data
}

function Get-StepSkippedCount {
    param(
        $Entry,
        [hashtable]$NoteData
    )

    if ($NoteData.ContainsKey('skipped') -and "$($NoteData['skipped'])" -match '^\d+$') {
        return [Math]::Max(0, [int]$NoteData['skipped'])
    }

    if ($NoteData.ContainsKey('total') -and "$($NoteData['total'])" -match '^\d+$') {
        return [Math]::Max(0, [int]$NoteData['total'] - [int]$Entry.Success - [int]$Entry.Failed)
    }

    if ($NoteData.ContainsKey('processed') -and "$($NoteData['processed'])" -match '^\d+$') {
        return [Math]::Max(0, [int]$NoteData['processed'] - [int]$Entry.Success - [int]$Entry.Failed)
    }

    $text = if ($NoteData.ContainsKey('_text')) { "$($NoteData['_text'])".ToLower() } else { '' }
    if ($text -match 'step skipped|nothing to download|no subtitles found|no valid videos in list') {
        return 1
    }

    return 0
}

function Get-StepExtraSummaryText {
    param(
        [string]$Step,
        $Entry,
        [hashtable]$NoteData
    )

    return ''
}

# ─── Helper functie voor gekleurd stap-resultaat ───────────────────────────
function Get-StepResultColor {
    param (
        [int]$Success,
        [int]$Failed,
        [int]$Skipped
    )
    
    # Prioriteit: Failed > Success > Skipped > None
    if ($Failed -gt 0) {
        return "Red"      # Fouten: kritiek
    } elseif ($Success -gt 0) {
        return "Green"    # Succes
    } elseif ($Skipped -gt 0) {
        return "Yellow"   # Overgeslagen
    } else {
        return "White"    # Niks gedaan
    }
}

# ─── Helper functie voor gekleurd resultaatformat per kolom ─────────────────
function Format-StepResultWithColors {
    param (
        [int]$Success,
        [int]$Failed,
        [int]$Skipped
    )
    
    # ANSI kleurcodes
    $colors = @{
        "Green"  = "`e[32m"
        "Red"    = "`e[31m"
        "Yellow" = "`e[33m"
        "White"  = "`e[37m"
    }
    $reset = "`e[0m"
    
    # Bepaal kleur per waarde
    $successColor = if ($Success -gt 0) { $colors["Green"] } else { $colors["White"] }
    $failedColor  = if ($Failed -gt 0) { $colors["Red"] } else { $colors["White"] }
    $skippedColor = if ($Skipped -gt 0) { $colors["Yellow"] } else { $colors["White"] }
    
    # Bouw gekleurd string - label EN getal in dezelfde kleur
    return "$($successColor)Success=$Success$reset | $($failedColor)Failed=$Failed$reset | $($skippedColor)Skipped=$Skipped$reset"
}

function Show-StepRunSummary {
    DrawBanner -Text "PIPELINE RESULT SUMMARY"

    if (-not $Global:StepRunResults -or $Global:StepRunResults.Count -eq 0) {
        Show-Format "INFO" "No step summary data available" "" -NameColor "Yellow"
        return
    }

    $order = @("02", "03", "04", "05", "06", "07", "08", "09", "10", "11", "12", "13")
    foreach ($step in $order) {
        if (-not $Global:StepRunResults.Contains($step)) { continue }

        $entry = $Global:StepRunResults[$step]
        $noteData = Get-StepNoteData -Note $entry.Note
        $skipped = Get-StepSkippedCount -Entry $entry -NoteData $noteData

        if ($step -eq '03' -and $noteData.ContainsKey('metadataSuccess')) {
            $metaSuccess = if ("$($noteData['metadataSuccess'])" -match '^\d+$') { [int]$noteData['metadataSuccess'] } else { 0 }
            $metaFailed = if ("$($noteData['metadataFailed'])" -match '^\d+$') { [int]$noteData['metadataFailed'] } else { 0 }
            $metaSkipped = if ("$($noteData['metadataSkipped'])" -match '^\d+$') { [int]$noteData['metadataSkipped'] } else { 0 }
            
            # Gebruik gekleurd format voor elke kolom apart
            $coloredInfo1 = Format-StepResultWithColors -Success $metaSuccess -Failed $metaFailed -Skipped $metaSkipped
            Show-Format "STEP $step" "[$(Get-StepSummaryLabel -Step $step)]" $coloredInfo1 -NameColor "Cyan" -InfoColor "White"

            if ($noteData.ContainsKey('mode')) {
                $modeLabel = Get-StepSummaryLabel -Step $step -Mode "$($noteData['mode'])"
                $coloredInfo2 = Format-StepResultWithColors -Success $entry.Success -Failed $entry.Failed -Skipped $skipped
                Show-Format "STEP $step" "[$modeLabel]" $coloredInfo2 -NameColor "Cyan" -InfoColor "White"
            }
        } else {
            $label = Get-StepSummaryLabel -Step $step
            $coloredInfo = Format-StepResultWithColors -Success $entry.Success -Failed $entry.Failed -Skipped $skipped
            $extraText = Get-StepExtraSummaryText -Step $step -Entry $entry -NoteData $noteData
            if ($extraText) {
                $coloredInfo += " | $extraText"
            }
            Show-Format "STEP $step" "[$label]" $coloredInfo -NameColor "Cyan" -InfoColor "White"
        }

        if ($entry.FailedItems -and $entry.FailedItems.Count -gt 0) {
            foreach ($failedItem in $entry.FailedItems) {
                Show-Format "FAILED" "$failedItem" "" -NameColor "Red"
            }
        }
    }
}

function Show-Format {
    param (
        [Parameter(Position=0, Mandatory=$true)] [string]$Tag,
        [Parameter(Position=1, Mandatory=$true)] [string]$Name,
        [Parameter(Position=2)] [string]$Info = "",
        [Parameter(Position=3)] [string]$Emoji,
        [int]$Width = ($Host.UI.RawUI.WindowSize.Width - 1),
        [string]$TagColor = "White",
        [string]$NameColor = "Green",
        [string]$InfoColor = "Yellow",
        [switch]$InverseTag
    )

    # ─── Vaste blokken ─────────────────────────────────────────────
    $tagBlock   = "[" + $Tag.PadRight(10) + "]"       # 12 tekens
    $emojiCore  = if ($Emoji) { $Emoji } else { " " }
    $emojiBlock = "[" + $emojiCore.PadRight(2) + "]"  # 4 tekens
    $spaceAfter = " "                                 # 1 teken

    $fixedLeftWidth = $tagBlock.Length + $emojiBlock.Length + $spaceAfter.Length
    $availableWidth = $Width - $fixedLeftWidth
    if ($availableWidth -lt 1) { $availableWidth = 1 }

    # Keep the Name column readable; trim Info first if line is too long.
    $minNameWidth = [Math]::Min(24, $availableWidth)
    $displayInfo = $Info
    $infoSeparator = if ($Info) { " " } else { "" }

    if ($Info) {
        $maxInfoWidth = $availableWidth - $minNameWidth - $infoSeparator.Length
        if ($maxInfoWidth -lt 0) { $maxInfoWidth = 0 }

        if ($displayInfo.Length -gt $maxInfoWidth) {
            if ($maxInfoWidth -ge 4) {
                $displayInfo = $displayInfo.Substring(0, $maxInfoWidth - 3) + "..."
            } elseif ($maxInfoWidth -gt 0) {
                $displayInfo = $displayInfo.Substring(0, $maxInfoWidth)
            } else {
                $displayInfo = ""
                $infoSeparator = ""
            }
        }

        $nameWidth = $availableWidth - $displayInfo.Length - $infoSeparator.Length
        if ($nameWidth -lt 1) { $nameWidth = 1 }
    } else {
        $nameWidth = $availableWidth
    }

    # ─── Naamblok ──────────────────────────────────────────────────
    $nameBlock = if ($Name.Length -gt $nameWidth) {
        $Name.Substring(0, $nameWidth)
    } else {
        $Name.PadRight($nameWidth)
    }

    # ─── Build complete line with ANSI codes to write as single string ────
    $colorMap = @{
        "White" = "`e[37m"
        "Green" = "`e[32m"
        "Yellow" = "`e[33m"
        "Red" = "`e[31m"
        "Cyan" = "`e[36m"
        "DarkGray" = "`e[90m"
        "DarkYellow" = "`e[33m"
        "Gray" = "`e[37m"
    }
    $reset = "`e[0m"
    
    $tagColorCode = if ($colorMap.ContainsKey($TagColor)) { $colorMap[$TagColor] } else { $colorMap["White"] }
    $nameColorCode = if ($colorMap.ContainsKey($NameColor)) { $colorMap[$NameColor] } else { $colorMap["Green"] }
    $infoColorCode = if ($colorMap.ContainsKey($InfoColor)) { $colorMap[$InfoColor] } else { $colorMap["Yellow"] }
    
    # Build the complete line as one string
    $line = ""
    $line += "$tagColorCode$tagBlock$reset"
    $line += "$($colorMap["DarkGray"])$emojiBlock$reset"
    $line += $spaceAfter
    $line += "$nameColorCode$nameBlock$reset"
    if ($displayInfo) {
        $line += $infoSeparator
        $line += "$infoColorCode$displayInfo$reset"
    }
    
    # Write the complete line in one call
    Write-Host $line
}

# ─── BANNER WITH INVERSE TEXT ───────────────────────────────────────────
# DrawBanner "SECTION NAME" prints a full-width banner
function DrawBanner {
    param ([string]$Text = "")
    
    Write-Host ""
    $width = $Host.UI.RawUI.WindowSize.Width - 1
    $textLen = $Text.Length
    
    # Check if text starts with "STEP" to determine color
    $bgColor = if ($Text -match '^\s*STEP\s') { "Cyan" } else { "Yellow" }
    
    if ($textLen -ge $width) {
        # Text is too long, just trim it
        Write-Host $Text.Substring(0, $width) -BackgroundColor $bgColor -ForegroundColor Black -NoNewline
    } else {
        # Calculate padding
        $leftPad = [Math]::Max(0, [int](($width - $textLen) / 2))
        $rightPad = $width - $leftPad - $textLen
        
        $line = (" " * $leftPad) + $Text + (" " * $rightPad)
        Write-Host $line -BackgroundColor $bgColor -ForegroundColor Black -NoNewline
    }
    Write-Host ""  # End the line without extra newline
}

function Write-ColoredSegments {
    param (
        [string]$prefix,
        [string]$green1,
        [string]$yellow,
        [string]$green2
    )
    Write-Host "`r$prefix" -NoNewline
    Write-Host $green1 -ForegroundColor Green -NoNewline
    Write-Host $yellow -ForegroundColor Yellow -NoNewline
    Write-Host $green2 -ForegroundColor Green -NoNewline
}

function DrawBar {
    param (
        [char]$Char = '=',
        [int]$Width,
        [string]$Color = "Yellow"
    )

    if (-not $Width) {
        $Width = [int]$ScreenWidth
    }

    #Write-Host "→ DrawBar: Char='$Char' Width=$Width Color='$Color'" -ForegroundColor DarkGray

    if ($Width -lt 1) {
        Write-Host "⚠️ Width is kleiner dan 1" -ForegroundColor Red
        return
    }

    $line = ("*" * $Width)    

    if ([string]::IsNullOrWhiteSpace($Color)) {
        Write-Host $line -NoNewline
    } elseif ([System.Enum]::GetNames([System.ConsoleColor]) -contains $Color) {
        Write-Host $line -ForegroundColor $Color -NoNewline
    } else {
        Write-Host $line -NoNewline
    }
    Write-Host ""  # Add single newline at the end
}



function Get-GapColor {
    param (
        [string]$Type,  # "start", "end", of "drift"
        [int]$Value
    )

    switch ($Type) {
        "start" {
            if ($Value -gt $Global:MAX_GAP_START) { return "Red" }
            elseif ($Value -gt $Global:WARN_GAP_START) { return "Yellow" }
            else { return "Green" }
        }
        "end" {
            if ($Value -gt $Global:MAX_GAP_END) { return "Red" }
            elseif ($Value -gt $Global:WARN_GAP_END) { return "Yellow" }
            else { return "Green" }
        }
        "drift" {
            if ($Value -gt $Global:MAX_DRIFT) { return "Red" }
            elseif ($Value -gt $Global:WARN_DRIFT) { return "Yellow" }
            else { return "Green" }
        }
    }
}
   

# Format minus included
function Format-Int4 {
    param ([int]$value)
    if ($value -lt 0) {
        return "-{0:D4}" -f [math]::Abs($value)
    } else {
        return "{0:D4}" -f $value
    }
}

function Remove-Diakritiek {
    param ([string]$inputText)
    $normalized = $inputText.Normalize([Text.NormalizationForm]::FormD)
    $clean = -join ($normalized.ToCharArray() | Where-Object { -not [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -eq 'NonSpacingMark' })
    return $clean
}

# Voorbeeld
# $text = "Café naïve façade"
# $cleaned = Remove-Diakritiek $text
# Write-Host $cleaned  # Output: Cafe naive facade

function Remove-Symbols {
    param ([string]$inputText)
    return ($inputText -replace '[<>%&]', '')
}

# Voorbeeld
# $text = "Prijs < €100 & korting > 20%"
# $cleaned = Remove-Symbols $text
# Write-Host $cleaned  # Output: Prijs  €100  korting  20

function Remove-NonAlphaNumeric {
    param ([string]$inputText)
    return ($inputText -replace '[^a-zA-Z0-9]', '')
}

# Voorbeeld
# $text = "Café #42! <test>"
# $cleaned = Remove-NonAlphaNumeric $text
# Write-Host $cleaned  # Output: Cafe42test

function ConvertTo-SafePathName {
    param ([string]$text)
    # Remove only truly problematic characters for Windows paths: < > : " | ? *
    # For brackets: if there's a character before [, replace [ with .
    # Always remove ]
    # This converts: MeGusta[EZTVx.to] → MeGusta.EZTVx.to
    
    # First remove truly problematic characters
    $cleaned = ($text -replace '[<>:"|?*]', '').Trim()
    
    # Replace [ with . if there's a non-whitespace character before it
    $cleaned = $cleaned -replace '(\S)\[', '$1.'
    
    # Remove any remaining [ (at start or after whitespace)
    $cleaned = $cleaned -replace '\[', ''
    
    # Remove all ]
    $cleaned = $cleaned -replace '\]', ''
    
    # Replace multiple consecutive dots with single dot
    $cleaned = $cleaned -replace '\.{2,}', '.'
    
    # Replace multiple spaces with single space
    $cleaned = $cleaned -replace '\s+', ' '
    
    return $cleaned
}

# Calculate Greatest Common Divisor (GCD) for aspect ratio simplification
function Get-GCD {
    param([int]$a, [int]$b)
    while ($b -ne 0) {
        $temp = $b
        $b = $a % $b
        $a = $temp
    }
    return $a
}

# Voorbeeld
# $text = "The.Mandalorian.S03[TGx]"
# $cleaned = ConvertTo-SafePathName $text
# Write-Host $cleaned  # Output: The.Mandalorian.S03TGx











#*********************************************************************************************
#      Other Utils
#*********************************************************************************************
function Get-FileDefs {
    param (
        [string]$FullPath
    )
    

    $SourceDir = $env:SourceDir
    $TempDir   = $env:TempDir
    $SubsDir   = $env:SubsDir
    $FinishDir = $env:FinishDir
    

    # ───── Basiscomponenten ─────
    $DrivePath = Split-Path $FullPath -Parent
    $NameExt   = Split-Path $FullPath -Leaf
    $Name      = [System.IO.Path]::GetFileNameWithoutExtension($FullPath)
    $Ext       = [System.IO.Path]::GetExtension($FullPath)

    # ───── Relatieve pad en baseType ─────
    $RelPath   = $null
    $BaseType  = "Unknown"

    $baseDirs = @{
        SourceDir = $SourceDir
        TempDir   = $TempDir
        SubsDir   = $SubsDir
    }

    foreach ($key in $baseDirs.Keys) {
        $base = [System.IO.Path]::GetFullPath($baseDirs[$key].Trim('"'))
        $inputPath = [System.IO.Path]::GetFullPath((Split-Path $FullPath -Parent).Trim('"'))

        if ($inputPath.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
            $RelPath  = $inputPath.Substring($base.Length).TrimStart('\\')
            $BaseType = $key
            break
        }
    }

    # ───── Genormaliseerde rootdirs ─────
    $normalize = {
        param($s)
        ($s -as [string]).Trim('"').TrimEnd('\')
    }
    $SourceDir_n = & $normalize $SourceDir
    $TempDir_n   = & $normalize $TempDir
    $SubsDir_n   = & $normalize $SubsDir
    $FinishDir_n = & $normalize $FinishDir

    # ───── Afgeleide paden ─────
    if ($RelPath) {
        $SourcePath = Join-Path $SourceDir_n $RelPath
        $TempPath   = Join-Path $TempDir_n   $RelPath
        $SubsPath   = Join-Path $SubsDir_n   $RelPath
        $FinishPath = Join-Path $FinishDir_n $RelPath
    } else {
        $SourcePath = $SourceDir_n
        $TempPath   = $TempDir_n
        $SubsPath   = $SubsDir_n
        $FinishPath = $FinishDir_n
    }

    # ───── Output als object ─────
    return [PSCustomObject]@{
        FullPath   = $FullPath
        DrivePath  = $DrivePath
        NameExt    = $NameExt
        Name       = $Name
        Ext        = $Ext
        RelPath    = $RelPath
        BaseType   = $BaseType
        SourcePath = $SourcePath
        TempPath   = $TempPath
        SubsPath   = $SubsPath
        FinishPath = $FinishPath
    }
}

# Create list of all possible language codes from LangKeep
function Expand-LangKeep {
    param (
        $LangKeep,  # Accept any type (string or array)
        [hashtable]$LangMap
    )

    $LangList = @()
    
    # Normalize LangKeep to array
    $langArray = @()
    if ($LangKeep -is [string]) {
        $langArray = @($LangKeep)
    } elseif ($LangKeep -is [array]) {
        $langArray = $LangKeep
    } else {
        return @()
    }

    foreach ($code in $langArray) {
        $aliases = $LangMap[$code]
        if ($aliases) {
            foreach ($alias in $aliases) {
                if (-not ($LangList -contains $alias)) {
                    $LangList += $alias
                }
            }
        }
    }

    return $LangList  # ← GEEN join
}

function Clear-Dirs {
    $
    Show-Format "INIT" "Cleaning Folders..." -NameColor "Yellow"
    
    if ([string]::IsNullOrWhiteSpace($RootDir)) {
        Show-Format "ERROR" "RootDir not set !!!" -NameColor "Red"
        return
    }

    Get-ChildItem -Path $RootDir -Directory | ForEach-Object {
        if ($_.Name -ieq "Downloads") {
            # Skip Downloads
        } else {
            Remove-Item $_.FullName -Recurse -Force
        }
    }
}

function Test-Vars {
    param (
        [string[]]$RequiredVars
    )
    Show-Format "INIT" "Validating required variables..." -NameColor "Yellow"
    $Missing = @()

    foreach ($var in $RequiredVars) {
        if (-not (Get-Variable -Name $var -Scope Script -ErrorAction SilentlyContinue)) {
            Show-Format "ERROR" "Variable '$var' is not defined!" -NameColor "Red"
            $Missing += $var
        } elseif ([string]::IsNullOrWhiteSpace((Get-Variable -Name $var -Scope Script).Value)) {
            Show-Format "ERROR" "Variable '$var' is empty!" -NameColor "Red"
            $Missing += $var
        }
    }

    if ($Missing.Count -gt 0) {
        Show-Format "ERROR" "Script terminated due to missing vars: $($Missing -join ', ')" -NameColor "Red"
        pause
        return $false
    }

    return $true
}

function Test-Tools {
    param (
        [hashtable]$ToolMap        
    )
    $ScriptDir = $env:ScriptDir
    Show-Format "INIT" "Checking tool paths..." -NameColor "Yellow"
    $ToolErrors = 0

    foreach ($label in $ToolMap.Keys) {
        $varName = $ToolMap[$label]
        $toolPath = Get-Variable -Name $varName -Scope Script -ErrorAction SilentlyContinue | ForEach-Object { $_.Value }
        $expectedPath = Join-Path $ScriptDir "$varName"

        if ([string]::IsNullOrWhiteSpace($toolPath)) {
            Show-Format "ERROR" "Missing ${label}: variable '${varName}' is not defined -> expected: ${expectedPath}" -NameColor "Red"
            $ToolErrors++
        } elseif (-not (Test-Path $toolPath)) {
            Show-Format "ERROR" "Missing ${label}: '${toolPath}' -> expected: ${expectedPath}" -NameColor "Red"
            $ToolErrors++
        } else {
            Show-Format "INIT" "Found ${label}: ${toolPath}" -NameColor "Green"
    }

    if ($ToolErrors -eq 0) {
        Show-Format "INIT" "All tools found - system is ready." -NameColor "Green"
        return $true
    }

    return $false
}
}

function pause {
    [Console]::Out.Flush()
    Write-Host "Druk op een toets om verder te gaan..." -ForegroundColor Yellow
    [Console]::Out.Flush()
    try {
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    } catch {
        # Fallback if interactive input not available
        Read-Host "Press Enter to continue"
    }
}

function Clear-TempLogs {
    param (
        [string]$TargetDir = $TempDir
    )
    DrawBanner "DELETE All LOGFILES IN $TargetDir..." -NameColor "Yellow"

    Get-ChildItem -Path $TargetDir -Filter *.log -Recurse -File | ForEach-Object {
        try {
            Remove-Item -Path $_.FullName -Force
            Show-Format  "PROCESS" "$($_.FullName)" -NameColor "Magenta"
        } catch {
            Show-Format "ERROR" "Failed: $($_.FullName)" -NameColor "Red"
        }
    }

    Show-Format "INFO" "All logfiles deleted" -Namecolor "Yellow"
}

function Update-MetaFile {
    param (
        [string]$metaPath,
        [hashtable]$Updates
    )

    if (-not (Test-Path $metaPath)) {
        Write-Warning "Bestand '$metaPath' bestaat niet."
        return
    }

    # Inlezen als key-value map
    $metaMap = @{}
    $metaLines = Get-Content $metaPath
    foreach ($line in $metaLines) {
        if ($line -match '^(?<key>[^=]+)=(?<value>.*)$') {
            $metaMap[$matches.key] = $matches.value
        }
    }

    # Toevoegen of updaten
    foreach ($key in $Updates.Keys) {
        $metaMap[$key] = $Updates[$key]
    }

    # Terugschrijven
    $newMeta = $metaMap.GetEnumerator() | Sort-Object Name | ForEach-Object {
        "$($_.Key)=$($_.Value)"
    }
    Set-Content -Path $metaPath -Value $newMeta
}

# ─── PROGRESS BAR ───────────────────────────────────────────────────────
# Simple progress bar: Show-ProgressBar -Current 5 -Total 10 -Length 30
# Displays: [###-------] 50% (5/10)
function Show-ProgressBar {
    param (
        [Parameter(Mandatory = $true)]
        [int]$Current,
        
        [Parameter(Mandatory = $true)]
        [int]$Total,
        
        [int]$Length = 30,
        
        [string]$Label = ""
    )
    
    if ($Total -le 0) { return }
    
    $percent = [Math]::Min(100, [int](($Current / $Total) * 100))
    $filled = [int]($percent / 100 * $Length)
    $empty = $Length - $filled
    $bar = "#" * $filled + "-" * $empty
    
    if ($Label) {
        Write-Host -NoNewline "`r[$bar] $percent% - $Label ($Current/$Total)  "
    } else {
        Write-Host -NoNewline "`r[$bar] $percent% ($Current/$Total)  "
    }
}

# ___ Extract and normalize language from subtitle filename ___________________________
function Get-SubtitleLanguage {
    param ([string]$fileName)

    if ([string]::IsNullOrWhiteSpace($fileName)) {
        return "unknown"
    }

    # Normaliseer bekende suffixen zodat de taalcode herkenbaar blijft.
    # Voorbeeld: video.eng.translated.srt -> video.eng.srt
    $normalizedName = $fileName
    if ($normalizedName -match '\.translated\.srt$') {
        $normalizedName = $normalizedName -replace '\.translated\.srt$', '.srt'
    }
    
    # Extract language code from filename (before .EXT/.INT/.SYN markers and any sync suffixes)
    # Pattern: .lang.EXT.srt or .lang.##.EXT.srt or just .lang.srt
    # Also handles .ffsubsync.synced, .alass.synced, etc.
    if ($normalizedName -match '\.([a-z]{2,3})(\.\d{2})?(\.?(EXT|INT|SYN))?(?:\.[a-z]+\.synced)?\.srt$') {
        $extractedLang = $matches[1]
        
        # Check against all languages in LangMap to find canonical form
        foreach ($canonical in $LangMap.Keys) {
            if ($extractedLang -in $LangMap[$canonical]) {
                return $canonical
            }
        }
        
        # If not found in LangMap, return as-is
        return $extractedLang
    }
    return "unknown"
}

function Repair-SrtTimestamps {
    param([string]$FilePath)

    if ([string]::IsNullOrWhiteSpace($FilePath) -or -not (Test-Path -LiteralPath $FilePath)) {
        return $false
    }

    $content = Get-Content -Raw -LiteralPath $FilePath -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($content)) {
        return $false
    }

    $fixed = $content

    # Normaliseer punt naar komma in milliseconden van timestamps.
    $fixed = [regex]::Replace($fixed, '(?m)(\d{2}:\d{2}:\d{2})\.(\d{3})', '$1,$2')

    # Fix timestamps where the comma between seconds and milliseconds is missing.
    # Examples:
    #   00:00:21710 --> 00:00:24,130  => 00:00:21,710 --> 00:00:24,130
    #   00:00:20,910 --> 00:00:21710  => 00:00:20,910 --> 00:00:21,710
    $fixed = [regex]::Replace($fixed, '(?m)(\d{2}:\d{2}:)(\d{2})(\d{3})(?=\s*-->)', '$1$2,$3')
    $fixed = [regex]::Replace($fixed, '(?m)(-->\s*)(\d{2}:\d{2}:)(\d{2})(\d{3})(?=\s*$)', '$1$2$3,$4')

    # Als er tekst op dezelfde regel na de timestamp staat: zet die op een nieuwe regel.
    $fixed = [regex]::Replace($fixed, '(?m)^(\d{2}:\d{2}:\d{2},\d{3}\s*-->\s*\d{2}:\d{2}:\d{2},\d{3})\s+(.+)$', '$1' + "`r`n" + '$2')

    if ($fixed -ne $content) {
        Set-Content -LiteralPath $FilePath -Value $fixed -Encoding UTF8
        return $true
    }

    return $false
}

function Convert-WhisperTimestampToSrtTimestamp {
    param([string]$Timestamp)

    if ([string]::IsNullOrWhiteSpace($Timestamp)) {
        return $null
    }

    $value = $Timestamp.Trim() -replace '\.', ','

    if ($value -match '^\d{2}:\d{2}:\d{2},\d{3}$') {
        return $value
    }

    if ($value -match '^(\d{2}):(\d{2}),(\d{3})$') {
        return ('00:{0}:{1},{2}' -f $matches[1], $matches[2], $matches[3])
    }

    return $null
}

function Normalize-WhisperSubtitleFile {
    param([string]$FilePath)

    if ([string]::IsNullOrWhiteSpace($FilePath) -or -not (Test-Path -LiteralPath $FilePath)) {
        return $false
    }

    $raw = Get-Content -Raw -LiteralPath $FilePath -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $false
    }

    # Faster-Whisper-XXL kan bracket cues schrijven zoals:
    # [00:03.130 --> 00:13.990] Text
    # Zet die eerst om naar echte SRT entries.
    $matches = [regex]::Matches(
        ($raw -replace "`r`n", "`n"),
        '(?m)^\[(?<start>\d{2}:\d{2}(?::\d{2})?[\.,]\d{3})\s*-->\s*(?<end>\d{2}:\d{2}(?::\d{2})?[\.,]\d{3})\]\s*(?<text>.*)$'
    )

    if ($matches.Count -eq 0) {
        return $false
    }

    $blocks = [System.Collections.Generic.List[string]]::new()
    $index = 1
    foreach ($match in $matches) {
        $start = Convert-WhisperTimestampToSrtTimestamp -Timestamp $match.Groups['start'].Value
        $end = Convert-WhisperTimestampToSrtTimestamp -Timestamp $match.Groups['end'].Value
        $text = $match.Groups['text'].Value.Trim()

        if (-not $start -or -not $end) { continue }
        if ([string]::IsNullOrWhiteSpace($text)) { $text = '...' }

        $blocks.Add((@("$index", "$start --> $end", $text) -join "`r`n"))
        $index++
    }

    if ($blocks.Count -eq 0) {
        return $false
    }

    $rebuilt = ($blocks -join "`r`n`r`n") + "`r`n"
    if ($rebuilt -eq $raw) {
        return $false
    }

    Set-Content -LiteralPath $FilePath -Value $rebuilt -Encoding UTF8
    return $true
}

function Normalize-SrtStructure {
    param([string]$FilePath)

    if ([string]::IsNullOrWhiteSpace($FilePath) -or -not (Test-Path -LiteralPath $FilePath)) {
        return $false
    }

    $raw = Get-Content -Raw -LiteralPath $FilePath -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $false
    }

    $normalized = ($raw -replace "`r`n", "`n") -replace '\.', ','
    $lines = @($normalized -split "`n")
    $blocks = [System.Collections.Generic.List[string]]::new()
    $index = 1
    $i = 0

    while ($i -lt $lines.Count) {
        $current = $lines[$i].Trim()
        if ($current -notmatch '^\d+$' -or ($i + 1) -ge $lines.Count) {
            $i++
            continue
        }

        $timestamp = $lines[$i + 1].Trim() -replace '\.', ','
        if ($timestamp -notmatch '^\d{2}:\d{2}:\d{2},\d{3}\s*-->\s*\d{2}:\d{2}:\d{2},\d{3}$') {
            $i++
            continue
        }

        $textLines = [System.Collections.Generic.List[string]]::new()
        $j = $i + 2
        while ($j -lt $lines.Count) {
            $probe = $lines[$j].Trim()
            if (($j + 1) -lt $lines.Count -and $probe -match '^\d+$' -and $lines[$j + 1].Trim() -replace '\.', ',' -match '^\d{2}:\d{2}:\d{2},\d{3}\s*-->\s*\d{2}:\d{2}:\d{2},\d{3}$') {
                break
            }

            if (-not [string]::IsNullOrWhiteSpace($probe)) {
                $textLines.Add($probe)
            }
            $j++
        }

        if ($textLines.Count -eq 0) {
            $textLines.Add('...')
        }

        $blocks.Add((@("$index", $timestamp) + @($textLines) -join "`r`n"))
        $index++
        $i = $j
    }

    if ($blocks.Count -eq 0) {
        return $false
    }

    $rebuilt = ($blocks -join "`r`n`r`n") + "`r`n"
    if ($rebuilt -eq $raw) {
        return $false
    }

    Set-Content -LiteralPath $FilePath -Value $rebuilt -Encoding UTF8
    return $true
}

function Split-SubtitleTextLines {
    param(
        [string]$Text,
        [int]$MaxCharsPerLine = 42,
        [int]$MaxLines = 0
    )

    $textToClean = if ([string]::IsNullOrEmpty($Text)) { '' } else { $Text }
    $cleanText = Normalize-SubtitleDialogueText -Text $textToClean
    if ([string]::IsNullOrWhiteSpace($cleanText)) {
        return @('')
    }

    if ($MaxCharsPerLine -lt 8) {
        return @($cleanText)
    }

    $words = $cleanText -split ' '
    $expandedWords = [System.Collections.Generic.List[string]]::new()
    foreach ($word in $words) {
        if ([string]::IsNullOrWhiteSpace($word)) { continue }

        if ($word.Length -le $MaxCharsPerLine) {
            $expandedWords.Add($word)
            continue
        }

        # Hard split for single long tokens so one line can never grow too wide.
        $remaining = $word
        while ($remaining.Length -gt $MaxCharsPerLine) {
            $expandedWords.Add($remaining.Substring(0, $MaxCharsPerLine))
            $remaining = $remaining.Substring($MaxCharsPerLine)
        }
        if (-not [string]::IsNullOrWhiteSpace($remaining)) {
            $expandedWords.Add($remaining)
        }
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $currentLine = ''

    foreach ($word in $expandedWords) {
        if ([string]::IsNullOrWhiteSpace($word)) { continue }

        if ([string]::IsNullOrWhiteSpace($currentLine)) {
            $currentLine = $word
            continue
        }

        $candidate = "$currentLine $word"
        if ($candidate.Length -le $MaxCharsPerLine) {
            $currentLine = $candidate
        } else {
            $lines.Add($currentLine)
            $currentLine = $word
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($currentLine)) {
        $lines.Add($currentLine)
    }

    # Prefer natural pause breaks for 2-line cues: if the second line is very short
    # and the first line contains a comma, rebalance around the comma.
    if ($MaxLines -eq 2 -and $lines.Count -eq 2) {
        $line1 = $lines[0]
        $line2 = $lines[1]

        if ($line1 -match ',' -and $line2.Length -lt [int]($MaxCharsPerLine * 0.6)) {
            $commaCandidates = [regex]::Matches($line1, ',')
            if ($commaCandidates.Count -gt 0) {
                $commaIdx = $commaCandidates[$commaCandidates.Count - 1].Index
                $left = $line1.Substring(0, $commaIdx + 1).Trim()
                $right = $line1.Substring($commaIdx + 1).Trim()

                if (-not [string]::IsNullOrWhiteSpace($right)) {
                    $newSecond = ("$right $line2").Trim()

                    if (
                        $left.Length -le $MaxCharsPerLine -and
                        $newSecond.Length -le $MaxCharsPerLine -and
                        $left.Length -ge [int]($MaxCharsPerLine * 0.35)
                    ) {
                        $lines[0] = $left
                        $lines[1] = $newSecond
                    }
                }
            }
        }
    }

    # If strict greedy wrapping produced >2 lines, try a balanced 2-line reflow.
    # This helps avoid tiny orphan tails like "Mannen" in a separate micro-cue.
    if ($MaxLines -eq 2 -and $lines.Count -gt 2) {
        $fullText = (($lines | ForEach-Object { $_.Trim() }) -join ' ').Trim()
        if (-not [string]::IsNullOrWhiteSpace($fullText)) {
            $wordsForBalance = @($fullText -split '\s+' | Where-Object { $_ })
            if ($wordsForBalance.Count -ge 2) {
                $softLimit = $MaxCharsPerLine + 6
                $bestLeft = $null
                $bestRight = $null
                $bestScore = [double]::PositiveInfinity

                for ($splitIdx = 1; $splitIdx -lt $wordsForBalance.Count; $splitIdx++) {
                    $left = ($wordsForBalance[0..($splitIdx - 1)] -join ' ').Trim()
                    $right = ($wordsForBalance[$splitIdx..($wordsForBalance.Count - 1)] -join ' ').Trim()

                    if ([string]::IsNullOrWhiteSpace($left) -or [string]::IsNullOrWhiteSpace($right)) { continue }
                    if ($left.Length -gt $softLimit -or $right.Length -gt $softLimit) { continue }

                    $lenDelta = [Math]::Abs($left.Length - $right.Length)
                    $punctBonus = if ($left -match '[,;:!\?\.]$') { -4 } else { 0 }
                    $overflowPenalty = [Math]::Max(0, $left.Length - $MaxCharsPerLine) + [Math]::Max(0, $right.Length - $MaxCharsPerLine)
                    $score = ($lenDelta + $overflowPenalty * 2 + $punctBonus)

                    if ($score -lt $bestScore) {
                        $bestScore = $score
                        $bestLeft = $left
                        $bestRight = $right
                    }
                }

                if ($bestLeft -and $bestRight) {
                    $lines = [System.Collections.Generic.List[string]]::new()
                    $lines.Add($bestLeft)
                    $lines.Add($bestRight)
                }
            }
        }
    }

    # Never truncate subtitle text here. If there are too many lines for a cue,
    # Limit-SrtCueLines will split the cue into multiple timed cues.
    $linesNoTrailingComma = @()
    for ($idx = 0; $idx -lt $lines.Count; $idx++) {
        $line = $lines[$idx].TrimEnd()

        # Remove leading punctuation artifacts like ", dan ...".
        $line = [regex]::Replace($line, '^\s*[,;:]+\s*', '')
        if ($idx -eq ($lines.Count - 1)) {
            # Only strip trailing comma on the LAST line of a cue.
            # Keep commas on intermediate lines when they represent a natural pause.
            $line = [regex]::Replace($line, ',\s*$', '')
        }
        $linesNoTrailingComma += $line
    }
    return @($linesNoTrailingComma)
}

function Normalize-SubtitleDialogueText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    $clean = [regex]::Replace($Text, '\s+', ' ').Trim()

    # Common STT punctuation artifacts.
    $clean = [regex]::Replace($clean, '\s*,\s*,+\s*', ', ')
    $clean = [regex]::Replace($clean, ',\s*([\.!\?;:])', '$1')
    $clean = [regex]::Replace($clean, '\s+([,\.;:!\?])', '$1')
    $clean = [regex]::Replace($clean, '([,]){2,}', ',')
    $clean = [regex]::Replace($clean, '([;:!\?]){2,}', '$1')
    $clean = [regex]::Replace($clean, '\.{4,}', '...')

    # Drop short truncated tail fragments like "aank..." or "groo...".
    $clean = [regex]::Replace($clean, '\s+[A-Za-zÀ-ÿ]{2,6}\.\.\.\s*$', '')

    # Remove leading punctuation artifacts when a fragment starts with commas.
    $clean = [regex]::Replace($clean, '^\s*[,;:]+\s*', '')

    # If a cue still ends with ellipsis, remove it to avoid visible clipping artifacts.
    $clean = [regex]::Replace($clean, '\s*\.\.\.\s*$', '')

    # Subtitles generally should not end with a dangling comma.
    $clean = [regex]::Replace($clean, ',\s*$', '')

    # Guard against empty text after cleanup.
    if ([string]::IsNullOrWhiteSpace($clean)) {
        return '...'
    }

    $clean = [regex]::Replace($clean, '\s{2,}', ' ')

    return $clean.Trim()
}

function Convert-SrtTimestampToMilliseconds {
    param([string]$Timestamp)

    if ([string]::IsNullOrWhiteSpace($Timestamp)) {
        return $null
    }

    $ts = $Timestamp.Trim() -replace '\.', ','
    if ($ts -notmatch '^(\d{2}):(\d{2}):(\d{2}),(\d{3})$') {
        return $null
    }

    $hours = [int]$matches[1]
    $mins = [int]$matches[2]
    $secs = [int]$matches[3]
    $millis = [int]$matches[4]

    return [int64]((((($hours * 60) + $mins) * 60) + $secs) * 1000 + $millis)
}

function Convert-MillisecondsToSrtTimestamp {
    param([Int64]$Milliseconds)

    if ($Milliseconds -lt 0) { $Milliseconds = 0 }

    $hours = [int][Math]::Floor($Milliseconds / 3600000)
    $remainder = $Milliseconds % 3600000
    $mins = [int][Math]::Floor($remainder / 60000)
    $remainder = $remainder % 60000
    $secs = [int][Math]::Floor($remainder / 1000)
    $millis = [int]($remainder % 1000)

    return ('{0:00}:{1:00}:{2:00},{3:000}' -f $hours, $mins, $secs, $millis)
}

function Split-SubtitleCueByPauses {
    param(
        [string]$Text,
        [int]$MaxCharsPerLine = 42,
        [int]$MaxLines = 2
    )

    $clean = Normalize-SubtitleDialogueText -Text $Text
    if ([string]::IsNullOrWhiteSpace($clean)) {
        return @()
    }

    if ($MaxCharsPerLine -lt 8) { $MaxCharsPerLine = 42 }
    if ($MaxLines -lt 1) { $MaxLines = 2 }
    $targetCueChars = $MaxCharsPerLine * $MaxLines

    $strongParts = @($clean -split '(?<=[\.!\?;:])\s+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($strongParts.Count -eq 0) {
        $strongParts = @($clean)
    }

    $chunks = [System.Collections.Generic.List[string]]::new()
    foreach ($part in $strongParts) {
        if ($part.Length -le $targetCueChars) {
            $chunks.Add($part)
            continue
        }

        # Split long parts on commas to better follow natural speaking pauses.
        $commaParts = @($part -split '(?<=,)\s+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($commaParts.Count -le 1) {
            $commaParts = @($part)
        }

        $current = ''
        foreach ($cp in $commaParts) {
            if ([string]::IsNullOrWhiteSpace($current)) {
                $current = $cp
                continue
            }

            $candidate = "$current $cp"
            if ($candidate.Length -le $targetCueChars) {
                $current = $candidate
            } else {
                $chunks.Add($current)
                $current = $cp
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($current)) {
            $chunks.Add($current)
        }
    }

    # Final guard: hard split anything still too long without dropping text.
    $finalChunks = [System.Collections.Generic.List[string]]::new()
    foreach ($chunk in $chunks) {
        if ($chunk.Length -le $targetCueChars) {
            $finalChunks.Add($chunk)
            continue
        }

        $words = @($chunk -split '\s+' | Where-Object { $_ })
        $current = ''
        foreach ($word in $words) {
            if ([string]::IsNullOrWhiteSpace($current)) {
                $current = $word
                continue
            }

            $candidate = "$current $word"
            if ($candidate.Length -le $targetCueChars) {
                $current = $candidate
            } else {
                $finalChunks.Add($current)
                $current = $word
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($current)) {
            $finalChunks.Add($current)
        }
    }

    return @($finalChunks)
}

function Limit-SrtCueLines {
    param(
        [string]$FilePath,
        [int]$MaxLines = 2,
        [int]$MaxCharsPerLine = 42
    )

    if ([string]::IsNullOrWhiteSpace($FilePath) -or -not (Test-Path -LiteralPath $FilePath)) {
        return $false
    }

    if ($MaxLines -lt 1) { $MaxLines = 1 }
    if ($MaxCharsPerLine -lt 8) { $MaxCharsPerLine = 42 }

    $raw = Get-Content -Raw -LiteralPath $FilePath -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $false
    }

    $normalized = $raw -replace "`r`n", "`n"
    $normalized = [regex]::Replace($normalized, '(?m)(\d{2}:\d{2}:\d{2})\.(\d{3})', '$1,$2')

    $originalTimestampCount = [regex]::Matches($normalized, '(?m)^\d{2}:\d{2}:\d{2}[,\.]\d{3}\s*-->\s*\d{2}:\d{2}:\d{2}[,\.]\d{3}$').Count
    if ($originalTimestampCount -eq 0) {
        return $false
    }

    $blocks = @($normalized -split "`n`n+")
    $rebuiltBlocks = [System.Collections.Generic.List[string]]::new()
    $changed = $false
    $nextIndex = 1

    foreach ($block in $blocks) {
        if ([string]::IsNullOrWhiteSpace($block)) {
            continue
        }

        $blockLines = @($block -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        if ($blockLines.Count -lt 3) {
            continue
        }

        $indexLine = $blockLines[0]
        $timestampLine = $blockLines[1] -replace '\.', ','
        if ($indexLine -notmatch '^\d+$') {
            continue
        }

        if ($timestampLine -notmatch '^\d{2}:\d{2}:\d{2},\d{3}\s*-->\s*\d{2}:\d{2}:\d{2},\d{3}$') {
            continue
        }

        $textLines = @($blockLines | Select-Object -Skip 2)
        $text = Normalize-SubtitleDialogueText -Text (($textLines -join ' '))
        if ([string]::IsNullOrWhiteSpace($text)) { $text = '...' }

        $pauseChunks = Split-SubtitleCueByPauses -Text $text -MaxCharsPerLine $MaxCharsPerLine -MaxLines $MaxLines
        if ($pauseChunks.Count -eq 0) {
            $pauseChunks = @('...')
        }

        $timeMatch = [regex]::Match($timestampLine, '^(?<start>\d{2}:\d{2}:\d{2},\d{3})\s*-->\s*(?<end>\d{2}:\d{2}:\d{2},\d{3})$')
        if (-not $timeMatch.Success) {
            continue
        }

        $startMs = Convert-SrtTimestampToMilliseconds -Timestamp $timeMatch.Groups['start'].Value
        $endMs = Convert-SrtTimestampToMilliseconds -Timestamp $timeMatch.Groups['end'].Value
        if ($null -eq $startMs -or $null -eq $endMs -or $endMs -le $startMs) {
            continue
        }

        $lineChunks = [System.Collections.Generic.List[object[]]]::new()
        $originalWrappedLineCount = 0
        foreach ($pauseChunk in $pauseChunks) {
            $wrappedLines = Split-SubtitleTextLines -Text $pauseChunk -MaxCharsPerLine $MaxCharsPerLine -MaxLines $MaxLines
            if ($wrappedLines.Count -eq 0) {
                $wrappedLines = @('...')
            }

            $originalWrappedLineCount += $wrappedLines.Count
            for ($lineIndex = 0; $lineIndex -lt $wrappedLines.Count; $lineIndex += $MaxLines) {
                $chunk = @($wrappedLines | Select-Object -Skip $lineIndex -First $MaxLines)
                if ($chunk.Count -gt 0) {
                    $lineChunks.Add($chunk)
                }
            }
        }

        if ($lineChunks.Count -eq 0) {
            $lineChunks.Add(@('...'))
        }

        # Merge a tiny trailing one-word chunk into the previous chunk if it fits.
        if ($lineChunks.Count -ge 2) {
            $lastChunk = @($lineChunks[$lineChunks.Count - 1])
            $prevChunk = @($lineChunks[$lineChunks.Count - 2])

            if ($lastChunk.Count -eq 1 -and $prevChunk.Count -ge 1) {
                $tailText = $lastChunk[0].Trim()
                $isTinyTail = ($tailText -match '^[A-Za-zÀ-ÿ]{1,12}$')
                if ($isTinyTail) {
                    $prevLastLine = $prevChunk[$prevChunk.Count - 1]
                    $candidate = ("$prevLastLine $tailText").Trim()
                    if ($candidate.Length -le $MaxCharsPerLine) {
                        $prevChunk[$prevChunk.Count - 1] = $candidate
                        $lineChunks[$lineChunks.Count - 2] = $prevChunk
                        $lineChunks.RemoveAt($lineChunks.Count - 1)
                        $changed = $true
                    }
                }
            }
        }

        $durationMs = [int64]($endMs - $startMs)
        $weights = [System.Collections.Generic.List[int]]::new()
        $totalWeight = 0
        foreach ($chunk in $lineChunks) {
            $w = ([string]::Join(' ', $chunk)).Length
            if ($w -lt 1) { $w = 1 }
            $weights.Add($w)
            $totalWeight += $w
        }
        if ($totalWeight -lt 1) { $totalWeight = $lineChunks.Count }

        $minChunkMs = 120
        $cursorStart = [int64]$startMs

        for ($chunkIndex = 0; $chunkIndex -lt $lineChunks.Count; $chunkIndex++) {
            $remainingAfter = $lineChunks.Count - $chunkIndex - 1

            if ($chunkIndex -eq ($lineChunks.Count - 1)) {
                $chunkEnd = [int64]$endMs
            } else {
                $rawShare = [int64][Math]::Round(($durationMs * $weights[$chunkIndex]) / $totalWeight)
                if ($rawShare -lt $minChunkMs) { $rawShare = $minChunkMs }

                $latestAllowed = [int64]($endMs - ($remainingAfter * $minChunkMs))
                $chunkEnd = $cursorStart + $rawShare
                if ($chunkEnd -gt $latestAllowed) { $chunkEnd = $latestAllowed }
                if ($chunkEnd -le $cursorStart) { $chunkEnd = $cursorStart + 1 }
            }

            $chunkTimestamp = "$(Convert-MillisecondsToSrtTimestamp -Milliseconds $cursorStart) --> $(Convert-MillisecondsToSrtTimestamp -Milliseconds $chunkEnd)"
            $rebuiltBlock = @("$nextIndex", $chunkTimestamp) + @($lineChunks[$chunkIndex])
            $rebuiltBlocks.Add(($rebuiltBlock -join "`r`n"))

            $nextIndex++
            $cursorStart = $chunkEnd
        }

        if ($indexLine -ne "$nextIndex") { $changed = $true }
        if ($textLines.Count -ne $originalWrappedLineCount -or $lineChunks.Count -gt 1) { $changed = $true }
    }

    # Adjacent cue carryover:
    # If a cue ends with a connector word and the next cue starts immediately,
    # pull 1..3 words from the next cue when it improves flow and still fits.
    if ($rebuiltBlocks.Count -ge 2) {
        for ($bi = 0; $bi -lt ($rebuiltBlocks.Count - 1); $bi++) {
            $curLines = @($rebuiltBlocks[$bi] -split "`r?`n" | ForEach-Object { $_.TrimEnd() })
            $nextLines = @($rebuiltBlocks[$bi + 1] -split "`r?`n" | ForEach-Object { $_.TrimEnd() })

            if ($curLines.Count -lt 3 -or $nextLines.Count -lt 3) { continue }

            $curTs = [regex]::Match($curLines[1], '^(?<s>\d{2}:\d{2}:\d{2},\d{3})\s*-->\s*(?<e>\d{2}:\d{2}:\d{2},\d{3})$')
            $nextTs = [regex]::Match($nextLines[1], '^(?<s>\d{2}:\d{2}:\d{2},\d{3})\s*-->\s*(?<e>\d{2}:\d{2}:\d{2},\d{3})$')
            if (-not $curTs.Success -or -not $nextTs.Success) { continue }

            $curEndMs = Convert-SrtTimestampToMilliseconds -Timestamp $curTs.Groups['e'].Value
            $nextStartMs = Convert-SrtTimestampToMilliseconds -Timestamp $nextTs.Groups['s'].Value
            if ($null -eq $curEndMs -or $null -eq $nextStartMs) { continue }

            # Only if cues are directly adjacent or nearly adjacent.
            if ([Math]::Abs([int64]($nextStartMs - $curEndMs)) -gt 400) { continue }

            $curTextLines = @($curLines | Select-Object -Skip 2)
            $nextTextLines = @($nextLines | Select-Object -Skip 2)
            if ($curTextLines.Count -eq 0 -or $nextTextLines.Count -eq 0) { continue }

            $lastCur = $curTextLines[$curTextLines.Count - 1].Trim()
            if ($lastCur -notmatch '(?i)\b(en|of|maar|want|omdat|zodat|terwijl|als|dan)$') { continue }

            # Safety: do not carry over if previous line already clearly ended a sentence.
            if ($lastCur -match '[\.!\?]$') { continue }

            $nextAllText = (($nextTextLines -join ' ').Trim())
            if ([string]::IsNullOrWhiteSpace($nextAllText)) { continue }

            # Safety: if next cue starts like a new sentence (uppercase, possibly after quote/paren),
            # we should not borrow words from it.
            if ($nextAllText -match '^\s*["''\(\[]?[A-ZÀ-Ý]') { continue }

            $firstWordMatch = [regex]::Match($nextAllText, '^\s*(?<w>[A-Za-zÀ-ÿ][A-Za-zÀ-ÿ0-9''-]*)\b')
            if (-not $firstWordMatch.Success) { continue }
            $firstWord = $firstWordMatch.Groups['w'].Value
            if ([string]::IsNullOrWhiteSpace($firstWord)) { continue }

            # Safety: only carry from a likely continuation (starts lowercase).
            if ([char]::IsUpper($firstWord[0])) { continue }

            $nextWords = @([regex]::Matches($nextAllText, "[A-Za-zÀ-ÿ0-9'-]+") | ForEach-Object { $_.Value })
            if ($nextWords.Count -lt 2) { continue }

            $carryApplied = $false
            $maxCarryWords = [Math]::Min(3, $nextWords.Count - 1)

            for ($cw = $maxCarryWords; $cw -ge 1; $cw--) {
                $carryPhrase = ($nextWords[0..($cw - 1)] -join ' ').Trim()
                if ([string]::IsNullOrWhiteSpace($carryPhrase)) { continue }

                $candidateLastLine = ("$lastCur $carryPhrase").Trim()
                if ($candidateLastLine.Length -gt $MaxCharsPerLine) { continue }

                $curPrefixLines = @()
                if ($curTextLines.Count -gt 1) {
                    $curPrefixLines = @($curTextLines | Select-Object -First ($curTextLines.Count - 1))
                }

                $curCombinedText = ((@($curPrefixLines) + @($candidateLastLine)) -join ' ').Trim()

                # Remove only the carried leading words from nextAllText and keep
                # punctuation/casing of the remainder exactly as recognized.
                $removePattern = '^(\s*(?:[A-Za-zÀ-ÿ0-9''-]+\s+){' + ($cw - 1) + '}[A-Za-zÀ-ÿ0-9''-]+)\s*'
                $nextRemainingText = [regex]::Replace($nextAllText, $removePattern, '', 1).Trim()
                if ([string]::IsNullOrWhiteSpace($nextRemainingText)) { continue }

                $curReflow = Split-SubtitleTextLines -Text $curCombinedText -MaxCharsPerLine $MaxCharsPerLine -MaxLines $MaxLines
                $nextReflow = Split-SubtitleTextLines -Text $nextRemainingText -MaxCharsPerLine $MaxCharsPerLine -MaxLines $MaxLines

                if ($curReflow.Count -eq 0 -or $nextReflow.Count -eq 0) { continue }
                if ($curReflow.Count -gt $MaxLines -or $nextReflow.Count -gt $MaxLines) { continue }

                $rebuiltBlocks[$bi] = (@($curLines[0], $curLines[1]) + @($curReflow)) -join "`r`n"
                $rebuiltBlocks[$bi + 1] = (@($nextLines[0], $nextLines[1]) + @($nextReflow)) -join "`r`n"
                $changed = $true
                $carryApplied = $true
                break
            }

            if ($carryApplied) { continue }
        }

        # If carryover was not possible, remove dangling connector endings
        # like "... en" / "... of" before the next cue.
        for ($bi = 0; $bi -lt ($rebuiltBlocks.Count - 1); $bi++) {
            $curLines = @($rebuiltBlocks[$bi] -split "`r?`n" | ForEach-Object { $_.TrimEnd() })
            if ($curLines.Count -lt 3) { continue }

            $curTextLines = @($curLines | Select-Object -Skip 2)
            if ($curTextLines.Count -eq 0) { continue }

            $lastIdx = $curTextLines.Count - 1
            $lastText = $curTextLines[$lastIdx].Trim()
            if ($lastText -notmatch '(?i)\b(en|of|maar|want|omdat|zodat|terwijl|als|dan)$') { continue }

            $trimmed = [regex]::Replace($lastText, '(?i)\s+\b(en|of|maar|want|omdat|zodat|terwijl|als|dan)\s*$', '').Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

            $curTextLines[$lastIdx] = $trimmed
            $rebuiltBlocks[$bi] = (@($curLines[0], $curLines[1]) + $curTextLines) -join "`r`n"
            $changed = $true
        }
    }

    if ($rebuiltBlocks.Count -eq 0) {
        return $false
    }

    $minExpectedBlocks = [Math]::Max(1, [int][Math]::Floor($originalTimestampCount * 0.7))
    if ($rebuiltBlocks.Count -lt $minExpectedBlocks) {
        return $false
    }

    $rebuilt = ($rebuiltBlocks -join "`r`n`r`n").TrimEnd() + "`r`n"
    if (-not $changed -and $rebuilt -eq $raw) {
        return $false
    }

    Set-Content -LiteralPath $FilePath -Value $rebuilt -Encoding UTF8
    return $true
}

#*********************************************************************************************
#      Video Conversion Functions
#*********************************************************************************************

function Convert-H265ToH264WithAAC {
    param (
        [Parameter(Mandatory = $true)]
        [string]$InputFile,

        [string]$OutputFile = "",

        [ValidateSet("ultrafast", "fast", "medium", "slow")]
        [string]$Preset = "fast",

        [ValidateRange(18, 28)]
        [int]$CRF = 28,
        
        [ValidateSet("nvidia", "amd", "cpu")]
        [string]$Encoder = "nvidia",

        [string]$VideoFilter = "",
        
        [string]$AspectRatio = "",
        
        [string]$LogFile = ""
    )

    if (-not (Test-Path $InputFile)) {
        Write-Host "❌ Bestand niet gevonden: $InputFile" -ForegroundColor Red
        return
    }

    if (-not $OutputFile) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
        $dir  = [System.IO.Path]::GetDirectoryName($InputFile)
        $OutputFile = Join-Path $dir "$base.h264.mkv"
    }

    $InputFileDisplay = Split-Path $InputFile -Leaf

    # Use a temporary file in the temp directory to avoid path issues
    $tempOutput = [System.IO.Path]::Combine($env:TEMP, [System.IO.Path]::GetRandomFileName() + ".mkv")

    # Try encoding with specified encoder, fallback to CPU on failure
    $encoders = @($Encoder)
    if ($Encoder -ne "cpu") {
        $encoders += "cpu"  # Add CPU as fallback
    }

    foreach ($enc in $encoders) {
        # Determine encoder and set appropriate flags
        $videoCodec = ""
        $encoderPreset = ""
        
        if ($enc -eq "nvidia") {
            $videoCodec = "h264_nvenc"
            # Samsung TV compatible: Main profile, Level 4.1, moderate bitrate
            $encoderPreset = "-preset p4 -profile:v main -level 4.1 -rc:v vbr_hq -cq:v 23 -b:v 5M"
        } elseif ($enc -eq "amd") {
            $videoCodec = "h264_amf"
            $encoderPreset = "-profile main -level 4.1 -quality speed -rc vbr -qp_i 23 -qp_p 23 -qp_b 23"
        } else {
            $videoCodec = "libx264"
            # CPU: Use high profile for better quality, let FFmpeg auto-select level
            # Main profile may have issues with some sources
            $encoderPreset = "-preset $Preset -crf $CRF"
        }

        # Check if source is 10-bit (hardware encoders don't support 10-bit)
        $pixFmt = ""
        try {
            $pixFmt = (& $Global:FFprobeExe -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=noprint_wrappers=1:nokey=1 $InputFile).Trim()
        } catch {
            $pixFmt = ""
        }
        $is10bit = $pixFmt -match "10le$|p010"
        
        # If 10-bit source with hardware encoder, force CPU fallback
        if ($is10bit -and $enc -ne "cpu") {
            Write-Host "⚠️  Source is 10-bit ($pixFmt), $enc doesn't support 10-bit. Using CPU..." -ForegroundColor Yellow
            $enc = "cpu"
            $videoCodec = "libx264"
            $encoderPreset = "-preset $Preset"
        }

        # Get input frame count for accurate progress calculation
        $totalFrames = 0
        try {
            $totalFrames = [int](& $Global:FFprobeExe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 $InputFile)
        } catch {
            $totalFrames = 0
        }

        $progressFile = [System.IO.Path]::GetTempFileName()
        
        try {
            # Build ffmpeg arguments - split preset if it contains multiple params
            $ffmpegArgs = @(
                "-loglevel", "verbose",
                "-stats_period", "2",
                "-i", $InputFile
            )
            
            # Add video codec
            $ffmpegArgs += "-c:v"
            $ffmpegArgs += $videoCodec
            
            # Add preset/quality parameters (may contain multiple values)
            if ($encoderPreset -match "\s") {
                # Multiple parameters - split and add individually
                foreach ($param in $encoderPreset.Split(" ")) {
                    if (-not [string]::IsNullOrWhiteSpace($param)) {
                        $ffmpegArgs += $param
                    }
                }
            } else {
                $ffmpegArgs += $encoderPreset
            }
            
            # Add pixel format conversion for hardware encoders only if needed
            if ($enc -ne "cpu" -and $pixFmt -ne "yuv420p") {
                $ffmpegArgs += @("-pix_fmt", "yuv420p")
            }
            
            # Build filter chain (optional scale/crop + optional DAR override)
            $filterChain = @()
            if (-not [string]::IsNullOrWhiteSpace($VideoFilter)) {
                $filterChain += $VideoFilter
            }
            if ($AspectRatio -and $AspectRatio -ne "keep" -and $AspectRatio -ne "") {
                $filterChain += "setdar=$AspectRatio"
            }
            if ($filterChain.Count -gt 0) {
                $ffmpegArgs += @("-vf", ($filterChain -join ","))
            }
            
            # Add remaining parameters - use temp file for output
            # Copy audio instead of re-encoding (faster, no quality loss)
            $ffmpegArgs += @(
                "-c:a", "copy",
                "-y",
                $tempOutput
            )

            # Run FFmpeg without redirecting stdout (which interferes with mkv output)
            # Use -stats_period to get regular progress updates to stderr
            $process = Start-Process -FilePath $Global:FFmpegExe -ArgumentList $ffmpegArgs -PassThru -NoNewWindow -RedirectStandardError $progressFile
            $startTime = Get-Date
            
            # Wait a moment for process to start
            Start-Sleep -Milliseconds 500
            if ($process.HasExited -and $process.ExitCode -ne 0) {
                Write-Host "❌ FFmpeg process exited immediately with code $($process.ExitCode)" -ForegroundColor Red
                $ffmpegOutput = Get-Content $progressFile -ErrorAction SilentlyContinue | Out-String
                Write-Host "Error output: $($ffmpegOutput | Select-Object -Last 5)" -ForegroundColor Red
                continue  # Try next encoder
            }

            # Monitor progress (update every 2 seconds)
            $lastProgress = 0
            $lastUpdate = Get-Date
            $stuckCounter = 0
            $maxStuckCount = 20  # Exit if no progress for 20 checks (10 seconds)
            
            while (-not $process.HasExited) {
                try {
                    $now = Get-Date
                    $progressData = Get-Content $progressFile -ErrorAction SilentlyContinue | Select-Object -Last 20
                    
                    # Look for frame= pattern in stats output
                    $frameMatch = $progressData | Select-String "frame=\s*(\d+)"
                    
                    if ($frameMatch) {
                        $currentFrame = [int]($frameMatch.Matches[-1].Groups[1].Value)
                        $stuckCounter = 0  # Reset stuck counter when progress detected
                        
                        if ($totalFrames -gt 0) {
                            $percent = [Math]::Min(100, [int](($currentFrame / $totalFrames) * 100))
                            # Update display every 2 seconds or when progress changes by 5%
                            if (($now - $lastUpdate).TotalSeconds -ge 2 -or ($percent - $lastProgress) -ge 5) {
                                $barLength = 30
                                $filled = [int]($percent / 100 * $barLength)
                                $bar = "#" * $filled + "-" * ($barLength - $filled)
                                Write-Host -NoNewline "`r[$bar] $percent% (Frame $currentFrame/$totalFrames)  "
                                $lastProgress = $percent
                                $lastUpdate = $now
                            }
                        }
                    } else {
                        $stuckCounter++
                        # If stuck for too long, check if process crashed
                        if ($stuckCounter -ge $maxStuckCount) {
                            Write-Host "`n⚠️  No progress detected, process may have crashed" -ForegroundColor Yellow
                            break
                        }
                    }
                } catch {
                    # Silently continue
                }
                Start-Sleep -Milliseconds 500
            }
            
            # Wait a bit for file to be fully written
            Start-Sleep -Milliseconds 1000
            
            # Check for errors in ffmpeg output
            $ffmpegOutput = Get-Content $progressFile -ErrorAction SilentlyContinue | Out-String
            $hasError = $ffmpegOutput -match "No capable devices found|error|Error|EBML header"
            
            # Kill process if it's still running (in case of error or hanging)
            if (-not $process.HasExited) {
                try {
                    $process.Kill()
                    Start-Sleep -Milliseconds 500
                } catch {
                    # Process already exited
                }
            }
            
            # Check FFmpeg exit code
            $exitCode = $process.ExitCode
            if ($exitCode -ne 0) {
                Write-Host "`n❌ FFmpeg failed with exit code $exitCode" -ForegroundColor Red
                
                # Extract relevant error messages
                $errorLines = $ffmpegOutput -split "`n" | Where-Object { $_ -match "error|Error|failed|Failed|invalid|Invalid" } | Select-Object -Last 5
                if ($errorLines) {
                    Write-Host "Error details:" -ForegroundColor Yellow
                    $errorLines | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
                }
                
                $errorSummary = if ($errorLines) { $errorLines -join " | " } else { "Exit code $exitCode" }
                $logMessage = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] ❌ $InputFileDisplay -> FFmpeg failed | Encoder: $enc | Error: $errorSummary"
                if ($LogFile) { Write-LogEntry -LogFile $LogFile -Message $logMessage }
                
                # Clean up invalid temp file
                Remove-Item $tempOutput -ErrorAction SilentlyContinue
                
                if ($enc -ne "cpu") {
                    Write-Host "⚠️  $enc failed, falling back to CPU..." -ForegroundColor Yellow
                    continue
                }
                return
            }
            
            # Verify output file exists and is valid
            if (-not (Test-Path $tempOutput)) {
                Write-Host "❌ Output file not created" -ForegroundColor Red
                
                # Get last lines of ffmpeg output for diagnostics
                $errorLines = $ffmpegOutput -split "`n" | Select-Object -Last 10 | Where-Object { $_ -match "error|Error|failed|Failed" }
                $errorSummary = if ($errorLines) { $errorLines -join " | " } else { "No specific error found in ffmpeg output" }
                
                $logMessage = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] ❌ $InputFileDisplay -> Output file not created | Error: $errorSummary"
                if ($LogFile) { Write-LogEntry -LogFile $LogFile -Message $logMessage }
                
                if ($enc -ne "cpu") {
                    Write-Host "⚠️  $enc failed, falling back to CPU..." -ForegroundColor Yellow
                    $logMessage = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] ⚠️  $InputFileDisplay | $enc failed (no output), trying CPU fallback"
                    if ($LogFile) { Write-LogEntry -LogFile $LogFile -Message $logMessage }
                    continue
                }
                return
            }
            
            # Verify output codec
            $outputCodec = ""
            $elapsedTime = ((Get-Date) - $startTime).TotalSeconds
            try {
                $outputCodec = (& $Global:FFprobeExe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 $tempOutput)
            } catch {
                $outputCodec = "unknown"
            }
            
            # Validate codec is h264
            if ($outputCodec -eq "h264") {
                # Replace original file with converted version
                try {
                    # Remove original H.265 file
                    Remove-Item -LiteralPath $InputFile -Force -ErrorAction Stop
                    
                    # Move converted file to original location (not .h264.mkv)
                    Move-Item -Path $tempOutput -Destination $InputFile -Force -ErrorAction Stop
                    
                    $logMessage = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] ✅ $InputFileDisplay -> H.264 | Encoder: $enc | Time: $([int]$elapsedTime)s"
                    Write-Host ""  # New line after progress bar
                    Write-Host ""  # Extra line to clear any background color bleeding
                    Write-Host "✅ Klaar ($enc): $InputFileDisplay replaced with H.264 [${elapsedTime}s]" -ForegroundColor Green
                    
                    if ($LogFile) {
                        Write-LogEntry -LogFile $LogFile -Message $logMessage
                    }
                    
                    # Also rename any associated subtitle files (remove .h264 from name)
                    $inputDir = [System.IO.Path]::GetDirectoryName($InputFile)
                    $inputBase = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
                    Get-ChildItem -Path $inputDir -Filter "$inputBase.h264.*" -ErrorAction SilentlyContinue | ForEach-Object {
                        $newName = $_.Name -replace '\.h264\.', '.'
                        $newPath = Join-Path $inputDir $newName
                        # Only rename if target doesn't exist
                        if (-not (Test-Path $newPath)) {
                            Move-Item -LiteralPath $_.FullName -Destination $newPath -Force -ErrorAction SilentlyContinue
                        } else {
                            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                        }
                    }
                    
                    return  # Success, exit function
                } catch {
                    Write-Host "❌ Kon bestand niet vervangen: $_" -ForegroundColor Red
                    $logMessage = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] ❌ $InputFileDisplay -> Failed to replace original file"
                    if ($LogFile) { Write-LogEntry -LogFile $LogFile -Message $logMessage }
                    Remove-Item $tempOutput -ErrorAction SilentlyContinue
                    return
                }
            } elseif ($hasError -and $enc -ne "cpu") {
                $logMessage = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] ⚠️  $InputFileDisplay | $enc failed, trying CPU fallback"
                Write-Host "⚠️  $enc failed (codec: $outputCodec), falling back to CPU..." -ForegroundColor Yellow
                
                if ($LogFile) {
                    Write-LogEntry -LogFile $LogFile -Message $logMessage
                }
                # Remove failed temp file
                Remove-Item $tempOutput -ErrorAction SilentlyContinue
                continue  # Try next encoder
            } else {
                $logMessage = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] ❌ $InputFileDisplay -> Invalid codec: $outputCodec"
                Write-Host "❌ Mislukt: codec=$outputCodec (expected h264)" -ForegroundColor Red
                
                if ($LogFile) {
                    Write-LogEntry -LogFile $LogFile -Message $logMessage
                }
                # Remove failed temp file
                Remove-Item $tempOutput -ErrorAction SilentlyContinue
                
                if ($enc -ne "cpu") {
                    Write-Host "⚠️  Falling back to CPU..." -ForegroundColor Yellow
                    $logMessage = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] ⚠️  $InputFileDisplay | Invalid codec from $enc, trying CPU fallback"
                    if ($LogFile) { Write-LogEntry -LogFile $LogFile -Message $logMessage }
                    continue
                }
                return
            }
        } finally {
            Remove-Item $progressFile -ErrorAction SilentlyContinue
        }
    }
}

function Convert-AllH265InFolder {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FolderPath,

        [ValidateSet("ultrafast", "fast", "medium", "slow")]
        [string]$Preset = "",

        [ValidateRange(18, 28)]
        [int]$CRF = 0,
        
        [ValidateSet("nvidia", "amd", "cpu")]
        [string]$Encoder = "",
        
        [string]$AspectRatio = ""
    )

    # Use config values if parameters not provided
    if ([string]::IsNullOrWhiteSpace($Preset)) { $Preset = $Global:H265Preset }
    if ($CRF -le 0) { $CRF = $Global:H265CRF }
    if ([string]::IsNullOrWhiteSpace($Encoder)) { $Encoder = $Global:H265Encoder }
    if ([string]::IsNullOrWhiteSpace($AspectRatio)) { $AspectRatio = $Global:ForceAspectRatio }
    
    # Debug output to verify values
    Write-Host "DEBUG: Using Preset=$Preset (config: $($Global:H265Preset)), CRF=$CRF (config: $($Global:H265CRF)), Encoder=$Encoder (config: $($Global:H265Encoder))" -ForegroundColor DarkGray

    if (-not (Test-Path $FolderPath)) {
        Write-Host "❌ Map niet gevonden: $FolderPath" -ForegroundColor Red
        return
    }

    # Use step-specific log file if available, otherwise create conversion-specific log
    if ($Global:CurrentStepLogFile) {
        $logFile = $Global:CurrentStepLogFile
    } else {
        $logFile = Join-Path $Global:LogDir "h265_conversion_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
        
        # Add header to log
        Add-Content -Path $logFile -Value "==============================================="
        Add-Content -Path $logFile -Value "H.265 to H.264 Conversion Log - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        Add-Content -Path $logFile -Value "Encoder: $Encoder | Preset: $Preset | CRF: $CRF"
        Add-Content -Path $logFile -Value "==============================================="
    }

    DrawBanner -Text "CONVERTING ALL H.265 TO H.264 (using $Encoder)"
    Show-Format "INFO" "Folder: $FolderPath - Preset: $Preset - CRF: $CRF - Encoder: $Encoder" -NameColor "Cyan"

    $count = 0
    $successCount = 0
    $skippedCount = 0
    Get-ChildItem -Path $FolderPath -Recurse -Filter *.mkv | ForEach-Object {
        $file = $_.FullName

        # ffprobe: check codec and pixel format
        $codec = ""
        $pixFmt = ""
        try {
            $codec = (& $Global:FFprobeExe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 $file | Select-Object -First 1).Trim()
            $pixFmt = (& $Global:FFprobeExe -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=noprint_wrappers=1:nokey=1 $file | Select-Object -First 1).Trim()
        } catch {
            $codec = ""
            $pixFmt = ""
        }

        if ($codec -eq "hevc") {
            $count++
            $is10bit = $pixFmt -match "10le$|p010"
            
            # Hybrid approach: Skip 10-bit files only if using GPU encoder
            if ($is10bit -and $Encoder -ne "cpu") {
                Show-Format "SKIP 10-bit" $_.Name "10-bit H.265 kept as-is ($Encoder doesn't support)" -NameColor "DarkYellow"
                $skippedCount++
            } else {
                $bitDepth = if ($is10bit) { "10-bit" } else { "8-bit" }
                Show-Format "FOUND H.265" $_.Name "[$count] Converting $bitDepth with $Encoder..." -NameColor "Yellow"
                Convert-H265ToH264WithAAC -InputFile $file -Preset $Preset -CRF $CRF -Encoder $Encoder -AspectRatio $AspectRatio -LogFile $logFile
                $successCount++
            }
        } else {
            Show-Format "SKIP" $_.Name "Codec: $codec" -NameColor "DarkGray"
        }
    }
    
    # Summary (only add to log if not using step transcript)
    if (-not $Global:CurrentStepLogFile) {
        Add-Content -Path $logFile -Value ""
        Add-Content -Path $logFile -Value "Summary: $successCount converted, $skippedCount skipped (10-bit), $count total H.265 files"
        Add-Content -Path $logFile -Value "Log file: $logFile"
        Add-Content -Path $logFile -Value ""
    }
    
    if ($count -eq 0) {
        Show-Format "INFO" "Geen H.265 bestanden gevonden" -NameColor "Cyan"
    } else {
        Show-Format "INFO" "Conversie voltooid" "$successCount converted, $skippedCount skipped (10-bit)" -NameColor "Green"
    }

    $Global:LastConversionStats = @{
        Converted = $successCount
        Failed = 0
        FailedItems = @()
        Skipped = $skippedCount
        Mode = "h265_to_h264"
    }
}

function Convert-HighBitDepthToH265 {
    param (
        [Parameter(Mandatory = $true)]
        [string]$InputFile,

        [string]$OutputFile = "",

        [ValidateSet("1080p", "720p", "keep")]
        [string]$Resolution = "",

        [string]$Preset = "",

        [ValidateRange(18, 32)]
        [int]$CRF = 0,
        
        [ValidateSet("nvidia", "amd", "cpu")]
        [string]$Encoder = "",
        
        [string]$Scaling = "",
        
        [string]$Audio = "",
        
        [string]$Bitrate = "",
        
        [string]$AspectRatio = "",
        
        [int]$MaxWidth = 0,
        
        [string]$LogFile = ""
    )
    
    # Use config values if not provided
    if ([string]::IsNullOrWhiteSpace($Resolution)) { $Resolution = $Global:DownscaleResolution }
    if ([string]::IsNullOrWhiteSpace($Preset)) { $Preset = $Global:DownscalePreset }
    if ($CRF -le 0) { $CRF = $Global:DownscaleCRF }
    if ([string]::IsNullOrWhiteSpace($Encoder)) { $Encoder = $Global:DownscaleEncoder }
    if ([string]::IsNullOrWhiteSpace($Scaling)) { $Scaling = $Global:DownscaleScaling }
    if ([string]::IsNullOrWhiteSpace($Audio)) { $Audio = $Global:DownscaleAudio }
    if ([string]::IsNullOrWhiteSpace($Bitrate)) { $Bitrate = $Global:DownscaleBitrate }
    if ([string]::IsNullOrWhiteSpace($AspectRatio)) { $AspectRatio = $Global:ForceAspectRatio }
    if ($MaxWidth -le 0) {
        if ($Global:DownscaleMaxWidth -gt 0) {
            $MaxWidth = [int]$Global:DownscaleMaxWidth
        } else {
            $MaxWidth = 1920
        }
    }

    # Optional compatibility fallback: after HEVC conversion, re-encode to H.264 for TV safety
    $fallbackToH264Enabled = $false
    if ($null -ne $Global:DownscaleFallbackToH264) {
        $fallbackToH264Enabled = [bool]$Global:DownscaleFallbackToH264
    }

    $fallbackH264Encoder = if ([string]::IsNullOrWhiteSpace($Global:DownscaleFallbackH264Encoder)) { "nvidia" } else { $Global:DownscaleFallbackH264Encoder }
    if ($fallbackH264Encoder -notin @("nvidia", "amd", "cpu")) {
        $fallbackH264Encoder = "nvidia"
    }

    $fallbackH264Preset = if ([string]::IsNullOrWhiteSpace($Global:DownscaleFallbackH264Preset)) { "fast" } else { $Global:DownscaleFallbackH264Preset }
    if ($fallbackH264Preset -notin @("ultrafast", "fast", "medium", "slow")) {
        $fallbackH264Preset = "fast"
    }

    $fallbackH264CRF = 23
    if ($Global:DownscaleFallbackH264CRF -is [int] -and $Global:DownscaleFallbackH264CRF -ge 18 -and $Global:DownscaleFallbackH264CRF -le 28) {
        $fallbackH264CRF = [int]$Global:DownscaleFallbackH264CRF
    }

    $fallbackH264Mode = if ([string]::IsNullOrWhiteSpace($Global:DownscaleFallbackH264Mode)) { "separate" } else { $Global:DownscaleFallbackH264Mode.ToLower() }
    if ($fallbackH264Mode -notin @("separate", "replace", "direct")) {
        $fallbackH264Mode = "separate"
    }

    if (-not (Test-Path -LiteralPath $InputFile)) {
        Write-Host "❌ Bestand niet gevonden: $InputFile" -ForegroundColor Red
        return $false
    }

    if (-not $OutputFile) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
        $dir  = [System.IO.Path]::GetDirectoryName($InputFile)
        $OutputFile = Join-Path $dir "$base.$Resolution.h265.mkv"
    }

    $InputFileDisplay = Split-Path $InputFile -Leaf

    # Detect pixel format, bit depth, current resolution, and aspect ratio
    $pixFmt = ""
    $bitDepth = ""
    $currentWidth = 0
    $currentHeight = 0
    $originalDAR = ""
    
    try {
        $pixFmt = (& $Global:FFprobeExe -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=noprint_wrappers=1:nokey=1 $InputFile).Trim()
        $currentWidth = [int](& $Global:FFprobeExe -v error -select_streams v:0 -show_entries stream=width -of default=noprint_wrappers=1:nokey=1 $InputFile).Trim()
        $currentHeight = [int](& $Global:FFprobeExe -v error -select_streams v:0 -show_entries stream=height -of default=noprint_wrappers=1:nokey=1 $InputFile).Trim()
        
        # Get original Display Aspect Ratio (DAR)
        $originalDAR = (& $Global:FFprobeExe -v error -select_streams v:0 -show_entries stream=display_aspect_ratio -of default=noprint_wrappers=1:nokey=1 $InputFile 2>$null).Trim()
        if ([string]::IsNullOrWhiteSpace($originalDAR) -or $originalDAR -eq "N/A") {
            # Calculate from resolution if not set
            $originalDAR = "${currentWidth}:${currentHeight}"
        }
        
        if ($pixFmt -match "10le$|p010") {
            $bitDepth = "10-bit"
        } elseif ($pixFmt -match "12le$|p012") {
            $bitDepth = "12-bit"
        } else {
            $bitDepth = "8-bit"
        }
    } catch {
        $pixFmt = "unknown"
        $bitDepth = "unknown"
        $originalDAR = ""
    }
    
    # Check if this file needs conversion based on minimum resolution threshold
    $minResolution = $Global:DownscaleMinResolution
    if ($minResolution -gt 0 -and $currentHeight -lt $minResolution) {
        Show-Format "SKIP" "$InputFileDisplay ($bitDepth ${currentWidth}x${currentHeight} - below ${minResolution}p threshold)" -NameColor "Yellow"
        return $false
    }

    # Determine scale filter based on resolution and scaling algorithm
    $autoWidthCapped = $false
    if ($Resolution -eq "keep") {
        # Keep original resolution unless it exceeds configured TV-safe max width
        if ($MaxWidth -gt 0 -and $currentWidth -gt $MaxWidth) {
            $targetWidth = $MaxWidth
            $rawTargetHeight = [math]::Round(($currentHeight * $targetWidth) / $currentWidth)
            # yuv420p requires even dimensions; ensure at least 2 pixels high
            if ($rawTargetHeight -lt 2) { $rawTargetHeight = 2 }
            if (($rawTargetHeight % 2) -ne 0) { $rawTargetHeight -= 1 }
            $targetHeight = $rawTargetHeight
            $scaleFilter = "scale=${targetWidth}:${targetHeight}:flags=${Scaling}"
            $autoWidthCapped = $true
            Show-Format "TV SAFE" "$InputFileDisplay" "Width ${currentWidth}px > ${MaxWidth}px, auto-scale to ${targetWidth}x${targetHeight}" -NameColor "Yellow"
        } else {
            $scaleFilter = ""
            $targetWidth = $currentWidth
            $targetHeight = $currentHeight
        }
    } else {
        # Scale to target resolution
        $targetWidth = if ($Resolution -eq "1080p") { 1920 } else { 1280 }
        $targetHeight = if ($Resolution -eq "1080p") { 1080 } else { 720 }
        $scaleFilter = "scale=${targetWidth}:${targetHeight}:flags=${Scaling}"
    }

    # Direct mode: when enabled, skip HEVC pass and go straight to H.264 for TV-risky wide sources.
    if ($fallbackToH264Enabled -and $autoWidthCapped -and $fallbackH264Mode -eq "direct") {
        Show-Format "TV SAFE" "$InputFileDisplay" "Direct H.264 mode active; skipping HEVC pass" -NameColor "Yellow"
        Convert-H265ToH264WithAAC -InputFile $InputFile -Preset $fallbackH264Preset -CRF $fallbackH264CRF -Encoder $fallbackH264Encoder -VideoFilter $scaleFilter -AspectRatio $AspectRatio -LogFile ""

        $directCodec = ""
        try {
            $directCodec = (& $Global:FFprobeExe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 $InputFile 2>$null).Trim()
        } catch {
            $directCodec = ""
        }

        if ($directCodec -eq "h264") {
            Write-Host "✅ Klaar: $InputFileDisplay converted directly to TV-safe H.264" -ForegroundColor Green
            return $true
        }

        Write-Host "❌ Direct H.264 mode failed (final codec='$directCodec')" -ForegroundColor Red
        return $false
    }

    # Use a temporary file
    $tempOutput = [System.IO.Path]::Combine($env:TEMP, [System.IO.Path]::GetRandomFileName() + ".mkv")

    # Determine encoder and settings
    $videoCodec = ""
    $encoderParams = ""
    
    if ($Encoder -eq "nvidia") {
        $videoCodec = "hevc_nvenc"
        # NVENC H.265 settings: Use config values
        if ($Bitrate) {
            # Bitrate mode (faster, more predictable file size)
            $encoderParams = "-preset $Preset -tune hq -profile:v main -rc vbr -cq $CRF -b:v $Bitrate -maxrate $Bitrate -bufsize $Bitrate"
        } else {
            # CRF mode (better quality)
            $encoderParams = "-preset $Preset -tune hq -profile:v main -rc vbr -cq $CRF"
        }
    } elseif ($Encoder -eq "amd") {
        $videoCodec = "hevc_amf"
        # AMF settings
        if ($Bitrate) {
            $encoderParams = "-quality balanced -rc vbr_latency -b:v $Bitrate"
        } else {
            $encoderParams = "-quality balanced -rc vbr_latency -qp_i $CRF -qp_p $CRF"
        }
    } else {
        $videoCodec = "libx265"
        # CPU: x265 with config preset
        $encoderParams = "-preset $Preset -crf $CRF -x265-params profile=main"
    }
    
    # Determine audio codec
    $audioCodec = if ($Audio -eq "copy") { "copy" } else { "aac" }
    $audioParams = if ($Audio -eq "aac") { "-b:a 192k" } else { "" }

    $resolutionText = if ($scaleFilter) { "${targetWidth}x${targetHeight}" } elseif ($Resolution -eq "keep") { "${currentWidth}x${currentHeight}" } else { $Resolution }
    Write-Host "🎬 Converting $bitDepth to H.265 8-bit $resolutionText..." -ForegroundColor Cyan
    Write-Host "   Source: $InputFileDisplay | Encoder: $Encoder" -ForegroundColor Gray

    # Debug
    if ($Global:DEBUGMode) {
        Write-Host "DEBUG: InputFile = '$InputFile'" -ForegroundColor Yellow
        Write-Host "DEBUG: File exists = $(Test-Path -LiteralPath $InputFile)" -ForegroundColor Yellow
    }
    
    $startTime = Get-Date
    
    try {
        # Build video filter chain
        $videoFilter = ""
        if ($scaleFilter) {
            $videoFilter = $scaleFilter
        }
        
        # For bit depth conversion without scaling, force correct aspect ratio
        # Calculate simplified DAR (e.g., 1920:800 → 12:5)
        if (-not $scaleFilter) {
            $gcd = Get-GCD -a $currentWidth -b $currentHeight
            $darNum = $currentWidth / $gcd
            $darDen = $currentHeight / $gcd
            $videoFilter = "setdar=${darNum}/${darDen}"
        }
        
        # Add aspect ratio if specified (overrides calculated one)
        if ($AspectRatio -and $AspectRatio -ne "keep" -and $AspectRatio -ne "") {
            $videoFilter = "setdar=${AspectRatio}"
        }
        
        # Build FFmpeg arguments
        $ffmpegArgs = @(
            "-hide_banner",
            "-nostdin",
            "-loglevel", "error",
            "-stats",
            "-i", "`"$InputFile`""
        )
        
        if ($videoFilter) {
            $ffmpegArgs += "-vf"
            $ffmpegArgs += $videoFilter
        }
        
        $ffmpegArgs += @(
            "-c:v", $videoCodec
        ) + $encoderParams.Split() + @(
            "-pix_fmt", "yuv420p",
            "-c:a", $audioCodec
        )
        
        if ($audioParams) {
            $ffmpegArgs += $audioParams.Split()
        }
        
        $ffmpegArgs += @(
            "-map", "0",
            "-map_metadata", "0",
            "-y",
            "`"$tempOutput`""
        )
        
        Write-Host "   🔄 Converting..." -ForegroundColor Cyan
        
        # Get total frames for progress
        $totalFrames = 0
        try {
            $totalFrames = [int](& $Global:FFprobeExe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 $InputFile)
        } catch {
            $totalFrames = 0
        }
        
        $progressFile = [System.IO.Path]::GetTempFileName()
        
        # Start FFmpeg process
        $process = Start-Process -FilePath $Global:FFmpegExe -ArgumentList $ffmpegArgs -PassThru -NoNewWindow -RedirectStandardError $progressFile
        
        # Monitor progress
        $lastProgress = 0
        $lastUpdate = Get-Date
        $stuckCounter = 0
        $maxStuckCount = 20
        
        while (-not $process.HasExited) {
            try {
                $now = Get-Date
                $progressData = Get-Content $progressFile -ErrorAction SilentlyContinue | Select-Object -Last 20
                
                $frameMatch = $progressData | Select-String "frame=\s*(\d+)"
                
                if ($frameMatch) {
                    $currentFrame = [int]($frameMatch.Matches[-1].Groups[1].Value)
                    $stuckCounter = 0
                    
                    if ($totalFrames -gt 0) {
                        $percent = [Math]::Min(100, [int](($currentFrame / $totalFrames) * 100))
                        if (($now - $lastUpdate).TotalSeconds -ge 2 -or ($percent - $lastProgress) -ge 5) {
                            $barLength = 30
                            $filled = [int]($percent / 100 * $barLength)
                            $bar = "#" * $filled + "-" * ($barLength - $filled)
                            Write-Host -NoNewline "`r[$bar] $percent% (Frame $currentFrame/$totalFrames)  "
                            $lastProgress = $percent
                            $lastUpdate = $now
                        }
                    }
                } else {
                    $stuckCounter++
                    if ($stuckCounter -ge $maxStuckCount) {
                        Write-Host "`n⚠️  No progress detected, terminating..." -ForegroundColor Yellow
                        $process.Kill()
                        break
                    }
                }
            } catch {
                # Continue
            }
            Start-Sleep -Milliseconds 500
        }
        
        Write-Host ""  # New line
        
        # Check exit code
        $exitCode = $process.ExitCode
        if ($exitCode -ne 0) {
            Write-Host "❌ FFmpeg failed with exit code $exitCode" -ForegroundColor Red
            
            # Show error details
            $ffmpegOutput = Get-Content $progressFile -ErrorAction SilentlyContinue | Out-String
            $errorLines = $ffmpegOutput -split "`n" | Where-Object { $_ -match "error|Error|failed|Failed|invalid|Invalid" } | Select-Object -Last 5
            if ($errorLines) {
                Write-Host "Error details:" -ForegroundColor Yellow
                $errorLines | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
            }
            
            if ($Encoder -ne "cpu") {
                Write-Host "⚠️  Hardware encoder '$Encoder' might not be available on this system" -ForegroundColor Yellow
                Write-Host "💡 Please set DownscaleEncoder=cpu in config.ini if this persists" -ForegroundColor Cyan
            }
            
            Remove-Item $tempOutput -ErrorAction SilentlyContinue
            Remove-Item $progressFile -ErrorAction SilentlyContinue
            return $false
        }

        # Verify output exists
        if (-not (Test-Path $tempOutput)) {
            Write-Host "❌ Output file not created" -ForegroundColor Red
            return $false
        }

        # Verify output codec
        $outputCodec = ""
        $elapsedTime = ((Get-Date) - $startTime).TotalSeconds
        try {
            $outputCodec = (& $Global:FFprobeExe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 $tempOutput)
        } catch {
            $outputCodec = "unknown"
        }

        if ($outputCodec -eq "hevc") {
            # Replace original file with converted version
            try {
                Remove-Item -LiteralPath $InputFile -Force -ErrorAction Stop
                Move-Item -Path $tempOutput -Destination $InputFile -Force -ErrorAction Stop

                # Optional fallback: if source needed width capping for TV safety, create H.264 final output
                if ($fallbackToH264Enabled -and $autoWidthCapped) {
                    if ($fallbackH264Mode -eq "replace") {
                        Show-Format "TV SAFE" "$InputFileDisplay" "HEVC output marked as risky; replacing with H.264 fallback" -NameColor "Yellow"
                        Convert-H265ToH264WithAAC -InputFile $InputFile -Preset $fallbackH264Preset -CRF $fallbackH264CRF -Encoder $fallbackH264Encoder -AspectRatio $AspectRatio -LogFile ""

                        $finalCodec = ""
                        try {
                            $finalCodec = (& $Global:FFprobeExe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 $InputFile 2>$null).Trim()
                        } catch {
                            $finalCodec = ""
                        }

                        if ($finalCodec -eq "h264") {
                            Write-Host "✅ Klaar: $InputFileDisplay replaced with TV-safe H.264 fallback [${elapsedTime}s + fallback]" -ForegroundColor Green
                            Remove-Item $progressFile -ErrorAction SilentlyContinue
                            return $true
                        }

                        Write-Host "⚠️  H.264 fallback enabled but final codec is '$finalCodec' (keeping current output)" -ForegroundColor Yellow
                    } elseif ($fallbackH264Mode -eq "separate") {
                        Show-Format "TV SAFE" "$InputFileDisplay" "HEVC output kept; creating separate H.264 fallback file" -NameColor "Yellow"

                        $inputDir = [System.IO.Path]::GetDirectoryName($InputFile)
                        $inputBase = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
                        $fallbackOutputPath = Join-Path $inputDir "$inputBase.tvsafe.h264.mkv"
                        $fallbackTempInput = Join-Path $env:TEMP ([System.IO.Path]::GetRandomFileName() + ".mkv")

                        try {
                            Copy-Item -LiteralPath $InputFile -Destination $fallbackTempInput -Force -ErrorAction Stop
                            Convert-H265ToH264WithAAC -InputFile $fallbackTempInput -Preset $fallbackH264Preset -CRF $fallbackH264CRF -Encoder $fallbackH264Encoder -AspectRatio $AspectRatio -LogFile ""

                            $fallbackCodec = ""
                            try {
                                $fallbackCodec = (& $Global:FFprobeExe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 $fallbackTempInput 2>$null).Trim()
                            } catch {
                                $fallbackCodec = ""
                            }

                            if ($fallbackCodec -eq "h264") {
                                Move-Item -LiteralPath $fallbackTempInput -Destination $fallbackOutputPath -Force -ErrorAction Stop
                                Write-Host "✅ Klaar: HEVC kept + H.264 fallback created: $([System.IO.Path]::GetFileName($fallbackOutputPath))" -ForegroundColor Green
                                Remove-Item $progressFile -ErrorAction SilentlyContinue
                                return $true
                            }

                            Write-Host "⚠️  Separate H.264 fallback failed (codec='$fallbackCodec'). HEVC output kept." -ForegroundColor Yellow
                        } catch {
                            Write-Host "⚠️  Separate H.264 fallback failed: $_. HEVC output kept." -ForegroundColor Yellow
                        } finally {
                            Remove-Item -LiteralPath $fallbackTempInput -ErrorAction SilentlyContinue
                        }
                    }
                } else {
                    Write-Host "✅ Klaar: $InputFileDisplay replaced with H.265 8-bit $Resolution [${elapsedTime}s]" -ForegroundColor Green
                }

                Remove-Item $progressFile -ErrorAction SilentlyContinue
                return $true
            } catch {
                Write-Host "❌ Kon bestand niet vervangen: $_" -ForegroundColor Red
                Remove-Item $tempOutput -ErrorAction SilentlyContinue
                Remove-Item $progressFile -ErrorAction SilentlyContinue
                return $false
            }
        } else {
            Write-Host "❌ Invalid output codec: $outputCodec (expected hevc)" -ForegroundColor Red
            Remove-Item $tempOutput -ErrorAction SilentlyContinue
            Remove-Item $progressFile -ErrorAction SilentlyContinue
            return $false
        }
    } catch {
        Write-Host "❌ Unexpected error during conversion: $_" -ForegroundColor Red
        Remove-Item $tempOutput -ErrorAction SilentlyContinue
        Remove-Item $progressFile -ErrorAction SilentlyContinue
        return $false
    }
}

function Convert-AllHighBitDepthInFolder {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FolderPath,

        [ValidateSet("1080p", "720p", "keep")]
        [string]$Resolution = "",

        [string]$Preset = "",

        [ValidateRange(18, 32)]
        [int]$CRF = 0,
        
        [ValidateSet("nvidia", "amd", "cpu")]
        [string]$Encoder = ""
    )

    # Use config values if parameters not provided
    if ([string]::IsNullOrWhiteSpace($Resolution)) { $Resolution = $Global:DownscaleResolution }
    if ([string]::IsNullOrWhiteSpace($Preset)) { $Preset = $Global:DownscalePreset }
    if ($CRF -le 0) { $CRF = $Global:DownscaleCRF }
    if ([string]::IsNullOrWhiteSpace($Encoder)) { $Encoder = $Global:DownscaleEncoder }

    if (-not (Test-Path $FolderPath)) {
        Write-Host "❌ Map niet gevonden: $FolderPath" -ForegroundColor Red
        return
    }

    # Use step-specific log file if available, otherwise create conversion-specific log
    if ($Global:CurrentStepLogFile) {
        $logFile = $Global:CurrentStepLogFile
    } else {
        $logFile = Join-Path $Global:LogDir "downscale_conversion_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
        
        # Add header to log
        Add-Content -Path $logFile -Value "==============================================="
        Add-Content -Path $logFile -Value "High Bit-Depth to H.265 8-bit Conversion Log - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        Add-Content -Path $logFile -Value "Resolution: $Resolution | Encoder: $Encoder | Preset: $Preset | CRF: $CRF"
        Add-Content -Path $logFile -Value "==============================================="
    }

    DrawBanner -Text "CONVERTING HIGH BIT-DEPTH TO H.265 8-BIT $Resolution (using $Encoder)"
    Show-Format "INFO" "Folder: $FolderPath - Resolution: $Resolution - Encoder: $Encoder" -NameColor "Cyan"

    $count = 0
    $successCount = 0
    $skippedCount = 0
    
    Get-ChildItem -Path $FolderPath -Recurse -Filter *.mkv | ForEach-Object {
        $file = $_.FullName

        # Check pixel format
        $pixFmt = ""
        try {
            $pixFmt = (& $Global:FFprobeExe -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=noprint_wrappers=1:nokey=1 $file | Select-Object -First 1).Trim()
        } catch {
            $pixFmt = ""
        }

        # Only process 10-bit or 12-bit files
        $isHighBitDepth = $pixFmt -match "(10|12)le$|p010|p012"
        
        if ($isHighBitDepth) {
            $count++
            $bitDepth = if ($pixFmt -match "12le|p012") { "12-bit" } else { "10-bit" }
            
            Show-Format "FOUND" $_.Name "[$count] Converting $bitDepth to H.265 8-bit $Resolution..." -NameColor "Yellow"
            
            # Convert-HighBitDepthToH265 returns $true if converted, $false if skipped
            $result = Convert-HighBitDepthToH265 -InputFile $file -LogFile $logFile
            
            if ($result -eq $true) {
                $successCount++
            } else {
                $skippedCount++
            }
        } else {
            Show-Format "SKIP" $_.Name "Already 8-bit (pixel format: $pixFmt)" -NameColor "DarkGray"
        }
    }
    
    # Summary (only add to log if not using step transcript)
    if (-not $Global:CurrentStepLogFile) {
        Add-Content -Path $logFile -Value ""
        Add-Content -Path $logFile -Value "Summary: $successCount converted, $skippedCount skipped (resolution threshold), $count total high bit-depth files"
        Add-Content -Path $logFile -Value "Log file: $logFile"
        Add-Content -Path $logFile -Value ""
    }
    
    if ($count -eq 0) {
        Show-Format "INFO" "Geen high bit-depth bestanden gevonden" -NameColor "Cyan"
    } elseif ($successCount -eq 0) {
        Show-Format "INFO" "Conversie voltooid" "$skippedCount skipped (below $($Global:DownscaleMinResolution)p threshold), 0 converted" -NameColor "Yellow"
    } else {
        Show-Format "INFO" "Conversie voltooid" "$successCount converted, $skippedCount skipped" -NameColor "Green"
    }

    $Global:LastConversionStats = @{
        Converted = $successCount
        Failed = 0
        FailedItems = @()
        Skipped = $skippedCount
        Mode = "high_bitdepth_to_h265_8bit"
    }
}

#*********************************************************************************************
#      Video Info Functions
#*********************************************************************************************

function Get-VideoInfo {
    param(
        [Parameter(Mandatory=$true)]
        [string]$FilePath
    )
    
    if (-not (Test-Path -LiteralPath $FilePath)) {
        Write-Host "❌ File not found: $FilePath" -ForegroundColor Red
        return $null
    }
    
    try {
        $codec = (& $Global:FFprobeExe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 $FilePath 2>$null).Trim()
        $pixFmt = (& $Global:FFprobeExe -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=noprint_wrappers=1:nokey=1 $FilePath 2>$null).Trim()
        $width = (& $Global:FFprobeExe -v error -select_streams v:0 -show_entries stream=width -of default=noprint_wrappers=1:nokey=1 $FilePath 2>$null).Trim()
        $height = (& $Global:FFprobeExe -v error -select_streams v:0 -show_entries stream=height -of default=noprint_wrappers=1:nokey=1 $FilePath 2>$null).Trim()
        $bitrate = (& $Global:FFprobeExe -v error -select_streams v:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 $FilePath 2>$null).Trim()
        $duration = (& $Global:FFprobeExe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $FilePath 2>$null).Trim()
        $fps = (& $Global:FFprobeExe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 $FilePath 2>$null).Trim()
        
        # Calculate bit depth
        $bitDepth = if ($pixFmt -match "10le|p010") { "10-bit" } 
                    elseif ($pixFmt -match "12le|p012") { "12-bit" } 
                    else { "8-bit" }
        
        # Format bitrate
        $bitrateFormatted = if ($bitrate -and $bitrate -ne "N/A") { 
            "$([Math]::Round([int]$bitrate/1000000, 1)) Mbps" 
        } else { 
            "N/A" 
        }
        
        # Format duration
        $durationFormatted = if ($duration -and $duration -ne "N/A") {
            $ts = [TimeSpan]::FromSeconds([double]$duration)
            "$($ts.Hours):$($ts.Minutes.ToString('00')):$($ts.Seconds.ToString('00'))"
        } else {
            "N/A"
        }
        
        # Format FPS
        $fpsFormatted = if ($fps -match "(\d+)/(\d+)") {
            "$([Math]::Round([double]$matches[1] / [double]$matches[2], 2)) fps"
        } else {
            $fps
        }
        
        return [PSCustomObject]@{
            FileName = Split-Path $FilePath -Leaf
            Codec = $codec
            Resolution = "${width}x${height}"
            BitDepth = $bitDepth
            PixelFormat = $pixFmt
            Bitrate = $bitrateFormatted
            Duration = $durationFormatted
            FPS = $fpsFormatted
            FullPath = $FilePath
        }
    } catch {
        Write-Host "❌ Error analyzing: $(Split-Path $FilePath -Leaf) - $_" -ForegroundColor Red
        return $null
    }
}

function Get-VideoInfoFolder {
    param(
        [string]$FolderPath = "",
        [string]$OutputFile = "",
        [switch]$Recurse
    )
    
    # GUI folder browser if no path provided
    if ([string]::IsNullOrWhiteSpace($FolderPath)) {
        Add-Type -AssemblyName System.Windows.Forms
        $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
        $folderBrowser.Description = "Select folder to analyze video files"
        $folderBrowser.RootFolder = [System.Environment+SpecialFolder]::MyComputer
        
        if ($folderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $FolderPath = $folderBrowser.SelectedPath
        } else {
            Write-Host "❌ Folder selection cancelled" -ForegroundColor Yellow
            return
        }
    }
    
    if (-not (Test-Path -LiteralPath $FolderPath)) {
        Write-Host "❌ Folder not found: $FolderPath" -ForegroundColor Red
        return
    }
    
    # Default output file
    if ([string]::IsNullOrWhiteSpace($OutputFile)) {
        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $OutputFile = Join-Path $FolderPath "VideoInfo_${timestamp}.txt"
    }
    
    Write-Host "🔍 Analyzing videos in: $FolderPath" -ForegroundColor Cyan
    Write-Host "📝 Output file: $OutputFile" -ForegroundColor Cyan
    Write-Host ""
    
    # Find all video files
    $videoExtensions = @("*.mkv", "*.mp4", "*.avi", "*.mov", "*.m4v", "*.wmv")
    $videos = @()
    
    foreach ($ext in $videoExtensions) {
        if ($Recurse) {
            $videos += Get-ChildItem -LiteralPath $FolderPath -Filter $ext -Recurse -File -ErrorAction SilentlyContinue
        } else {
            $videos += Get-ChildItem -LiteralPath $FolderPath -Filter $ext -File -ErrorAction SilentlyContinue
        }
    }
    
    if ($videos.Count -eq 0) {
        Write-Host "❌ No video files found in folder" -ForegroundColor Yellow
        return
    }
    
    Write-Host "Found $($videos.Count) video file(s)" -ForegroundColor Green
    Write-Host ""
    
    # Analyze each video
    $results = @()
    $index = 1
    
    foreach ($video in $videos) {
        Write-Host "[$index/$($videos.Count)] Analyzing: $($video.Name)" -ForegroundColor Gray
        $info = Get-VideoInfo -FilePath $video.FullName
        if ($info) {
            $results += $info
        }
        $index++
    }
    
    # Write to console
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "VIDEO ANALYSIS RESULTS" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    
    foreach ($result in $results) {
        Write-Host "File: $($result.FileName)" -ForegroundColor Yellow
        Write-Host "  Codec: $($result.Codec) | Resolution: $($result.Resolution) | Bit Depth: $($result.BitDepth)" -ForegroundColor Green
        Write-Host "  Pixel Format: $($result.PixelFormat) | Bitrate: $($result.Bitrate)" -ForegroundColor Gray
        Write-Host "  Duration: $($result.Duration) | FPS: $($result.FPS)" -ForegroundColor Gray
        Write-Host ""
    }
    
    # Write to file
    $output = @()
    $output += "═══════════════════════════════════════════════════════════════════════"
    $output += "VIDEO ANALYSIS REPORT"
    $output += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $output += "Folder: $FolderPath"
    $output += "Total Files: $($results.Count)"
    $output += "═══════════════════════════════════════════════════════════════════════"
    $output += ""
    
    foreach ($result in $results) {
        $output += "File: $($result.FileName)"
        $output += "  Codec: $($result.Codec)"
        $output += "  Resolution: $($result.Resolution)"
        $output += "  Bit Depth: $($result.BitDepth)"
        $output += "  Pixel Format: $($result.PixelFormat)"
        $output += "  Bitrate: $($result.Bitrate)"
        $output += "  Duration: $($result.Duration)"
        $output += "  FPS: $($result.FPS)"
        $output += "  Path: $($result.FullPath)"
        $output += ""
    }
    
    $output += "═══════════════════════════════════════════════════════════════════════"
    $output += "SUMMARY"
    $output += "═══════════════════════════════════════════════════════════════════════"
    
    # Summary statistics
    $codecCount = $results | Group-Object Codec | Select-Object Name, Count
    $bitDepthCount = $results | Group-Object BitDepth | Select-Object Name, Count
    
    $output += ""
    $output += "Codecs:"
    foreach ($item in $codecCount) {
        $output += "  $($item.Name): $($item.Count) file(s)"
    }
    
    $output += ""
    $output += "Bit Depths:"
    foreach ($item in $bitDepthCount) {
        $output += "  $($item.Name): $($item.Count) file(s)"
    }
    
    # Write to file
    Set-Content -Path $OutputFile -Value $output -Encoding UTF8
    
    Write-Host "✅ Report saved to: $OutputFile" -ForegroundColor Green
    Write-Host ""
    
    # Return results for further processing
    return $results
}


