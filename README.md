# kimi-code-statusline-bash

English | [中文](README.zh-CN.md)

A Claude Code style status line for [Kimi Code](https://www.kimi.com/code) on Windows and macOS. It replaces the first line of Kimi Code's footer with the things worth a glance while you work: the permission mode, model and thinking effort, folder, git branch, your plan quota, how long the session has run and how many lines it changed, and between turns, how long the server still keeps your prompt cache.

![The status line under Kimi Code's input box](assets/screenshot.png)

Inside a git repository and once a session has started, the branch, the session's time and changed lines, and the cache countdown join in:

```text
Ask When Needed | K3 · max | ~/Desktop/proj | main | 5h 5% · 3h41m · 7d 52% · Sat 23:34 | 1h23m +120/-45 | 24m
```

It is one bash script, the same on both systems: on Windows it runs on the bash that comes with Git for Windows, on macOS on the bash that comes with macOS. There is nothing to compile, and you can read and change all of it.

> Unofficial: this project is not affiliated with or endorsed by Moonshot AI.

## What it shows

| Part | Shows | Details |
|---|---|---|
| Permission mode | `Always Ask`, `Ask When Needed` or `Never Ask`, plus `plan` in plan mode | Kimi Code's own names for its modes, in green, yellow and red: the more that runs without asking, the warmer the color. |
| Model | model and thinking effort | The effort comes from the session's log (the one really in use), or from `config.toml` until the session has one. |
| Folder | working folder | `~` stands for your user folder; long paths keep their last three folders. |
| Git | current branch | Hidden outside a git repository. |
| Quota | 5-hour and 7-day use of your Kimi Code plan: the time left until the 5-hour window resets, and the day and time the week resets | Green below 60%, yellow below 85%, red above. Refreshed every 5 minutes in the background (and right after a window resets) and greyed out when the last refresh is over 15 minutes old. Hidden if you use Kimi Code without a Kimi Code plan. |
| Session | time since the session started, lines added and removed | Counts the Edit and Write tool calls that succeeded, sub-agents included, as a line diff. |
| Prompt cache | between turns, the minutes until the server drops the session's prompt cache | After each model call, Kimi Code's server keeps the conversation cached for a while: by Kimi Code's own estimate, which it also uses for its "cache expired" prompt, currently 30 minutes for K3 and K3.1 Pro and 60 for Kimi for Coding. Blue, yellow in the last 5 minutes, then `cold`: the next message has the whole conversation read again, which is slower and costs more of your quota. Also `cold` right after you switch to another model, which has no cache of this conversation. Hidden while a turn runs (every model call refreshes the cache) unless the cache has expired anyway, and for models Kimi Code has no estimate for. |

Context use is left out because Kimi Code's second footer line already shows it. Kimi Code shows a status line command's output instead of its own first footer line, so that line's goal and running-task badges (Kimi Code 2.3) don't appear; Kimi Code doesn't pass them to the command.

## Requirements

**Windows**

- Windows 10 or 11 with [Kimi Code](https://www.kimi.com/code). Tested with Kimi Code 2.2.0 and 2.3.1.
- [Git for Windows](https://git-scm.com/download/win), for its bash 5: `winget install Git.Git`
- [jq](https://jqlang.org), for the quota, thinking effort, changed lines and cache countdown: `winget install jqlang.jq`. Without it, those parts stay empty.

**macOS**

- macOS with [Kimi Code](https://www.kimi.com/code). Tested with Kimi Code 2.3.2 on macOS 27 (Apple silicon).
- bash and curl come with macOS. The status line runs on macOS's own bash 3.2 (Homebrew's bash 5 works too, see the installer's `--bash`).
- [jq](https://jqlang.org), for the quota, thinking effort, changed lines and cache countdown. macOS 15 and later have it built in (`/usr/bin/jq`); on older versions, `brew install jq`. Without it, those parts stay empty.

**Both:** a [Nerd Font](https://www.nerdfonts.com) as your terminal's font, for the icons.

## Install

**Windows**, in PowerShell:

```powershell
irm https://raw.githubusercontent.com/infinitr0us/kimi-code-statusline-bash/main/install.ps1 | iex
```

**macOS**, in Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/infinitr0us/kimi-code-statusline-bash/main/install.sh | bash
```

Then run `/reload-tui` in Kimi Code, or restart it.

This installs the latest release. For a particular release:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/infinitr0us/kimi-code-statusline-bash/main/install.ps1))) -Version v0.3.0
```

```sh
curl -fsSL https://raw.githubusercontent.com/infinitr0us/kimi-code-statusline-bash/main/install.sh | bash -s -- --version v0.3.0
```

You can also download `kimi-code-statusline-bash-<version>.zip` from [Releases](https://github.com/infinitr0us/kimi-code-statusline-bash/releases), unzip it, read the scripts, and in that folder run `powershell -ExecutionPolicy Bypass -File .\install.ps1` on Windows or `bash install.sh` on macOS. Installing from the zip needs no network access.

### What the installer changes

- It puts `statusline.sh` into `.kimi-code/statusline-bash/` in your user folder (or into `$KIMI_CODE_HOME/statusline-bash/` if you set `KIMI_CODE_HOME`). On Windows, a small `statusline.cmd` launcher goes next to it.
- It sets `command` under `[status_line]` in Kimi Code's `tui.toml`: to the launcher on Windows, to `/bin/bash <that folder>/statusline.sh` on macOS. The rest of `tui.toml` stays as it was.
- Any file it changes is first backed up to `<file>.bak-<date>-<time>`.
- It finds jq (and on Windows, Git Bash) and records where they are (jq in `jq-path.txt` next to the script, Git Bash in the launcher), because the shell that Kimi Code starts may not have your terminal's PATH.
- At the end it runs the status line once and shows the result.

If `tui.toml` already runs some other status line command, the installer stops without changing anything. With `-Force` (Windows) or `--force` (macOS) it replaces that command, and the uninstaller puts it back later.

Options on Windows: `-Version`, `-KimiHome`, `-GitBash`, `-JqPath`, `-Force`; see `Get-Help .\install.ps1 -Detailed`. On macOS: `--version`, `--kimi-home`, `--bash`, `--jq`, `--force`; see `bash install.sh --help`.

## Update

Run the install command again. It replaces `statusline.sh` (and keeps a backup if yours was different) and leaves everything else as it is.

## Uninstall

**Windows**, in PowerShell:

```powershell
irm https://raw.githubusercontent.com/infinitr0us/kimi-code-statusline-bash/main/uninstall.ps1 | iex
```

**macOS**, in Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/infinitr0us/kimi-code-statusline-bash/main/uninstall.sh | bash
```

This removes the `[status_line]` command from `tui.toml` (or restores the one that was there before), deletes the installed files and the cache in `.kimi-code/cache/statusline`, and keeps the backups. Then run `/reload-tui`.

## Customize

Edit `.kimi-code/statusline-bash/statusline.sh` in your user folder. Kimi Code runs the file fresh every time, so a change shows within a second. The parts are put together near the end of the file, in display order, and the colors are plain ANSI codes (`92` green, `93` yellow, `91` red and so on). Keep that part fast: Kimi Code drops any run that takes more than 300 ms (see [How it works](#how-it-works)). On macOS, keep to what bash 3.2 can do too, as `/bin/bash` runs it (no associative arrays, for one).

An update overwrites your changes, but the installer keeps your version as `statusline.sh.bak-<date>-<time>`.

To use a different jq, run the installer with `-JqPath` (Windows) or `--jq` (macOS), or set the environment variable `KIMI_STATUSLINE_JQ` to its path.

## How it works

About once a second, Kimi Code runs the `[status_line]` command with a JSON snapshot (model, folder, branch, permission mode, session id) on stdin and shows the first line it prints. A run still going after 300 ms is stopped and ignored. On Windows the command goes through `cmd.exe`, which is why the installer points it at `statusline.cmd`, which starts Git Bash on `statusline.sh`. On macOS it goes through `sh -c`, which starts `/bin/bash` on `statusline.sh`.

In Git Bash, each program started costs tens of milliseconds, so a render uses only bash builtins and takes about 50 ms. On macOS, starting a program costs a millisecond or two, and a render takes about 10 ms. The slow work runs in background processes, which leave their results in `.kimi-code/cache/statusline` for later renders:

- every 5 minutes, one fetches the quota from Kimi Code's usage API (curl and jq), and once a day the prompt-cache durations that Kimi Code itself uses;
- when a session's log has grown, one reads the new records for changed lines, the thinking effort, the time of the last model call and whether a turn is running (jq). An idle session costs nothing.

## Privacy and security

- For the quota, the script reads the login token that Kimi Code keeps in `.kimi-code/credentials/` (or the API key in `config.toml`) and sends it only to the Kimi Code provider's own `base_url` (by default `https://api.kimi.com/coding/v1/usages`). The token reaches curl through stdin, so it never shows up in a process list. The script never refreshes or writes your credentials; while the token is expired, it waits for Kimi Code to refresh it.
- The prompt-cache durations come from the same server (`<base_url>/client_configs`, a public setting), fetched without your token. If that fails, the script reads Kimi Code's own copy in `.kimi-code/cache/client-configs/`.
- Session logs are only read locally, to count changed lines and time the prompt cache. Nothing else leaves your computer.
- Apart from a temporary download, the installer writes only inside Kimi Code's home folder.

## Troubleshooting

**Kimi Code still shows its own footer.** Run `/reload-tui`. If that doesn't help, the command failed or took longer than 300 ms. Try it by hand (on Windows, the icons may look garbled in PowerShell's output):

```powershell
Measure-Command { '{"model":"K3","permissionMode":"yolo"}' | & "$HOME\.kimi-code\statusline-bash\statusline.cmd" | Out-Host }
```

```sh
time (echo '{"model":"K3","permissionMode":"yolo"}' | /bin/bash ~/.kimi-code/statusline-bash/statusline.sh)
```

**Boxes or question marks instead of icons.** Set a Nerd Font as your terminal's font.

**The quota shows `…`, `?`, or is grey.** `…` means the first fetch hasn't finished yet. `?` or grey means fetching fails: check that you are logged in to Kimi Code with a Kimi Code plan and that jq is installed. A token that expired while Kimi Code sat idle is refreshed the next time Kimi Code talks to its server.

**No thinking effort or changed lines.** jq is missing. Install it (`winget install jqlang.jq` on Windows, `brew install jq` on macOS before 15) and run the installer again.

**No cache countdown.** It shows between turns once the session has made a model call, for the models of a Kimi Code plan. It also needs jq. It can take a second or two after a turn ends to appear.

**A part looks wrong after a Kimi Code update.** The script reads files and an API that Kimi Code doesn't document (session logs, the usage endpoint), and an update can change them. Please [open an issue](https://github.com/infinitr0us/kimi-code-statusline-bash/issues) with your Kimi Code version (`kimi --version`) and your system.

## Development

The tests install into throwaway Kimi homes in the temporary folder, render the status line the way Kimi Code runs it (with made-up sessions and a mock usage API), and uninstall again. They never touch your own Kimi home.

- `tests\run-tests.ps1` on Windows; the mock server needs Python. CI runs it with PowerShell 7 and Windows PowerShell 5.1.
- `bash tests/run-tests.sh` on macOS; needs Python 3 (`tests/render.py` runs the status line as Kimi Code does there) and jq. CI runs it with the status line on macOS's own bash 3.2 and on Homebrew's bash 5.

`statusline.sh` has to run on bash 3.2 as well as bash 5, with GNU tools (Git Bash) and BSD tools (macOS); the comments at its top say what that rules out.

To make a release, add a `## [x.y.z] - <date>` section to `CHANGELOG.md` and push a tag `vx.y.z`. The release workflow runs the tests, builds the assets with `tools\build-release.ps1`, and publishes them.

## License

[MIT](LICENSE)
