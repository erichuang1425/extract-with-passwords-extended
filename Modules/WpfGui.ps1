# WpfGui.ps1 — WPF GUI for archive extraction with progress tracking

function Show-ExtractionGui {
    param(
        [string]$ModulesDir,
        # Paths (files and/or folders) to pre-load into the list. Lets the GUI be
        # launched directly from an Explorer right-click with the selection already
        # queued, instead of opening empty.
        [string[]]$InitialPaths
    )

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName System.Windows.Forms

    # PowerShell script blocks that are converted to .NET delegates (WPF event
    # handlers, Dispatcher callbacks, and BackgroundWorker callbacks) require a
    # runspace on the thread that invokes them. WPF/BackgroundWorker may invoke
    # those delegates on dispatcher or thread-pool threads where PowerShell has
    # not installed one, which produces the runtime error "There is no Runspace
    # available to run scripts in this thread." Capture the GUI runspace and
    # explicitly make it the default for callback threads before any script block
    # work runs.
    $guiRunspace = [System.Management.Automation.Runspaces.Runspace]::DefaultRunspace
    if (-not $guiRunspace) {
        $guiRunspace = [runspacefactory]::CreateRunspace()
        $guiRunspace.ApartmentState = [System.Threading.ApartmentState]::STA
        $guiRunspace.Open()
        [System.Management.Automation.Runspaces.Runspace]::DefaultRunspace = $guiRunspace
    }
    $ensureGuiRunspace = {
        if (-not [System.Management.Automation.Runspaces.Runspace]::DefaultRunspace) {
            [System.Management.Automation.Runspaces.Runspace]::DefaultRunspace = $guiRunspace
        }
    }

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
    $btnRemove = $window.FindName("btnRemove")
    $btnClear = $window.FindName("btnClear")
    $btnSettings = $window.FindName("btnSettings")
    $btnEditPasswords = $window.FindName("btnEditPasswords")
    $dgArchives = $window.FindName("dgArchives")
    $txtCount = $window.FindName("txtCount")
    $txtOverallProgress = $window.FindName("txtOverallProgress")
    $pbOverall = $window.FindName("pbOverall")
    $txtCurrentProgress = $window.FindName("txtCurrentProgress")
    $pbCurrent = $window.FindName("pbCurrent")
    $txtLog = $window.FindName("txtLog")
    $svLog = $window.FindName("svLog")
    $btnStart = $window.FindName("btnStart")
    $btnCancel = $window.FindName("btnCancel")
    $btnSkip = $window.FindName("btnSkip")
    $btnOpenOutput = $window.FindName("btnOpenOutput")

    # MenuItems inside a ContextMenu sit in their own WPF namescope, so
    # $window.FindName can't see them. Match them by Name on the menu's items
    # instead, which is independent of namescope quirks.
    $getMenuItem = {
        param($menu, [string]$name)
        foreach ($it in $menu.Items) {
            if (($it -is [System.Windows.Controls.MenuItem]) -and ($it.Name -eq $name)) { return $it }
        }
        return $null
    }
    $rowMenu = $dgArchives.ContextMenu
    $miOpenOutput = & $getMenuItem $rowMenu "miOpenOutput"
    $miOpenLocation = & $getMenuItem $rowMenu "miOpenLocation"
    $miCopyPassword = & $getMenuItem $rowMenu "miCopyPassword"
    $miCopyPath = & $getMenuItem $rowMenu "miCopyPath"
    $miRemove = & $getMenuItem $rowMenu "miRemove"

    $archiveItems = New-Object System.Collections.ObjectModel.ObservableCollection[PSObject]
    $dgArchives.ItemsSource = $archiveItems

    # Track already-queued paths so the same archive isn't added twice (via Add
    # Files, Add Folder, drag-and-drop, or the launch selection).
    $seenPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    $state = @{
        IsRunning = $false
        CancelSource = $null
        SkipSource = $null
        OutputFolders = @()
    }

    $appendLog = {
        param([string]$msg)
        $window.Dispatcher.Invoke([Action]{
            & $ensureGuiRunspace
            $txtLog.Text += "$msg`n"
            # Cap the buffer so very large batches don't bloat the UI text block.
            if ($txtLog.Text.Length -gt 60000) {
                $txtLog.Text = "...(trimmed)...`n" + $txtLog.Text.Substring($txtLog.Text.Length - 50000)
            }
            $svLog.ScrollToEnd()
        })
    }

    $updateCount = {
        $n = $archiveItems.Count
        $txtCount.Text = "$n archive$(if ($n -ne 1) { 's' })"
    }

    # Renumber the visible index column after add/remove so it stays 1..N.
    $reindex = {
        for ($k = 0; $k -lt $archiveItems.Count; $k++) {
            $archiveItems[$k].Index = $k + 1
        }
        $dgArchives.Items.Refresh()
    }

    # Add a single archive file (deduped). Returns 1 if added, 0 otherwise.
    $addFile = {
        param([string]$f)
        if (-not ((Test-IsSupportedArchiveName $f) -and (Test-IsFirstVolumeOrNormalArchive $f))) { return 0 }
        if (-not $seenPaths.Add($f)) { return 0 }
        $archiveItems.Add([PSCustomObject]@{
            Index = $archiveItems.Count + 1
            Name = [IO.Path]::GetFileName($f)
            FullPath = $f
            Status = "Pending"
            Password = ""
            RealPassword = ""
            Time = ""
            OutputDir = ""
        })
        return 1
    }

    # Add a file or recurse one level into a folder. Returns count added.
    $addPath = {
        param([string]$path)
        $added = 0
        if (Test-Path -LiteralPath $path -PathType Container) {
            $dirFiles = Get-ChildItem -LiteralPath $path -File -ErrorAction SilentlyContinue
            foreach ($df in $dirFiles) { $added += (& $addFile $df.FullName) }
        } elseif (Test-Path -LiteralPath $path -PathType Leaf) {
            $added += (& $addFile $path)
        }
        return $added
    }

    $btnAddFiles.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = "Select archive(s)"
        $dlg.Filter = "Archive files|*.zip;*.zipx;*.7z;*.rar;*.001;*.tar;*.gz;*.tgz;*.bz2;*.tbz2;*.xz;*.txz;*.zst;*.tzst;*.cab;*.iso;*.wim;*.img;*.dmg|All files|*.*"
        $dlg.Multiselect = $true
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $added = 0
            foreach ($f in $dlg.FileNames) { $added += (& $addFile $f) }
            & $reindex
            & $updateCount
            & $appendLog "Added $added archive(s)"
        }
    })

    $btnAddFolder.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = "Select folder to scan for archives"
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $count = & $addPath $dlg.SelectedPath
            & $reindex
            & $updateCount
            & $appendLog "Found $count archive(s) in folder"
        }
    })

    $removeSelected = {
        if ($state.IsRunning) {
            & $appendLog "Cannot remove items while extraction is running"
            return
        }
        $selected = @($dgArchives.SelectedItems)
        if ($selected.Count -eq 0) { return }
        foreach ($it in $selected) {
            [void]$seenPaths.Remove([string]$it.FullPath)
            [void]$archiveItems.Remove($it)
        }
        & $reindex
        & $updateCount
        & $appendLog "Removed $($selected.Count) item(s)"
    }

    $btnRemove.Add_Click($removeSelected)
    $miRemove.Add_Click($removeSelected)

    $btnClear.Add_Click({
        if ($state.IsRunning) {
            & $appendLog "Cannot clear the list while extraction is running"
            return
        }
        $archiveItems.Clear()
        $seenPaths.Clear()
        & $updateCount
        & $appendLog "Cleared archive list"
    })

    $btnSettings.Add_Click({
        if (Test-Path -LiteralPath $ConfigFile) {
            Start-Process notepad.exe -ArgumentList $ConfigFile
        }
    })

    $btnEditPasswords.Add_Click({
        if (Test-Path -LiteralPath $PwFile) {
            Start-Process notepad.exe -ArgumentList $PwFile
        }
    })

    # ---- Row context-menu actions -------------------------------------------

    $miOpenOutput.Add_Click({
        $sel = $dgArchives.SelectedItem
        if ($sel -and $sel.OutputDir -and (Test-Path -LiteralPath $sel.OutputDir)) {
            Start-Process explorer.exe -ArgumentList $sel.OutputDir
        } else {
            & $appendLog "No output folder available for the selected item"
        }
    })

    $miOpenLocation.Add_Click({
        $sel = $dgArchives.SelectedItem
        if ($sel -and (Test-Path -LiteralPath $sel.FullPath)) {
            Start-Process explorer.exe -ArgumentList "/select,`"$($sel.FullPath)`""
        }
    })

    $miCopyPassword.Add_Click({
        $sel = $dgArchives.SelectedItem
        if ($sel -and $sel.RealPassword) {
            try {
                Set-Clipboard -Value $sel.RealPassword
                & $appendLog "Password for '$($sel.Name)' copied to clipboard"
            } catch {
                & $appendLog "Could not copy password: $($_.Exception.Message)"
            }
        } else {
            & $appendLog "No recovered password to copy for the selected item"
        }
    })

    $miCopyPath.Add_Click({
        $sel = $dgArchives.SelectedItem
        if ($sel) {
            try { Set-Clipboard -Value $sel.FullPath } catch {}
        }
    })

    # Select the row under the cursor on right-click so the context-menu actions
    # always target what the user clicked (WPF's DataGrid doesn't do this itself).
    # An existing multi-selection is preserved when right-clicking inside it.
    $dgArchives.Add_PreviewMouseRightButtonDown({
        param($sender, $e)
        $dep = $e.OriginalSource
        while ($null -ne $dep -and -not ($dep -is [System.Windows.Controls.DataGridRow])) {
            $dep = [System.Windows.Media.VisualTreeHelper]::GetParent($dep)
        }
        if ($dep -is [System.Windows.Controls.DataGridRow] -and -not $dep.IsSelected) {
            $dgArchives.SelectedItems.Clear()
            $dep.IsSelected = $true
        }
    })

    # Double-click a finished row to jump straight to its output folder.
    $dgArchives.Add_MouseDoubleClick({
        $sel = $dgArchives.SelectedItem
        if ($sel -and $sel.OutputDir -and (Test-Path -LiteralPath $sel.OutputDir)) {
            Start-Process explorer.exe -ArgumentList $sel.OutputDir
        }
    })

    $dgArchives.Add_Drop({
        param($sender, $e)
        if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
            $files = $e.Data.GetData([System.Windows.DataFormats]::FileDrop)
            $added = 0
            foreach ($f in $files) { $added += (& $addPath $f) }
            & $reindex
            & $updateCount
            if ($added -gt 0) { & $appendLog "Added $added archive(s) via drag-and-drop" }
        }
    })

    $showGuiYesNo = {
        param([string]$Message, [string]$Title, [bool]$DefaultYes = $true)
        $result = [System.Windows.MessageBox]::Show(
            $Message,
            $Title,
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question,
            $(if ($DefaultYes) { [System.Windows.MessageBoxResult]::Yes } else { [System.Windows.MessageBoxResult]::No }))
        return ($result -eq [System.Windows.MessageBoxResult]::Yes)
    }

    $selectGuiFolder = {
        param([string]$Description, [string]$InitialPath)
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = $Description
        if ($InitialPath -and (Test-Path -LiteralPath $InitialPath -PathType Container)) {
            $dlg.SelectedPath = $InitialPath
        }
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return $dlg.SelectedPath
        }
        return $null
    }

    $showOutputBehaviorDialog = {
        param([string]$Current = "replace")

        $labels = @{
            "replace" = "Overwrite existing folders"
            "new"     = "Keep both (new _2/_3 folders)"
            "merge"   = "Merge, skip duplicate files"
        }
        if (-not $labels.ContainsKey($Current)) { $Current = "replace" }

        $dlg = New-Object System.Windows.Window
        $dlg.Title = "Existing Output Folders"
        $dlg.Width = 430
        $dlg.Height = 210
        $dlg.WindowStartupLocation = "CenterOwner"
        $dlg.ResizeMode = "NoResize"
        $dlg.Background = [System.Windows.Media.Brushes]::White
        $dlg.Owner = $window

        $panel = New-Object System.Windows.Controls.StackPanel
        $panel.Margin = "16"

        $text = New-Object System.Windows.Controls.TextBlock
        $text.Text = "How should existing extracted folders be handled?"
        $text.Margin = "0,0,0,10"
        $panel.Children.Add($text) | Out-Null

        $combo = New-Object System.Windows.Controls.ComboBox
        $combo.Margin = "0,0,0,14"
        $combo.DisplayMemberPath = "Label"
        $combo.SelectedValuePath = "Value"
        $combo.Items.Add([PSCustomObject]@{ Label = $labels["replace"]; Value = "replace" }) | Out-Null
        $combo.Items.Add([PSCustomObject]@{ Label = $labels["new"]; Value = "new" }) | Out-Null
        $combo.Items.Add([PSCustomObject]@{ Label = $labels["merge"]; Value = "merge" }) | Out-Null
        foreach ($item in $combo.Items) {
            if ($item.Value -eq $Current) {
                $combo.SelectedItem = $item
                break
            }
        }
        $panel.Children.Add($combo) | Out-Null

        $buttons = New-Object System.Windows.Controls.StackPanel
        $buttons.Orientation = "Horizontal"
        $buttons.HorizontalAlignment = "Right"
        $ok = New-Object System.Windows.Controls.Button
        $ok.Content = "OK"
        $ok.Width = 80
        $ok.Margin = "0,0,8,0"
        $cancel = New-Object System.Windows.Controls.Button
        $cancel.Content = "Cancel"
        $cancel.Width = 80
        $buttons.Children.Add($ok) | Out-Null
        $buttons.Children.Add($cancel) | Out-Null
        $panel.Children.Add($buttons) | Out-Null

        $ok.Add_Click({ $dlg.DialogResult = $true })
        $cancel.Add_Click({ $dlg.DialogResult = $false })
        $dlg.Content = $panel

        if ($dlg.ShowDialog() -eq $true -and $combo.SelectedValue) {
            return [string]$combo.SelectedValue
        }
        return $Current
    }

    $btnStart.Add_Click({
        if ($state.IsRunning) { return }
        if ($archiveItems.Count -eq 0) {
            & $appendLog "No archives to process"
            return
        }

        $archives = @($archiveItems | ForEach-Object { $_.FullPath })
        if ($AskBeforeExtracting) {
            $continue = & $showGuiYesNo "Continue with these $($archives.Count) archive(s)?" "Confirm Extraction" $true
            if (-not $continue) {
                & $appendLog "Extraction cancelled before start"
                return
            }
        }

        $useCustomOutputDir = $false
        $customOutputBase = $null
        if ($DefaultOutputDirectory -and $DefaultOutputDirectory.Length -gt 0) {
            $expanded = [Environment]::ExpandEnvironmentVariables($DefaultOutputDirectory)
            if (!(Test-Path -LiteralPath $expanded)) {
                $createIt = & $showGuiYesNo "Default output directory does not exist:`n$expanded`n`nCreate it?" "Create Output Directory" $true
                if ($createIt) {
                    try { New-Item -ItemType Directory -Force -Path $expanded | Out-Null } catch {
                        & $appendLog "Could not create default output directory: $($_.Exception.Message)"
                    }
                }
            }
            if (Test-Path -LiteralPath $expanded -PathType Container) {
                $useCustomOutputDir = $true
                $customOutputBase = $expanded
            }
        }

        if ($AlwaysAskOutputDirectory) {
            $currentDefault = if ($useCustomOutputDir) { $customOutputBase } else { "next to each archive" }
            $chooseCustom = & $showGuiYesNo "Current output location is: $currentDefault`n`nChoose a different output folder for this run?" "Output Folder" $false
            if ($chooseCustom) {
                $chosen = & $selectGuiFolder "Choose output folder for extracted archives" $customOutputBase
                if ($chosen) {
                    $useCustomOutputDir = $true
                    $customOutputBase = $chosen
                }
            }
        }

        if ($AskOutputBehavior) {
            $script:ExistingOutputBehavior = & $showOutputBehaviorDialog $ExistingOutputBehavior
            if ($script:ExistingOutputBehavior -eq "merge") {
                $script:SevenZipOverwriteMode = "aos"
                $script:WinRarOverwriteMode = "-o-"
            } else {
                $script:SevenZipOverwriteMode = "aoa"
                $script:WinRarOverwriteMode = "-o+"
            }
        }

        $separateFolders = if ($AskSeparateFolders) {
            & $showGuiYesNo "Extract each archive into its own separate folder?" "Output Layout" $DefaultSeparateFolders
        } else {
            $DefaultSeparateFolders
        }

        $commonOutputDir = $null
        if (-not $separateFolders) {
            $firstDir = if ($useCustomOutputDir) { $customOutputBase } else { Split-Path $archives[0] -Parent }
            if ([string]::IsNullOrEmpty($firstDir)) {
                $firstDir = [IO.Path]::GetPathRoot($archives[0])
            }
            $defaultCommon = Join-Path $firstDir ("Extracted_Batch_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
            $chooseCommon = & $showGuiYesNo "Use this shared output folder?`n$defaultCommon`n`nChoose No to browse for a different folder." "Shared Output Folder" $true
            if ($chooseCommon) {
                $commonOutputDir = $defaultCommon
            } else {
                $chosenCommon = & $selectGuiFolder "Choose shared output folder" $firstDir
                $commonOutputDir = if ($chosenCommon) { $chosenCommon } else { $defaultCommon }
            }
            try { New-Item -ItemType Directory -Force -Path $commonOutputDir | Out-Null } catch {
                & $appendLog "Could not create shared output directory: $($_.Exception.Message)"
                return
            }
        }

        $layoutText = if ($separateFolders) { "separate folders" } else { "shared folder: $commonOutputDir" }
        $baseText = if ($useCustomOutputDir -and $separateFolders) { " under $customOutputBase" } else { "" }
        & $appendLog "Output: $layoutText$baseText; existing folders: $ExistingOutputBehavior"

        $state.IsRunning = $true
        $state.CancelSource = New-Object System.Threading.CancellationTokenSource
        $state.OutputFolders = @()
        $btnStart.IsEnabled = $false
        $btnCancel.IsEnabled = $true
        $btnSkip.IsEnabled = $true
        $btnOpenOutput.IsEnabled = $false
        $btnAddFiles.IsEnabled = $false
        $btnAddFolder.IsEnabled = $false
        $btnRemove.IsEnabled = $false
        $btnClear.IsEnabled = $false

        $total = $archiveItems.Count

        $worker = New-Object System.ComponentModel.BackgroundWorker
        $worker.WorkerReportsProgress = $true

        $worker.Add_DoWork({
            param($s, $e)
            & $ensureGuiRunspace
            $workArgs = $e.Argument
            $items = $workArgs.Items
            $token = $workArgs.CancelToken
            $separateFolders = [bool]$workArgs.SeparateFolders
            $commonOutputDir = $workArgs.CommonOutputDir
            $useCustomOutputDir = [bool]$workArgs.UseCustomOutputDir
            $customOutputBase = $workArgs.CustomOutputBase
            $passwords = @(Get-Passwords)

            $sevenZip = Get-NormalSevenZipPath
            $peaZip7z = Get-PeaZipBundledSevenZipPath
            $winRar = Get-WinRarOrUnRarPath

            $succeeded = 0
            $failed = 0

            for ($i = 0; $i -lt $items.Count; $i++) {
                if ($token.IsCancellationRequested) { break }

                $archive = $items[$i]
                $skipSource = New-Object System.Threading.CancellationTokenSource
                # Marshal the per-archive cancellation source through
                # BackgroundWorker's normal progress channel. Invoking a
                # PowerShell script block directly on Dispatcher/worker threads
                # can fail because those threads do not own a PowerShell
                # runspace ("There is no Runspace available...").
                $s.ReportProgress(0, @{ Type = "CurrentSkipSource"; Source = $skipSource })
                $attemptToken = $skipSource.Token
                $sw = [System.Diagnostics.Stopwatch]::StartNew()

                $s.ReportProgress(0, @{ Type = "Status"; Index = $i; Text = "Testing..."; Overall = [math]::Floor(($i / $items.Count) * 100) })

                $enginePlan = @(Get-EnginePlanForArchive -Archive $archive -SevenZip $sevenZip -PeaZip7z $peaZip7z -WinRar $winRar)
                if ($enginePlan.Count -eq 0) {
                    $sw.Stop()
                    $s.ReportProgress(0, @{ Type = "Result"; Index = $i; Status = "No Engine"; Password = ""; RealPassword = ""; Time = (Format-Elapsed $sw) })
                    $s.ReportProgress(0, @{ Type = "CurrentSkipSource"; Source = $null })
                    $skipSource.Dispose()
                    $failed++
                    continue
                }

                $archiveDir = Split-Path $archive -Parent
                $archiveBase = Get-ArchiveBaseName $archive
                if ($separateFolders) {
                    $outputBaseDir = if ($useCustomOutputDir) { $customOutputBase } else { $archiveDir }
                    $outputDir = Join-Path $outputBaseDir $archiveBase
                    $outputDir = Resolve-OutputDir -BaseDir $outputDir -IsSharedOutput $false
                } else {
                    $outputDir = Resolve-OutputDir -BaseDir $commonOutputDir -IsSharedOutput $true
                }

                $isEncryptable = Test-IsEncryptionCapable $archive
                if ($isEncryptable -and $CheckEncryptionBeforeCycling -and $sevenZip) {
                    $enc = Test-ArchiveIsEncrypted -Archive $archive -SevenZipPath $sevenZip -CancelToken $attemptToken
                    if ($enc -eq $false) { $isEncryptable = $false }
                }

                $found = $false

                # The encryption probe above runs its own engine process; if the
                # user pressed Skip Current/Cancel while it was running, stop now
                # instead of cycling passwords or launching further engine
                # processes on this archive.
                if ($attemptToken.IsCancellationRequested -or $token.IsCancellationRequested) {
                    $sw.Stop()
                    $s.ReportProgress(0, @{ Type = "Result"; Index = $i; Status = "Skipped"; Password = ""; RealPassword = ""; Time = (Format-Elapsed $sw) })
                    Remove-EmptyOutputDir -OutputDir $outputDir -SeparateFolders $separateFolders
                    $s.ReportProgress(0, @{ Type = "CurrentSkipSource"; Source = $null })
                    $skipSource.Dispose()
                    continue
                }

                if (-not $isEncryptable) {
                    foreach ($engine in $enginePlan) {
                        $ok = Try-EnginePassword -EngineName $engine.Name -EnginePath $engine.Path -Archive $archive -Password "" -OutputDir $outputDir -CanClearFailedOutput $separateFolders -OmitPasswordArg $true -Timeout $ExtractionTimeoutSeconds -CancelToken $attemptToken
                        if ($attemptToken.IsCancellationRequested) { break }
                        if ($ok) {
                            $sw.Stop()
                            $s.ReportProgress(0, @{ Type = "Result"; Index = $i; Status = "Success"; Password = "(none)"; RealPassword = ""; Time = (Format-Elapsed $sw); OutputDir = $outputDir })
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
                            $testOk = Try-EnginePassword -EngineName $engine.Name -EnginePath $engine.Path -Archive $archive -Password $pw -OutputDir $outputDir -CanClearFailedOutput $separateFolders -Timeout $ExtractionTimeoutSeconds -TestOnly $true -CancelToken $attemptToken
                            if ($attemptToken.IsCancellationRequested) { break }
                            if ($testOk) {
                                $extractOk = Try-EnginePassword -EngineName $engine.Name -EnginePath $engine.Path -Archive $archive -Password $pw -OutputDir $outputDir -CanClearFailedOutput $separateFolders -Timeout $ExtractionTimeoutSeconds -TestOnly $false -CancelToken $attemptToken
                                if ($extractOk) {
                                    $sw.Stop()
                                    $masked = Format-MaskedPassword $pw
                                    Save-PasswordToCache $pw
                                    $s.ReportProgress(0, @{ Type = "Result"; Index = $i; Status = "Success"; Password = $masked; RealPassword = $pw; Time = (Format-Elapsed $sw); OutputDir = $outputDir })
                                    $succeeded++
                                    $found = $true
                                    break
                                }
                            }
                        }
                        if ($found -or $attemptToken.IsCancellationRequested) { break }
                    }
                }

                if ($attemptToken.IsCancellationRequested) {
                    $sw.Stop()
                    $s.ReportProgress(0, @{ Type = "Result"; Index = $i; Status = "Skipped"; Password = ""; RealPassword = ""; Time = (Format-Elapsed $sw) })
                    Remove-EmptyOutputDir -OutputDir $outputDir -SeparateFolders $separateFolders
                } elseif (-not $found) {
                    $sw.Stop()
                    $s.ReportProgress(0, @{ Type = "Result"; Index = $i; Status = "Failed"; Password = ""; RealPassword = ""; Time = (Format-Elapsed $sw) })
                    Remove-EmptyOutputDir -OutputDir $outputDir -SeparateFolders $separateFolders
                    $failed++
                }
                $s.ReportProgress(0, @{ Type = "CurrentSkipSource"; Source = $null })
                $skipSource.Dispose()
            }

            $e.Result = @{ Succeeded = $succeeded; Failed = $failed }
        })

        $worker.Add_ProgressChanged({
            param($s, $e)
            & $ensureGuiRunspace
            $data = $e.UserState
            switch ($data.Type) {
                "CurrentSkipSource" {
                    $state.SkipSource = $data.Source
                }
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
                        if ($data.ContainsKey("RealPassword")) { $item.RealPassword = $data.RealPassword }
                        $item.Time = $data.Time
                        if ($data.OutputDir) { $item.OutputDir = $data.OutputDir }
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
            & $ensureGuiRunspace
            $state.IsRunning = $false
            $btnStart.IsEnabled = $true
            $btnCancel.IsEnabled = $false
            $btnSkip.IsEnabled = $false
            $state.SkipSource = $null
            $btnAddFiles.IsEnabled = $true
            $btnAddFolder.IsEnabled = $true
            $btnRemove.IsEnabled = $true
            $btnClear.IsEnabled = $true
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

        $worker.RunWorkerAsync(@{
            Items = $archives
            CancelToken = $state.CancelSource.Token
            SeparateFolders = $separateFolders
            CommonOutputDir = $commonOutputDir
            UseCustomOutputDir = $useCustomOutputDir
            CustomOutputBase = $customOutputBase
        })
    })

    $btnCancel.Add_Click({
        if ($state.CancelSource) {
            $state.CancelSource.Cancel()
            if ($state.SkipSource) {
                try { $state.SkipSource.Cancel() } catch {}
            }
            & $appendLog "Cancellation requested..."
            $btnCancel.IsEnabled = $false
        }
    })

    $btnSkip.Add_Click({
        if ($state.IsRunning -and $state.SkipSource) {
            try { $state.SkipSource.Cancel() } catch {}
            & $appendLog "Skipping the current archive..."
        }
    })

    $btnOpenOutput.Add_Click({
        if ($state.OutputFolders.Count -gt 0) {
            Start-Process explorer.exe -ArgumentList $state.OutputFolders[0]
        }
    })

    # Close confirmation: never let an accidental close discard a run or results
    # without a prompt. While running, closing also cancels the in-flight worker.
    $window.Add_Closing({
        param($sender, $e)
        if ($state.IsRunning) {
            $r = [System.Windows.MessageBox]::Show(
                "Extraction is still in progress.`n`nCancel it and close the window?",
                "Confirm Close",
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Warning)
            if ($r -ne [System.Windows.MessageBoxResult]::Yes) {
                $e.Cancel = $true
                return
            }
            if ($state.CancelSource) { $state.CancelSource.Cancel() }
            if ($state.SkipSource) {
                try { $state.SkipSource.Cancel() } catch {}
            }
        } elseif ($ConfirmGuiClose -and $archiveItems.Count -gt 0) {
            $r = [System.Windows.MessageBox]::Show(
                "Close the Archive Password Extractor?",
                "Confirm Close",
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Question)
            if ($r -ne [System.Windows.MessageBoxResult]::Yes) {
                $e.Cancel = $true
                return
            }
        }
    })

    # Pre-load any paths handed in from the launch (e.g. an Explorer selection).
    if ($InitialPaths) {
        $loaded = 0
        foreach ($p in $InitialPaths) {
            if (-not [string]::IsNullOrWhiteSpace($p)) { $loaded += (& $addPath $p) }
        }
        & $reindex
        if ($loaded -gt 0) { & $appendLog "Loaded $loaded archive(s) from selection" }
    }
    & $updateCount

    [void]$window.ShowDialog()
}
