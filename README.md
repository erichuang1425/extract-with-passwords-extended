# Extract with Passwords Extended

[![CI](https://github.com/erichuang1425/extract-with-passwords-extended/actions/workflows/ci.yml/badge.svg)](https://github.com/erichuang1425/extract-with-passwords-extended/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/erichuang1425/extract-with-passwords-extended?sort=semver)](https://github.com/erichuang1425/extract-with-passwords-extended/releases/latest)

Windows context-menu tool for extracting encrypted archives using a password list. Supports multiple extraction engines with automatic fallback.

## Features

### Core
- **Multi-engine support** — 7-Zip, WinRAR/UnRAR, and PeaZip's bundled 7z with automatic fallback chain
- **Windows context menu integration** — right-click any archive to extract with password list
- **Batch folder processing** — right-click a folder to scan and extract all archives inside
- **Format-aware password testing** — non-encryption formats (tar, gz, cab, iso, etc.) skip password cycling entirely
- **Header-based encryption detection** — inspects archive headers to skip password cycling on unencrypted archives
- **Test-only-then-extract** — finds the correct password via lightweight test commands, then extracts once
- **Recursive nested-archive extraction** — optionally extracts archives found inside extracted output (e.g. a `.zip` containing `.rar` files), bounded by a configurable depth and reusing the parent's password
- **Error classification** — distinguishes wrong password vs corrupt archive vs timeout vs missing volume

### GUI
- **WPF GUI mode** — native Windows GUI with archive list, dual progress bars, live log viewer, and drag-and-drop
- **Interactive browse interface** — file/folder browser when launched without arguments
- **Toast notifications** — Windows notification when batch extraction completes

### Performance
- **Parallel archive processing** — process multiple archives concurrently via runspace pools
- **Parallel password testing** — test multiple passwords simultaneously against a single archive
- **Password cache** — remembers successful passwords across sessions; tries cached passwords first
- **Session-local password reordering** — last successful password is tried first on the next archive
- **Large archive strategies** — detects large archives and adjusts strategy to avoid repeated disk writes

### Logging
- **Condensed logging** — suppresses repetitive "Wrong password" errors from engine output into a single summary line
- **Structured per-attempt logs** — one line per password attempt instead of full engine dumps
- **Verbose mode** — `verboseEngineLogging` config option restores full engine output when needed

### Other
- **Modular architecture** — separate module files for maintainability
- **Split/multi-volume archive support** — `.001`, `.part01.rar`, and other split formats with volume validation
- **External JSON configuration** — settings stored in `config.json` that survive reinstalls
- **Masked password display** — found passwords are masked in console output by default
- **Send To shortcut** — drag-and-drop archives via the Windows Send To menu
- **Robust installer** — reports which context menu registrations succeeded or failed

## Requirements

- **Windows 10 or 11**
- **PowerShell 3.0+** (5.0+ recommended for clipboard features and toast notifications)
- At least one extraction engine installed:
  - [7-Zip](https://www.7-zip.org/) (recommended)
  - [WinRAR](https://www.win-rar.com/)
  - [PeaZip](https://peazip.github.io/) (uses its bundled 7z.exe)

## Installation

1. Download and extract the latest release ZIP from the [Releases page](https://github.com/erichuang1425/extract-with-passwords-extended/releases/latest) (or clone this repository)
2. Right-click `Install-ArchivePwExtract.ps1` and select **Run with PowerShell**
   - Or run from a PowerShell prompt: `powershell -ExecutionPolicy Bypass -File Install-ArchivePwExtract.ps1`
3. The installer will:
   - Copy the orchestrator and module files to `%LOCALAPPDATA%\ArchivePwExtract\`
   - Copy the WPF GUI resources
   - Create a default `config.json` (if one doesn't exist)
   - Register Windows Explorer context menu entries for all supported archive types
   - Create a Send To shortcut
   - Create a password list template (if one doesn't exist) and open it in Notepad
   - On Windows 11: optionally restore the classic right-click menu
   - Display a registration summary showing which steps succeeded

### Project structure

```
Install-ArchivePwExtract.ps1    # Installer (run this)
TryPwExtract.ps1                # Main orchestrator
Modules/
  Config.ps1                    # Configuration defaults and JSON reader
  Logging.ps1                   # Log writing, process invocation, output condensing
  ConsoleUI.ps1                 # Console formatting, progress bars, interactive menu
  ArchiveUtils.ps1              # Archive detection, validation, output management
  Extraction.ps1                # Engine detection, test/extract, error classification
  Passwords.ps1                 # Password loading, caching, deduplication
  NestedExtraction.ps1          # Recursive nested-archive extraction post-pass
  Parallel.ps1                  # Runspace pool management for concurrency
  WpfGui.ps1                    # WPF GUI window management
Resources/
  MainWindow.xaml               # WPF window layout definition
CHANGELOG.md                    # Release history (Keep a Changelog format)
```

See [CHANGELOG.md](CHANGELOG.md) for the release history.

## Usage

### Right-click an archive file

Right-click any supported archive and select **Try password list and extract**. The tool will try each password from your list until one works.

### Right-click a folder

Right-click a folder and select **Extract archives with password list** to scan and extract all archives inside (with optional recursive scanning).

### Edit your password list

Right-click any folder background and select **Edit archive password list** to open the password file in Notepad. Add one password per line. Lines starting with `#` are ignored.

### Edit configuration

Right-click any folder background and select **Edit archive extractor config** to open `config.json` in Notepad.

### Launch without arguments

Double-click the helper script or run it without arguments to get an interactive menu:
- Browse for archive(s) to extract
- Browse for a folder to scan
- Edit password list
- Open settings
- View recent logs
- Launch GUI mode

### Password file location

The password list is stored at:
```
<Documents>\ArchivePwExtract\passwords.txt
```

Additional `.txt` files in the same directory are loaded when `loadAllPasswordFiles` is enabled in config.

### Password cache

Successful passwords are automatically cached at:
```
%LOCALAPPDATA%\ArchivePwExtract\password-cache.txt
```

Cached passwords are tried first on subsequent runs. Cache entries expire after 90 days (configurable).

## Configuration

Settings are stored in `%LOCALAPPDATA%\ArchivePwExtract\config.json` and survive reinstalls. The helper script reads this file at startup and falls back to defaults for any missing keys.

| Setting | Default | Description |
|---------|---------|-------------|
| `tryNoPasswordFirst` | `true` | Try extracting without a password before cycling the list |
| `askBeforeExtracting` | `true` | Prompt for confirmation before starting extraction |
| `askSeparateFolders` | `true` | Ask whether to use separate output folders per archive |
| `defaultSeparateFolders` | `true` | Default answer for separate folders prompt |
| `existingOutputBehavior` | `"replace"` | How to handle existing output: `replace`, `merge`, or `new` |
| `sevenZipOverwriteMode` | `"aoa"` | 7-Zip overwrite mode (`aoa` = overwrite all) |
| `winRarOverwriteMode` | `"-o+"` | WinRAR overwrite mode (`-o+` = overwrite all) |
| `useSevenZip` | `true` | Enable 7-Zip as an extraction engine |
| `useWinRarFallback` | `true` | Enable WinRAR/UnRAR as a fallback engine |
| `usePeaZipBundled7zFallback` | `true` | Enable PeaZip's bundled 7z as a fallback engine |
| `tryExtractEvenIfTestFails` | `true` | Attempt extraction even if integrity test reports failure |
| `cleanFailedAttemptOutput` | `true` | Delete output from failed extraction attempts |
| `showPasswordInConsole` | `false` | Show the full matched password in console (masked by default) |
| `clearClipboardOnExit` | `true` | Clear clipboard when the script finishes |
| `openOutputAfterSuccess` | `true` | Offer to open the output folder when done |
| `alwaysShowFinalConfirmation` | `true` | Show summary and wait for Enter before closing |
| `extractionTimeoutSeconds` | `300` | Per-process timeout in seconds (0 = no timeout) |
| `logRetentionDays` | `30` | Auto-delete logs older than N days (0 = keep all) |
| `usePasswordCache` | `true` | Remember successful passwords across sessions |
| `passwordCacheRetentionDays` | `90` | Auto-delete cache entries older than N days |
| `loadAllPasswordFiles` | `false` | Load passwords from all .txt files in the password directory |
| `checkEncryptionBeforeCycling` | `true` | Inspect archive headers before cycling passwords |
| `testOnlyFirst` | `true` | Use test-only phase to find password, then extract once |
| `defaultOutputDirectory` | `""` | Default output directory (empty = extract beside archive) |
| `alwaysAskOutputDirectory` | `false` | Always prompt for output directory before extraction |
| `showToastNotification` | `true` | Show Windows toast notification on batch completion |
| `largeArchiveThresholdMB` | `500` | Archives above this size trigger large archive mode |
| `skipTestExtractFallbackForLargeArchives` | `true` | Skip extract fallback for large archives when test fails |
| `verboseEngineLogging` | `false` | Log full engine output instead of condensed summaries |
| `maxParallelArchives` | `1` | Number of archives to process concurrently (1 = sequential) |
| `maxParallelPasswords` | `1` | Number of passwords to test concurrently per archive |
| `maxArchivesPerScan` | `0` | Cap on archives detected per folder scan (0 = unbounded). Stops recursive enumeration early on huge directories. |
| `preferGui` | `false` | Launch WPF GUI instead of console mode (requires PS 5.1+) |
| `extractNestedArchives` | `false` | After extraction, scan output folders and extract archives found inside them |
| `maxNestedDepth` | `1` | How many levels of nesting to recurse into (0 disables; clamped to 1–10) |
| `deleteNestedArchiveAfterExtract` | `false` | Delete a nested archive file after it is successfully extracted (applies to archives found *inside* output, not the original inputs) |
| `askOutputBehavior` | `true` | Prompt each run to choose how existing extracted folders are handled: overwrite, keep both, or merge & skip duplicates |
| `postExtractionAction` | `"prompt"` | What to do with the original source archives after a run: `none`, `prompt`, `delete` (successful sets, all volume parts), or `sort` (move into `_Extracted` / `_Failed`) |
| `postExtractionSilent` | `false` | When `postExtractionAction` is `delete`, skip the confirmation prompt |
| `preventSleepDuringExtraction` | `true` | Keep the system awake (no idle-sleep) while extraction is running; the display is allowed to sleep |

## Supported Formats

### Encryption-capable formats (password list is cycled)

| Format | 7-Zip | WinRAR | UnRAR |
|--------|-------|--------|-------|
| `.zip` / `.zipx` | Yes | Yes | No |
| `.7z` | Yes | No | No |
| `.rar` | Yes | Yes | Yes |

Split variants (`.zip.001`, `.7z.001`, `.rar.001`, `.part01.rar`) are also supported. Multi-volume archives are validated for completeness before extraction.

### Non-encryption formats (extracted directly, no password cycling)

| Format | 7-Zip | WinRAR | UnRAR |
|--------|-------|--------|-------|
| `.tar` | Yes | No | No |
| `.tar.gz` / `.tgz` | Yes | No | No |
| `.tar.bz2` / `.tbz2` | Yes | No | No |
| `.tar.xz` / `.txz` | Yes | No | No |
| `.tar.zst` / `.tzst` | Yes | No | No |
| `.gz` / `.bz2` / `.xz` / `.zst` | Yes | No | No |
| `.cab` | Yes | No | No |
| `.iso` / `.wim` / `.img` / `.dmg` | Yes | No | No |

Compound tar archives (`.tar.zst`, `.tar.gz`, `.tgz`, …) are two-layer: 7-Zip/WinRAR peel the outer compression to an intermediate `.tar`, which the script then extracts **in place** automatically (independent of the nested-extraction setting), so the output folder holds the real contents — not a leftover `.tar`, and with no redundant `name\name` subfolder.

## Engine Priority

Engines are tried in this order for each archive:

1. **7-Zip** — primary engine; supports all formats
2. **WinRAR** — fallback for `.zip`, `.7z`, `.rar`, and other formats it supports. **UnRAR** is RAR-only and will not be used for non-RAR formats.
3. **PeaZip bundled 7z** — fallback using PeaZip's included 7z.exe (only if different from standalone 7-Zip)

The script auto-detects installed engines from common installation paths and PATH. Each detected engine is validated with a smoke test before use.

## Performance Optimizations

### Test-only-then-extract

When `testOnlyFirst` is enabled (default), the script tests passwords using lightweight `7z t` or `unrar t` commands without writing any files. Once the correct password is found, a single extraction is performed. This eliminates repeated directory creation and cleanup for each failed password attempt.

### Password caching

Successful passwords are cached in `password-cache.txt`. On subsequent runs, cached passwords are tried first, before the main password list. Cache entries expire after a configurable number of days.

### Session-local reordering

During batch extraction, the most recently successful password is automatically moved to the front of the list for the next archive. This makes batch extraction of archives with the same password nearly instant.

### Header-based encryption detection

For encryption-capable formats (.zip, .rar, .7z), the script inspects the archive header using `7z l -slt` to determine if files are actually encrypted. Unencrypted archives in these formats skip password cycling entirely.

### Large archive mode

Archives above the configured threshold (default 500 MB) skip the extract-even-if-test-fails fallback to avoid expensive failed extraction attempts.

### Parallel processing

Set `maxParallelArchives` > 1 to process multiple archives concurrently using PowerShell runspace pools. Set `maxParallelPasswords` > 1 to test multiple passwords simultaneously against each archive. Both use cancellation tokens to stop work as soon as a match is found. Start with conservative values (2-4) to avoid I/O saturation.

## Known Limitations

- **PeaZip Password Manager**: The script cannot read passwords saved in PeaZip's built-in Password Manager. If PeaZip opens a failed archive using a saved password, copy that password into your password list file.
- **Password file is plaintext**: The `passwords.txt` file is stored unencrypted in your Documents folder.
- **Clipboard exposure**: Even with auto-clear, the matched password is briefly in the clipboard between discovery and script exit.
- **No archive creation**: This tool is extraction-only.
- **Nested extraction is bounded and single-threaded**: When `extractNestedArchives` is enabled, the nested post-pass runs sequentially (regardless of `maxParallelArchives`), is capped by `maxNestedDepth`, and reuses the parent run's password list and cache. A visited-path guard prevents runaway recursion. Each layer is tried with the previously-successful password first and then the rest, so layers protected by **different** passwords are handled. The pass descends into a freshly-extracted layer only while it still contains a compressed file to peel and has not yet produced an executable payload (`.exe`/`.msi`/`.com`/`.scr`) — an executable is treated as the intended final output and stops further descent.
- **Toast notifications**: Require PowerShell 5.0+ and Windows 10+. Silently skipped if unavailable.

## Troubleshooting

### Corrupted config

If `config.json` becomes malformed (invalid JSON, out-of-range numeric values, unknown enum strings), the script prints `[!] Falling back to defaults due to invalid config.json` at startup and ignores all stored settings for that run. Out-of-range values for individual keys (e.g. negative timeouts, `maxParallelArchives` outside `[1, 32]`) are clamped to the valid range with a `[!]` warning rather than disabling the whole file.

To reset to defaults, delete the file:

```
%LOCALAPPDATA%\ArchivePwExtract\config.json
```

Re-run the installer (or just the helper script) to regenerate a fresh `config.json` with default values.

### Configuration combinations to avoid

Some combinations are valid JSON but produce undesirable behavior:

| Combination | Effect |
|---|---|
| `testOnlyFirst = false` + `tryExtractEvenIfTestFails = true` | Wasteful — every password attempt does a full extract; the test/extract fallback never kicks in because there is no test phase. |
| `checkEncryptionBeforeCycling = false` + `tryNoPasswordFirst = false` | Unencrypted-but-encryption-capable archives (a plain `.zip` with no password) get the full password list cycled against them even though they don't need any password. |
| `maxParallelPasswords > 1` + `testOnlyFirst = false` | Each worker writes extraction output to the same folder concurrently, racing each other. Parallel password testing is designed for the test-only path. |
| `maxParallelArchives > 1` + `alwaysAskOutputDirectory = true` | The script will still prompt once at startup, but interactive prompts inside parallel workers are not surfaced and may hang. |
| `usePasswordCache = false` + `passwordCacheRetentionDays > 0` | Retention setting has no effect; the cache file is never read or written. |

## Uninstallation

Run the uninstall script:

```
%LOCALAPPDATA%\ArchivePwExtract\Uninstall-ArchivePwExtract.ps1
```

Right-click and select **Run with PowerShell**. This removes all context menu entries, the Send To shortcut, and optionally reverses the Windows 11 classic menu restoration. Your password file, config file, and log folder are preserved.

## Log Files

Diagnostic logs are saved to:

```
%LOCALAPPDATA%\ArchivePwExtract\Logs\
```

Each run creates a timestamped log file. By default, repetitive engine errors (like "Wrong password" repeated per file) are condensed into a single summary line. Set `verboseEngineLogging` to `true` in config.json to restore full engine output. Passwords are always redacted in logs.

## Development / Testing

The pure-logic modules (config validation, password loading/caching, archive-name
detection, command-line quoting, and console formatting) are covered by a
[Pester](https://pester.dev) test suite under `Tests/`, and all scripts are linted
with [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer). Both run
automatically in CI (`.github/workflows/ci.yml`) on every push and pull request.

To run them locally on Windows (PowerShell 5.1 or PowerShell 7+):

```powershell
# One-time: install the tooling
Install-Module Pester -MinimumVersion 5.5.0 -Force -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Force

# Run the tests (writes testResults.xml + coverage.xml)
./Tests/PesterConfiguration.ps1

# Run the linter
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

Tests exercise individual functions by dot-sourcing only the Windows-independent
modules; the GUI (`WpfGui.ps1`), parallel runspaces (`Parallel.ps1`), and engine
invocation (`Extraction.ps1`) are out of scope for this suite.

## License

[MIT](LICENSE)
