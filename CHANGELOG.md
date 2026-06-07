# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- **`.tar.zst` (and other compound tar archives) now fully extract in one pass.**
  7-Zip and WinRAR peel only the outer compression layer of a `.tar.zst` /
  `.tar.gz` / `.tgz` / … archive, leaving an intermediate `.tar` behind. That
  leftover tarball is now extracted automatically *in place* — regardless of the
  `extractNestedArchives` setting — so the output folder holds the real contents
  instead of a stray `.tar`. The contents land directly in the cleanly-named
  output folder (no redundant `name\name` nesting).
- **Multi-part archives with non-dot separators are no longer extracted multiple
  times.** Sets named `Name_part1.rar`, `Name_part2.rar`, … (underscore, hyphen,
  or space before `part`, not just the WinRAR-default dot) were each treated as a
  separate standalone archive, producing one duplicate output folder per part and
  reporting the non-first parts as failures. Detection now recognizes a flexible
  separator: only the first volume is queued, and its output folder uses the clean
  base name.
- **No more WinRAR window popping up.** The console `UnRAR.exe` / `Rar.exe` are now
  preferred over the GUI `WinRAR.exe`; the startup engine smoke-test no longer
  launches `WinRAR.exe` with empty arguments (which opened its file-manager
  window), and if `WinRAR.exe` must be used it runs minimized in the background
  (`-ibck`).

### Added
- **Launch the WPF GUI straight from Explorer.** New *"Extract with GUI (password
  list)"* right-click entries (on archive files, folders, and folder backgrounds)
  open the windowed extractor with the right-clicked selection already queued, so
  you can review the list and click **Start Extraction**. The orchestrator gained a
  `-Gui` switch that forces GUI mode regardless of `preferGui`, and the GUI now
  accepts the launch selection instead of always opening empty.
- **GUI usability pass.** The archive list has a right-click context menu (open
  output folder, open file location, copy the recovered password, copy the archive
  path, remove from list), supports multi-select and a **Remove** button, opens a
  row's output folder on double-click, dedupes archives added more than once,
  keeps the index column renumbered, shows a live count, and adds an **Edit
  Passwords** button. The live log is now capped so very large batches don't bloat
  the UI, and the add/remove/clear controls are disabled while a run is in flight.
- **Close confirmation for the GUI** (`confirmGuiClose`, default `true`): closing
  the window asks first when archives are queued, and a close mid-run prompts before
  cancelling the in-flight extraction — so a stray click never silently discards a
  run or its results.
- **Choose how existing output is handled, each run** (`askOutputBehavior`): a
  prompt to overwrite, keep both (new `_2`/`_3` folder), or merge & skip duplicate
  files.
- **Post-extraction handling of the original archives** (`postExtractionAction`):
  leave them, delete the successfully-extracted ones, or sort them into
  `_Extracted` / `_Failed` folders — all volume parts are handled together.
- **Smarter multilayer nesting that stops at the payload.** The nested
  (recursive) extraction pass already tries the previously-successful password
  first and then the rest, so each layer of a nested archive can use a *different*
  password. A layer is now scanned for archives only while it has not yet produced
  an executable payload (`.exe`/`.msi`/`.com`/`.scr`) — once an executable appears
  it is treated as the intended final output and the pass stops descending there.
  This check is applied to the initial output folders as well as every deeper
  layer, so the very first layer that yields an executable ends the descent.
- **Keep the system awake during long runs** (`preventSleepDuringExtraction`): the
  machine no longer idle-sleeps mid-extraction (the display may still sleep).
- **Background-friendly engine priority** (`engineProcessPriority`): each
  extraction engine process (7-Zip / WinRAR / UnRAR) now runs at a configurable
  CPU/I-O priority — `Idle`, `BelowNormal` (new default), `Normal`, `AboveNormal`,
  or `High`. Lowering it stops a busy extraction from starving browsers, downloads
  writing to the same drive, and other apps; `Idle` additionally yields background
  disk-I/O priority on Windows. The setting is applied the moment each engine
  starts and propagates to every parallel worker.
- **Custom output folder names** (`folderNameRules`): regex search/replace rules
  that reshape the auto-derived output folder name, so publisher tags or other
  noise can be excluded or rewritten — e.g. `Nomachi-Ankergames.zip` extracts into
  a `Nomachi` folder. Each rule is a bare pattern (removed) or an object with
  `pattern` / `replacement` / `ignoreCase`; rules apply in order and an invalid
  pattern is logged and skipped instead of failing the run.
- A clearer progress indicator: it now shows elapsed time and a passwords/sec
  rate, and only shows a remaining-time estimate once the sample is large enough
  to be meaningful (instead of a misleading one-sample "~1s left").

## [4.1.1] - 2026-05-29

### Fixed
- **Parallel archive mode now caches found passwords.** The cache file path was
  never passed into the worker runspaces, so every cache write silently failed.
  `password-cache.txt` is now populated in parallel mode just like sequential.
- **Concurrency-safe password cache.** Cache read/modify/write is now serialized
  with a named, per-cache-file mutex (with graceful fallback), preventing
  duplicate entries or a clobbered file when multiple archives finish at once.
- **Parallel password-test logging no longer corrupts the run log.** Each
  password-test worker now writes to its own per-thread log that is merged at the
  end (matching the parallel-archive path) instead of all workers appending to
  the shared main log concurrently. `Write-Log` is also hardened to retry briefly
  and never throw, so a transient file lock can't abort a run.
- **Accurate failure reporting.** The previously-unused error classifier is now
  wired through every failure path, so timeouts, corrupt archives, missing
  volumes, permission errors, and engine faults are reported distinctly in the
  summary instead of all being labelled "Wrong password".
- A corrupt password-cache line with an unparseable timestamp now contributes
  only its password portion as a candidate, not the raw `timestamp|password` text.
- `Resolve-OutputDir` "replace" now warns when an existing output folder cannot
  be fully cleared, instead of silently mixing stale files into new output.

### Changed
- Parallel archive mode now reports found passwords and copies one to the
  clipboard (honoring `showPasswordInConsole`), matching sequential-mode behavior.

## [4.1.0] - 2026-05-29

### Added
- **Recursive nested-archive extraction.** After the main extraction pass, the
  tool can optionally scan each successful output folder for archives that were
  themselves extracted (e.g. a `.zip` containing `.rar` files) and extract them
  too, up to a configurable depth. Controlled by three new `config.json` settings:
  - `extractNestedArchives` (default `false`)
  - `maxNestedDepth` (default `1`, clamped to 1–10; `0` disables)
  - `deleteNestedArchiveAfterExtract` (default `false`)
  The nested pass reuses the parent run's password list and cache (trying the
  last successful password first), runs after both the sequential and parallel
  paths, and is guarded by a visited-path set to prevent runaway recursion. A
  dedicated "Nested archives" summary box reports found/extracted/failed counts.
- Single source of truth for the application version (`$AppVersion` in
  `Modules/Config.ps1`); all banners and log lines read from it.
- `CHANGELOG.md` and a tag-triggered GitHub release workflow that packages the
  scripts, modules, and resources into a downloadable ZIP.
- Pester coverage for the new `Find-NestedArchives` helper and the
  `maxNestedDepth` config clamping.

## [4.0.0] - 2026-05-29

### Added
- **Phase 2 — performance & scalability:** parallel archive processing and
  parallel password testing via runspace pools, cross-session password cache,
  session-local password reordering, header-based encryption detection,
  test-only-then-extract optimization, and large-archive strategies.
- **WPF GUI mode** with archive list, dual progress bars, live log viewer, and
  drag-and-drop, plus an interactive console browse interface and toast
  notifications.
- **Modular architecture** splitting the tool into focused module files.
- **Quality infrastructure:** a Pester test suite for the pure-logic modules,
  PSScriptAnalyzer linting, and a GitHub Actions CI matrix.

## [3.0.0] - 2026-05-28

### Added
- **Phase 1 — UX & observability:** interactive menu, ETA reporting, summary
  boxes, condensed logging that collapses repetitive wrong-password output, and
  toast notifications on batch completion.

## [2.0.0] - 2026-05-28

### Fixed
- **Phase 0 — critical correctness:** eliminated silent failures, added config
  validation and clamping, error classification (wrong password vs corrupt vs
  timeout vs missing volume), robust multi-volume validation, orphaned
  split-entry promotion, and safer command-line quoting.

## Planned
- Password hints derived from archive filename patterns.

[Unreleased]: https://github.com/erichuang1425/extract-with-passwords-extended/compare/v4.1.0...HEAD
[4.1.0]: https://github.com/erichuang1425/extract-with-passwords-extended/releases/tag/v4.1.0
[4.0.0]: https://github.com/erichuang1425/extract-with-passwords-extended/releases/tag/v4.0.0
[3.0.0]: https://github.com/erichuang1425/extract-with-passwords-extended/releases/tag/v3.0.0
[2.0.0]: https://github.com/erichuang1425/extract-with-passwords-extended/releases/tag/v2.0.0
