<#
.SYNOPSIS
    End-to-end tests for kimi-code-statusline-bash.

.DESCRIPTION
    Installs into throwaway Kimi homes under %TEMP%, renders the status line the way Kimi
    Code runs it (cmd.exe /d /s /c with a JSON snapshot on stdin), and uninstalls again.
    Your real Kimi home is never touched. Needs Git for Windows and jq; the quota and
    web-install tests also need Python, for a local mock server.

.PARAMETER Keep
    Keep the temporary folder for a look afterwards.
#>
[CmdletBinding()]
param([switch]$Keep)

$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$Root = Join-Path ([IO.Path]::GetTempPath()) ('ksl-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Root | Out-Null
$Utf8 = New-Object System.Text.UTF8Encoding $false
$Esc = [char]27
$G = @{   # the Nerd Font icons statusline.sh prints (this file stays ASCII)
    model = [char]::ConvertFromUtf32(0xF06A9); dir = [char]::ConvertFromUtf32(0xF024B)
    git = [char]::ConvertFromUtf32(0xF02A2); quota = [char]::ConvertFromUtf32(0xF0A9E)
    session = [char]::ConvertFromUtf32(0xF19BB); dot = [string][char]0xB7; ellipsis = [string][char]0x2026
}
$script:Passed = 0
$script:Failed = 0
$script:Times = New-Object System.Collections.Generic.List[double]

function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { $script:Passed++; Write-Host "  ok    $Name" -ForegroundColor Green }
    else {
        $script:Failed++; Write-Host "  FAIL  $Name" -ForegroundColor Red
        if ($Detail) { Write-Host "        $Detail" }
    }
}
function Skip([string]$Name, [string]$Why) { Write-Host "  skip  $Name ($Why)" -ForegroundColor Yellow }
function Write-Text([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, $Utf8)
}
function Add-Text([string]$Path, [string]$Text) { [IO.File]::AppendAllText($Path, $Text, $Utf8) }
function Wait-Until([scriptblock]$Condition, [int]$Seconds = 20) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) { if (& $Condition) { return $true }; Start-Sleep -Milliseconds 200 }
    [bool](& $Condition)
}
function Read-Text([string]$Path) { if (Test-Path -LiteralPath $Path) { [IO.File]::ReadAllText($Path) } else { '' } }

$Pwsh = (Get-Process -Id $PID).Path   # run the installers with the same PowerShell as the tests
# (Continue: under Windows PowerShell 5.1 a child's stderr would otherwise stop the tests)
function Invoke-Script([string]$File, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $out = & $Pwsh -NoProfile -ExecutionPolicy Bypass -File $File @Arguments 2>&1 | Out-String
    [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out }
}
function Invoke-Command64([string]$Command) {   # a -Command run without quoting trouble
    $ErrorActionPreference = 'Continue'
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
    $out = & $Pwsh -NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc 2>&1 | Out-String
    [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out }
}

function Get-Command-From-Tui([string]$KimiHome) {
    $tui = Read-Text (Join-Path $KimiHome 'tui.toml')
    if ($tui -match '(?ms)^\[status_line\]\s*$(.*?)(?=^\[|\z)' -and $Matches[1] -match '(?m)^\s*command\s*=\s*"([^"]*)"') { $Matches[1] }
}

# One status line run as Kimi Code does it: Node hands `cmd.exe /d /s /c <command>` the
# command in double quotes when it has a space, and the snapshot comes on stdin.
function Invoke-Render([string]$KimiHome, [string]$Mode = 'yolo', [string]$Cwd = $HOME, [string]$Sid = $null, [bool]$Plan = $false, [string]$Branch = 'main') {
    $command = Get-Command-From-Tui $KimiHome
    if (-not $command) { throw "no status line command in $KimiHome\tui.toml" }
    $snap = [ordered]@{
        model = 'K3'; cwd = $Cwd; gitBranch = $Branch; permissionMode = $Mode; planMode = $Plan
        contextUsage = 0.1; contextTokens = 1000; maxContextTokens = 10000; sessionId = $Sid; version = '2.2.0'
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $env:ComSpec
    $psi.Arguments = '/d /s /c ' + $(if ($command -match '\s') { '"' + $command + '"' } else { $command })
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.StandardOutputEncoding = $Utf8
    $psi.EnvironmentVariables['KIMI_CODE_HOME'] = $KimiHome
    $psi.EnvironmentVariables['KIMI_CODE_STATUS_LINE'] = '1'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write(($snap | ConvertTo-Json -Compress)); $p.StandardInput.Close()
    $task = $p.StandardOutput.ReadToEndAsync()
    if (-not $p.WaitForExit(5000)) { $p.Kill(); throw 'status line run hung' }
    $sw.Stop()
    $script:Times.Add($sw.Elapsed.TotalMilliseconds)
    $raw = (($task.Result -split "`n")[0]).TrimEnd()
    [pscustomobject]@{ Raw = $raw; Text = ($raw -replace "$Esc\[[0-9;]*m", ''); Code = $p.ExitCode; Ms = $sw.ElapsedMilliseconds }
}

# A Kimi home with config.toml and an OAuth token. -NoPlan: only another provider's API key.
function New-KimiHome([string]$Name, [string]$BaseUrl = 'http://127.0.0.1:9/coding/v1', [switch]$NoPlan, [string]$Tui) {
    $h = Join-Path $Root $Name
    New-Item -ItemType Directory -Force -Path $h | Out-Null
    if ($NoPlan) {
        $cfg = "default_model = `"moonshot/kimi-k2`"`n`n[providers.moonshot]`ntype = `"kimi`"`nbase_url = `"http://127.0.0.1:9/v1`"`napi_key = `"sk-test`"`n`n[models.`"moonshot/kimi-k2`"]`nprovider = `"moonshot`"`nmodel = `"kimi-k2`"`n"
    } else {
        $cfg = "default_model = `"kimi-code/k3`"`n`n[thinking]`nenabled = true`n`n[providers.`"managed:kimi-code`"]`ntype = `"kimi`"`nbase_url = `"$BaseUrl`"`n`n[providers.`"managed:kimi-code`".oauth]`nstorage = `"file`"`nkey = `"oauth/kimi-code`"`n`n[models.`"kimi-code/k3`"]`nprovider = `"managed:kimi-code`"`nmodel = `"k3`"`ndisplay_name = `"K3`"`ndefault_effort = `"high`"`n"
        $exp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600
        Write-Text (Join-Path $h 'credentials\kimi-code.json') ('{"access_token":"test-token","refresh_token":"x","expires_at":' + $exp + '}')
    }
    Write-Text (Join-Path $h 'config.toml') $cfg
    if ($null -ne $Tui) { Write-Text (Join-Path $h 'tui.toml') $Tui }
    $h
}

function Get-Record($Object) { ($Object | ConvertTo-Json -Compress -Depth 10) + "`n" }
function Edit-Call([string]$Id, [string]$Old, [string]$New) {
    Get-Record ([ordered]@{ type = 'context.append_loop_event'; event = [ordered]@{ type = 'tool.call'; name = 'Edit'; toolCallId = $Id; args = [ordered]@{ path = 'a.txt'; old_string = $Old; new_string = $New } } })
}
function Write-Call([string]$Id, [string]$Content) {
    Get-Record ([ordered]@{ type = 'context.append_loop_event'; event = [ordered]@{ type = 'tool.call'; name = 'Write'; toolCallId = $Id; args = [ordered]@{ path = 'b.txt'; content = $Content } } })
}
function Tool-Result([string]$Id, [string]$Output, [bool]$IsError = $false) {
    $r = [ordered]@{ output = $Output; note = $null }
    if ($IsError) { $r.isError = $true }
    Get-Record ([ordered]@{ type = 'context.append_loop_event'; event = [ordered]@{ type = 'tool.result'; toolCallId = $Id; result = $r } })
}
function Effort-Record([string]$Effort) { Get-Record ([ordered]@{ type = 'config.update'; modelAlias = 'kimi-code/k3'; thinkingEffort = $Effort; time = 1 }) }

$KimiDefaultTui = @"
# ~/.kimi-code/tui.toml
# Client preferences for kimi-code.
# Agent/runtime settings stay in ~/.kimi-code/config.toml.

theme = "auto" # "auto" | "dark" | "light" | custom theme name

[editor]
command = "" # Empty uses `$VISUAL / `$EDITOR

# [status_line]
# Pick and order the built-in footer slots: mode, goal, model, tasks, cwd, git, tips
# command = "~/.kimi-code/statusline.sh"

"@ -replace "`r`n", "`n"

$Server = $null
try {
    # --------------------------------------------------------------- mock server ---
    $Python = $null
    foreach ($c in 'python', 'python3', 'py') {
        $cmd = Get-Command $c -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd -and (& $cmd.Source -c 'print(1)' 2>$null) -eq '1') { $Python = $cmd.Source; break }
    }
    $BaseUrl = 'http://127.0.0.1:9/coding/v1'
    if ($Python) {
        $files = Join-Path $Root 'files'
        New-Item -ItemType Directory -Path $files | Out-Null
        Copy-Item (Join-Path $Repo 'statusline.sh') $files
        $portFile = Join-Path $Root 'port'
        $Server = Start-Process -FilePath $Python -ArgumentList '-I', ('"' + (Join-Path $PSScriptRoot 'mock_server.py') + '"'), ('"' + $portFile + '"'), ('"' + $files + '"') -PassThru -WindowStyle Hidden
        if (-not (Wait-Until { Test-Path -LiteralPath $portFile } 15)) { throw 'mock server did not start' }
        $Port = (Get-Content -LiteralPath $portFile -Raw).Trim()
        $BaseUrl = "http://127.0.0.1:$Port/coding/v1"
    }

    # ---------------------------------------------------------------- install ---
    Write-Host 'install'
    # a space, & and ( ) in the path: install.ps1 must ^-escape them for cmd
    $A = New-KimiHome 'kimi home (A) & co' -BaseUrl $BaseUrl -Tui $KimiDefaultTui
    $r = Invoke-Script (Join-Path $Repo 'install.ps1') @('-KimiHome', $A)
    Check 'install.ps1 succeeds' ($r.Code -eq 0) $r.Output
    $app = Join-Path $A 'statusline-bash'
    Check 'statusline.sh installed with LF line endings' ((Test-Path -LiteralPath "$app\statusline.sh") -and -not (Read-Text "$app\statusline.sh").Contains("`r"))
    $shimBytes = [IO.File]::ReadAllBytes("$app\statusline.cmd")
    Check 'statusline.cmd is ASCII' (-not ($shimBytes | Where-Object { $_ -gt 127 }))
    Check 'statusline.cmd records jq' ((Read-Text "$app\statusline.cmd") -match 'set "KIMI_STATUSLINE_JQ=')
    $cmd = Get-Command-From-Tui $A
    Check 'tui.toml command is the ^-escaped launcher path' ($cmd -and $cmd.EndsWith('/statusline-bash/statusline.cmd') -and $cmd.Contains('kimi^ home^ ^(A^)^ ^&^ co')) "command = $cmd"
    $tui = Read-Text "$A\tui.toml"
    Check 'tui.toml keeps everything else' ($tui.StartsWith($KimiDefaultTui.TrimEnd("`n"))) $tui
    Check 'tui.toml backed up' ((Get-ChildItem -LiteralPath $A -Filter 'tui.toml.bak-*').Count -eq 1)

    $r = Invoke-Script (Join-Path $Repo 'install.ps1') @('-KimiHome', $A)
    Check 'running install.ps1 again succeeds' ($r.Code -eq 0) $r.Output
    Check '... and changes nothing' (((Read-Text "$A\tui.toml") -eq $tui) -and (Get-ChildItem -LiteralPath $A -Filter 'tui.toml.bak-*').Count -eq 1 -and -not (Get-ChildItem -LiteralPath $app -Filter '*.bak-*'))

    # ------------------------------------------------------------------ render ---
    Write-Host 'render'
    foreach ($case in @(
            @{ mode = 'manual'; label = 'Always Ask'; color = 92 },
            @{ mode = 'yolo'; label = 'Ask When Needed'; color = 93 },
            @{ mode = 'auto'; label = 'Never Ask'; color = 91 },
            @{ mode = 'weird'; label = 'weird'; color = 97 })) {
        $o = Invoke-Render $A -Mode $case.mode
        Check "permission mode $($case.mode) -> $($case.label)" ($o.Code -eq 0 -and $o.Raw.StartsWith("$Esc[1;$($case.color)m$($case.label)$Esc[0m")) $o.Text
    }
    $o = Invoke-Render $A -Mode 'yolo' -Plan $true
    Check 'plan mode badge' ($o.Text.StartsWith('Ask When Needed plan | ')) $o.Text
    $o = Invoke-Render $A -Cwd (Join-Path $HOME 'Desktop\proj')
    Check 'model and config effort' ($o.Text.Contains("$($G.model) K3 $($G.dot) high")) $o.Text
    Check 'home folder shown as ~' ($o.Text.Contains("$($G.dir) ~/Desktop/proj")) $o.Text
    Check 'git branch' ($o.Text.Contains("$($G.git) main")) $o.Text
    $o = Invoke-Render $A -Cwd 'D:\a\b\c\d\e' -Branch $null
    Check 'long path keeps the last 3 folders' ($o.Text.Contains("$($G.dir) $($G.ellipsis)/c/d/e")) $o.Text
    Check 'no branch, no git part' (-not $o.Text.Contains($G.git)) $o.Text

    # ----------------------------------------------------------------- session ---
    Write-Host 'session'
    $sid = 'session_0123456789abcdef'
    $sdir = Join-Path $A "sessions\wd_test_000000000000\$sid"
    $created = [DateTimeOffset]::UtcNow.AddMinutes(-83).AddSeconds(-20).ToUnixTimeMilliseconds()
    Write-Text "$sdir\state.json" ('{"agents":{},"createdAt":' + $created + ',"title":"t","workDir":"C:\\x"}')
    $main = "$sdir\agents\main\wire.jsonl"
    Write-Text $main ((Get-Record ([ordered]@{ type = 'metadata'; protocol_version = '1.5'; created_at = $created })) +
        (Effort-Record 'max') +
        (Edit-Call 'c1' "a`nb`nc" "a`nB`nc`nd") + (Tool-Result 'c1' 'Replaced 1 occurrence') +        # +2 -1
        (Write-Call 'c2' "x`ny`nz`n") + (Tool-Result 'c2' 'Wrote b.txt') +                            # +3
        (Edit-Call 'c3' 'p' 'q') + (Tool-Result 'c3' 'old_string not found' $true) +                 # failed: 0
        (Edit-Call 'c4' 'foo' 'bar') + (Tool-Result 'c4' 'Replaced 3 occurrences'))                  # +3 -3
    Write-Text "$sdir\agents\sub1\wire.jsonl" ((Effort-Record 'low') + (Edit-Call 's1' 'q' "r`ns") + (Tool-Result 's1' 'Replaced 1 occurrence'))   # +2 -1
    $state = Join-Path $A "cache\statusline\$sid.state"
    $o = Invoke-Render $A -Sid $sid
    Check 'elapsed time' ($o.Text -match "$($G.session) 1h2[34]m") $o.Text
    $ok = Wait-Until { (Read-Text $state).StartsWith("10`t5`tmax`n") }
    Check 'background scan counts main and sub-agent edits' $ok (Read-Text $state)
    $o = Invoke-Render $A -Sid $sid
    Check 'changed lines +10/-5' ($o.Text -match "1h2[34]m \+10/-5$") $o.Text
    Check 'thinking effort from the session (main agent only)' ($o.Text.Contains("K3 $($G.dot) max")) $o.Text

    Add-Text $main ((Edit-Call 'c5' '1' '2') + (Tool-Result 'c5' 'Replaced 1 occurrence'))
    Add-Text $main (Edit-Call 'c6' 'm' 'n').TrimEnd("`n")   # a record still being written
    $o = Invoke-Render $A -Sid $sid
    $ok = Wait-Until { (Read-Text $state).StartsWith("11`t6`tmax`n") }
    Check 'appended records are added; a half-written one waits' $ok (Read-Text $state)
    Add-Text $main ("`n" + (Tool-Result 'c6' 'Replaced 1 occurrence'))
    $o = Invoke-Render $A -Sid $sid
    $ok = Wait-Until { (Read-Text $state).StartsWith("12`t7`tmax`n") }
    Check '... and is counted once complete' $ok (Read-Text $state)
    $o = Invoke-Render $A -Sid $sid
    Check 'changed lines +12/-7' ($o.Text -match '\+12/-7$') $o.Text

    # ------------------------------------------------------------------- quota ---
    Write-Host 'quota'
    $quota = Join-Path $A 'cache\statusline\quota'
    if ($Python) {
        Invoke-Render $A | Out-Null
        $ok = Wait-Until { (Read-Text $quota) -match "`t92`t5h 5%" }
        Check 'quota fetched in the background' $ok (Read-Text $quota)
        $o = Invoke-Render $A
        $want = [regex]::Escape("$($G.quota) 5h 5% (rst ") + '\d\d:\d\d\) ' + [regex]::Escape("$($G.dot) 7d 52% (rst ") + '\d\d/\d\d \d\d:\d\d\)'
        Check 'quota part' ($o.Text -match $want) $o.Text
        Check 'quota colored green under 60%' ($o.Raw.Contains("$Esc[92m$($G.quota) 5h")) $o.Raw
    } else { Skip 'quota fetch' 'no Python for the mock server' }
    # also: a jq under %LOCALAPPDATA% (TEMP is there) goes into the launcher as %LOCALAPPDATA%\...
    $jqCopy = $null
    foreach ($j in @(Get-Command jq.exe -All -CommandType Application -ErrorAction SilentlyContinue)) {
        $dest = Join-Path $Root "bin$($script:Passed)\jq.exe"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
        Copy-Item -LiteralPath $j.Source -Destination $dest
        if ((& $dest -n '1' 2>$null) -eq '1') { $jqCopy = $dest; break }   # runs without its own folder's DLLs
    }
    $N = New-KimiHome 'no plan' -NoPlan -Tui ''
    $nArgs = @('-KimiHome', $N)
    if ($jqCopy) { $nArgs += @('-JqPath', $jqCopy) }
    $r = Invoke-Script (Join-Path $Repo 'install.ps1') $nArgs
    Check 'install into an empty tui.toml' ($r.Code -eq 0 -and (Get-Command-From-Tui $N)) $r.Output
    if ($jqCopy -and $jqCopy.StartsWith($env:LOCALAPPDATA + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Check 'launcher writes the jq path as %LOCALAPPDATA%\...' ((Read-Text "$N\statusline-bash\statusline.cmd") -match 'set "KIMI_STATUSLINE_JQ=%LOCALAPPDATA%\\')
        $nsid = 'session_n'
        Write-Text "$N\sessions\wd_n\$nsid\state.json" ('{"createdAt":' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + '}')
        Write-Text "$N\sessions\wd_n\$nsid\agents\main\wire.jsonl" ((Edit-Call 'n1' 'a' 'b') + (Tool-Result 'n1' 'Replaced 1 occurrence'))
        Invoke-Render $N -Sid $nsid | Out-Null
        Check '... and that jq does the counting' (Wait-Until { (Read-Text "$N\cache\statusline\$nsid.state").StartsWith("1`t1`t") }) (Read-Text "$N\cache\statusline\$nsid.state")
    } else { Skip 'jq path as %LOCALAPPDATA%' 'no stand-alone jq.exe to copy, or TEMP outside LOCALAPPDATA' }
    Invoke-Render $N | Out-Null
    $ok = Wait-Until { (Read-Text (Join-Path $N 'cache\statusline\quota')) -match "`t-`n?$" }
    Check 'no Kimi Code plan: quota marked as none' $ok (Read-Text (Join-Path $N 'cache\statusline\quota'))
    $o = Invoke-Render $N
    Check '... and not shown' ($o.Code -eq 0 -and $o.Text -and -not $o.Text.Contains($G.quota)) $o.Text

    # --------------------------------------------------------------- uninstall ---
    Write-Host 'uninstall'
    $r = Invoke-Script (Join-Path $Repo 'uninstall.ps1') @('-KimiHome', $A)
    Check 'uninstall.ps1 succeeds' ($r.Code -eq 0) $r.Output
    Check 'tui.toml is back to the original' ((Read-Text "$A\tui.toml") -eq $KimiDefaultTui) (Read-Text "$A\tui.toml")
    Check 'installed files and cache removed' (-not (Test-Path -LiteralPath $app) -and -not (Test-Path -LiteralPath (Join-Path $A 'cache\statusline')))

    # ----------------------------------------------------- someone else's command ---
    Write-Host 'another status line'
    $otherTui = "theme = `"dark`"`n`n[status_line]`nitems = [`"mode`", `"model`"]`ncommand = `"C:/tools/other.cmd`"`n`n[upgrade]`nauto_install = true`n"
    $B = New-KimiHome 'kimiB' -Tui $otherTui
    $r = Invoke-Script (Join-Path $Repo 'install.ps1') @('-KimiHome', $B)
    Check 'install.ps1 refuses to replace it' ($r.Code -ne 0 -and $r.Output -match 'another status line command') $r.Output
    Check '... and leaves tui.toml alone' ((Read-Text "$B\tui.toml") -eq $otherTui)
    $r = Invoke-Script (Join-Path $Repo 'install.ps1') @('-KimiHome', $B, '-Force')
    Check 'install.ps1 -Force replaces it' ($r.Code -eq 0 -and (Get-Command-From-Tui $B) -match 'statusline-bash/statusline\.cmd$') $r.Output
    Check '... in place' ((Read-Text "$B\tui.toml") -match '(?s)\[status_line\]\nitems = \["mode", "model"\]\ncommand = "[^"]+statusline\.cmd"\n\n\[upgrade\]') (Read-Text "$B\tui.toml")
    $r = Invoke-Script (Join-Path $Repo 'uninstall.ps1') @('-KimiHome', $B)
    Check 'uninstall.ps1 puts the old command back' ($r.Code -eq 0 -and (Read-Text "$B\tui.toml") -eq $otherTui) (Read-Text "$B\tui.toml")

    # ------------------------------------------------------------------ web mode ---
    Write-Host 'web install'
    if ($Python) {
        $C = New-KimiHome 'kimiC' -Tui $KimiDefaultTui
        $installer = Join-Path $Repo 'install.ps1'
        $r = Invoke-Command64 "`$ErrorActionPreference = 'Continue'; & ([scriptblock]::Create([IO.File]::ReadAllText('$installer'))) -KimiHome '$C' -Source 'http://127.0.0.1:$Port/download/statusline.sh'; `"EAP=`$ErrorActionPreference`""
        $installed = Read-Text (Join-Path $C 'statusline-bash\statusline.sh')
        Check 'installs a downloaded statusline.sh' ($r.Code -eq 0 -and $installed -eq (Read-Text (Join-Path $Repo 'statusline.sh')) -and $r.Output -match 'Downloading') $r.Output
        Check "leaves the caller's settings alone" ($r.Output -match 'EAP=Continue') $r.Output
        $o = Invoke-Render $C
        Check '... and it renders' ($o.Code -eq 0 -and $o.Text.StartsWith('Ask When Needed | ')) $o.Text
    } else { Skip 'web install' 'no Python for the mock server' }
    $missing = Join-Path $Root 'does-not-exist'
    $r = Invoke-Command64 "`$env:KIMI_CODE_HOME = '$missing'; try { [IO.File]::ReadAllText('$(Join-Path $Repo 'install.ps1')') | Invoke-Expression } catch { `"caught: `$_`" }; `"EAP=`$ErrorActionPreference`""
    Check 'via iex, a failure is an error, not a closed window' ($r.Output -match 'caught: .*does not exist' -and $r.Output -match 'EAP=Continue') $r.Output

    # ------------------------------------------------------------------ timing ---
    $sorted = $script:Times | Sort-Object
    $median = $sorted[[int][math]::Floor($sorted.Count / 2)]
    $msg = 'median {0:N0} ms, max {1:N0} ms over {2} runs' -f $median, $sorted[-1], $sorted.Count
    if ($env:CI) { Write-Host "  info  render time: $msg (not checked on CI)" }
    else { Check "median render under 300 ms ($msg)" ($median -lt 300) }
}
finally {
    if ($Server -and -not $Server.HasExited) { Stop-Process -Id $Server.Id -Force -ErrorAction SilentlyContinue }
    if ($Keep) { Write-Host "kept $Root" }
    else {
        # background workers may still hold a cache file for a moment
        for ($i = 0; $i -lt 10 -and (Test-Path -LiteralPath $Root); $i++) {
            try { Remove-Item -LiteralPath $Root -Recurse -Force } catch { Start-Sleep -Milliseconds 500 }
        }
    }
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
