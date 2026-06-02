# CHANGELOG

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