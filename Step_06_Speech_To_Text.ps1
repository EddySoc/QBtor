# ─── Bescherm tegen herhaald laden ─────────────────────────────────────
if ($Global:STTLoaded) { return }
$Global:STTLoaded = $true

# ─── Module: STT.ps1 ─────────────────────────────────────────────────
# Doel: Genereer een ondertitel via Speech-to-Text (Whisper) voor video's
#       die na stap 05 (download) nog steeds geen ondertitel hebben.
#       De gegenereerde .srt wordt door stap 10 (Sync) en stap 11 (Translate)
#       verder verwerkt.
#
# Config [STT]:
#   STTEnabled   = true/false            → stap in-/uitschakelen
#   STTExe       = pad naar whisper.exe  → bijv. C:\Video\whisper\whisper.exe
#   STTModel     = tiny/base/small/medium/large  → kwaliteit vs. snelheid
#   STTLanguage  = auto of taalcode (eng/nl/...)  → audiotaal of auto-detectie
#   STTOutputLang= taalcode van de output-SRT (leeg = zelfde als audiotaal)

function Start-STT {
    Start-StepLog -StepNumber "06" -StepName "STT"
    Invoke-STT
    Stop-StepLog
}

function Stop-ProcessTreeSafe {
    param([Parameter(Mandatory=$true)][int]$ProcessId)

    try {
        $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $ProcessId" -ErrorAction SilentlyContinue)
        foreach ($child in $children) {
            Stop-ProcessTreeSafe -ProcessId ([int]$child.ProcessId)
        }

        $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if ($proc) {
            try {
                if (-not $proc.HasExited) {
                    $proc.Kill($true)
                }
            } catch {
                Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Stop-LingeringSTTProcesses {
    param(
        [string]$WhisperExe,
        [int[]]$KeepPids = @()
    )

    if (-not $WhisperExe) { return }

    $processName = [System.IO.Path]::GetFileNameWithoutExtension($WhisperExe)
    $exeFullPath = try { [System.IO.Path]::GetFullPath($WhisperExe) } catch { $WhisperExe }
    $running = @(Get-Process -Name $processName -ErrorAction SilentlyContinue)

    foreach ($p in $running) {
        if ($KeepPids -contains $p.Id) { continue }

        $sameExe = $true
        try {
            $sameExe = ([System.IO.Path]::GetFullPath($p.MainModule.FileName) -eq $exeFullPath)
        } catch {
            $sameExe = ($p.ProcessName -ieq $processName)
        }

        if (-not $sameExe) { continue }

        try {
            Stop-ProcessTreeSafe -ProcessId $p.Id
            Show-Format "CLEANUP" "$($p.ProcessName) PID=$($p.Id)" "Achterblijvend Whisper-proces afgesloten" -NameColor "Yellow"
        } catch {
            Show-Format "WARNING" "Kon STT-proces niet afsluiten" "$($p.ProcessName) PID=$($p.Id)" -NameColor "Yellow"
        }
    }
}

function Invoke-STTLanguageDetect {
    # Detecteert de primaire audiotaal door een 60s clip uit het MIDDEN van de video
    # te transcriberen. Zo beïnvloedt een cold open in een andere taal (bv. Russisch)
    # de taaldetectie niet — Whisper ziet dat de meeste audio de hoofdtaal is.
    param([string]$VideoPath, [string]$WhisperExe, [string]$Model, [string]$ModelDir)

    $ffprobeExe = $Global:FFprobeExe
    $ffmpegExe  = $Global:FFmpegExe
    if (-not $ffprobeExe -or -not (Test-Path $ffprobeExe)) { return $null }
    if (-not $ffmpegExe  -or -not (Test-Path $ffmpegExe))  { return $null }

    # ── Videoduur ophalen via ffprobe ──────────────────────────────────
    $durRaw = & $ffprobeExe -v quiet -show_entries format=duration `
                            -of default=noprint_wrappers=1:nokey=1 $VideoPath 2>&1 |
              Where-Object { $_ -match '^\d' } | Select-Object -First 1
    $duration = $durRaw -as [double]
    if (-not $duration -or $duration -lt 120) { return $null }

    # ── 60s clip extraheren vanaf 1/3 van de video ────────────────────
    $sampleStart = [int][math]::Max(120, $duration / 3)
    $tempClip = [System.IO.Path]::Combine(
        [System.IO.Path]::GetTempPath(),
        [System.IO.Path]::GetRandomFileName() + ".mkv"
    )

    & $ffmpegExe -y -ss $sampleStart -i $VideoPath -t 60 -vn -c:a copy $tempClip 2>&1 | Out-Null
    if (-not (Test-Path $tempClip) -or (Get-Item $tempClip -ErrorAction SilentlyContinue).Length -lt 1000) {
        Remove-Item $tempClip -Force -ErrorAction SilentlyContinue
        return $null
    }

    try {
        $tempOutDir = [System.IO.Path]::GetTempPath()
        $wArgs = @($tempClip, "--model", $Model, "--output_format", "txt",
                   "--output_dir", $tempOutDir, "--language_detection_segments", "1")
        if ($ModelDir) { $wArgs += "--model_dir", $ModelDir }

        $wOut = & $WhisperExe @wArgs 2>&1
        $langLine = $wOut | Where-Object { $_ -match "Detected language" } | Select-Object -First 1
        if ($langLine -match "Detected language[^']*'?(\w+)") {
            return $Matches[1].ToLower()  # bijv. "english", "dutch"
        }
    } finally {
        Remove-Item $tempClip -Force -ErrorAction SilentlyContinue
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($tempClip)
        Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter "$baseName*" -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    return $null
}

function Invoke-STT {
    DrawBanner -Text "STEP 06 SPEECH-TO-TEXT (WHISPER)"

    # --- Config lezen
    $sttEnabled = -not ($Global:STTEnabled -eq $false -or "$($Global:STTEnabled)".ToLower() -eq 'false')

    if (-not $sttEnabled) {
        Show-Format "SKIP" "STTEnabled=false" "STT-stap overgeslagen via config" -NameColor "DarkGray"
        Set-StepRunResult -Step "06" -Success 0 -Failed 0 -FailedItems @() -Note "step skipped (STTEnabled=false)"
        return
    }

    $whisperExe = $Global:STTExe
    if (-not $whisperExe -or -not (Test-Path $whisperExe)) {
        Show-Format "ERROR" "STTExe niet gevonden" "$whisperExe" -NameColor "Red"
        Show-Format "INFO"  "Stel STTExe in config.ini [STT] in" "" -NameColor "Yellow"
        Set-StepRunResult -Step "06" -Success 0 -Failed 1 -FailedItems @("STTExe missing") -Note "configuration error"
        return
    }

    $whisperProcessName = [System.IO.Path]::GetFileNameWithoutExtension($whisperExe)
    if (-not $Global:InitialSTTPids) {
        $Global:InitialSTTPids = @(Get-Process -Name $whisperProcessName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    }
    $baselineWhisperPids = @($Global:InitialSTTPids)

    $model       = if ($Global:STTModel)      { $Global:STTModel }      else { "medium" }
    $audioLang   = if ($Global:STTLanguage)   { $Global:STTLanguage }   else { "auto" }
    $outputLang  = if ($Global:STTOutputLang) { $Global:STTOutputLang } else { "" }
    $detectionSegs = if ($Global:STTDetectionSegments) { [int]"$($Global:STTDetectionSegments)" } else { 5 }
    $maxCueLines = if ($Global:STTMaxLinesPerCue) { [int]"$($Global:STTMaxLinesPerCue)" } else { 2 }
    $maxCharsPerLine = if ($Global:STTMaxCharsPerLine) { [int]"$($Global:STTMaxCharsPerLine)" } else { 42 }

    if ($maxCueLines -lt 1) { $maxCueLines = 2 }
    if ($maxCharsPerLine -lt 8) { $maxCharsPerLine = 42 }

    $multilingualSetting = if ($Global:STTMultilingual) { "$($Global:STTMultilingual)".ToLower().Trim() } else { 'auto' }
    $multilingualInfo = if ($multilingualSetting -eq 'false') { '' } else { ' | Multilingual=on' }

    Show-Format "CONFIG" "Model=$model" "AudioLang=$audioLang$(if ($outputLang) { ' | OutputLang=' + $outputLang }) | MaxCueLines=$maxCueLines | MaxCharsPerLine=$maxCharsPerLine$multilingualInfo" -NameColor "Cyan"

    # --- Normaliseer taalcodes naar 2-letter ISO (Whisper gebruikt 2-letter)
    $langMap = @{
        'dut'='nl'; 'nld'='nl'; 'eng'='en'; 'fra'='fr'; 'fre'='fr';
        'deu'='de'; 'ger'='de'; 'spa'='es'; 'por'='pt'; 'ita'='it';
        'pol'='pl'; 'swe'='sv'; 'nor'='no'; 'dan'='da'; 'fin'='fi';
        'rus'='ru'; 'jpn'='ja'; 'kor'='ko'; 'chi'='zh'; 'ara'='ar'
    }
    $whisperAudioLang  = if ($audioLang -ne 'auto' -and $langMap.ContainsKey($audioLang))  { $langMap[$audioLang]  } else { $audioLang }
    $whisperOutputLang = if ($outputLang -and $langMap.ContainsKey($outputLang)) { $langMap[$outputLang] } elseif ($outputLang) { $outputLang } else { $null }

    # Bepaal taalcode voor sub-bestandsnaam (3-letter of teruggeven wat ingesteld is)
    $subLangTag = if ($outputLang) { $outputLang } elseif ($audioLang -ne 'auto') { $audioLang } else { "unk" }

    # --- Loop over video's
    $allVideos = @(Get-ChildItem -LiteralPath $Global:TempDir -Recurse -Filter "*.mkv" -File -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -notlike "*.h264.mkv" })
    $allVideos += @(Get-ChildItem -LiteralPath $Global:TempDir -Recurse -Filter "*.mp4" -File -ErrorAction SilentlyContinue)

    $generatedCount = 0
    $skippedCount   = 0
    $failedCount    = 0
    $failedItems    = @()

    foreach ($video in $allVideos) {
        $videoName = $video.BaseName
        $videoDir  = $video.DirectoryName

        # Controleer of er al een sub bestaat voor exact dit videobestand (elke taal).
        # Gebruik geen serie-brede prefix, anders kan E02 ten onrechte E01 matchen.
        $existingSubs = @(Get-ChildItem -LiteralPath $videoDir -File -Filter "*.srt" -ErrorAction SilentlyContinue |
                          Where-Object { $_.BaseName -match "^$([regex]::Escape($videoName))(\.|$)" })

        if ($existingSubs.Count -gt 0) {
            $taggedName  = "$videoName.$subLangTag.srt"
            # Hernoem ongetagde sub (geen taalcode in naam) naar correct taalgelabelde versie
            $untaggedSub = $existingSubs | Where-Object { $_.Name -eq "$videoName.srt" }
            if ($untaggedSub -and -not ($existingSubs | Where-Object { $_.Name -eq $taggedName })) {
                Rename-Item -LiteralPath $untaggedSub.FullName -NewName $taggedName -Force -ErrorAction SilentlyContinue
                Show-Format "SKIP" "$videoName" "Ongetagde sub hernoemd naar $taggedName, STT overgeslagen" -NameColor "Yellow"
            } else {
                Show-Format "SKIP" "$videoName" "Sub reeds aanwezig: $($existingSubs[0].Name)" -NameColor "DarkGray"
            }
            $skippedCount++
            continue
        }

        # Geen sub → STT uitvoeren
        Show-Format "STT" "$videoName" "Whisper transcriptie starten (model: $model)" -NameColor "Cyan"

        # Whisper schrijft: <basename>.srt in de output_dir
        # We geven --output_dir = videoDir zodat het bestand naast de video terechtkomt
        $whisperArgs = @(
            "`"$($video.FullName)`"",
            "--model", $model,
            "--output_format", "srt",
            "--output_dir", "`"$videoDir`""
        )

        $modelDir = if ($Global:STTModelDir) { $Global:STTModelDir.Trim() } else { '' }
        if ($modelDir -ne '') {
            $whisperArgs += @("--model_dir", "`"$modelDir`"")
        }

        if ($whisperAudioLang -and $whisperAudioLang -ne 'auto') {
            $whisperArgs += @("--language", $whisperAudioLang)
        } elseif ($detectionSegs -gt 1) {
            # Bij auto-detectie: sample meerdere segmenten zodat een korte intro in een
            # andere taal (bv. Russisch) niet de hele transcriptie beïnvloedt.
            $whisperArgs += @("--language_detection_segments", $detectionSegs)
        }

        # ── Taaldetectie ──────────────────────────────────────────────────────
        # STTMultilingual=auto/true (standaard): sample 60s uit het MIDDEN van de video
        # via een snelle Whisper-run zodat een cold open in een andere taal (bv. Russisch)
        # de transcriptie niet breekt. De --multilingual vlag werkt niet omdat Whisper de
        # begintaal als context aanhoudt; het midden sampelen omzeilt dit volledig.
        # STTMultilingual=false: gebruik klassieke language_detection_segments (begin).
        $effectiveAudioLang = $whisperAudioLang

        if ($whisperAudioLang -eq 'auto' -or -not $whisperAudioLang) {
            $whisperArgs += @("--language_detection_segments", $detectionSegs)
        } else {
            $whisperArgs += @("--language", $whisperAudioLang)
        }

        # Optionele vertaling door Whisper zelf (task=translate → output in Engels)
        # Bij auto-detectie: altijd --task translate meegeven als STTOutputLang=eng,
        # zodat Whisper de gedetecteerde taal naar Engels vertaalt (ook bij Spaans, Frans, etc.).
        if ($whisperOutputLang -and ($effectiveAudioLang -eq 'auto' -or ($effectiveAudioLang -and $whisperOutputLang -ne $effectiveAudioLang))) {
            $whisperArgs += @("--task", "translate")
        }

        # ── Pure C# achtergrond-threads lezen stdout én stderr ──
        # Faster-Whisper-XXL schrijft progress soms naar stdout, soms naar stderr.
        # Door beide streams te lezen via een generieke StreamReader-klasse missen
        # we nooit output. Geen PS scriptblocks op achtergrondthreads → geen Runspace crash.
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

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $whisperExe
        $psi.Arguments              = $whisperArgs -join ' '
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true

        $proc = $null
        try {
            $proc           = New-Object System.Diagnostics.Process
            $proc.StartInfo = $psi
            $null           = $proc.Start()

            if (-not $Global:TrackedSTTPids) { $Global:TrackedSTTPids = @() }
            $Global:TrackedSTTPids = @($Global:TrackedSTTPids + $proc.Id | Select-Object -Unique)

            # Lees stdout EN stderr in aparte achtergrondthreads
            $stdoutReader = New-Object WhisperOutputReader($proc.StandardOutput)
            $stderrReader = New-Object WhisperOutputReader($proc.StandardError)
            $stdoutReader.StartReading()
            $stderrReader.StartReading()

            # Polling loop op de hoofd-thread — Write-Progress mag hier wel
            $allLines = [System.Collections.Generic.List[string]]::new()
            $lastPct  = -1

            while (-not $proc.HasExited) {
                foreach ($readerObj in @($stdoutReader, $stderrReader)) {
                    $line = $null
                    while ($readerObj.Lines.TryDequeue([ref]$line)) {
                        $allLines.Add($line)

                        # Faster-Whisper-XXL / Whisper progress: "Transcribing: 42%|..."
                        $pct = -1
                        if ($line -match '(\d{1,3})%') { $pct = [int]$Matches[1] }

                        if ($pct -ge 0 -and $pct -ne $lastPct) {
                            $lastPct = $pct
                            $bar     = '#' * [int]($pct / 5)
                            $empty   = '-' * (20 - [int]($pct / 5))
                            Write-Progress -Activity "Whisper STT" `
                                           -Status "$videoName  ($pct%)" `
                                           -PercentComplete $pct
                            Write-Host "`r  [STT] [$bar$empty] $pct%  " -NoNewline -ForegroundColor Cyan
                        } elseif ($line.Trim() -ne '') {
                            # Toon alle andere niet-lege regels (model laden, taaldetectie, etc.)
                            Write-Host "  [STT] $($line.Trim())" -ForegroundColor DarkCyan
                        }
                    }
                }
                Start-Sleep -Milliseconds 150
            }

            $proc.WaitForExit()

            # Drain resterende regels na exit
            foreach ($readerObj in @($stdoutReader, $stderrReader)) {
                $line = $null
                while ($readerObj.Lines.TryDequeue([ref]$line)) { $allLines.Add($line) }
            }

            # Sluit voortgangsindicator af
            Write-Progress -Activity "Whisper STT" -Completed
            Write-Host ""  # newline na inline voortgangsregel
            $stderr = $allLines -join "`n"

            # Whisper genereert: <videobasename>.srt (zonder taaltag)
            $whisperOut = Join-Path $videoDir "$videoName.srt"
            $taggedName = "$videoName.$subLangTag.srt"
            $taggedPath = Join-Path $videoDir $taggedName

            # Corrigeer tijdcodes in Whisper output vóór hernoemen
            if (Test-Path -LiteralPath $whisperOut) {
                Normalize-WhisperSubtitleFile -FilePath $whisperOut | Out-Null
                Repair-SrtTimestamps -FilePath $whisperOut | Out-Null
                Limit-SrtCueLines -FilePath $whisperOut -MaxLines $maxCueLines -MaxCharsPerLine $maxCharsPerLine | Out-Null
            } elseif (Test-Path -LiteralPath $taggedPath) {
                Normalize-WhisperSubtitleFile -FilePath $taggedPath | Out-Null
                Repair-SrtTimestamps -FilePath $taggedPath | Out-Null
                Limit-SrtCueLines -FilePath $taggedPath -MaxLines $maxCueLines -MaxCharsPerLine $maxCharsPerLine | Out-Null
            }

            if (Test-Path -LiteralPath $whisperOut) {
                # Hernoem naar videoname.{lang}.srt zodat de taaldetectie werkt
                # Controleer exitcode NIET: Faster-Whisper-XXL geeft soms non-zero terug ondanks succes
                Rename-Item -LiteralPath $whisperOut -NewName $taggedName -Force -ErrorAction SilentlyContinue
                if ($proc.ExitCode -ne 0) {
                    Show-Format "STT" "$taggedName" "Geslaagd (exitcode $($proc.ExitCode), bestand aanwezig)" -NameColor "Yellow"
                } else {
                    Show-Format "STT" "$taggedName" "Geslaagd" -NameColor "Green"
                }
                $generatedCount++
            } elseif (Test-Path -LiteralPath $taggedPath) {
                # Whisper heeft soms al een taalextensie toegevoegd
                Show-Format "STT" "$taggedName" "Geslaagd (reeds hernoemd)" -NameColor "Green"
                $generatedCount++
            } else {
                Show-Format "STT" "$videoName" "Mislukt (exitcode $($proc.ExitCode)): $stderr" -NameColor "Red"
                $failedCount++
                $failedItems += $videoName
            }
        } finally {
            Write-Progress -Activity "Whisper STT" -Completed
            if ($proc) {
                try { $proc.StandardOutput.Dispose() } catch {}
                try { $proc.StandardError.Dispose() } catch {}
                try { $proc.Dispose() } catch {}
            }
        }
    }

    Stop-LingeringSTTProcesses -WhisperExe $whisperExe -KeepPids $baselineWhisperPids

    Show-Format "SUMMARY" "STT voltooid" "Gegenereerd: $generatedCount | Overgeslagen: $skippedCount" -NameColor "Cyan"
    Set-StepRunResult -Step "06" -Success $generatedCount -Failed $failedCount -FailedItems $failedItems -Note "skipped=$skippedCount"
}
