# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
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
- **Choose how existing output is handled, each run** (`askOutputBehavior`): a
  prompt to overwrite, keep both (new `_2`/`_3` folder), or merge & skip duplicate
  files.
- **Post-extraction handling of the original archives** (`postExtractionAction`):
  leave them, delete the successfully-extracted ones, or sort them into
  `_Extracted` / `_Failed` folders — all volume parts are handled together.
- **Keep the system awake during long runs** (`preventSleepDuringExtraction`): the
  machine no longer idle-sleeps mid-extraction (the display may still sleep).
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
