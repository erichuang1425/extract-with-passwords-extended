# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
