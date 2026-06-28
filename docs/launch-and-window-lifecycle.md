# Launch & window lifecycle

How the tool is started from Windows Explorer, why a window never just "flashes
and disappears," and how each window closes with a confirmation.

## The problem this solves

Every Explorer right-click verb runs a command line, and
`powershell.exe -File TryPwExtract.ps1 …` **always creates a console host
window**. That caused two bad behaviors:

1. **A console flashed even when the GUI was wanted.** `TryPwExtract.ps1`
   dot-sources all of its modules and reads `config.json` at the very top — in
   the console window — *before* it decides whether to show the GUI. So even a
   "GUI" launch showed a terminal first.
2. **Early failures vanished silently.** Module loading and `Read-Config` run
   *before* the main `try/catch`. If anything there threw (a half-updated
   install, a missing module, …), the script died before reaching any pause, so
   the console just closed instantly — no message, no confirmation, no GUI.

## The launch model

Two right-click entries are registered per archive type / folder / folder
background:

| Entry (primary first)                     | Verb key                       | Command |
|-------------------------------------------|--------------------------------|---------|
| **Extract with password list** (GUI)      | `ArchivePwExtract*`            | `wscript.exe "…\LaunchGui.vbs" "%1"` |
| **Extract in console (password list)**    | `ArchivePwExtract*Console`    | `powershell.exe … -File "…\TryPwExtract.ps1" "%1"` |

### GUI path — no console window

`LaunchGui.vbs` is a tiny windowless [Windows Script Host] shim the installer
writes next to `TryPwExtract.ps1`. It starts PowerShell **fully hidden** and
detached:

```vbs
helper = fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), "TryPwExtract.ps1")
ps = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & helper & """ -Gui"
' … append each selected path …
sh.Run ps, 0, False          ' window style 0 = hidden, no console flash
```

Because `wscript.exe` is itself windowless and starts PowerShell with window
style `0`, **no console appears at all** — the WPF window is the only thing the
user sees. The shim resolves `TryPwExtract.ps1` relative to its own location, so
its body is static ASCII and works even when the install path contains non-ASCII
characters.

`TryPwExtract.ps1 -Gui` loads the modules (hidden) and calls
`Show-ExtractionGui -InitialPaths <selection>`, so the window opens with the
right-clicked files/folder already queued.

### Console path — text-mode flow

The secondary entry is the original console experience for users who prefer it
(or when WPF isn't available, e.g. PowerShell < 5).

## Window lifecycle — "close with confirmation"

| Surface | Closes with confirmation by… |
|---------|------------------------------|
| **GUI window** | `Add_Closing` handler. With archives queued it asks *"Close the Archive Password Extractor?"*; mid-run it asks *"Cancel it and close the window?"* and only then cancels the worker. Gated by `confirmGuiClose` (default `true`). |
| **GUI, fatal startup error** | `Invoke-FatalExit` shows a WinForms **MessageBox** (there is no console to read from when launched hidden). |
| **Console, normal end** | `Pause-Close` ("Press Enter to close") when `alwaysShowFinalConfirmation` is `true`. |
| **Console, any early/fatal error** | A script-level `trap` (and the main `catch`) calls `Invoke-FatalExit`, which prints the error and waits on `Read-Host` — so a context-menu console launch can no longer flash and vanish. |

The key fix for the "it only flashed a terminal" report is the **`trap` placed
above module loading**: it catches terminating errors that occur *outside* the
main `try/catch` (module load, `Read-Config`) and routes them through
`Invoke-FatalExit` instead of letting the window close unannounced.

## Running a scan — threading model

The window pumps WPF messages on the UI thread, so the extraction work has to run
off-thread. A `BackgroundWorker` **cannot** be used here: its `DoWork` event
fires on a thread-pool thread that owns no PowerShell runspace, and PowerShell
fails *while invoking the `DoWork` script-block delegate* with "There is no
Runspace available to run scripts in this thread" — before any statement inside
the handler (even one that tries to install a runspace) gets a chance to run. So
a `BackgroundWorker`-based GUI can never start a scan.

Instead, **Start** opens a dedicated runspace and drives it with
`[PowerShell].BeginInvoke()`:

| Piece | Thread | Why it's safe |
|-------|--------|---------------|
| `$extractionWorker` | dedicated runspace | `BeginInvoke` makes that runspace the executing thread's default for the whole pipeline, so every dot-sourced engine/password function runs normally. The block re-bootstraps the modules + `config.json` in its own runspace and receives all paths/choices through a single `$ctx` argument. |
| progress reporting | dedicated → UI | The worker only enqueues plain hashtables onto a `Queue::Synchronized` and publishes the current archive's skip `CancellationTokenSource` onto a `Hashtable::Synchronized`. It never calls a WPF control or invokes a script block on the UI thread. |
| `$drainProgress` | UI thread (DispatcherTimer) | A `DispatcherTimer` tick drains the queue and applies every UI change. It runs on the UI thread, which owns the GUI runspace, so the control updates are valid. |
| Skip / Cancel | UI thread | The buttons read the published skip source and call `.Cancel()` (thread-safe). |

There is therefore **no cross-runspace script-block marshalling anywhere** — the
single failure mode that kept the old GUI from starting a scan is structurally
impossible. When the run finishes (or the window closes mid-run) the worker is
cancelled, `EndInvoke` reaps it, and the runspace is disposed.

## Uninstall

The uninstaller removes both the primary (`ArchivePwExtract*`) and secondary
(`ArchivePwExtract*Console`) verbs, any legacy `…Gui` verbs from earlier builds,
and `LaunchGui.vbs`.

[Windows Script Host]: https://learn.microsoft.com/en-us/previous-versions/windows/internet-explorer/ie-developer/scripting-articles/9bbdkx3k(v=vs.84)
