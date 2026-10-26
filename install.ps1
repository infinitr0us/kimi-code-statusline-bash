<#
.SYNOPSIS
    Installs kimi-code-statusline-bash, a Claude Code style status line for Kimi Code on Windows.

.DESCRIPTION
    Puts statusline.sh and a statusline.cmd launcher into <Kimi home>\statusline-bash and
    points [status_line] command in <Kimi home>\tui.toml at the launcher. <Kimi home> is
    KIMI_CODE_HOME, else ~\.kimi-code. Files it replaces are backed up first, and
    uninstall.ps1 undoes the install. Running it again upgrades in place.

    From a release zip or a clone it installs the statusline.sh next to it. Run from the
    web, it downloads statusline.sh from the GitHub release:
        irm https://raw.githubusercontent.com/infinitr0us/kimi-code-statusline-bash/main/install.ps1 | iex

.PARAMETER Version
    Release tag to download statusline.sh from, such as v0.1.0. Default: the latest release.
    Not used when a statusline.sh sits next to this script.

.PARAMETER Source
    Path or http(s) URL of the statusline.sh to install, instead of the two above.

.PARAMETER KimiHome
    Kimi Code's home folder. Default: KIMI_CODE_HOME, else ~\.kimi-code.

.PARAMETER GitBash
    Path to Git for Windows' bash.exe. Default: found automatically.

.PARAMETER JqPath
    Path to jq.exe. Default: found automatically (PATH, WinGet, Scoop, Chocolatey, conda).

.PARAMETER Force
    Replace a status line command that something else set in tui.toml. Its old line is
    recorded, and uninstall.ps1 puts it back.
#>
[CmdletBinding()]
param(
    [string]$Version = 'latest',
    [string]$Source,
    [string]$KimiHome,
    [string]$GitBash,
    [string]$JqPath,
    [switch]$Force
)

# The file this script runs from, or $null under `irm ... | iex` (a script block literal
# knows the file it was parsed from; $MyInvocation would be the caller's under iex).
$KslSelf = { }.File

# Everything runs in a child scope, so `irm ... | iex` leaves no settings behind in the
# caller's session, and a failure ends the script without closing the window (no `exit`).
& {
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest's progress bar is very slow in 5.1

$Repo = 'infinitr0us/kimi-code-statusline-bash'
$Utf8 = New-Object System.Text.UTF8Encoding $false

function Say([string]$Message) { Write-Host "  $Message" }
function Warn([string]$Message) { Write-Host "  ! $Message" -ForegroundColor Yellow }
function Parent([string]$Path) { if ($Path) { Split-Path -Parent $Path } }
function Test-File([string]$Path) { $Path -and (Test-Path -LiteralPath $Path -PathType Leaf) }
function Test-Ascii([string]$Text) { $Text -notmatch '[^\x00-\x7F]' }

if ($env:OS -ne 'Windows_NT') {
    throw 'This installer is for Kimi Code on Windows (it runs on Git for Windows). On macOS, use install.sh (see the README).'
}
Write-Host 'kimi-code-statusline-bash installer'

# Nothing is written until every check below has passed.

# ---------------------------------------------------------------- Kimi home ---
if (-not $KimiHome) {
    $KimiHome = if ($env:KIMI_CODE_HOME) { $env:KIMI_CODE_HOME } else { Join-Path $HOME '.kimi-code' }
}
$KimiHome = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($KimiHome).TrimEnd('\')
if (-not (Test-Path -LiteralPath $KimiHome -PathType Container)) {
    throw "Kimi Code's home folder $KimiHome does not exist. Install Kimi Code and start it once, or pass -KimiHome."
}
if ($KimiHome -match '[%!"]') {
    throw "Kimi Code's home folder $KimiHome contains % ! or `", which a cmd.exe command line cannot carry."
}
$AppDir = Join-Path $KimiHome 'statusline-bash'
$ShimPath = Join-Path $AppDir 'statusline.cmd'
$TuiPath = Join-Path $KimiHome 'tui.toml'
$InfoPath = Join-Path $AppDir 'install.json'
Say "Kimi Code home: $KimiHome"

# ----------------------------------------------------------------- Git Bash ---
function Find-GitBash {
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($key in 'HKLM:\SOFTWARE\GitForWindows', 'HKCU:\SOFTWARE\GitForWindows') {
        $p = (Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue).InstallPath
        if ($p) { $roots.Add($p) }
    }
    $git = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($git) {   # <root>\cmd\git.exe, <root>\bin\git.exe or <root>\mingw64\bin\git.exe
        $d = Parent $git.Source
        $roots.Add((Parent $d)); $roots.Add((Parent (Parent $d)))
    }
    $roots.Add((Join-Path $env:ProgramFiles 'Git'))
    if ($env:LOCALAPPDATA) { $roots.Add((Join-Path $env:LOCALAPPDATA 'Programs\Git')) }
    $roots.Add((Join-Path $HOME 'scoop\apps\git\current'))
    foreach ($r in $roots) {
        # usr\bin\bash.exe itself: bin\bash.exe is only a launcher for it, ~12 ms slower
        if ($r) { $b = Join-Path $r 'usr\bin\bash.exe'; if (Test-File $b) { return $b } }
    }
}
if ($GitBash) {
    $GitBash = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($GitBash)
    if (-not (Test-File $GitBash)) { throw "-GitBash $GitBash does not exist." }
} else {
    $GitBash = Find-GitBash
    if (-not $GitBash) {
        throw 'Git for Windows was not found. Install it (winget install Git.Git) or pass -GitBash <path to usr\bin\bash.exe>.'
    }
}
$bashMajor = & $GitBash --norc --noprofile -c 'echo ${BASH_VERSINFO[0]}' 2>$null
if (-not ($bashMajor -match '^\d+$' -and [int]$bashMajor -ge 5)) {
    throw "$GitBash is not bash 5 or newer (got '$bashMajor'). Update Git for Windows."
}
Say "Git Bash: $GitBash"

function ConvertTo-BatchPath([string]$Path) {
    # %LOCALAPPDATA% & co. for the user's folders, so the .cmd file stays ASCII under a
    # non-ASCII user name: cmd reads .cmd files in the console code page, not UTF-8
    $Path = $Path -replace '%', '%%'
    foreach ($v in 'LOCALAPPDATA', 'APPDATA', 'USERPROFILE') {
        $root = [Environment]::GetEnvironmentVariable($v)
        if (-not $root) { continue }
        $root = $root.TrimEnd('\') -replace '%', '%%'
        if ($Path.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { return "%$v%" + $Path.Substring($root.Length) }
    }
    $Path
}
$bashForBatch = ConvertTo-BatchPath $GitBash
if (-not (Test-Ascii $bashForBatch)) {   # an 8.3 short name, where the volume has them
    $short = (New-Object -ComObject Scripting.FileSystemObject).GetFile($GitBash).ShortPath
    $bashForBatch = ConvertTo-BatchPath $short
    if (-not (Test-Ascii $bashForBatch)) {
        throw "Git Bash's path $GitBash has non-ASCII characters, which a .cmd file cannot carry reliably. Install Git for Windows in a folder with an ASCII name, or pass -GitBash with such a copy."
    }
}

# ----------------------------------------------------------------------- jq ---
function Find-Jq {
    $c = Get-Command jq.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:LOCALAPPDATA) { $candidates.Add((Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\jq.exe')) }
    $candidates.Add((Join-Path $HOME 'scoop\shims\jq.exe'))
    if ($env:ProgramData) { $candidates.Add((Join-Path $env:ProgramData 'chocolatey\bin\jq.exe')) }
    $conda = Get-Command conda -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    foreach ($exe in @($env:CONDA_EXE, $(if ($conda) { $conda.Source }))) {
        $root = Parent (Parent $exe)   # <root>\Scripts\conda.exe or <root>\condabin\conda.bat
        if ($root) {
            $candidates.Add((Join-Path $root 'Library\mingw-w64\bin\jq.exe'))
            $candidates.Add((Join-Path $root 'Library\bin\jq.exe'))
        }
    }
    foreach ($p in $candidates) { if (Test-File $p) { return $p } }
}
if ($JqPath) {
    $JqPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($JqPath)
    if (-not (Test-File $JqPath)) { throw "-JqPath $JqPath does not exist." }
} else {
    $JqPath = Find-Jq
}
if ($JqPath) { Say "jq: $JqPath" }
else { Warn 'jq was not found: the quota, thinking effort and changed-lines parts stay empty. Install it with "winget install jqlang.jq" and run this installer again.' }

# -------------------------------------------------------------- statusline.sh ---
$tmp = $null
if (-not $Source) {
    $local = if ($KslSelf) { Join-Path (Parent $KslSelf) 'statusline.sh' }
    if (Test-File $local) { $Source = $local }
    elseif ($Version -eq 'latest') { $Source = "https://github.com/$Repo/releases/latest/download/statusline.sh" }
    else { $Source = "https://github.com/$Repo/releases/download/$Version/statusline.sh" }
}
if ($Source -match '^https?://') {
    Say "Downloading $Source"
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('kimi-statusline-' + [guid]::NewGuid().ToString('N') + '.sh')
    Invoke-WebRequest -Uri $Source -OutFile $tmp -UseBasicParsing
    $srcFile = $tmp
} else {
    $srcFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Source)
    if (-not (Test-File $srcFile)) { throw "$srcFile does not exist." }
}
try { $script = [IO.File]::ReadAllText($srcFile, $Utf8) } finally { if ($tmp) { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue } }
if (-not $script.StartsWith('#!') -or -not $script.Contains('kimi-code-statusline-bash')) {
    throw "$Source is not kimi-code-statusline-bash's statusline.sh."
}
$script = $script.TrimStart([char]0xFEFF) -replace "`r`n", "`n"   # bash needs LF
$ver = if ($script -match '(?m)^KSL_VERSION=(\S+)') { $Matches[1] } else { 'unknown' }

# ----------------------------------------------------------------- tui.toml ---
# Kimi runs the command as `cmd.exe /d /s /c <command>` through Node, which wraps it in
# quotes when it has a space; /s strips them again. So: forward slashes (no TOML escapes),
# and ^ in front of each space or other cmd special character, which cmd then reads as
# part of the path.
$Command = ($ShimPath -replace '\\', '/') -replace '([ &|<>^(),;=])', '^$1'

# TOML, as far as this installer needs it: bare, "quoted" or 'quoted' key and table names
$TableRe = '^\s*\[\s*(?:status_line|"status_line"|''status_line'')\s*\]\s*(?:#.*)?$'
$DottedRe = '^\s*(?:status_line|"status_line"|''status_line'')\s*[.=]'
$KeyRe = '^\s*(?:command|"command"|''command'')\s*='
function Get-TomlCommand([string]$Line) {
    # the string value of a `command = ...` line, or $null for any other form
    $m = [regex]::Match($Line, $KeyRe + '\s*(?:"((?:[^"\\]|\\.)*)"|''([^'']*)'')\s*(?:#.*)?$')
    if (-not $m.Success) { return $null }
    if ($m.Groups[2].Success) { return $m.Groups[2].Value }
    [regex]::Replace($m.Groups[1].Value, '\\(u[0-9A-Fa-f]{4}|U[0-9A-Fa-f]{8}|.)', [Text.RegularExpressions.MatchEvaluator] {
        param($e)
        $c = $e.Groups[1].Value
        $k = $c.Substring(0, 1)
        if ($k -ceq 'u') { return [string][char][Convert]::ToInt32($c.Substring(1), 16) }
        if ($k -ceq 'U') { return [char]::ConvertFromUtf32([Convert]::ToInt32($c.Substring(1), 16)) }
        if ($k -ceq 'b') { return [string][char]8 }
        if ($k -ceq 't') { return "`t" }
        if ($k -ceq 'n') { return "`n" }
        if ($k -ceq 'f') { return [string][char]12 }
        if ($k -ceq 'r') { return "`r" }
        return $c   # \" and \\
    })
}
function Test-OurCommand([string]$Value, [string]$Recorded) {
    # the whole value is this home's launcher (as written by this installer, or as recorded)
    $plain = { param($s) ($s -replace '\^(.)', '$1' -replace '\\', '/').Trim() }
    $v = & $plain $Value
    ($v -ieq (& $plain $Command)) -or ($Recorded -and $v -ieq (& $plain $Recorded))
}

# The file as $lines and what ended each line, $seps ("`r`n", "`n", or '' for the last), so a
# file with mixed line endings is written back as it was, but for the lines changed. (Ordinal
# tests only: .NET's culture-aware string comparisons may ignore control characters.)
function Split-Lines([string]$Text) {   # fills $lines and $seps
    $start = 0
    while (($i = $Text.IndexOf([char]10, $start)) -ge 0) {
        $l = $Text.Substring($start, $i - $start)
        if ($l.Length -gt 0 -and [int]$l[$l.Length - 1] -eq 13) { $lines.Add($l.Substring(0, $l.Length - 1)); $seps.Add("`r`n") }
        else { $lines.Add($l); $seps.Add("`n") }
        $start = $i + 1
    }
    $lines.Add($Text.Substring($start)); $seps.Add('')
}
function Add-Line([int]$At, [string]$Text) {
    # a line put before line $At (or at the end), ending like the line before it
    $sep = $nl
    if ($At -gt 0 -and $seps[$At - 1].Length -gt 0) { $sep = $seps[$At - 1] }
    if ($At -ge $lines.Count) {   # at the end: the old last line gets an end, the new one has none
        if ($lines.Count -gt 0) { $seps[$lines.Count - 1] = $sep }
        $lines.Add($Text); $seps.Add('')
    } else { $lines.Insert($At, $Text); $seps.Insert($At, $sep) }
}

$raw = ''
$bom = $false
if (Test-File $TuiPath) {
    $bytes = [IO.File]::ReadAllBytes($TuiPath)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $raw = $Utf8.GetString($bytes).TrimStart([char]0xFEFF)
}
$lines = New-Object System.Collections.Generic.List[string]
$seps = New-Object System.Collections.Generic.List[string]
if ($raw.Length -gt 0) { Split-Lines $raw }
# for lines that have no neighbor to follow: the more common line ending
$nl = if (@($seps | Where-Object { $_.Length -eq 2 }).Count -gt @($seps | Where-Object { $_.Length -eq 1 }).Count) { "`r`n" } else { "`n" }
foreach ($l in $lines) {
    if ($l -match $DottedRe) {
        throw "$TuiPath sets status_line in a form this installer does not edit ($($l.Trim())). Change it to a [status_line] table, or set command = `"$Command`" there yourself."
    }
    # names spelled with escapes ("status\u005fline", "com\u006dand") are not read here:
    # refuse them rather than miss the status line command and add a second one
    if ($l -match '^\s*\[[^\]#]*\\' -or $l -match '^\s*"[^"]*\\[^=]*=') {
        throw "$TuiPath has a name spelled with escapes ($($l.Trim())), which this installer does not read. Write it plainly, or set command = `"$Command`" under [status_line] yourself."
    }
}
$header = -1
for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match $TableRe) { $header = $i; break } }
$cmdLine = -1
if ($header -ge 0) {
    for ($i = $header + 1; $i -lt $lines.Count -and $lines[$i] -notmatch '^\s*\['; $i++) {
        if ($lines[$i] -match $KeyRe) { $cmdLine = $i; break }
    }
}
$current = $null
if ($cmdLine -ge 0) {
    $current = Get-TomlCommand $lines[$cmdLine]
    if ($null -eq $current) { throw "Could not read the status line command in ${TuiPath}: $($lines[$cmdLine].Trim())" }
}

# what to put back on uninstall: the line this replaced, and whether the table is ours
$old = $null
if (Test-File $InfoPath) { $old = [IO.File]::ReadAllText($InfoPath, $Utf8) | ConvertFrom-Json }
if ($current -and (Test-OurCommand $current $(if ($old) { $old.command }))) {
    $previousLine = $null; $previousCommand = $null; $createdTable = $false
    if ($old) {
        if ($old.previousLine -is [string]) { $previousLine = $old.previousLine }
        if ($old.previousCommand -is [string]) { $previousCommand = $old.previousCommand }
        $createdTable = $old.createdTable -eq $true
    }
} elseif ($current) {
    if (-not $Force) {
        throw "tui.toml already runs another status line command: $current`nRun this installer with -Force to replace it; uninstall.ps1 puts it back."
    }
    $previousLine = $lines[$cmdLine]; $previousCommand = $current; $createdTable = $false
    Say "Replacing the status line command $current"
} else {
    # (explicit $null: an `if` that yields nothing would become {} in 5.1's ConvertTo-Json)
    $previousLine = $null
    if ($cmdLine -ge 0) { $previousLine = $lines[$cmdLine] }   # command = "" stays as it was
    $previousCommand = $null
    $createdTable = $header -lt 0
}

$newLine = 'command = "' + $Command + '"'
if ($cmdLine -ge 0) { $lines[$cmdLine] = $newLine }
elseif ($header -ge 0) { Add-Line ($header + 1) $newLine }
else {   # a [status_line] table of its own at the end, after an empty line
    $n = $lines.Count
    if ($n -eq 0) { Add-Line 0 '[status_line]'; Add-Line 1 $newLine; Add-Line 2 '' }
    elseif ($lines[$n - 1].Length -eq 0) {   # (the file ends with a newline: the table goes before it)
        Add-Line ($n - 1) ''; Add-Line $n '[status_line]'; Add-Line ($n + 1) $newLine
    } else {                                 # (no newline at the end, and none added)
        Add-Line $n ''; Add-Line ($n + 1) '[status_line]'; Add-Line ($n + 2) $newLine
    }
}
$sb = New-Object System.Text.StringBuilder
for ($i = 0; $i -lt $lines.Count; $i++) { [void]$sb.Append($lines[$i]).Append($seps[$i]) }
$newRaw = $sb.ToString()
$changed = -not [string]::Equals($newRaw, $raw)
if ($changed -and (Test-File $TuiPath)) {   # (tui.toml is written last, so find out now whether it can be)
    try { [IO.File]::Open($TuiPath, 'Open', 'ReadWrite', 'ReadWrite').Dispose() }
    catch { throw "Cannot write ${TuiPath}, so nothing was changed: $($_.Exception.Message)" }
}

# ------------------------------------------------------------------- write ---
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
function Backup-File([string]$Path) {
    # copies $Path to <name>.bak-<stamp>, or -2, -3 .. if that is taken (as by the backup of
    # an install in the same second)
    $b = "$Path.bak-$stamp"; $n = 2
    while (Test-Path -LiteralPath $b) { $b = "$Path.bak-$stamp-$n"; $n++ }
    Copy-Item -LiteralPath $Path -Destination $b
    Say "Backed up $Path"
}
function Write-Kept([string]$Path, [byte[]]$Bytes) {
    # writes $Path, first backing up an existing different file
    if (Test-File $Path) {
        $was = [IO.File]::ReadAllBytes($Path)
        if ([Convert]::ToBase64String($was) -ceq [Convert]::ToBase64String($Bytes)) { return }
        Backup-File $Path
    }
    [IO.File]::WriteAllBytes($Path, $Bytes)
}

New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
Write-Kept (Join-Path $AppDir 'statusline.sh') $Utf8.GetBytes($script)
# jq's path goes in a UTF-8 file that bash reads, as it may hold any characters
$jqFile = Join-Path $AppDir 'jq-path.txt'
if ($JqPath) { Write-Kept $jqFile $Utf8.GetBytes($JqPath + "`n") }
elseif (Test-File $jqFile) { Remove-Item -LiteralPath $jqFile }
$shim = @(
    '@echo off'
    "rem kimi-code-statusline-bash $ver launcher, written by install.ps1. Kimi Code runs"
    'rem [status_line] command through "cmd.exe /d /s /c"; this starts Git Bash on the'
    'rem statusline.sh next to it. Run install.ps1 again instead of editing this file.'
    ('"' + $bashForBatch + '" "%~dp0statusline.sh"')
)
Write-Kept $ShimPath ([Text.Encoding]::ASCII.GetBytes(($shim -join "`r`n") + "`r`n"))

if ($changed -and (Test-File $TuiPath)) { Backup-File $TuiPath }
# install.json goes before tui.toml, and back to what it was should tui.toml fail after all:
# so it always tells of the command tui.toml runs, which is what uninstall puts back
$oldInfo = $null
if (Test-File $InfoPath) { $oldInfo = [IO.File]::ReadAllBytes($InfoPath) }
$info = [ordered]@{
    version = $ver; installedAt = (Get-Date).ToString('o'); command = $Command
    previousCommand = $previousCommand; previousLine = $previousLine; createdTable = $createdTable
}
try { [IO.File]::WriteAllText($InfoPath, ($info | ConvertTo-Json) + "`n", $Utf8) }
catch { throw "Cannot write ${InfoPath}, so tui.toml was left as it was: $($_.Exception.Message)" }
if ($changed) {
    $out = $Utf8.GetBytes($newRaw)
    if ($bom) { $out = [byte[]](0xEF, 0xBB, 0xBF) + $out }
    try { [IO.File]::WriteAllBytes($TuiPath, $out) }
    catch {
        if ($null -ne $oldInfo) { [IO.File]::WriteAllBytes($InfoPath, $oldInfo) }
        else { Remove-Item -LiteralPath $InfoPath -ErrorAction SilentlyContinue }
        throw "Cannot write ${TuiPath} (see its backup), so install.json was put back as it was: $($_.Exception.Message)"
    }
}
Say "tui.toml: [status_line] command = `"$Command`""

# --------------------------------------------------------------- smoke test ---
# One run the way Kimi does it: the JSON snapshot on stdin, the first stdout line used.
$payload = '{"model":"Kimi","cwd":' + (ConvertTo-Json ([string]$HOME)) + ',"gitBranch":null,"permissionMode":"yolo","planMode":false,"sessionId":null}'
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
$psi.Arguments = '/d /s /c ' + $(if ($Command -match '\s') { '"' + $Command + '"' } else { $Command })
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.StandardOutputEncoding = $Utf8
$psi.EnvironmentVariables['KIMI_CODE_HOME'] = $KimiHome
$psi.EnvironmentVariables['KIMI_CODE_STATUS_LINE'] = '1'
$sw = [Diagnostics.Stopwatch]::StartNew()
$p = [Diagnostics.Process]::Start($psi)
$p.StandardInput.Write($payload); $p.StandardInput.Close()
$outTask = $p.StandardOutput.ReadToEndAsync()
if (-not $p.WaitForExit(5000)) { try { $p.Kill() } catch {} }
$sw.Stop()
$line = (($outTask.Result -split "`n")[0]).TrimEnd()
if ($p.HasExited -and $p.ExitCode -eq 0 -and $line) {
    if (-not $Host.UI.SupportsVirtualTerminal) { $line = $line -replace "\x1b\[[0-9;]*m", '' }
    Say ("Test run ({0} ms):" -f $sw.ElapsedMilliseconds)
    Write-Host "    $line"
    if ($sw.ElapsedMilliseconds -gt 300) { Warn 'That run took over 300 ms, the limit after which Kimi drops a run. A first run is slower; if Kimi keeps showing its own footer, see Troubleshooting in the README.' }
} else {
    Warn 'The test run printed nothing. See Troubleshooting in the README.'
}

Write-Host ''
Write-Host "Installed kimi-code-statusline-bash $ver into $AppDir"
Write-Host 'Next: run /reload-tui in Kimi Code (or restart it). The icons need a Nerd Font in your terminal.'
}
