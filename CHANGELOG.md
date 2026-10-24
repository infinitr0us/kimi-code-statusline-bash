# Changelog

## [Unreleased]

- Prompt-cache countdown at the end of the line, between turns: the minutes until Kimi Code's server drops the session's prompt cache (blue, yellow in the last 5 minutes, then `cold`), as the Claude Code status line has it. The duration per model is Kimi Code's own estimate, fetched once a day from its server without a token (Kimi Code's cached copy if that fails). The time of the last model call, whether a turn is running and model switches (which make it `cold`) come from the session log, so no hooks are needed.
- The quota reads like ccline 2 in Claude Code: the time left in the 5-hour window and the day and time the week resets (`5h 5% · 3h41m · 7d 52% · Sat 23:34`). It is refetched right after a window resets.
- Session caches written by 0.1.0 are rebuilt from the session log on the next scan. The quota cache changed format and is refetched at once.
- Fixed: after a session log record with a long run of emoji or other characters jq miscounts (it measured some lines a few bytes too long), the next record was skipped, and with it its changed lines. The script now counts the bytes it has read itself.
- Fixed: a usage report without the 5-hour window (or without a reset time) shifted the remaining numbers into the wrong places. Numbers read back from cache files must have no leading zeros (bash arithmetic would read them as octal).
- Kimi Code 2.3.1 runs the status line as 2.2.0 did.

## [0.1.0] - 2026-10-19

First public release.

- A one-line status line for Kimi Code on Windows: permission mode under Kimi Code's own names, model and thinking effort, folder, git branch, Kimi Code plan quota (5 hours and 7 days, with reset times), session time and lines changed.
- Renders in about 50 ms using bash builtins only. Fetching the quota and reading session logs happen in background processes.
- `install.ps1` and `uninstall.ps1` find Git Bash and jq, back up what they change, leave another tool's status line command alone unless given `-Force`, and restore it on uninstall. They run from a release zip or through `irm ... | iex`, in PowerShell 7 and Windows PowerShell 5.1.
- README in English and Chinese.
