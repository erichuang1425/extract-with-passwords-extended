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
        [string]$InitialLastPassword = $null
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
        $item = $queue.Dequeue()
        $folder = $item.Folder
        $depth = [int]$item.Depth

        if ($depth -gt $MaxDepth) { continue }

        $nested = @(Find-NestedArchives -Root $folder)
        if ($nested.Count -eq 0) { continue }

        foreach ($archive in $nested) {
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
            # Non-encryption-capable formats only need a single no-password attempt.
            if ($isEncryptable) {
                $tryList = @($Passwords)
                if ($lastWin) {
                    $reordered = @($lastWin)
                    foreach ($pw in $Passwords) { if ($pw -ne $lastWin) { $reordered += $pw } }
                    $tryList = $reordered
                }
            } else {
                $tryList = @("")
            }

            $found = $false
            $winPw = $null
            $winEngine = $null

            foreach ($pw in $tryList) {
                foreach ($engine in $enginePlan) {
                    $ok = Try-EnginePassword `
                        -EngineName $engine.Name `
                        -EnginePath $engine.Path `
                        -Archive $archive `
                        -Password $pw `
                        -OutputDir $outputDir `
                        -CanClearFailedOutput $true `
                        -OmitPasswordArg (-not $isEncryptable) `
                        -Timeout $Timeout `
                        -TestOnly:$false

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

                # Recurse into the freshly extracted output unless we are at the depth limit.
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
                $results.Add([PSCustomObject]@{
                    Archive = $archive; Status = "Failed"; OutputDir = $null
                    Engine = $null; Password = $null; ElapsedMs = $sw.ElapsedMilliseconds
                    Depth = $depth; IsNested = $true; Reason = "WrongPassword"; EnginesInPlan = $planNames
                })
            }
        }
    }

    return @($results.ToArray())
}
