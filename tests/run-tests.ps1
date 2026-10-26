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
    session = [char]::ConvertFromUtf32(0xF19BB); cache = [string][char]0xF1C0
    dot = [string][char]0xB7; ellipsis = [string][char]0x2026
}
$Days = 'Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'
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
function ConvertTo-MsysPath([string]$Path) { '/' + $Path.Substring(0, 1).ToLower() + ($Path.Substring(2) -replace '\\', '/') }
function Get-EpochMs([double]$MinutesAgo = 0) { [DateTimeOffset]::UtcNow.AddMinutes(-$MinutesAgo).ToUnixTimeMilliseconds() }

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

# Renders about once a second, as Kimi Code does, until $Ok accepts one (or 20 s pass):
# right after a log grows, a render may still wait for the background scan.
function Wait-Render([string]$KimiHome, [string]$Sid, [scriptblock]$Ok) {
    $deadline = (Get-Date).AddSeconds(20)
    do {
        $o = Invoke-Render $KimiHome -Sid $Sid
        if (& $Ok $o) { break }
        Start-Sleep -Milliseconds 700
    } while ((Get-Date) -lt $deadline)
    $o
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
        $cfg = "default_model = `"kimi-code/k3`"`n`n[thinking]`nenabled = true`n`n[secondary_model]`ndefault_model = `"kimi-code/k3-mini`"`ndefault_effort = `"low`"`n`n[providers.`"managed:kimi-code`"]`ntype = `"kimi`"`nbase_url = `"$BaseUrl`"`n`n[providers.`"managed:kimi-code`".oauth]`nstorage = `"file`"`nkey = `"oauth/kimi-code`"`n`n[models.`"kimi-code/k3`"]`nprovider = `"managed:kimi-code`"`nmodel = `"k3`"`ndisplay_name = `"K3`"`ndefault_effort = `"high`"`n"
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
# a turn's boundaries and one model call, as Kimi Code 2.3 logs them
function Turn-Start([int]$Id) {
    (Get-Record ([ordered]@{ turnId = $Id; queueItemId = "msg_$Id"; type = 'agent.turn.started'; time = (Get-EpochMs); kind = 'event' })) +
    (Get-Record ([ordered]@{ type = 'turn.prompt'; agentId = 'main'; promptId = "msg_$Id"; turnId = $Id; time = (Get-EpochMs) }))
}
function Turn-End([int]$Id) {
    (Get-Record ([ordered]@{ turnId = $Id; outcome = 'done'; type = 'agent.turn.ended'; time = (Get-EpochMs); kind = 'event' })) +
    (Get-Record ([ordered]@{ type = 'turn.ended'; agentId = 'main'; turnId = $Id; reason = 'completed'; time = (Get-EpochMs) }))
}
function Model-Request([string]$Model, [double]$MinutesAgo = 0) {
    Get-Record ([ordered]@{ type = 'llm.request'; agentId = 'main'; kind = 'loop'; provider = 'openai'; model = $Model; modelAlias = "kimi-code/$Model"; time = (Get-EpochMs $MinutesAgo) })
}
function Model-Call([double]$MinutesAgo, [string]$Model = 'k3') {   # a request and its completion
    (Model-Request $Model $MinutesAgo) +
    (Get-Record ([ordered]@{ type = 'usage.record'; agentId = 'main'; model = "kimi-code/$Model"; usage = [ordered]@{ inputOther = 1; output = 2; inputCacheRead = 3; inputCacheCreation = 0 }; usageScope = 'turn'; time = (Get-EpochMs $MinutesAgo) }))
}
function Model-Switch([string]$Model) {   # /model while idle
    Get-Record ([ordered]@{ type = 'config.update'; modelAlias = "kimi-code/$Model"; thinkingEffort = 'high'; time = (Get-EpochMs) })
}
# Kimi Code's own cached copy of the prompt-cache rules (cache\client-configs)
function Write-KimiCacheRules([string]$KimiHome, [int]$Seconds) {
    Write-Text (Join-Path $KimiHome 'cache\client-configs\global%3A%2Fclient_configs%3Aestimated_cache_duration.json') (
        '{"version":1,"fetchedAt":1,"config":{"version":1,"config":{"k3":{"min_tokens_to_hint":200000,"cache_duration":' + $Seconds + '}}}}')
}

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
    Write-KimiCacheRules $A 1800   # used only without the mock server
    $r = Invoke-Script (Join-Path $Repo 'install.ps1') @('-KimiHome', $A)
    Check 'install.ps1 succeeds' ($r.Code -eq 0) $r.Output
    $app = Join-Path $A 'statusline-bash'
    Check 'statusline.sh installed with LF line endings' ((Test-Path -LiteralPath "$app\statusline.sh") -and -not (Read-Text "$app\statusline.sh").Contains("`r"))
    $shimBytes = [IO.File]::ReadAllBytes("$app\statusline.cmd")
    Check 'statusline.cmd is ASCII' (-not ($shimBytes | Where-Object { $_ -gt 127 }))
    $jqRecorded = (Read-Text "$app\jq-path.txt").Trim()
    Check 'jq-path.txt records jq' ($jqRecorded -and (Test-Path -LiteralPath $jqRecorded)) $jqRecorded
    $cmd = Get-Command-From-Tui $A
    Check 'tui.toml command is the ^-escaped launcher path' ($cmd -and $cmd.EndsWith('/statusline-bash/statusline.cmd') -and $cmd.Contains('kimi^ home^ ^(A^)^ ^&^ co')) "command = $cmd"
    $tui = Read-Text "$A\tui.toml"
    Check 'tui.toml keeps everything else' ($tui.StartsWith($KimiDefaultTui.TrimEnd("`n"))) $tui
    Check 'tui.toml backed up' ((Get-ChildItem -LiteralPath $A -Filter 'tui.toml.bak-*').Count -eq 1)
    $infoText = Read-Text "$app\install.json"
    Check 'install.json records no previous line (as null)' ($infoText -match '"previousLine":\s*null' -and $infoText -match '"createdTable":\s*true') $infoText

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

    # A long run of emoji (jq miscounts its bytes) must not push the read position into the
    # next record. Written by hand: Windows PowerShell's ConvertTo-Json would escape them.
    $emoji = [char]::ConvertFromUtf32(0x1F600) * 3000
    Add-Text $main ('{"type":"context.append_loop_event","event":{"type":"tool.call","name":"Write","toolCallId":"c7","args":{"path":"e.txt","content":"' + $emoji + '\n"}}}' + "`n" +
        (Tool-Result 'c7' 'Wrote e.txt'))                                                           # +1
    Invoke-Render $A -Sid $sid | Out-Null
    Wait-Until { (Read-Text $state).StartsWith("13`t7`tmax`n") } | Out-Null
    Add-Text $main ((Edit-Call 'c8' 'g' 'h') + (Tool-Result 'c8' 'Replaced 1 occurrence'))          # +1 -1
    Invoke-Render $A -Sid $sid | Out-Null
    Check 'a record after a long run of emoji is still read' (Wait-Until { (Read-Text $state).StartsWith("14`t8`tmax`n") }) (Read-Text $state)

    # ------------------------------------------------------------------- quota ---
    Write-Host 'quota'
    $quota = Join-Path $A 'cache\statusline\quota'
    if ($Python) {
        Invoke-Render $A | Out-Null
        $ok = Wait-Until { (Read-Text $quota) -match "`t92`tq`t5`t\d+`t52`t\d+`t-`n" }
        Check 'quota fetched in the background' $ok (Read-Text $quota)
        $o = Invoke-Render $A
        $f = (Read-Text $quota).Split("`t")
        $left = [math]::Ceiling(([long]$f[5] - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) / 60)
        $leftText = @($left, ($left + 1) | ForEach-Object { '{0}h{1:00}m' -f [math]::Floor($_ / 60), ($_ % 60) })   # rendered a moment earlier
        $reset = [DateTimeOffset]::FromUnixTimeSeconds([long]$f[7]).ToLocalTime()
        $want = "$($G.quota) 5h 5% $($G.dot) <left> $($G.dot) 7d 52% $($G.dot) $($Days[[int]$reset.DayOfWeek]) $($reset.ToString('HH:mm'))"
        Check 'quota part: time left in 5 hours, the week''s reset in local time' (
            $o.Text.Contains($want.Replace('<left>', $leftText[0])) -or $o.Text.Contains($want.Replace('<left>', $leftText[1]))) "$($o.Text) / want $want, <left> = $($leftText -join ' or ')"
        Check 'quota colored green under 60%' ($o.Raw.Contains("$Esc[92m$($G.quota) 5h")) $o.Raw

        # a quota cache written by v0.1.0 (text): refetched at once, "..." until then
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        Write-Text $quota ("$($now + 300)`t$now`t92`t5h 5% (rst 00:34) $($G.dot) 7d 52% (rst 10/25 23:34)`n")
        $o = Invoke-Render $A
        Check 'quota cache in the old format: not shown as numbers' ($o.Text.Contains("$($G.quota) $($G.ellipsis)")) $o.Text
        Check '... and refetched right away' (Wait-Until { (Read-Text $quota) -match "`tq`t5`t" }) (Read-Text $quota)

        # the week only: no 5-hour numbers, and the week's not shifted into their place
        $Wk = New-KimiHome 'weekly only' -BaseUrl "http://127.0.0.1:$Port/weekly/coding/v1" -Tui ''
        Invoke-Script (Join-Path $Repo 'install.ps1') @('-KimiHome', $Wk) | Out-Null
        Check 'a report with the week only' (Wait-Until { (Read-Text "$Wk\cache\statusline\quota") -match "`tq`t-`t-`t52`t\d+`t-`n" }) (Read-Text "$Wk\cache\statusline\quota")
        $o = Invoke-Render $Wk
        Check '... shows the week only' ($o.Text -match ([regex]::Escape("$($G.quota) 7d 52% $($G.dot) ") + '[A-Z][a-z]{2} \d\d:\d\d') -and -not $o.Text.Contains('5h')) $o.Text
        # a 5-hour window that resets this very second: fetched again 5 s later
        $Sn = New-KimiHome 'reset now' -BaseUrl "http://127.0.0.1:$Port/now/coding/v1" -Tui ''
        Invoke-Script (Join-Path $Repo 'install.ps1') @('-KimiHome', $Sn) | Out-Null
        Wait-Until { (Read-Text "$Sn\cache\statusline\quota") -match "`tq`t5`t" } | Out-Null
        $f = (Read-Text "$Sn\cache\statusline\quota").Split("`t")
        Check 'a window that resets before the next fetch: fetched again 5 s after the reset' ($f.Count -ge 6 -and [long]$f[0] -eq [long]$f[5] + 5) (Read-Text "$Sn\cache\statusline\quota")
    } else { Skip 'quota fetch' 'no Python for the mock server' }
    # also: a jq in a folder with a non-ASCII name (its path goes into jq-path.txt, as UTF-8)
    $jqCopy = $null
    foreach ($j in @(Get-Command jq.exe -All -CommandType Application -ErrorAction SilentlyContinue)) {
        $dest = Join-Path $Root ("jq " + [char]0x4E2D + [char]0x6587 + "$($script:Passed)\jq.exe")
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
        Copy-Item -LiteralPath $j.Source -Destination $dest
        if ((& $dest -n '1' 2>$null) -eq '1') { $jqCopy = $dest; break }   # runs without its own folder's DLLs
    }
    $N = New-KimiHome 'no plan' -NoPlan -Tui ''
    $nArgs = @('-KimiHome', $N)
    if ($jqCopy) { $nArgs += @('-JqPath', $jqCopy) }
    $r = Invoke-Script (Join-Path $Repo 'install.ps1') $nArgs
    Check 'install into an empty tui.toml' ($r.Code -eq 0 -and (Get-Command-From-Tui $N)) $r.Output
    if ($jqCopy) {
        Check 'non-ASCII jq folder: launcher stays ASCII' (-not ([IO.File]::ReadAllBytes("$N\statusline-bash\statusline.cmd") | Where-Object { $_ -gt 127 }))
        Check '... and jq-path.txt holds the path' ((Read-Text "$N\statusline-bash\jq-path.txt").Trim() -eq $jqCopy) (Read-Text "$N\statusline-bash\jq-path.txt")
        $nsid = 'session_n'
        Write-Text "$N\sessions\wd_n\$nsid\state.json" ('{"createdAt":' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + '}')
        Write-Text "$N\sessions\wd_n\$nsid\agents\main\wire.jsonl" ((Edit-Call 'n1' 'a' 'b') + (Tool-Result 'n1' 'Replaced 1 occurrence'))
        Invoke-Render $N -Sid $nsid | Out-Null
        Check '... and that jq does the counting' (Wait-Until { (Read-Text "$N\cache\statusline\$nsid.state").StartsWith("1`t1`t") }) (Read-Text "$N\cache\statusline\$nsid.state")
    } else { Skip 'non-ASCII jq folder' 'no stand-alone jq.exe to copy' }
    Invoke-Render $N | Out-Null
    $ok = Wait-Until { (Read-Text (Join-Path $N 'cache\statusline\quota')) -match "`t-`n?$" }
    Check 'no Kimi Code plan: quota marked as none' $ok (Read-Text (Join-Path $N 'cache\statusline\quota'))
    $o = Invoke-Render $N
    Check '... and not shown' ($o.Code -eq 0 -and $o.Text -and -not $o.Text.Contains($G.quota)) $o.Text
    Check '... nor the prompt-cache rules fetched' (-not (Test-Path -LiteralPath "$N\cache\statusline\cache-rules"))

    # ------------------------------------------------------------ prompt cache ---
    Write-Host 'prompt cache'
    $rules = Join-Path $A 'cache\statusline\cache-rules'
    Check 'cache rules fetched with the quota' (Wait-Until { (Read-Text $rules) -match "(?m)^k3`t1800$" }) (Read-Text $rules)
    if ($Python) {
        Check '... from the server' ((Read-Text $rules) -match "^[1-9]\d*`n" -and (Read-Text $rules) -match "(?m)^kimi-for-coding`t3600$") (Read-Text $rules)
    } else { Skip 'cache rules from the server' 'no Python for the mock server' }
    $csid = 'session_cache'
    $csdir = Join-Path $A "sessions\wd_test_000000000000\$csid"
    Write-Text "$csdir\state.json" ('{"createdAt":' + (Get-EpochMs 30) + '}')
    $cmain = "$csdir\agents\main\wire.jsonl"
    $cstate = Join-Path $A "cache\statusline\$csid.state"
    Write-Text $cmain ((Get-Record ([ordered]@{ type = 'metadata'; protocol_version = '1.5'; created_at = (Get-EpochMs 30) })) +
        (Turn-Start 0) + (Model-Call 10.2) + (Turn-End 0))
    # K line: last model call (epoch, model, alias), in a turn, the alias selected now, and
    # the last request (alias, model)
    function Get-KPattern([string]$Busy, [string]$Model, [string]$Cur = "kimi-code/$Model") {
        "(?m)^K`t\d+`t$Busy`t" + [regex]::Escape("$Model`tkimi-code/$Model`t$Cur`t") + '\S+\t\S+$'
    }
    $cacheEnd = { param([string]$Text, [int]$Color = 34) "$Esc[$($Color)m$($G.cache) $Text$Esc[0m" }
    Invoke-Render $A -Sid $csid | Out-Null
    Check 'the scan records the last model call, the turn state and the model' (Wait-Until { (Read-Text $cstate) -match (Get-KPattern 0 'k3') }) (Read-Text $cstate)
    $want = & $cacheEnd '20m'
    $o = Wait-Render $A $csid { param($o) $o.Raw.EndsWith($want) }
    Check 'between turns: minutes left on the cache, in blue, at the end' ($o.Raw.EndsWith($want)) $o.Text

    Add-Text $cmain (Model-Switch 'kimi-for-coding')
    $want = & $cacheEnd 'cold' 33
    $o = Wait-Render $A $csid { param($o) $o.Raw.EndsWith($want) }
    Check 'another model selected (/model): "cold"' ($o.Raw.EndsWith($want)) "$($o.Text) / $(Read-Text $cstate)"
    Add-Text $cmain (Model-Switch 'k3')
    $want = & $cacheEnd '20m'
    $o = Wait-Render $A $csid { param($o) $o.Raw.EndsWith($want) }
    Check '... and back to the first model: the countdown again' ($o.Raw.EndsWith($want)) "$($o.Text) / $(Read-Text $cstate)"

    Add-Text $cmain (Turn-Start 1)
    $o = Invoke-Render $A -Sid $csid
    Check 'hidden as soon as the log grows (a turn is likely running)' (-not $o.Text.Contains($G.cache)) $o.Text
    Wait-Until { (Read-Text $cstate) -match (Get-KPattern 1 'k3') } | Out-Null
    $o = Invoke-Render $A -Sid $csid
    Check '... and while the turn runs' ((Read-Text $cstate) -match "(?m)^K`t\d+`t1`t" -and -not $o.Text.Contains($G.cache)) "$($o.Text) / $(Read-Text $cstate)"
    Add-Text $cmain ((Model-Request 'kimi-for-coding') + (Turn-End 1))   # stopped before it completed
    $want = & $cacheEnd 'cold' 33
    $o = Wait-Render $A $csid { param($o) $o.Raw.EndsWith($want) }
    Check "a request to another model that never completed: `"cold`", not that model's time" ($o.Raw.EndsWith($want) -and (Read-Text $cstate) -match (Get-KPattern 0 'k3' 'kimi-code/kimi-for-coding')) "$($o.Text) / $(Read-Text $cstate)"

    Add-Text $cmain ((Turn-Start 2) + (Model-Call 28) + (Turn-End 2))   # (an older call, to get near the end)
    $want = & $cacheEnd '2m' 33
    $o = Wait-Render $A $csid { param($o) $o.Raw.EndsWith($want) }
    Check 'yellow in the last 5 minutes' ($o.Raw.EndsWith($want)) "$($o.Text) / $(Read-Text $cstate)"
    # a duration with a leading zero (bash would read 03600 as octal 1920): not used
    $rulesText = Read-Text $rules
    Write-Text $rules ($rulesText -replace "(?m)^k3`t1800$", "k3`t03600")
    $o = Invoke-Render $A -Sid $csid
    Check 'a cache rule with a leading zero is ignored' ($o.Code -eq 0 -and -not $o.Text.Contains($G.cache)) $o.Text
    Write-Text $rules $rulesText

    Add-Text $cmain ((Turn-Start 3) + (Model-Call 31))
    Invoke-Render $A -Sid $csid | Out-Null
    Wait-Until { (Read-Text $cstate) -match (Get-KPattern 1 'k3') } | Out-Null
    $o = Invoke-Render $A -Sid $csid
    Check 'expired: "cold", even during a turn' ($o.Raw.EndsWith((& $cacheEnd 'cold' 33))) $o.Text

    Add-Text $cmain ((Model-Call 1 'unknown-model') + (Turn-End 3))
    Invoke-Render $A -Sid $csid | Out-Null
    Wait-Until { (Read-Text $cstate) -match (Get-KPattern 0 'unknown-model') } | Out-Null
    $o = Invoke-Render $A -Sid $csid
    Check 'no rule for the model: no countdown' ($o.Code -eq 0 -and $o.Text -and -not $o.Text.Contains($G.cache)) $o.Text

    # a state written by v0.1.0 (no K line, everything already read): the logs are read again
    $size = (Get-Item -LiteralPath $cmain).Length
    Write-Text $cstate ("3`t4`tmax`nF`t" + (ConvertTo-MsysPath $cmain) + "`t$size`n")
    (Get-Item -LiteralPath $cstate).LastWriteTime = (Get-Date).AddMinutes(-5)
    Invoke-Render $A -Sid $csid | Out-Null
    Check 'a state from v0.1.0 is rebuilt from the whole log' (Wait-Until { (Read-Text $cstate) -match "^0`t0`thigh`n" -and (Read-Text $cstate) -match (Get-KPattern 0 'unknown-model') }) (Read-Text $cstate)
    $size =(Get-Item -LiteralPath $cmain).Length
    Write-Text $cstate ("0`t0`thigh`nK`t1`t0`tk3`nF`t" + (ConvertTo-MsysPath $cmain) + "`t$size`n")
    (Get-Item -LiteralPath $cstate).LastWriteTime = (Get-Date).AddMinutes(-5)
    Invoke-Render $A -Sid $csid | Out-Null
    Check '... and so is one with a K line it cannot read' (Wait-Until { (Read-Text $cstate) -match (Get-KPattern 0 'unknown-model') }) (Read-Text $cstate)

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

    # ------------------------------------------------------- other tui.toml forms ---
    Write-Host 'tui.toml forms'
    $install = Join-Path $Repo 'install.ps1'
    $uninstall = Join-Path $Repo 'uninstall.ps1'
    foreach ($t in @(
            @{ name = 'quoted key'; tui = "[status_line]`n`"command`" = `"C:/tools/other.cmd`"`n" },
            @{ name = 'quoted table name'; tui = "[`"status_line`"]`ncommand = `"C:/tools/other.cmd`"`n" },
            @{ name = 'our path inside another command'; tui = "[status_line]`ncommand = `"echo C:/tools/statusline-bash/statusline.cmd`"`n" })) {
        $h = New-KimiHome ('form ' + $t.name) -Tui $t.tui
        Write-Text "$h\statusline-bash\statusline.sh" "custom`n"
        $r = Invoke-Script $install @('-KimiHome', $h)
        Check "$($t.name): seen as another tool's command" ($r.Code -ne 0 -and $r.Output -match 'another status line command') $r.Output
        Check '... and nothing is written' ((Read-Text "$h\tui.toml") -ceq $t.tui -and (Read-Text "$h\statusline-bash\statusline.sh") -ceq "custom`n" -and -not (Test-Path -LiteralPath "$h\statusline-bash\statusline.cmd"))
    }
    $zh = [string][char]0x4E2D
    foreach ($t in @(
            @{ name = 'non-ASCII command'; line = "command = `"C:/tools/$zh.cmd`""; value = "C:/tools/$zh.cmd" },
            @{ name = 'escaped command'; line = 'command = "C:/tools/' + '\' + 'u4e2d.cmd" # note'; value = "C:/tools/$zh.cmd" },
            @{ name = 'literal string'; line = "command = 'C:\tools\other.cmd'"; value = 'C:\tools\other.cmd' })) {
        $tui = "theme = `"dark`"`n`n[status_line]`n$($t.line)`n"
        $h = New-KimiHome ('round ' + $t.name) -Tui $tui
        $r = Invoke-Script $install @('-KimiHome', $h, '-Force')
        $info = [IO.File]::ReadAllText("$h\statusline-bash\install.json", $Utf8) | ConvertFrom-Json
        Check "$($t.name): -Force records it" ($r.Code -eq 0 -and $info.previousCommand -ceq $t.value -and $info.previousLine -ceq $t.line) "$($r.Output) / $($info | ConvertTo-Json -Compress)"
        $r = Invoke-Script $install @('-KimiHome', $h)
        Check '... a second install keeps the record' ($r.Code -eq 0 -and ([IO.File]::ReadAllText("$h\statusline-bash\install.json", $Utf8) | ConvertFrom-Json).previousLine -ceq $t.line) $r.Output
        $r = Invoke-Script $uninstall @('-KimiHome', $h)
        Check '... and uninstall restores it byte for byte' ($r.Code -eq 0 -and (Read-Text "$h\tui.toml") -ceq $tui) (Read-Text "$h\tui.toml")
    }
    $tui = "[status_line] # my choice`n# items = [`"mode`"]`n`n[upgrade]`nauto_install = true`n"
    $h = New-KimiHome 'table with comments' -Tui $tui
    $r = Invoke-Script $install @('-KimiHome', $h)
    Check 'a table with only comments gets the command under its header' ($r.Code -eq 0 -and (Read-Text "$h\tui.toml") -match '^\[status_line\] # my choice\ncommand = "[^"]+"\n# items') (Read-Text "$h\tui.toml")
    $r = Invoke-Script $uninstall @('-KimiHome', $h)
    Check '... and uninstall keeps the table and its comments' ((Read-Text "$h\tui.toml") -ceq $tui) (Read-Text "$h\tui.toml")
    $h = New-KimiHome 'single quoted ours' -Tui ''
    Invoke-Script $install @('-KimiHome', $h) | Out-Null
    Write-Text "$h\tui.toml" ((Read-Text "$h\tui.toml") -replace 'command = "([^"]+)"', 'command = ''$1''')
    $r = Invoke-Script $uninstall @('-KimiHome', $h)
    Check 'uninstall recognizes its command in a literal string' ($r.Code -eq 0 -and (Read-Text "$h\tui.toml") -notmatch 'command') (Read-Text "$h\tui.toml")
    $tui = "[status_line]`ncommand = `"C:/tools/other.cmd`" # was = `"C:/x/statusline-bash/statusline.cmd`"`n"
    $h = New-KimiHome 'comment mentions us' -Tui $tui
    $r = Invoke-Script $uninstall @('-KimiHome', $h)
    Check "uninstall leaves another tool's command alone, whatever its comment says" ($r.Code -eq 0 -and (Read-Text "$h\tui.toml") -ceq $tui) (Read-Text "$h\tui.toml")

    # ---------------------------------------------------------------- hardening ---
    Write-Host 'hardening'
    $D = New-KimiHome 'kimiD' -Tui ''   # no usage API: every fetch fails
    Write-KimiCacheRules $D 1200
    Invoke-Script $install @('-KimiHome', $D) | Out-Null
    $dsid = 'session_d'
    $dsdir = "$D\sessions\wd_d\$dsid"
    Write-Text "$dsdir\state.json" ('{"createdAt":' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + '}')
    Write-Text "$dsdir\agents\main\wire.jsonl" ((Edit-Call 'd1' 'a' 'b') + (Tool-Result 'd1' 'Replaced 1 occurrence'))
    $proof = Join-Path $Root 'proof'
    $dstate = "$D\cache\statusline\$dsid.state"
    # an offset that bash arithmetic would evaluate: a[$(...)] runs the command substitution
    Write-Text $dstate ("0`t0`t`nK`t0`t0`t-`t-`t-`t-`t-`nF`t" + (ConvertTo-MsysPath "$dsdir\agents\main\wire.jsonl") + "`ta[`$(printf owned > " + (ConvertTo-MsysPath $proof) + ")]`n")
    (Get-Item -LiteralPath $dstate).LastWriteTime = (Get-Date).AddHours(-1)
    Invoke-Render $D -Sid $dsid | Out-Null
    $ok = Wait-Until { (Read-Text $dstate).StartsWith("1`t1`t") }
    Check 'a tampered session cache is not evaluated' ($ok -and -not (Test-Path -LiteralPath $proof)) (Read-Text $dstate)
    $drules = "$D\cache\statusline\cache-rules"
    Check "server unreachable: Kimi Code's own copy of the cache rules, fetched again next time" (Wait-Until { (Read-Text $drules) -ceq "0`nk3`t1200`n" }) (Read-Text $drules)
    Check '... and the quota marked as failed' (Wait-Until { (Read-Text "$D\cache\statusline\quota") -match "`t\?`n$" }) (Read-Text "$D\cache\statusline\quota")
    # a tampered quota cache: numbers only, nothing evaluated (r5 ends up in arithmetic)
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Write-Text "$D\cache\statusline\quota" ("$($now + 300)`t$now`t92`tq`t1`ta[`$(printf owned > " + (ConvertTo-MsysPath $proof) + ")]`t2`t3`t4`n")
    $o = Invoke-Render $D
    Check 'a tampered quota cache is not evaluated' ($o.Code -eq 0 -and -not (Test-Path -LiteralPath $proof) -and $o.Text.Contains("$($G.quota) 5h 1% $($G.dot) 7d 2%")) $o.Text
    # Kimi Code reached the server since: its newer copy replaces ours
    (Get-Item -LiteralPath $drules).LastWriteTime = (Get-Date).AddMinutes(-1)
    Write-KimiCacheRules $D 2400
    Write-Text "$D\cache\statusline\quota" "0`t0`t90`t?`n"   # a fetch is due
    Invoke-Render $D | Out-Null
    Check "... and a newer copy of Kimi Code's replaces it" (Wait-Until { (Read-Text $drules) -ceq "0`nk3`t2400`n" }) (Read-Text $drules)
    if ($Python) {
        $E = New-KimiHome 'kimiE' -BaseUrl $BaseUrl -Tui ''
        $cfg = (Read-Text "$E\config.toml") -replace '\[providers\."managed:kimi-code"\]', "  [providers.'managed:kimi-code']" -replace '\[providers\."managed:kimi-code"\.oauth\]', "[ providers . 'managed:kimi-code' . oauth ]"
        Write-Text "$E\config.toml" $cfg
        Invoke-Script $install @('-KimiHome', $E) | Out-Null
        Invoke-Render $E | Out-Null
        Check 'provider header spelled another way: quota still fetched' (Wait-Until { (Read-Text "$E\cache\statusline\quota") -match "`tq`t5`t" }) (Read-Text "$E\cache\statusline\quota")
    } else { Skip 'provider header spelling' 'no Python for the mock server' }

    # ------------------------------------------------------------------ web mode ---
    Write-Host 'web install'
    # iex from a wrapper script must download, not take a statusline.sh next to the wrapper
    $wrap = Join-Path $Root 'wrapper'
    Write-Text "$wrap\statusline.sh" "#!/bin/sh`n# kimi-code-statusline-bash decoy`necho decoy`n"
    Write-Text "$wrap\setup.ps1" ("# runs kimi-code-statusline-bash's installer`n[IO.File]::ReadAllText('" + $install + "') | Invoke-Expression`n")
    $W = New-KimiHome 'kimiW' -Tui ''
    $r = Invoke-Command64 "`$env:KIMI_CODE_HOME = '$W'; try { & '$wrap\setup.ps1' } catch { `"caught: `$_`" }"
    Check "iex from a wrapper script ignores the wrapper's neighbor" ($r.Output -match 'Downloading https://github\.com/' -and (Read-Text "$W\statusline-bash\statusline.sh") -notmatch 'decoy') $r.Output
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
