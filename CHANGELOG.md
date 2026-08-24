# CHANGELOG

## [2.1.0] - 2026-08-10

### Fixed
- **New packages detection restored:** `brew update` output is now captured with `2>&1`. Since Homebrew 4.1+, when stdout is not a TTY the whole update report (`==> New Formulae`, `==> New Casks`, …) is written to **stderr**, so redirecting stderr to the log file made the parser find zero new packages. A failed `brew update` is now detected and logged too.
- Section headers in the package extractor are matched strictly (`==> New Formulae`), so descriptions merely mentioning the section title can no longer swallow or leak package entries.

### Changed
- **Dashboard redesign ("Aurora Glass"):** fully rebuilt interactive landing page in `generate_landing_page`.
  - Animated aurora background with glassmorphism surfaces and a sticky glass top bar.
  - Animated count-up metric cards and an SVG donut chart with per-category breakdown and legend.
  - Filter pills with live counts, search box with `/` shortcut and `Esc` to clear.
  - Package cards with gradient avatars, animated version transition (`old ⟶ new`), staggered entrance animations.
  - "Copy all commands" bulk action, robust clipboard fallback for `file://`, and toast notifications.
  - Dedicated empty states (celebration when up-to-date, hints when filters match nothing).
  - Honors `prefers-reduced-motion` and is fully responsive.
  - HTML emission rewritten with quoted heredocs (no more shell-escaping of backticks/`${}` inside the JS).
  - Compact overview: slimmer metric cards and donut panel with grid legend; with zero packages the donut/controls are hidden and a floating celebration panel is shown instead of empty widget space.

## [2.0.0] - 2026-07-26

### Added
- **Interactive HTML Dashboard:** Added `generate_landing_page` function which automatically builds and opens a modern HTML dashboard (`/tmp/brew-update-landing.html`) in default browser.
  - Real-time search filter by package name or description.
  - Category filtering tabs (All, Outdated Formulae/Casks, New Formulae/Casks).
  - Version transition badges (`old → new`) for outdated packages.
  - Direct links to Homepage and automatically generated GitHub Release/Changelog links.
  - One-click copy buttons for `brew upgrade` / `brew install` commands.
- **Command-line Flags:**
  - `-y`, `--yes`: Automatically perform `brew upgrade` without prompting.
  - `-h`, `--help`: Display usage information.
- **Visual Progress:** Added interactive visual spinner animation during `brew update`.
- **Version 2 Entry Script:** Created `brew_upgrade_tracker_v2.sh` with updated architecture and embedded interactive UI dashboard.

### Changed
- **Log Management:** Log files are now automatically cleaned up on exit if no errors were recorded during script execution.
- **Bulk JSON Handling:** Streamlined single-pass bulk metadata aggregation using `jq` and `brew info --json=v2`.

## [1.1.0] - 2026-05-27

### Added
- `process_packages` function for bulk handling of Homebrew API calls.
- Automatic cleanup of tap names (e.g., `tap/name`) from new casks before fetching information.

### Changed
- **Performance:** Replaced slow individual `while` loops with bulk processing via `xargs` and `jq` for `brew info`, drastically reducing execution times.
- The `brew outdated` command now uses native `--json=v2` output instead of fragile textual parsing via `sed`, making the script much more robust to future Homebrew updates.

### Removed
- Removed the `safe_jq_parse` function as it is now natively replaced by optimized `jq` queries in bulk processing.

## 2026-05-24 — Major improvements

- Fix: Precise extraction of *New Formulae* and *New Casks* from `brew update` output (limits section until next `==>`).
- Fix: Normalization of names (removal of `:` suffixes and descriptions after `:` for casks; removal of versions in parentheses from `brew outdated`).
- Improvement: Running `brew update` in background with progress indicator; output captured to temporary file for more reliable parsing.
- Fix: Simplified information retrieval process — for each package, `brew info --json=v2` is used and `homepage`/`desc` are read directly (more robust than building large JSON arrays).
- Fix: Improved message/log handling (`printf` instead of `echo -e`) and better handling of non-critical errors.
- Removal: Removed costly `brew search` calls for complete list comparison (faster and less fragile).
- Cleanup: Removed debug scripts and temporary test files from workspace.

### Why these changes
The changes aim to make the script more reliable in parsing Homebrew output, reduce false positives (wrong names in "New" sections), and show real homepage/descriptions for packages when available. Some trade-offs: the new strategy calls `brew info` for each package (slightly slower), but is more robust.

---

Relevant files modified: `brew_upgrade_tracker.sh` (several revisions between 2025 and 2026).

(Automatically added commit on 2026-05-24)