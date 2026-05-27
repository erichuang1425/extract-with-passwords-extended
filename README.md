# Extract with Passwords Extended

Windows context-menu tool for extracting encrypted archives using a password list. Supports multiple extraction engines with automatic fallback.

## Features

- **Multi-engine support** — 7-Zip, WinRAR/UnRAR, and PeaZip's bundled 7z with automatic fallback chain
- **Windows context menu integration** — right-click any archive to extract with password list
- **Batch folder processing** — right-click a folder to scan and extract all archives inside
- **Format-aware password testing** — non-encryption formats (tar, gz, cab, iso, etc.) skip password cycling entirely and extract directly
- **Header-based encryption detection** — inspects archive headers to skip password cycling on unencrypted .zip/.rar/.7z files
- **Test-only-then-extract** — finds the correct password via lightweight test commands, then extracts once (faster than test+extract per password)
- **Password cache** — remembers successful passwords across sessions; tries cached passwords first
- **Session-local password reordering** — when batch-extracting, the last successful password is tried first on the next archive
- **Multiple password files** — optionally load passwords from all .txt files in the password directory
- **Split/multi-volume archive support** — `.001`, `.part01.rar`, and other split formats auto-detected with volume completeness validation
- **Large archive strategies** — detects large archives and adjusts strategy to avoid repeated disk writes
- **Custom output directory** — configurable default extraction destination
- **External JSON configuration** — settings stored in `config.json` that survive reinstalls
- **Masked password display** — found passwords are masked in console output by default; full password copied to clipboard with auto-clear
- **Interactive browse interface** — file/folder browser when launched without arguments
- **Toast notifications** — Windows notification when batch extraction completes
- **Send To shortcut** — drag-and-drop archives via the Windows Send To menu
- **Windows 11 classic menu opt-in** — installer offers to restore the classic right-click menu
- **Engine validation** — smoke-tests detected engines before use to avoid broken installations
- **Locked file detection** — checks if archives are accessible before attempting extraction
- **ETA reporting** — progress bar with estimated time remaining during password testing
- **Detailed logging** — every run produces a timestamped diagnostic log with partial output on timeouts
- **Robust installer** — reports which context menu registrations succeeded or failed

## Requirements

- **Windows 10 or 11**
- **PowerShell 3.0+** (5.0+ recommended for clipboard features and toast notifications)
- At least one extraction engine installed:
  - [7-Zip](https://www.7-zip.org/) (recommended)
  - [WinRAR](https://www.win-rar.com/)
  - [PeaZip](https://peazip.github.io/) (uses its bundled 7z.exe)

## Installation

1. Download `Install-ArchivePwExtract.ps1`
2. Right-click the file and select **Run with PowerShell**
   - Or run from a PowerShell prompt: `powershell -ExecutionPolicy Bypass -File Install-ArchivePwExtract.ps1`
3. The installer will:
   - Create the helper script at `%LOCALAPPDATA%\ArchivePwExtract\TryPwExtract.ps1`
   - Create a default `config.json` (if one doesn't exist)
   - Register Windows Explorer context menu entries for all supported archive types
   - Create a Send To shortcut
   - Create a password list template (if one doesn't exist) and open it in Notepad
   - On Windows 11: optionally restore the classic right-click menu
   - Display a registration summary showing which steps succeeded

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

## Known Limitations

- **PeaZip Password Manager**: The script cannot read passwords saved in PeaZip's built-in Password Manager. If PeaZip opens a failed archive using a saved password, copy that password into your password list file.
- **Password file is plaintext**: The `passwords.txt` file is stored unencrypted in your Documents folder.
- **Clipboard exposure**: Even with auto-clear, the matched password is briefly in the clipboard between discovery and script exit.
- **No archive creation**: This tool is extraction-only.
- **Toast notifications**: Require PowerShell 5.0+ and Windows 10+. Silently skipped if unavailable.

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

Each run creates a timestamped log file with full command-line output from extraction engines (passwords are redacted in logs). Process timeouts capture partial output for diagnostic purposes.

## License

[MIT](LICENSE)
