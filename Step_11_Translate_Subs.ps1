# ─── Bescherm tegen herhaald laden ─────────────────────────────────────
if ($Global:TranslateSubsLoaded) { return }
$Global:TranslateSubsLoaded = $true

# ─── Module: TranslateSubs.ps1 ───────────────────────────────────────
# Doel: Vertaal ondertitels via Argos Translate wanneer geen doeltaal-sub gevonden is.
#       Resultaat: een .translated.srt bestand dat door Step_08 (sync) opgepikt wordt.
#
# TranslateMode (config.ini [Lang]):
#   fallback = alleen vertalen als GEEN sub in doeltaal gevonden (standaard)
#   force    = altijd vertalen vanuit LangFallback, ook als er al een sub is
#   off      = vertaling volledig uitschakelen

# ─── Ollama-beheer functies ───────────────────────────────────────────
function Test-OllamaRunning {
    try {
        $response = Invoke-WebRequest -Uri "http://127.0.0.1:11434/api/tags" `
                                      -Method Get `
                                      -TimeoutSec 2 `
                                      -ErrorAction SilentlyContinue
        return $response.StatusCode -eq 200
    } catch {
        return $false
    }
}

function Start-OllamaService {
    if (Test-OllamaRunning) {
        Show-Format "INFO" "Ollama" "Service al actief" -NameColor "Yellow"
        return $false  # retourneer $false = we hebben het niet gestart
    }

    Show-Format "INFO" "Ollama" "Service starten..." -NameColor "Yellow"
    try {
        # Probeer Ollama te starten via command line
        $ollamaExe = "ollama"
        if (Get-Command $ollamaExe -ErrorAction SilentlyContinue) {
            Start-Process -FilePath $ollamaExe -ArgumentList "serve" -WindowStyle Hidden -NoNewWindow
            Start-Sleep -Seconds 3
            if (Test-OllamaRunning) {
                Show-Format "INFO" "Ollama" "Service succesvol gestart" -NameColor "Green"
                return $true  # retourneer $true = we hebben het gestart
            }
        }

        # Als commando niet werkt, probeer direct het exe-pad
        $possiblePaths = @(
            "C:\Users\$env:USERNAME\AppData\Local\Programs\Ollama\ollama.exe",
            "C:\Program Files\Ollama\ollama.exe",
            "C:\Program Files (x86)\Ollama\ollama.exe"
        )
        foreach ($path in $possiblePaths) {
            if (Test-Path $path) {
                Start-Process -FilePath $path -ArgumentList "serve" -WindowStyle Hidden -NoNewWindow
                Start-Sleep -Seconds 3
                if (Test-OllamaRunning) {
                    Show-Format "INFO" "Ollama" "Service succesvol gestart" -NameColor "Green"
                    return $true  # retourneer $true = we hebben het gestart
                }
                break
            }
        }
        
        Show-Format "WARN" "Ollama" "Kon Ollama niet starten, toch proberen..." -NameColor "Yellow"
        return $false
    } catch {
        Show-Format "WARN" "Ollama" "Fout bij starten: $_" -NameColor "Yellow"
        return $false
    }
}

function Stop-OllamaService {
    if (-not (Test-OllamaRunning)) {
        return
    }

    Show-Format "INFO" "Ollama" "Service stoppen..." -NameColor "Yellow"
    try {
        Get-Process -Name "ollama" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        if (-not (Test-OllamaRunning)) {
            Show-Format "INFO" "Ollama" "Service gestopt" -NameColor "Green"
        } else {
            Show-Format "WARN" "Ollama" "Service loopt nog" -NameColor "Yellow"
        }
    } catch {
        Show-Format "WARN" "Ollama" "Fout bij stoppen: $_" -NameColor "Yellow"
    }
}

function Start-TranslateSubs {
    Start-StepLog -StepNumber "11" -StepName "Translate_Subs"
    Invoke-TranslateSubs
    Stop-StepLog
}

function Invoke-TranslateSubs {
    DrawBanner -Text "STEP 11 TRANSLATE SUBTITLES"

    # --- Controleer TranslateMode
    $translateMode = if ($Global:TranslateMode) { $Global:TranslateMode.ToLower() } else { "fallback" }

    $translateModeDisplay = $translateMode.ToUpper()
    $translateInfo = switch ($translateModeDisplay) {
        "FALLBACK" { "alleen vertalen indien geen sub gevonden" }
        "FORCE"    { "altijd vertalen vanuit LangFallback" }
        "OFF"      { "vertaling uitgeschakeld" }
        default    { $translateModeDisplay }
    }
    Show-Format "CONFIG" "TranslateMode=$translateModeDisplay" $translateInfo -NameColor "Cyan"

    if ($translateMode -eq "off") {
        Show-Format "SKIP" "TranslateMode=off" "Stap overgeslagen" -NameColor "DarkGray"
        Set-StepRunResult -Step "11" -Success 0 -Failed 0 -FailedItems @() -Note "step skipped (TranslateMode=off)"
        return
    }

    # --- Controleer vereisten
    if (-not $Global:LangFallback) {
        Show-Format "SKIP" "LangFallback niet ingesteld" "Stel LangFallback in config.ini [Lang] in om te vertalen" -NameColor "Yellow"
        Set-StepRunResult -Step "11" -Success 0 -Failed 0 -FailedItems @() -Note "LangFallback missing"
        return
    }

    if (-not $Global:TranslatorExe -or -not (Test-Path $Global:TranslatorExe)) {
        Show-Format "ERROR" "TranslatorExe niet gevonden" "$($Global:TranslatorExe)" -NameColor "Red"
        Show-Format "INFO"  "Stel TranslatorExe in config.ini [Executables] in" "" -NameColor "Yellow"
        Set-StepRunResult -Step "11" -Success 0 -Failed 1 -FailedItems @("TranslatorExe missing") -Note "configuration error"
        return
    }

    $targetLang    = if ($Global:Lang) { $Global:Lang } else { ($Global:LangKeep -split ',')[0].Trim() }
    $fallbackLangs = @(($Global:LangFallback -split ',') | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })

    Show-Format "INFO" "Doeltaal: $targetLang" "Brontaal: $($fallbackLangs -join ', ')" -NameColor "Cyan"

    # --- Controleer of Ollama nodig is en start het op als nodig
    $translatorBackend = if ($Global:TranslatorBackend) { $Global:TranslatorBackend.ToLower() } else { 'argos' }
    $ollamaWasStartedByScript = $false

    if ($translatorBackend -eq 'ollama') {
        $ollamaWasStartedByScript = Start-OllamaService
    }

    # --- Loop over alle video's in TempDir
    $allVideos = @(Get-ChildItem -LiteralPath $Global:TempDir -Recurse -Filter "*.mkv" -File -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -notlike "*.h264.mkv" })
    $allVideos += @(Get-ChildItem -LiteralPath $Global:TempDir -Recurse -Filter "*.mp4" -File -ErrorAction SilentlyContinue)

    $translatedCount = 0
    $skippedCount    = 0
    $failedCount     = 0
    $failedItems     = @()

    foreach ($video in $allVideos) {
        $videoName  = $video.BaseName
        $videoDir   = $video.DirectoryName

        # Prefixbeleid:
        # 1) SxxEyy aanwezig => serie (episode-specifiek)
        # 2) Anders jaar aanwezig => film
        # 3) Anders volledige bestandsnaam
        $titlePrefix = if ($videoName -match '(?i)^(.+?[\.\s_-]S\d{2}E\d{2})(?:[\.\s_-]|$)') {
            $matches[1]
        } elseif ($videoName -match '^(.+?[\.\s_-]\d{4})(?:[\.\s_-]|$)') {
            $matches[1]
        } else {
            $videoName
        }

        # Zoek bestaande subs in doeltaal (exclusief al gesyncde en al vertaalde)
        $existingTargetSubs = @(Get-ChildItem -LiteralPath $videoDir -File -Filter "*.srt" -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -like "$titlePrefix*.srt" -and
            $_.Name -notmatch '\.synced\.' -and
            $_.Name -notmatch '\.translated\.srt$' -and
            (Get-SubtitleLanguage $_.Name) -eq $targetLang
        })

        # Beslissing: vertalen of overslaan?
        if ($translateMode -eq "fallback" -and $existingTargetSubs.Count -gt 0) {
            Show-Format "SKIP" "$videoName" "Sub in $targetLang reeds aanwezig ($($existingTargetSubs[0].Name))" -NameColor "DarkGray"
            $skippedCount++
            continue
        }

        # Zoek brontaal subs om van te vertalen (probeer elke fallbacktaal in volgorde)
        $fallbackSubs = $null
        $fallbackLang = $null
        foreach ($fl in $fallbackLangs) {
            $candidates = @(Get-ChildItem -LiteralPath $videoDir -File -Filter "*.srt" -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -like "$titlePrefix*.srt" -and
                $_.Name -notmatch '\.synced\.' -and
                $_.Name -notmatch '\.translated\.srt$' -and
                (Get-SubtitleLanguage $_.Name) -eq $fl
            })
            if ($candidates.Count -gt 0) {
                $fallbackSubs = $candidates
                $fallbackLang = $fl
                break
            }
        }

        if (-not $fallbackSubs -or $fallbackSubs.Count -eq 0) {
            Show-Format "SKIP" "$videoName" "Geen sub gevonden in ($($fallbackLangs -join '/')) om van te vertalen" -NameColor "Yellow"
            $skippedCount++
            continue
        }

        # Gebruik de gesyncde bron-sub indien beschikbaar (timestamps al gecorrigeerd)
        $syncedFallback = @($fallbackSubs | Where-Object { $_.Name -match '\.ffsubsync\.synced\.srt$' -or $_.Name -match '\.alass\.synced\.srt$' })
        $fbSub = if ($syncedFallback.Count -gt 0) {
            Show-Format "INFO" "Gesyncde bronversie gevonden" "$($syncedFallback[0].Name)" -NameColor "DarkCyan"
            $syncedFallback[0]
        } else {
            $fallbackSubs[0]
        }
        $translatedName = "$([System.IO.Path]::GetFileNameWithoutExtension($fbSub.Name)).$targetLang.translated.srt"
        $translatedPath = Join-Path $videoDir $translatedName

        # Sla over als vertaald bestand al bestaat
        if (Test-Path -LiteralPath $translatedPath) {
            Show-Format "SKIP" "$translatedName" "Vertaling al aanwezig" -NameColor "DarkGray"
            $skippedCount++
            continue
        }

        $translatorOllamaModel = if ($Global:TranslatorOllamaModel) { $Global:TranslatorOllamaModel } else { 'mistral' }
        $backendLabel = if ($translatorBackend -eq 'ollama') { 'Ollama' } elseif ($translatorBackend -eq 'argos') { 'Argos' } else { 'Auto (Argos eerst)' }
        Show-Format "TRANSLATE" "$($fbSub.Name)" "$fallbackLang -> $targetLang [$backendLabel]" -NameColor "Cyan"

        # Zorg dat de generieke stream-reader geladen is (gedeeld met Step_06_STT)
        if (-not ([System.Management.Automation.PSTypeName]'WhisperOutputReader').Type) {
            Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.IO;
using System.Threading;
public class WhisperOutputReader {
    public readonly ConcurrentQueue<string> Lines = new ConcurrentQueue<string>();
    private readonly StreamReader _reader;
    public WhisperOutputReader(StreamReader reader) { _reader = reader; }
    public void StartReading() {
        Thread t = new Thread(ReadLoop);
        t.IsBackground = true;
        t.Start();
    }
    private void ReadLoop() {
        string line;
        while ((line = _reader.ReadLine()) != null) {
            Lines.Enqueue(line);
        }
    }
}
'@
        }

        $translatorArgs = "--input `"$($fbSub.FullName)`" --output `"$translatedPath`" --from $fallbackLang --to $targetLang --backend $translatorBackend --ollama-model $translatorOllamaModel --ollama-base-url http://127.0.0.1:11434"
        if ($Global:TranslatorScript) {
            $scriptPrefix = "`"$($Global:TranslatorScript)`""
            if ($Global:TranslatorPackagesDir) { $scriptPrefix += " --packages-dir `"$($Global:TranslatorPackagesDir)`"" }
            $translatorArgs = "$scriptPrefix $translatorArgs"
        }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $Global:TranslatorExe
        $psi.Arguments              = $translatorArgs
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true

        $proc           = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $null           = $proc.Start()

        $stdoutReader = New-Object WhisperOutputReader($proc.StandardOutput)
        $stderrReader = New-Object WhisperOutputReader($proc.StandardError)
        $stdoutReader.StartReading()
        $stderrReader.StartReading()

        $allLines = [System.Collections.Generic.List[string]]::new()
        $lastPct  = -1

        while (-not $proc.HasExited) {
            foreach ($readerObj in @($stdoutReader, $stderrReader)) {
                $line = $null
                while ($readerObj.Lines.TryDequeue([ref]$line)) {
                    $allLines.Add($line)
                    $pct = -1
                    if ($line -match '(\d{1,3})%') { $pct = [int]$Matches[1] }

                    if ($pct -ge 0 -and $pct -ne $lastPct) {
                        $lastPct = $pct
                        Write-Progress -Activity "Translate subtitles" `
                                       -Status "$($fbSub.Name)  ($pct%)" `
                                       -PercentComplete $pct -ErrorAction SilentlyContinue
                    }
                }
            }
            Start-Sleep -Milliseconds 150
        }

        $proc.WaitForExit()
        foreach ($readerObj in @($stdoutReader, $stderrReader)) {
            $line = $null
            while ($readerObj.Lines.TryDequeue([ref]$line)) { $allLines.Add($line) }
        }
        Write-Progress -Activity "Translate subtitles" -Completed -ErrorAction SilentlyContinue
        Write-Host ""  # Nieuwe regel na voortgangsbalk
        $stderr = $allLines -join "`n"

        if ($proc.ExitCode -eq 0 -and (Test-Path -LiteralPath $translatedPath)) {
            Repair-SrtTimestamps -FilePath $translatedPath | Out-Null
            Show-Format "TRANSLATE" "$translatedName" "Geslaagd (geen extra sync nodig)" -NameColor "Green"
            # Schrijf metadata zodat Step_09 deze sub embedt
            Update-SubtitleMetadata -VideoBaseName $videoName -SyncedSubtitlePath $translatedPath -OriginalSubtitleName $translatedName
            $translatedCount++
        } else {
            Show-Format "TRANSLATE" "$($fbSub.Name)" "Mislukt: $stderr" -NameColor "Red"
            $failedCount++
            $failedItems += $fbSub.Name
        }
    }

    # --- Stop Ollama als we het hebben gestart
    if ($ollamaWasStartedByScript) {
        Stop-OllamaService
    }

    Show-Format "SUMMARY" "Vertaling voltooid" "Vertaald: $translatedCount | Overgeslagen: $skippedCount" -NameColor "Cyan"
    Set-StepRunResult -Step "11" -Success $translatedCount -Failed $failedCount -FailedItems $failedItems -Note "skipped=$skippedCount"
}
