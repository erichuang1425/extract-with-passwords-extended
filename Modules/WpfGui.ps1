# WpfGui.ps1 — WPF GUI for archive extraction with progress tracking

function Show-ExtractionGui {
    param([string]$ModulesDir)

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName System.Windows.Forms

    $xamlPath = Join-Path (Split-Path $ModulesDir -Parent) "Resources\MainWindow.xaml"
    if (-not (Test-Path -LiteralPath $xamlPath)) {
        Write-Status "GUI XAML not found at $xamlPath" "fail"
        return
    }

    $xamlContent = Get-Content -LiteralPath $xamlPath -Raw
    $xamlContent = $xamlContent -replace 'x:Class="[^"]*"', ''
    $xamlContent = $xamlContent -replace 'x:Name="', 'Name="'

    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xamlContent))
    $window = [System.Windows.Markup.XamlReader]::Load($reader)

    $btnAddFiles = $window.FindName("btnAddFiles")
    $btnAddFolder = $window.FindName("btnAddFolder")
    $btnClear = $window.FindName("btnClear")
    $btnSettings = $window.FindName("btnSettings")
    $dgArchives = $window.FindName("dgArchives")
    $txtOverallProgress = $window.FindName("txtOverallProgress")
    $pbOverall = $window.FindName("pbOverall")
    $txtCurrentProgress = $window.FindName("txtCurrentProgress")
    $pbCurrent = $window.FindName("pbCurrent")
    $txtLog = $window.FindName("txtLog")
    $svLog = $window.FindName("svLog")
    $btnStart = $window.FindName("btnStart")
    $btnCancel = $window.FindName("btnCancel")
    $btnOpenOutput = $window.FindName("btnOpenOutput")

    $archiveItems = New-Object System.Collections.ObjectModel.ObservableCollection[PSObject]
    $dgArchives.ItemsSource = $archiveItems

    $state = @{
        IsRunning = $false
        CancelSource = $null
        OutputFolders = @()
    }

    $appendLog = {
        param([string]$msg)
        $window.Dispatcher.Invoke([Action]{
            $txtLog.Text += "$msg`n"
            $svLog.ScrollToEnd()
        })
    }

    $btnAddFiles.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = "Select archive(s)"
        $dlg.Filter = "Archive files|*.zip;*.zipx;*.7z;*.rar;*.001;*.tar;*.gz;*.tgz;*.bz2;*.tbz2;*.xz;*.txz;*.zst;*.tzst;*.cab;*.iso;*.wim;*.img;*.dmg|All files|*.*"
        $dlg.Multiselect = $true
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            foreach ($f in $dlg.FileNames) {
                if ((Test-IsSupportedArchiveName $f) -and (Test-IsFirstVolumeOrNormalArchive $f)) {
                    $archiveItems.Add([PSCustomObject]@{
                        Index = $archiveItems.Count + 1
                        Name = [IO.Path]::GetFileName($f)
                        FullPath = $f
                        Status = "Pending"
                        Password = ""
                        Time = ""
                    })
                }
            }
            & $appendLog "Added $($dlg.FileNames.Count) file(s)"
        }
    })

    $btnAddFolder.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = "Select folder to scan for archives"
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $files = Get-ChildItem -LiteralPath $dlg.SelectedPath -File -ErrorAction SilentlyContinue
            $count = 0
            foreach ($f in $files) {
                if ((Test-IsSupportedArchiveName $f.FullName) -and (Test-IsFirstVolumeOrNormalArchive $f.FullName)) {
                    $archiveItems.Add([PSCustomObject]@{
                        Index = $archiveItems.Count + 1
                        Name = $f.Name
                        FullPath = $f.FullName
                        Status = "Pending"
                        Password = ""
                        Time = ""
                    })
                    $count++
                }
            }
            & $appendLog "Found $count archive(s) in folder"
        }
    })

    $btnClear.Add_Click({
        $archiveItems.Clear()
        & $appendLog "Cleared archive list"
    })

    $btnSettings.Add_Click({
        if (Test-Path -LiteralPath $ConfigFile) {
            Start-Process notepad.exe -ArgumentList $ConfigFile
        }
    })

    $dgArchives.Add_Drop({
        param($sender, $e)
        if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
            $files = $e.Data.GetData([System.Windows.DataFormats]::FileDrop)
            foreach ($f in $files) {
                if (Test-Path -LiteralPath $f -PathType Leaf) {
                    if ((Test-IsSupportedArchiveName $f) -and (Test-IsFirstVolumeOrNormalArchive $f)) {
                        $archiveItems.Add([PSCustomObject]@{
                            Index = $archiveItems.Count + 1
                            Name = [IO.Path]::GetFileName($f)
                            FullPath = $f
                            Status = "Pending"
                            Password = ""
                            Time = ""
                        })
                    }
                } elseif (Test-Path -LiteralPath $f -PathType Container) {
                    $dirFiles = Get-ChildItem -LiteralPath $f -File -ErrorAction SilentlyContinue
                    foreach ($df in $dirFiles) {
                        if ((Test-IsSupportedArchiveName $df.FullName) -and (Test-IsFirstVolumeOrNormalArchive $df.FullName)) {
                            $archiveItems.Add([PSCustomObject]@{
                                Index = $archiveItems.Count + 1
                                Name = $df.Name
                                FullPath = $df.FullName
                                Status = "Pending"
                                Password = ""
                                Time = ""
                            })
                        }
                    }
                }
            }
        }
    })

    $btnStart.Add_Click({
        if ($state.IsRunning) { return }
        if ($archiveItems.Count -eq 0) {
            & $appendLog "No archives to process"
            return
        }

        $state.IsRunning = $true
        $state.CancelSource = New-Object System.Threading.CancellationTokenSource
        $state.OutputFolders = @()
        $btnStart.IsEnabled = $false
        $btnCancel.IsEnabled = $true
        $btnOpenOutput.IsEnabled = $false

        $total = $archiveItems.Count
        $archives = @($archiveItems | ForEach-Object { $_.FullPath })

        $worker = New-Object System.ComponentModel.BackgroundWorker
        $worker.WorkerReportsProgress = $true

        $worker.Add_DoWork({
            param($s, $e)
            $args = $e.Argument
            $items = $args.Items
            $token = $args.CancelToken
            $passwords = @(Get-Passwords)

            $sevenZip = Get-NormalSevenZipPath
            $peaZip7z = Get-PeaZipBundledSevenZipPath
            $winRar = Get-WinRarOrUnRarPath

            $succeeded = 0
            $failed = 0

            for ($i = 0; $i -lt $items.Count; $i++) {
                if ($token.IsCancellationRequested) { break }

                $archive = $items[$i]
                $archiveName = [IO.Path]::GetFileName($archive)
                $sw = [System.Diagnostics.Stopwatch]::StartNew()

                $s.ReportProgress(0, @{ Type = "Status"; Index = $i; Text = "Testing..."; Overall = [math]::Floor(($i / $items.Count) * 100) })

                $enginePlan = @(Get-EnginePlanForArchive -Archive $archive -SevenZip $sevenZip -PeaZip7z $peaZip7z -WinRar $winRar)
                if ($enginePlan.Count -eq 0) {
                    $sw.Stop()
                    $s.ReportProgress(0, @{ Type = "Result"; Index = $i; Status = "No Engine"; Password = ""; Time = (Format-Elapsed $sw) })
                    $failed++
                    continue
                }

                $archiveDir = Split-Path $archive -Parent
                $archiveBase = Get-ArchiveBaseName $archive
                $outputDir = Join-Path $archiveDir $archiveBase
                $outputDir = Resolve-OutputDir -BaseDir $outputDir -IsSharedOutput $false

                $isEncryptable = Test-IsEncryptionCapable $archive
                if ($isEncryptable -and $CheckEncryptionBeforeCycling -and $sevenZip) {
                    $enc = Test-ArchiveIsEncrypted -Archive $archive -SevenZipPath $sevenZip
                    if ($enc -eq $false) { $isEncryptable = $false }
                }

                $found = $false

                if (-not $isEncryptable) {
                    foreach ($engine in $enginePlan) {
                        $ok = Try-EnginePassword -EngineName $engine.Name -EnginePath $engine.Path -Archive $archive -Password "" -OutputDir $outputDir -CanClearFailedOutput $true -OmitPasswordArg $true -Timeout $ExtractionTimeoutSeconds
                        if ($ok) {
                            $sw.Stop()
                            $s.ReportProgress(0, @{ Type = "Result"; Index = $i; Status = "Success"; Password = "(none)"; Time = (Format-Elapsed $sw); OutputDir = $outputDir })
                            $succeeded++
                            $found = $true
                            break
                        }
                    }
                } else {
                    $pwIndex = 0
                    foreach ($pw in $passwords) {
                        if ($token.IsCancellationRequested) { break }
                        $pwIndex++

                        $currentPct = [math]::Floor(($pwIndex / $passwords.Count) * 100)
                        $s.ReportProgress(0, @{ Type = "Password"; Index = $i; Current = $pwIndex; Total = $passwords.Count; Pct = $currentPct })

                        foreach ($engine in $enginePlan) {
                            $testOk = Try-EnginePassword -EngineName $engine.Name -EnginePath $engine.Path -Archive $archive -Password $pw -OutputDir $outputDir -CanClearFailedOutput $true -Timeout $ExtractionTimeoutSeconds -TestOnly $true
                            if ($testOk) {
                                $extractOk = Try-EnginePassword -EngineName $engine.Name -EnginePath $engine.Path -Archive $archive -Password $pw -OutputDir $outputDir -CanClearFailedOutput $true -Timeout $ExtractionTimeoutSeconds -TestOnly $false
                                if ($extractOk) {
                                    $sw.Stop()
                                    $masked = Format-MaskedPassword $pw
                                    Save-PasswordToCache $pw
                                    $s.ReportProgress(0, @{ Type = "Result"; Index = $i; Status = "Success"; Password = $masked; Time = (Format-Elapsed $sw); OutputDir = $outputDir })
                                    $succeeded++
                                    $found = $true
                                    break
                                }
                            }
                        }
                        if ($found) { break }
                    }
                }

                if (-not $found) {
                    $sw.Stop()
                    $s.ReportProgress(0, @{ Type = "Result"; Index = $i; Status = "Failed"; Password = ""; Time = (Format-Elapsed $sw) })
                    Remove-EmptyOutputDir -OutputDir $outputDir -SeparateFolders $true
                    $failed++
                }
            }

            $e.Result = @{ Succeeded = $succeeded; Failed = $failed }
        })

        $worker.Add_ProgressChanged({
            param($s, $e)
            $data = $e.UserState
            switch ($data.Type) {
                "Status" {
                    $idx = $data.Index
                    if ($idx -lt $archiveItems.Count) {
                        $item = $archiveItems[$idx]
                        $item.Status = $data.Text
                        $dgArchives.Items.Refresh()
                    }
                    $pbOverall.Value = $data.Overall
                    $txtOverallProgress.Text = "Processing archive $($idx + 1) / $total"
                }
                "Password" {
                    $pbCurrent.Value = $data.Pct
                    $txtCurrentProgress.Text = "Password $($data.Current) / $($data.Total)"
                }
                "Result" {
                    $idx = $data.Index
                    if ($idx -lt $archiveItems.Count) {
                        $item = $archiveItems[$idx]
                        $item.Status = $data.Status
                        $item.Password = $data.Password
                        $item.Time = $data.Time
                        $dgArchives.Items.Refresh()
                    }
                    if ($data.OutputDir) {
                        $state.OutputFolders += $data.OutputDir
                    }
                    & $appendLog "[$($data.Status)] $($archiveItems[$idx].Name) ($($data.Time))"
                }
            }
        })

        $worker.Add_RunWorkerCompleted({
            param($s, $e)
            $state.IsRunning = $false
            $btnStart.IsEnabled = $true
            $btnCancel.IsEnabled = $false
            $pbCurrent.Value = 0
            $txtCurrentProgress.Text = ""

            if ($e.Error) {
                & $appendLog "Error: $($e.Error.Message)"
                $pbOverall.Value = 0
                $txtOverallProgress.Text = "Error occurred"
            } else {
                $r = $e.Result
                $pbOverall.Value = 100
                $txtOverallProgress.Text = "Done: $($r.Succeeded) succeeded, $($r.Failed) failed"
                if ($state.OutputFolders.Count -gt 0) {
                    $btnOpenOutput.IsEnabled = $true
                }
                Show-CompletionToast -Succeeded $r.Succeeded -Failed $r.Failed -Total $total
            }
        })

        $worker.RunWorkerAsync(@{ Items = $archives; CancelToken = $state.CancelSource.Token })
    })

    $btnCancel.Add_Click({
        if ($state.CancelSource) {
            $state.CancelSource.Cancel()
            & $appendLog "Cancellation requested..."
            $btnCancel.IsEnabled = $false
        }
    })

    $btnOpenOutput.Add_Click({
        if ($state.OutputFolders.Count -gt 0) {
            Start-Process explorer.exe -ArgumentList $state.OutputFolders[0]
        }
    })

    $window.Add_Closing({
        if ($state.CancelSource) {
            $state.CancelSource.Cancel()
        }
    })

    [void]$window.ShowDialog()
}
