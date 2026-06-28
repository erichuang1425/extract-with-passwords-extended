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
    # handlers and DispatcherTimer ticks) require a runspace on the thread that
    # invokes them. These all fire on the GUI thread, which already owns this
    # runspace, but capture it anyway and re-assert it as a belt-and-suspenders
    # guard so a callback can never hit "There is no Runspace available to run
    # scripts in this thread." (The extraction work itself runs in its own
    # dedicated runspace — see $extractionWorker — never on a callback thread.)
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
        OutputFolders = @()
        Total = 0
        Worker = $null
        WorkerAsync = $null
        WorkerRunspace = $null
        Timer = $null
    }

    # Cross-thread channels between the UI thread and the extraction worker
    # runspace. The worker only ever touches these thread-safe .NET objects — it
    # never calls a WPF control or invokes a PowerShell script block on the UI
    # thread — so there is no runspace-affinity hazard.
    #   * $progressQueue : worker enqueues plain progress records; a UI-thread
    #                      DispatcherTimer drains them and applies UI changes.
    #   * $shared        : a synchronized hashtable the worker uses to publish the
    #                      current archive's skip CancellationTokenSource so the
    #                      Skip/Cancel buttons (UI thread) can signal it.
    $progressQueue = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
    $shared = [System.Collections.Hashtable]::Synchronized(@{ CurrentSkipSource = $null })

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

    # ----------------------------------------------------------------------
    # The extraction worker. This script block is handed to a DEDICATED runspace
    # (via [PowerShell].AddScript), so it is re-parsed there and must not touch
    # any GUI-thread state directly — everything it needs arrives through the
    # $ctx argument, and everything it reports goes back through $ctx.Queue.
    #
    # Why a dedicated runspace instead of a BackgroundWorker: a BackgroundWorker
    # raises DoWork on a thread-pool thread that owns no PowerShell runspace, and
    # PowerShell throws "There is no Runspace available to run scripts in this
    # thread" *while invoking the DoWork script-block delegate* — before any
    # statement inside it can install a runspace. That made the old GUI unable to
    # start a scan at all. [PowerShell].BeginInvoke() instead runs this block
    # inside a runspace we opened, which PowerShell makes the executing thread's
    # default for the lifetime of the pipeline, so every cmdlet/function works.
    # ----------------------------------------------------------------------
    $extractionWorker = {
        param($ctx)

        $queue = $ctx.Queue
        $shared = $ctx.Shared
        $emit = { param($m) [void]$queue.Enqueue($m) }

        $succeeded = 0
        $failed = 0
        try {
            # Bootstrap this runspace exactly like the host script: derive the
            # paths, load the modules (which defines every engine/password
            # function and seeds the config defaults), then layer config.json and
            # finally the GUI's per-run choices on top.
            $p = $ctx.Paths
            $ToolDir    = $p.ToolDir
            $ModulesDir = $p.ModulesDir
            $PwDir      = $p.PwDir
            $PwFile     = $p.PwFile
            $LogDir     = $p.LogDir
            $ConfigFile = $p.ConfigFile
            $CacheFile  = $p.CacheFile
            $RunLogPath = $p.RunLogPath
            $RunStamp   = $p.RunStamp

            . "$ModulesDir\Config.ps1"
            . "$ModulesDir\Logging.ps1"
            . "$ModulesDir\ConsoleUI.ps1"
            . "$ModulesDir\ArchiveUtils.ps1"
            . "$ModulesDir\Extraction.ps1"
            . "$ModulesDir\Passwords.ps1"
            . "$ModulesDir\NestedExtraction.ps1"
            . "$ModulesDir\Parallel.ps1"
            . "$ModulesDir\PowerManagement.ps1"

            Read-Config

            # The GUI's pre-extraction dialog choices win over config.json.
            foreach ($k in $ctx.Overrides.Keys) {
                Set-Variable -Name $k -Value $ctx.Overrides[$k]
            }

            $items = $ctx.Items
            $token = $ctx.CancelToken
            $separateFolders = [bool]$ctx.SeparateFolders
            $commonOutputDir = $ctx.CommonOutputDir
            $useCustomOutputDir = [bool]$ctx.UseCustomOutputDir
            $customOutputBase = $ctx.CustomOutputBase
            $passwords = @(Get-Passwords)

            $sevenZip = Get-NormalSevenZipPath
            $peaZip7z = Get-PeaZipBundledSevenZipPath
            $winRar = Get-WinRarOrUnRarPath

            for ($i = 0; $i -lt $items.Count; $i++) {
                if ($token.IsCancellationRequested) { break }

                $archive = $items[$i]
                $skipSource = New-Object System.Threading.CancellationTokenSource
                # Publish the per-archive skip source so the Skip/Cancel buttons
                # on the UI thread can signal just this archive.
                $shared.CurrentSkipSource = $skipSource
                $attemptToken = $skipSource.Token
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                try {
                    & $emit @{ Type = "Status"; Index = $i; Text = "Testing..."; Overall = [math]::Floor(($i / $items.Count) * 100) }

                    $enginePlan = @(Get-EnginePlanForArchive -Archive $archive -SevenZip $sevenZip -PeaZip7z $peaZip7z -WinRar $winRar)
                    if ($enginePlan.Count -eq 0) {
                        $sw.Stop()
                        & $emit @{ Type = "Result"; Index = $i; Status = "No Engine"; Password = ""; RealPassword = ""; Time = (Format-Elapsed $sw) }
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
                    # instead of cycling passwords on this archive.
                    if ($attemptToken.IsCancellationRequested -or $token.IsCancellationRequested) {
                        $sw.Stop()
                        & $emit @{ Type = "Result"; Index = $i; Status = "Skipped"; Password = ""; RealPassword = ""; Time = (Format-Elapsed $sw) }
                        Remove-EmptyOutputDir -OutputDir $outputDir -SeparateFolders $separateFolders
                        continue
                    }

                    if (-not $isEncryptable) {
                        foreach ($engine in $enginePlan) {
                            $ok = Try-EnginePassword -EngineName $engine.Name -EnginePath $engine.Path -Archive $archive -Password "" -OutputDir $outputDir -CanClearFailedOutput $separateFolders -OmitPasswordArg $true -Timeout $ExtractionTimeoutSeconds -CancelToken $attemptToken
                            if ($attemptToken.IsCancellationRequested) { break }
                            if ($ok) {
                                $sw.Stop()
                                & $emit @{ Type = "Result"; Index = $i; Status = "Success"; Password = "(none)"; RealPassword = ""; Time = (Format-Elapsed $sw); OutputDir = $outputDir }
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
                            & $emit @{ Type = "Password"; Index = $i; Current = $pwIndex; Total = $passwords.Count; Pct = $currentPct }

                            foreach ($engine in $enginePlan) {
                                $testOk = Try-EnginePassword -EngineName $engine.Name -EnginePath $engine.Path -Archive $archive -Password $pw -OutputDir $outputDir -CanClearFailedOutput $separateFolders -Timeout $ExtractionTimeoutSeconds -TestOnly $true -CancelToken $attemptToken
                                if ($attemptToken.IsCancellationRequested) { break }
                                if ($testOk) {
                                    $extractOk = Try-EnginePassword -EngineName $engine.Name -EnginePath $engine.Path -Archive $archive -Password $pw -OutputDir $outputDir -CanClearFailedOutput $separateFolders -Timeout $ExtractionTimeoutSeconds -TestOnly $false -CancelToken $attemptToken
                                    if ($extractOk) {
                                        $sw.Stop()
                                        $masked = Format-MaskedPassword $pw
                                        Save-PasswordToCache $pw
                                        & $emit @{ Type = "Result"; Index = $i; Status = "Success"; Password = $masked; RealPassword = $pw; Time = (Format-Elapsed $sw); OutputDir = $outputDir }
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
                        & $emit @{ Type = "Result"; Index = $i; Status = "Skipped"; Password = ""; RealPassword = ""; Time = (Format-Elapsed $sw) }
                        Remove-EmptyOutputDir -OutputDir $outputDir -SeparateFolders $separateFolders
                    } elseif (-not $found) {
                        $sw.Stop()
                        & $emit @{ Type = "Result"; Index = $i; Status = "Failed"; Password = ""; RealPassword = ""; Time = (Format-Elapsed $sw) }
                        Remove-EmptyOutputDir -OutputDir $outputDir -SeparateFolders $separateFolders
                        $failed++
                    }
                } finally {
                    $shared.CurrentSkipSource = $null
                    $skipSource.Dispose()
                }
            }
        } catch {
            & $emit @{ Type = "Log"; Message = "Extraction error: $($_.Exception.Message)" }
            try { Write-Log "GUI worker error: $($_.Exception.Message)" "ERROR" } catch {}
        } finally {
            & $emit @{ Type = "Done"; Succeeded = $succeeded; Failed = $failed }
        }
    }

    # Tear down a finished worker run and restore the idle UI state. Runs on the
    # UI thread (called from the DispatcherTimer tick).
    $finishRun = {
        param($result)
        if ($state.Timer) { try { $state.Timer.Stop() } catch {} ; $state.Timer = $null }
        $state.IsRunning = $false
        $shared.CurrentSkipSource = $null
        $btnStart.IsEnabled = $true
        $btnCancel.IsEnabled = $false
        $btnSkip.IsEnabled = $false
        $btnAddFiles.IsEnabled = $true
        $btnAddFolder.IsEnabled = $true
        $btnRemove.IsEnabled = $true
        $btnClear.IsEnabled = $true
        $pbCurrent.Value = 0
        $txtCurrentProgress.Text = ""

        # Reap the pipeline and surface anything it wrote to the error stream.
        if ($state.Worker) {
            try {
                if ($state.WorkerAsync) { $state.Worker.EndInvoke($state.WorkerAsync) }
            } catch {
                & $appendLog "Worker error: $($_.Exception.Message)"
            }
            try {
                foreach ($werr in @($state.Worker.Streams.Error)) {
                    & $appendLog "Worker: $($werr.ToString())"
                }
            } catch {}
            try { $state.Worker.Dispose() } catch {}
        }
        try { if ($state.WorkerRunspace) { $state.WorkerRunspace.Dispose() } } catch {}
        $state.Worker = $null
        $state.WorkerAsync = $null
        $state.WorkerRunspace = $null

        $pbOverall.Value = 100
        $txtOverallProgress.Text = "Done: $($result.Succeeded) succeeded, $($result.Failed) failed"
        if ($state.OutputFolders.Count -gt 0) {
            $btnOpenOutput.IsEnabled = $true
        }
        Show-CompletionToast -Succeeded $result.Succeeded -Failed $result.Failed -Total $state.Total
    }

    # DispatcherTimer tick: drain the worker's progress records and apply them to
    # the UI. Always runs on the UI thread, which owns the GUI runspace, so the
    # control updates here are safe.
    $drainProgress = {
        & $ensureGuiRunspace
        while ($progressQueue.Count -gt 0) {
            $data = $progressQueue.Dequeue()
            switch ($data.Type) {
                "Status" {
                    $idx = $data.Index
                    if ($idx -lt $archiveItems.Count) {
                        $archiveItems[$idx].Status = $data.Text
                        $dgArchives.Items.Refresh()
                    }
                    $pbOverall.Value = $data.Overall
                    $txtOverallProgress.Text = "Processing archive $($idx + 1) / $($state.Total)"
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
                        & $appendLog "[$($data.Status)] $($item.Name) ($($data.Time))"
                    }
                    if ($data.OutputDir) {
                        $state.OutputFolders += $data.OutputDir
                    }
                }
                "Log" {
                    & $appendLog $data.Message
                }
                "Done" {
                    & $finishRun $data
                    return
                }
            }
        }
        # Backstop: if the pipeline ended without emitting a Done record (a hard
        # abort), finalize anyway so the UI never stays wedged in the running
        # state.
        if ($state.WorkerAsync -and $state.WorkerAsync.IsCompleted -and $progressQueue.Count -eq 0) {
            & $finishRun @{ Succeeded = 0; Failed = 0 }
        }
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
        $shared.CurrentSkipSource = $null
        $btnStart.IsEnabled = $false
        $btnCancel.IsEnabled = $true
        $btnSkip.IsEnabled = $true
        $btnOpenOutput.IsEnabled = $false
        $btnAddFiles.IsEnabled = $false
        $btnAddFolder.IsEnabled = $false
        $btnRemove.IsEnabled = $false
        $btnClear.IsEnabled = $false

        $total = $archiveItems.Count
        $state.Total = $total
        $progressQueue.Clear()

        # Everything the worker runspace needs, marshalled as plain data.
        $ctx = @{
            Items              = $archives
            CancelToken        = $state.CancelSource.Token
            SeparateFolders    = $separateFolders
            CommonOutputDir    = $commonOutputDir
            UseCustomOutputDir = $useCustomOutputDir
            CustomOutputBase   = $customOutputBase
            Queue              = $progressQueue
            Shared             = $shared
            Paths              = @{
                ToolDir    = $ToolDir
                ModulesDir = $ModulesDir
                PwDir      = $PwDir
                PwFile     = $PwFile
                LogDir     = $LogDir
                ConfigFile = $ConfigFile
                CacheFile  = $CacheFile
                RunLogPath = $RunLogPath
                RunStamp   = $RunStamp
            }
            Overrides          = @{
                ExistingOutputBehavior = $ExistingOutputBehavior
                SevenZipOverwriteMode  = $SevenZipOverwriteMode
                WinRarOverwriteMode    = $WinRarOverwriteMode
            }
        }

        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = [System.Threading.ApartmentState]::MTA
        $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $rs.Open()

        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($extractionWorker).AddArgument($ctx)

        $state.Worker = $ps
        $state.WorkerRunspace = $rs
        $state.WorkerAsync = $ps.BeginInvoke()

        # Poll the worker's progress queue on the UI thread.
        $state.Timer = New-Object System.Windows.Threading.DispatcherTimer
        $state.Timer.Interval = [TimeSpan]::FromMilliseconds(120)
        $state.Timer.Add_Tick($drainProgress)
        $state.Timer.Start()
    })

    $btnCancel.Add_Click({
        if ($state.CancelSource) {
            $state.CancelSource.Cancel()
            $cur = $shared.CurrentSkipSource
            if ($cur) {
                try { $cur.Cancel() } catch {}
            }
            & $appendLog "Cancellation requested..."
            $btnCancel.IsEnabled = $false
        }
    })

    $btnSkip.Add_Click({
        if ($state.IsRunning) {
            $cur = $shared.CurrentSkipSource
            if ($cur) {
                try { $cur.Cancel() } catch {}
                & $appendLog "Skipping the current archive..."
            }
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
            $cur = $shared.CurrentSkipSource
            if ($cur) {
                try { $cur.Cancel() } catch {}
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

    # The window has closed. If a run was still in flight (the user closed
    # mid-extraction and confirmed), make sure the worker is cancelled and its
    # runspace disposed so nothing is left running in the background.
    if ($state.Timer) { try { $state.Timer.Stop() } catch {} }
    if ($state.CancelSource) { try { $state.CancelSource.Cancel() } catch {} }
    $cur = $shared.CurrentSkipSource
    if ($cur) { try { $cur.Cancel() } catch {} }
    if ($state.Worker) {
        try { if ($state.WorkerAsync) { $state.Worker.EndInvoke($state.WorkerAsync) } } catch {}
        try { $state.Worker.Dispose() } catch {}
    }
    if ($state.WorkerRunspace) { try { $state.WorkerRunspace.Dispose() } catch {} }
}
