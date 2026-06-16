# NestedExtraction.ps1 — Recursive post-pass that extracts archives found
# inside already-extracted output folders.
#
# Runs after the main (sequential or parallel) extraction pass, consuming the
# unified $OutputFolders list. It reuses the existing engine machinery
# (Get-EnginePlanForArchive, Try-EnginePassword) and detection helpers rather
# than duplicating extraction logic. Bounded by $MaxNestedDepth and a visited
# set to prevent runaway recursion.

function Get-NormalizedPathKey {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }

    try {
        return ([IO.Path]::GetFullPath($Path)).TrimEnd('\').ToLowerInvariant()
    } catch {
        return $Path.TrimEnd('\').ToLowerInvariant()
    }
}

function Invoke-NestedExtractionPass {
    param(
        [string[]]$SeedFolders,
        [string[]]$Passwords,
        [string]$SevenZip,
        [string]$PeaZip7z,
        [string]$WinRar,
        [int]$MaxDepth = 1,
        [int]$Timeout = 0,
        [string]$InitialLastPassword = $null,
        [System.Threading.CancellationToken]$CancelToken = [System.Threading.CancellationToken]::None
    )

    $results = New-Object System.Collections.Generic.List[object]
    $visitedFolders = @{}
    $visitedArchives = @{}
    $lastWin = $InitialLastPassword

    $queue = New-Object System.Collections.Generic.Queue[object]
    foreach ($folder in @($SeedFolders | Sort-Object -Unique)) {
        $key = Get-NormalizedPathKey $folder
        if ($key -and -not $visitedFolders.ContainsKey($key)) {
            $visitedFolders[$key] = $true
            $queue.Enqueue(@{ Folder = $folder; Depth = 1 })
        }
    }

    while ($queue.Count -gt 0) {
        if ($CancelToken.IsCancellationRequested) {
            Write-Log "Nested extraction cancelled before scanning next queued folder." "WARN"
            break
        }

        $item = $queue.Dequeue()
        $folder = $item.Folder
        $depth = [int]$item.Depth

        if ($depth -gt $MaxDepth) { continue }

        $nested = @(Find-NestedArchives -Root $folder)
        if ($nested.Count -eq 0) { continue }

        # Stop at the payload layer: if this layer already contains an executable
        # payload (.exe/.msi/...), treat it as the intended final output and do not
        # extract any archive sitting alongside it. Applied here — before scanning
        # a dequeued folder — it gates the seed (main output) folders *and* every
        # deeper layer alike, so the first layer that yields an executable ends the
        # descent.
        if (Test-DirectoryHasExecutable -Dir $folder) {
            Write-Status "Reached an executable payload; skipping nested archives in this layer." "dim"
            Write-Log "Nested scan skipped for $folder (executable payload present)."
            continue
        }

        foreach ($archive in $nested) {
            if ($CancelToken.IsCancellationRequested) {
                Write-Log "Nested extraction cancelled before processing remaining archives in $folder." "WARN"
                break
            }

            $archiveKey = Get-NormalizedPathKey $archive
            if ($archiveKey -and $visitedArchives.ContainsKey($archiveKey)) { continue }
            if ($archiveKey) { $visitedArchives[$archiveKey] = $true }

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $archiveName = [IO.Path]::GetFileName($archive)
            Write-Status "Nested [depth $depth]: $archiveName" "info"
            Write-Log "Nested archive (depth $depth): $archive"

            $enginePlan = @(Get-EnginePlanForArchive -Archive $archive -SevenZip $SevenZip -PeaZip7z $PeaZip7z -WinRar $WinRar)
            $planNames = @($enginePlan | ForEach-Object { $_.Name })

            if (@($enginePlan).Count -eq 0) {
                $sw.Stop()
                Write-Status "No compatible engine for nested archive." "fail"
                $results.Add([PSCustomObject]@{
                    Archive = $archive; Status = "Failed"; OutputDir = $null
                    Engine = $null; Password = $null; ElapsedMs = $sw.ElapsedMilliseconds
                    Depth = $depth; IsNested = $true; Reason = "NoEngine"; EnginesInPlan = $planNames
                })
                continue
            }

            # Force non-destructive "new" behavior: the nested archive lives inside the
            # parent's output tree, so honoring a "replace" config could delete a
            # sibling directory the parent already extracted (e.g. photos.zip vs photos/).
            $outputBase = Join-Path (Split-Path $archive -Parent) (Get-ArchiveBaseName $archive)
            $outputDir = Resolve-OutputDir -BaseDir $outputBase -IsSharedOutput $false -BehaviorOverride "new"

            $isEncryptable = Test-IsEncryptionCapable $archive

            # Password order: try the last successful password first, then the rest.
            # This is what lets a multilayer archive use a *different* password at
            # each layer — the promoted guess fails and the remaining candidates are
            # tried until the layer's own password is found (then it becomes the new
            # preferred guess). Non-encryption-capable formats only need a single
            # no-password attempt.
            if ($isEncryptable) {
                $tryList = @(Get-PasswordTryOrder -Passwords $Passwords -PreferredFirst $lastWin)
            } else {
                $tryList = @("")
            }

            $found = $false
            $winPw = $null
            $winEngine = $null

            foreach ($pw in $tryList) {
                if ($CancelToken.IsCancellationRequested) { break }

                foreach ($engine in $enginePlan) {
                    if ($CancelToken.IsCancellationRequested) { break }
                    $ok = Try-EnginePassword `
                        -EngineName $engine.Name `
                        -EnginePath $engine.Path `
                        -Archive $archive `
                        -Password $pw `
                        -OutputDir $outputDir `
                        -CanClearFailedOutput $true `
                        -OmitPasswordArg (-not $isEncryptable) `
                        -Timeout $Timeout `
                        -TestOnly:$false `
                        -CancelToken $CancelToken

                    if ($ok) {
                        $winPw = $pw
                        $winEngine = $engine.Name
                        $found = $true
                        break
                    }
                }
                if ($found) { break }
            }

            $sw.Stop()

            if (-not $found -and $CancelToken.IsCancellationRequested) {
                # The user cancelled after this archive was selected but before any
                # engine attempt succeeded. Report it as Skipped (matching the GUI's
                # cancellation status) rather than letting it fall through to the
                # failure branch, which would miscount a user-cancelled archive as a
                # real extraction failure.
                Write-Status "Nested skipped (cancelled): $archiveName" "dim"
                Write-Log "Nested extraction cancelled for $archive" "WARN"
                Remove-EmptyOutputDir -OutputDir $outputDir -SeparateFolders $true
                $results.Add([PSCustomObject]@{
                    Archive = $archive; Status = "Skipped"; OutputDir = $null
                    Engine = $null; Password = $null; ElapsedMs = $sw.ElapsedMilliseconds
                    Depth = $depth; IsNested = $true; Reason = "Cancelled"; EnginesInPlan = $planNames
                })
                break
            }

            if ($found) {
                $status = if ($winPw -eq "") { "NoPassword" } else { "Succeeded" }
                Write-Status "Nested extracted via $winEngine -> $outputDir" "dim"
                Write-Log "Nested success: $archive (engine $winEngine)"

                if ($winPw) {
                    $lastWin = $winPw
                    Save-PasswordToCache $winPw
                }

                if ($DeleteNestedArchiveAfterExtract) {
                    try {
                        Remove-Item -LiteralPath $archive -Force -ErrorAction Stop
                        Write-Log "Deleted nested archive after extraction: $archive"
                    } catch {
                        Write-Log "Could not delete nested archive $archive : $($_.Exception.Message)" "WARN"
                    }
                }

                # Queue the freshly extracted output for the next layer (unless we
                # are at the depth limit). The executable-payload gate at the top
                # of the loop decides whether that layer is actually scanned, so a
                # layer that turns out to hold the payload is skipped when dequeued.
                $childKey = Get-NormalizedPathKey $outputDir
                if (($depth + 1) -le $MaxDepth -and $childKey -and -not $visitedFolders.ContainsKey($childKey)) {
                    $visitedFolders[$childKey] = $true
                    $queue.Enqueue(@{ Folder = $outputDir; Depth = $depth + 1 })
                }

                $results.Add([PSCustomObject]@{
                    Archive = $archive; Status = $status; OutputDir = $outputDir
                    Engine = $winEngine; Password = $winPw; ElapsedMs = $sw.ElapsedMilliseconds
                    Depth = $depth; IsNested = $true; Reason = $null; EnginesInPlan = $planNames
                })
            } else {
                Write-Status "Nested FAILED: no matching password for $archiveName" "fail"
                Write-Log "Nested failure: $archive" "ERROR"
                Remove-EmptyOutputDir -OutputDir $outputDir -SeparateFolders $true
                $nestedReason = Get-LastEngineFailureType -ArchiveKnownEncrypted $isEncryptable
                if ([string]::IsNullOrEmpty($nestedReason) -or $nestedReason -in @("Success", "Unknown", "WrongPassword")) {
                    $nestedReason = if ($isEncryptable) { "WrongPassword" } else { "ExtractionFailed" }
                }
                $results.Add([PSCustomObject]@{
                    Archive = $archive; Status = "Failed"; OutputDir = $null
                    Engine = $null; Password = $null; ElapsedMs = $sw.ElapsedMilliseconds
                    Depth = $depth; IsNested = $true; Reason = $nestedReason; EnginesInPlan = $planNames
                })
            }
        }
    }

    return @($results.ToArray())
}
