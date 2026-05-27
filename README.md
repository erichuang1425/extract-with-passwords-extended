# Extract with Passwords Extended

Windows context-menu tool for extracting encrypted archives using a password list. Supports multiple extraction engines with automatic fallback.

## Features

- **Multi-engine support** — 7-Zip, WinRAR/UnRAR, and PeaZip's bundled 7z with automatic fallback chain
- **Windows context menu integration** — right-click any archive to extract with password list
- **Batch folder processing** — right-click a folder to scan and extract all archives inside
- **Format-aware password testing** — non-encryption formats (tar, gz, cab, iso, etc.) skip password cycling entirely and extract directly
- **Split/multi-volume archive support** — `.001`, `.part01.rar`, and other split formats auto-detected
- **Masked password display** — found passwords are masked in console output by default; full password copied to clipboard with auto-clear
- **Send To shortcut** — drag-and-drop archives via the Windows Send To menu
- **Detailed logging** — every run produces a timestamped diagnostic log

## Requirements

- **Windows 10 or 11**
- **PowerShell 3.0+** (5.0+ recommended for clipboard features)
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
   - Register Windows Explorer context menu entries for all supported archive types
   - Create a Send To shortcut
   - Create a password list template (if one doesn't exist) and open it in Notepad

## Usage

### Right-click an archive file

Right-click any supported archive and select **Try password list and extract**. The tool will try each password from your list until one works.

### Right-click a folder

Right-click a folder and select **Extract archives with password list** to scan and extract all archives inside (with optional recursive scanning).

### Edit your password list

Right-click any folder background and select **Edit archive password list** to open the password file in Notepad. Add one password per line. Lines starting with `#` are ignored.

### Password file location

The password list is stored at:
```
<Documents>\ArchivePwExtract\passwords.txt
```

## Configuration

The helper script (`%LOCALAPPDATA%\ArchivePwExtract\TryPwExtract.ps1`) contains user-editable variables near the top:

| Variable | Default | Description |
|----------|---------|-------------|
| `$TryNoPasswordFirst` | `$true` | Try extracting without a password before cycling the list |
| `$AskBeforeExtracting` | `$true` | Prompt for confirmation before starting extraction |
| `$AskSeparateFolders` | `$true` | Ask whether to use separate output folders per archive |
| `$DefaultSeparateFolders` | `$true` | Default answer for separate folders prompt |
| `$ExistingOutputBehavior` | `"replace"` | How to handle existing output: `replace`, `merge`, or `new` |
| `$SevenZipOverwriteMode` | `"aoa"` | 7-Zip overwrite mode (`aoa` = overwrite all) |
| `$WinRarOverwriteMode` | `"-o+"` | WinRAR overwrite mode (`-o+` = overwrite all) |
| `$UseSevenZip` | `$true` | Enable 7-Zip as an extraction engine |
| `$UseWinRarFallback` | `$true` | Enable WinRAR/UnRAR as a fallback engine |
| `$UsePeaZipBundled7zFallback` | `$true` | Enable PeaZip's bundled 7z as a fallback engine |
| `$TryExtractEvenIfTestFails` | `$true` | Attempt extraction even if integrity test reports failure |
| `$CleanFailedAttemptOutput` | `$true` | Delete output from failed extraction attempts |
| `$ShowPasswordInConsole` | `$false` | Show the full matched password in console (masked by default) |
| `$ClearClipboardOnExit` | `$true` | Clear clipboard when the script finishes |
| `$OpenOutputAfterSuccess` | `$true` | Offer to open the output folder when done |
| `$AlwaysShowFinalConfirmation` | `$true` | Show summary and wait for Enter before closing |

## Supported Formats

### Encryption-capable formats (password list is cycled)

| Format | 7-Zip | WinRAR | UnRAR |
|--------|-------|--------|-------|
| `.zip` / `.zipx` | Yes | Yes | No |
| `.7z` | Yes | No | No |
| `.rar` | Yes | Yes | Yes |

Split variants (`.zip.001`, `.7z.001`, `.rar.001`, `.part01.rar`) are also supported.

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

The script auto-detects installed engines from common installation paths and PATH.

## Known Limitations

- **Windows 11 context menu**: Menu entries appear under **Show more options** (the classic right-click menu). Use `Shift`+Right-click to access directly. This is a Windows 11 limitation for registry-based context menus.
- **PeaZip Password Manager**: The script cannot read passwords saved in PeaZip's built-in Password Manager. If PeaZip opens a failed archive using a saved password, copy that password into your password list file.
- **Sequential testing**: Passwords are tried one at a time. Large password lists against many archives will be slow.
- **Password file is plaintext**: The `passwords.txt` file is stored unencrypted in your Documents folder.
- **Clipboard exposure**: Even with auto-clear, the matched password is briefly in the clipboard between discovery and script exit.
- **No archive creation**: This tool is extraction-only.

## Uninstallation

Run the uninstall script:

```
%LOCALAPPDATA%\ArchivePwExtract\Uninstall-ArchivePwExtract.ps1
```

Right-click and select **Run with PowerShell**. This removes all context menu entries and the Send To shortcut. Your password file and log folder are preserved.

## Log Files

Diagnostic logs are saved to:

```
%LOCALAPPDATA%\ArchivePwExtract\Logs\
```

Each run creates a timestamped log file with full command-line output from extraction engines (passwords are redacted in logs).

## License

[MIT](LICENSE)
