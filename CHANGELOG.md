# Changelog

## [0.1.0] - 2026-10-19

First public release.

- A one-line status line for Kimi Code on Windows: permission mode under Kimi Code's own names, model and thinking effort, folder, git branch, Kimi Code plan quota (5 hours and 7 days, with reset times), session time and lines changed.
- Renders in about 50 ms using bash builtins only. Fetching the quota and reading session logs happen in background processes.
- `install.ps1` and `uninstall.ps1` find Git Bash and jq, back up what they change, leave another tool's status line command alone unless given `-Force`, and restore it on uninstall. They run from a release zip or through `irm ... | iex`, in PowerShell 7 and Windows PowerShell 5.1.
- README in English and Chinese.
