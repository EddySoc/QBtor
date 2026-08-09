function Sync-AndScore {
    # Load config if not already loaded (for standalone execution)
    if (-not $Global:ConfigLoaded) {
        . (Join-Path $PSScriptRoot "Config.ps1")
    }

    DrawBanner "STEP 10 SYNC AND SELECT BEST SUBTITLES"

    $syncEnabled = $false
    if ($null -ne $Global:SyncEnabled) {
        $syncEnabled = Test-TrueValue $Global:SyncEnabled
    } elseif ($Global:SyncMode) {
        $syncEnabled = ($Global:SyncMode.ToLower() -eq 'always')
    } else {
        $syncEnabled = $true
    }
    Show-Format "CONFIG" "SyncEnabled=$syncEnabled" "" -NameColor "Cyan"

    $strictSkipSyncPath = Join-Path $Global:LogDir "strict_stt_skip_sync.txt"
    $strictSkipSyncVideos = @{}
    if (Test-Path -LiteralPath $strictSkipSyncPath) {
        foreach ($entry in (Get-Content -LiteralPath $strictSkipSyncPath -ErrorAction SilentlyContinue)) {
            $normalized = "$entry".Trim().ToLower()
            if ($normalized) {
                $strictSkipSyncVideos[$normalized] = $true
            }
        }
    }

    # Get all videos
    $tempDir = $Global:TempDir
    $allVideos = @(Get-ChildItem -LiteralPath $tempDir -Recurse -Filter "*.mkv" -File)
    $syncSuccess = 0
    $syncFailed = 0
    $syncFailedItems = @()

    foreach ($video in $allVideos) {
        $videoName = $video.BaseName
        $videoPath = $video.FullName
        $videoDir = $video.DirectoryName

        if ($strictSkipSyncVideos.ContainsKey($videoPath.ToLower())) {
            Show-Format "SKIP" "$videoName" "Strict download zonder match: sync overgeslagen (STT/vertaal-flow)" -NameColor "DarkGray"
            continue
        }

        # Extract title prefix for fuzzy matching so manually downloaded subs are found
        # even when codec/releasegroup differs. Priority:
        #   1. Title + year:    "28.Years.Later.2025"
        #   2. Title + episode: "Game.of.Thrones.S01E01"
        #   3. Fallback:        full basename (original behaviour)
        $titlePrefix = if ($videoName -match '^(.+?\.\d{4})\.') {
            $matches[1]
        } elseif ($videoName -match '^(.+?\.S\d{2}E\d{2})[\.\s]') {
            $matches[1]
        } else {
            $videoName
        }

        # Find subtitles for this specific video (exclude already synced ones)
        # Match on title prefix so manually downloaded subs with different codec/group names are found
        $videoSubs = @(Get-ChildItem -LiteralPath $videoDir -File -Filter "*.srt" | Where-Object { 
            $_.Name -like "$titlePrefix*.srt" -and
            $_.Name -notmatch '\.alass\.synced\.srt$' -and 
            $_.Name -notmatch '\.ffsubsync\.synced\.srt$' -and
            $_.Name -notmatch '\.synced\.'
        })

        # Filter to only subtitles in the target language
        if ($Global:Lang) {
            $videoSubs = @($videoSubs | Where-Object {
                (Get-SubtitleLanguage $_.Name) -eq $Global:Lang
            })
        }

        if ($videoSubs.Count -eq 0) {
            # Geen doeltaal-sub gevonden. In de STT/vertaal-flow wordt GEEN pre-sync gedaan:
            # STT levert al bruikbare timing en vertaling volgt daarop rechtstreeks.
            $translateMode = if ($Global:TranslateMode) { $Global:TranslateMode.ToLower() } else { "fallback" }
            if ($translateMode -ne "off") {
                Show-Format "SKIP" "$videoName" "Geen doeltaal-sub: pre-sync overgeslagen voor STT/vertaal-flow" -NameColor "DarkGray"
            } else {
                Show-Format "SKIP" "$videoName" "No subtitles found" -NameColor "Yellow"
            }
            continue
        }

        # Sorteer kandidaten op kwaliteit en kies de beste voor sync/embed
        $videoSubs = @($videoSubs | Sort-Object -Property @{ Expression = { Score-Subtitle -filePath $_.FullName -language (Get-SubtitleLanguage $_.Name) }; Descending = $true })
        if ($videoSubs.Count -gt 1) {
            Show-Format "SELECT" "$videoName" "Best subtitle: $($videoSubs[0].Name)" -NameColor "Green"
            $videoSubs = @($videoSubs[0])
        }

        DrawBar "*"
        Show-Format "PROCESS" "$videoName" "$($videoSubs.Count) subtitles"

        # Process each subtitle
        foreach ($sub in $videoSubs) {
            $subPath = $sub.FullName
            $subName = $sub.Name

            # Check if sync is needed
            $needsSync = Test-SubtitleNeedsSync -VideoPath $videoPath -SubtitlePath $subPath -VideoName $videoName

            if ($needsSync) {
                
                # Show separator between subtitles if there are multiple
                if ($videoSubs.Count -gt 1) {
                    Show-Format "DEBUG" "Trying ALASS + FFSubSync chain" "" -NameColor "Cyan"
                }

                $syncResult = Invoke-SyncChain -VideoPath $videoPath -SubtitleInfo @{
                    Name = $subName
                    Path = $subPath
                    Language = "unknown"
                } -VideoDir $videoDir
                
                if ($syncResult) {
                    Show-Format "SYNC" "$subName" "$($syncResult.Chain) sync successful" -NameColor "Green"
                    $syncSuccess++
                    # Update metadata to use the synced subtitle
                    Update-SubtitleMetadata -VideoBaseName $videoName -SyncedSubtitlePath $syncResult.Path -OriginalSubtitleName $subName -SyncChain $syncResult.Chain
                } else {
                    Show-Format "WARNING" "$subName" "Sync result rejected: geen bruikbare sync met ALASS of FFSubSync" -NameColor "Red"
                    $syncFailed++
                    $syncFailedItems += "$videoName :: $subName"
                    # Markeer als rejected: geen sync, geen embed
                    Update-SubtitleMetadata -VideoBaseName $videoName -SyncedSubtitlePath $null -OriginalSubtitleName $subName -SyncChain "Rejected"
                }
            } else {
                Show-Format "SKIP" "$subName" "Sync not needed" -NameColor "Cyan"
                $syncSuccess++
                # Still write metadata so Step 09 can embed the subtitle
                Update-SubtitleMetadata -VideoBaseName $videoName -SyncedSubtitlePath $subPath -OriginalSubtitleName $subName
            }
            
            # Add separator between subtitles if there are multiple
            if ($videoSubs.Count -gt 1 -and $sub -ne $videoSubs[-1]) {
                DrawBar "*"
            }
        }
    }

    Set-StepRunResult -Step "10" -Success $syncSuccess -Failed $syncFailed -FailedItems $syncFailedItems -Note "subtitle sync stage"
}

function Test-SubtitleNeedsSync {
    param(
        [string]$VideoPath,
        [string]$SubtitlePath,
        [string]$VideoName
    )

    # Volg SyncEnabled checkbox: true = syncen, false = niet syncen
    if ($null -ne $Global:SyncEnabled) {
        return (Test-TrueValue $Global:SyncEnabled)
    }
    # Fallback op oude SyncMode voor compatibiliteit
    $syncMode = if ($Global:SyncMode) { $Global:SyncMode.ToLower() } else { "always" }
    if ($syncMode -eq "always") { return $true }
    if ($syncMode -eq "none") { return $false }
    return $true
}

function Test-TrueValue {
    param($Value)

    if ($null -eq $Value) { return $false }
    return @('1', 'true', 'yes', 'on') -contains "$Value".Trim().ToLower()
}

function Convert-SrtTimeToMs {
    param([string]$Timecode)

    if (-not $Timecode -or $Timecode -notmatch '^(\d{2}):(\d{2}):(\d{2}),(\d{3})$') {
        return $null
    }

    return (([int]$matches[1] * 3600 + [int]$matches[2] * 60 + [int]$matches[3]) * 1000 + [int]$matches[4])
}

function Get-SubtitleTimingInfo {
    param([string]$SubtitlePath)

    if (-not (Test-Path -LiteralPath $SubtitlePath)) {
        return $null
    }

    $pattern = '(\d{2}:\d{2}:\d{2},\d{3})\s*-->\s*(\d{2}:\d{2}:\d{2},\d{3})'
    $matchesFound = [regex]::Matches((Get-Content -LiteralPath $SubtitlePath -Raw -ErrorAction SilentlyContinue), $pattern)
    if (($null -eq $matchesFound) -or ($matchesFound.Count -eq 0)) {
        return $null
    }

    $firstStart = Convert-SrtTimeToMs -Timecode $matchesFound[0].Groups[1].Value
    $lastEnd = Convert-SrtTimeToMs -Timecode $matchesFound[$matchesFound.Count - 1].Groups[2].Value

    return @{
        CueCount = $matchesFound.Count
        FirstStartMs = $firstStart
        LastEndMs = $lastEnd
    }
}

function Test-SyncedSubtitleLooksSafe {
    param(
        [string]$OriginalPath,
        [string]$CandidatePath
    )

    $original = Get-SubtitleTimingInfo -SubtitlePath $OriginalPath
    $candidate = Get-SubtitleTimingInfo -SubtitlePath $CandidatePath

    if (-not $original -or -not $candidate) {
        return $true
    }

    $minimumCueCount = [Math]::Max(10, [int][Math]::Floor($original.CueCount * 0.6))
    if ($candidate.CueCount -lt $minimumCueCount) {
        return $false
    }

    $shiftMs = $candidate.FirstStartMs - $original.FirstStartMs
    if ($original.FirstStartMs -lt 300000 -and $candidate.FirstStartMs -gt 900000 -and $shiftMs -gt 600000) {
        return $false
    }

    return $true
}

function Invoke-SyncChain {
    param(
        [string]$VideoPath,
        [hashtable]$SubtitleInfo,
        [string]$VideoDir
    )

    $useAlass = $true
    $useFFSubSync = $true
    if ($null -ne $Global:UseAlass) { $useAlass = Test-TrueValue $Global:UseAlass }
    if ($null -ne $Global:UseFFSubSync) { $useFFSubSync = Test-TrueValue $Global:UseFFSubSync }

    if (-not $useAlass -and -not $useFFSubSync) {
        Show-Format "ERROR" "Synchronisatie" "Geen sync tool geselecteerd! Vink ALASS en/of FFSubSync aan in de config." -NameColor "Red"
        return $null
    }

    $alassResult = $null
    $ffsubsyncResult = $null

    if ($useAlass) {
        $alassResult = Sync-WithAlass -VideoPath $VideoPath -SubtitleInfo $SubtitleInfo -VideoDir $VideoDir
        if ($alassResult -and (Test-SyncedSubtitleLooksSafe -OriginalPath $SubtitleInfo.Path -CandidatePath $alassResult)) {
            return @{
                Path = $alassResult
                Chain = 'ALASS'
            }
        }
    }

    if ($useFFSubSync) {
        # Gebruik output van ALASS als input, tenzij die er niet is
        $ffInputName = $alassResult ? [System.IO.Path]::GetFileName($alassResult) : $SubtitleInfo.Name
        $ffInputPath = $alassResult ? $alassResult : $SubtitleInfo.Path
        $ffsubsyncResult = Sync-WithFFSubSync -VideoPath $VideoPath -SubtitleInfo @{
            Name = $ffInputName
            Path = $ffInputPath
            Language = $SubtitleInfo.Language
        } -VideoDir $VideoDir
        if ($ffsubsyncResult -and (Test-SyncedSubtitleLooksSafe -OriginalPath $SubtitleInfo.Path -CandidatePath $ffsubsyncResult)) {
            return @{
                Path = $ffsubsyncResult
                Chain = $alassResult ? 'ALASS + FFSubSync' : 'FFSubSync'
            }
        }
    }

    # Beide pogingen gefaald
    return $null
}

function Sync-WithAlass {
    param(
        [string]$VideoPath,
        [hashtable]$SubtitleInfo,
        [string]$VideoDir
    )
    $alassExe = if ($Global:AlassExe -and (Test-Path $Global:AlassExe)) { $Global:AlassExe } else { Join-Path $PSScriptRoot 'alass.exe' }
    if (-not (Test-Path $alassExe)) {
        return $null
    }
    $syncOutput = Join-Path $VideoDir "$([System.IO.Path]::GetFileNameWithoutExtension($SubtitleInfo.Name)).alass.synced.srt"
    $alassParams = @(
        "`"$VideoPath`"",
        "`"$($SubtitleInfo.Path)`"",
        "`"$syncOutput`""
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $alassExe
    $psi.Arguments = $alassParams -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $false
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $null = $proc.Start()
    $proc.WaitForExit()
    if ($proc.ExitCode -eq 0 -and (Test-Path -LiteralPath $syncOutput)) {
        return $syncOutput
    }
    return $null
}

function Sync-WithFFSubSync {
    param(
        [string]$VideoPath,
        [hashtable]$SubtitleInfo,
        [string]$VideoDir
    )
    $ffsubsyncExe = if ($Global:FFSubSyncExe -and (Test-Path $Global:FFSubSyncExe)) { $Global:FFSubSyncExe } else { Join-Path $PSScriptRoot 'ffsubsync.exe' }
    if (-not (Test-Path $ffsubsyncExe)) {
        Show-Format "SKIP SYNC" "$($SubtitleInfo.Name)" "ffsubsync.exe niet gevonden: $ffsubsyncExe" -NameColor "Yellow"
        return $false
    }
    $syncOutput = Join-Path $VideoDir "$([System.IO.Path]::GetFileNameWithoutExtension($SubtitleInfo.Name)).ffsubsync.synced.srt"

    $ffParams = @(
        "`"$VideoPath`"",
        "-i", "`"$($SubtitleInfo.Path)`"",
        "-o", "`"$syncOutput`""
    )

    if ($Global:FFSubSyncMaxSubtitleSeconds) {
        $ffParams += @("--max-subtitle-seconds", "$($Global:FFSubSyncMaxSubtitleSeconds)")
    }
    if ($Global:FFSubSyncStartSeconds -and "$($Global:FFSubSyncStartSeconds)" -ne '0') {
        $ffParams += @("--start-seconds", "$($Global:FFSubSyncStartSeconds)")
    }
    if ($Global:FFSubSyncMaxOffset) {
        $ffParams += @("--max-offset-seconds", "$($Global:FFSubSyncMaxOffset)")
    } else {
        $ffParams += @("--max-offset-seconds", "600")
    }
    if ($Global:FFSubSyncVAD) {
        $ffParams += @("--vad", "$($Global:FFSubSyncVAD)")
    }
    if ($Global:FFSubSyncFrameRate) {
        $ffParams += @("--frame-rate", "$($Global:FFSubSyncFrameRate)")
    }
    if (Test-TrueValue $Global:FFSubSyncNoFixFramerate) {
        $ffParams += "--no-fix-framerate"
    }
    if ($Global:FFSubSyncEncoding) {
        $ffParams += @("--encoding", "$($Global:FFSubSyncEncoding)")
    }
    if ($Global:FFSubSyncOutputEncoding) {
        $ffParams += @("--output-encoding", "$($Global:FFSubSyncOutputEncoding)")
    }
    if ($Global:FFmpegExe -and (Test-Path $Global:FFmpegExe)) {
        $ffParams += @("--ffmpeg-path", "`"$([System.IO.Path]::GetDirectoryName($Global:FFmpegExe))`"")
    }
    if ($Global:LogDir -and (Test-Path $Global:LogDir)) {
        $ffParams += @("--log-dir-path", "`"$Global:LogDir`"")
    }

    $commandLine = "`"$ffsubsyncExe`" " + ($ffParams -join ' ')
    Write-Host "[CMD Test] $commandLine" -ForegroundColor Magenta
    if (Test-TrueValue $Global:SyncDebug) {
        Show-Format "DEBUG" "FFSubSync args" ($ffParams -join ' ') -NameColor "DarkGray"
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ffsubsyncExe
    $psi.Arguments = $ffParams -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $false
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $null = $proc.Start()
    $proc.WaitForExit()

    if ($proc.ExitCode -eq 0 -and (Test-Path -LiteralPath $syncOutput)) {
        return $syncOutput
    } else {
        Show-Format "DEBUG" "FFSubSync output file not found or exit code != 0" "" -NameColor "Red"
        return $null
    }
}

function Update-SubtitleMetadata {
    param(
        [string]$VideoBaseName,
        [string]$SyncedSubtitlePath,
        [string]$OriginalSubtitleName,
        [string]$SyncChain = "FFSubSync"
    )
    
    $metaDir = $Global:MetaDir
    if (-not (Test-Path $metaDir)) {
        New-Item -ItemType Directory -Path $metaDir -Force | Out-Null
    }
    
    $metaFile = Join-Path $metaDir "$VideoBaseName.meta.json"
    
    # Extract language from synced subtitle filename
    $syncedFileName = [System.IO.Path]::GetFileName($SyncedSubtitlePath)
    $extractedLang = Get-SubtitleLanguage $syncedFileName
    
    # Create or load metadata
    if (Test-Path -LiteralPath $metaFile) {
        $existingMeta = Get-Content -LiteralPath $metaFile | ConvertFrom-Json
        # Convert to hashtable for modification
        $meta = @{
            VideoName = $existingMeta.VideoName
            SourceFolder = $existingMeta.SourceFolder
            SubtitleFile = $existingMeta.SubtitleFile
            SubtitlePath = $existingMeta.SubtitlePath
            Language = $existingMeta.Language
            Score = $existingMeta.Score
        }
    } else {
        # Create basic metadata structure
        $meta = @{
            VideoName = $VideoBaseName
            SourceFolder = ""
            SubtitleFile = [System.IO.Path]::GetFileName($SyncedSubtitlePath)
            SubtitlePath = $SyncedSubtitlePath
            Language = $extractedLang
            Score = 0
        }
    }
    
    # Update the subtitle path to the synced version
    $meta.SubtitlePath = $SyncedSubtitlePath
    $meta.SubtitleFile = [System.IO.Path]::GetFileName($SyncedSubtitlePath)
    
    # Update language if it was extracted from the filename (and is valid)
    if ($extractedLang -and $extractedLang -ne "unknown") {
        $meta.Language = $extractedLang
    }
    
    # Add sync info
    $meta | Add-Member -MemberType NoteProperty -Name "SyncedFrom" -Value $OriginalSubtitleName -Force
    $meta | Add-Member -MemberType NoteProperty -Name "SyncChain" -Value $SyncChain -Force
    
    $meta | ConvertTo-Json | Set-Content -LiteralPath $metaFile -Force
    Show-Format "UPDATE" "$VideoBaseName" "Metadata updated with synced subtitle" -NameColor "Green"
}

function Start-Sync {
    Start-StepLog -StepNumber "10" -StepName "Sync_Subs"
    Sync-AndScore
    Stop-StepLog
}