<#
.SYNOPSIS
    Removes kimi-code-statusline-bash from Kimi Code.

.DESCRIPTION
    Takes the [status_line] command out of <Kimi home>\tui.toml, or puts back the line
    that install.ps1 -Force replaced, then deletes the installed files and the status
    line's cache. Backups made by install.ps1 stay where they are. <Kimi home> is
    KIMI_CODE_HOME, else ~\.kimi-code.
        irm https://raw.githubusercontent.com/infinitr0us/kimi-code-statusline-bash/main/uninstall.ps1 | iex

.PARAMETER KimiHome
    Kimi Code's home folder. Default: KIMI_CODE_HOME, else ~\.kimi-code.
#>
[CmdletBinding()]
param(
    [string]$KimiHome
)

# Child scope and no `exit`, as in install.ps1, so `irm ... | iex` is safe.
& {
$ErrorActionPreference = 'Stop'
$Utf8 = New-Object System.Text.UTF8Encoding $false

function Say([string]$Message) { Write-Host "  $Message" }
function Test-File([string]$Path) { $Path -and (Test-Path -LiteralPath $Path -PathType Leaf) }

Write-Host 'kimi-code-statusline-bash uninstaller'
if (-not $KimiHome) {
    $KimiHome = if ($env:KIMI_CODE_HOME) { $env:KIMI_CODE_HOME } else { Join-Path $HOME '.kimi-code' }
}
$KimiHome = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($KimiHome).TrimEnd('\')
if (-not (Test-Path -LiteralPath $KimiHome -PathType Container)) { throw "Kimi Code's home folder $KimiHome does not exist." }
$AppDir = Join-Path $KimiHome 'statusline-bash'
$ShimPath = Join-Path $AppDir 'statusline.cmd'
$TuiPath = Join-Path $KimiHome 'tui.toml'
$InfoPath = Join-Path $AppDir 'install.json'
$info = $null
if (Test-File $InfoPath) { $info = [IO.File]::ReadAllText($InfoPath, $Utf8) | ConvertFrom-Json }

# the same TOML reading and launcher test as install.ps1
$Command = ($ShimPath -replace '\\', '/') -replace '([ &|<>^(),;=])', '^$1'
$TableRe = '^\s*\[\s*(?:status_line|"status_line"|''status_line'')\s*\]\s*(?:#.*)?$'
$KeyRe = '^\s*(?:command|"command"|''command'')\s*='
function Get-TomlCommand([string]$Line) {
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
        return $c
    })
}
function Test-OurCommand([string]$Value, [string]$Recorded) {
    $plain = { param($s) ($s -replace '\^(.)', '$1' -replace '\\', '/').Trim() }
    $v = & $plain $Value
    ($v -ieq (& $plain $Command)) -or ($Recorded -and $v -ieq (& $plain $Recorded))
}
# the lines with their own line endings, as in install.ps1
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
function Remove-Lines([int]$From, [int]$To) {
    # lines $From to $To - 1 go; if they ran to the end, the line before them ends the file
    $toEnd = $To -ge $lines.Count
    $lines.RemoveRange($From, $To - $From); $seps.RemoveRange($From, $To - $From)
    if ($toEnd -and $From -gt 0) { $seps[$From - 1] = '' }
}

# ----------------------------------------------------------------- tui.toml ---
if (Test-File $TuiPath) {
    $bytes = [IO.File]::ReadAllBytes($TuiPath)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $raw = $Utf8.GetString($bytes).TrimStart([char]0xFEFF)
    $lines = New-Object System.Collections.Generic.List[string]
    $seps = New-Object System.Collections.Generic.List[string]
    Split-Lines $raw

    $header = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match $TableRe) { $header = $i; break } }
    $cmdLine = -1
    $end = $lines.Count
    if ($header -ge 0) {
        for ($i = $header + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*\[') { $end = $i; break }
            if ($cmdLine -lt 0 -and $lines[$i] -match $KeyRe) { $cmdLine = $i }
        }
    }
    $current = if ($cmdLine -ge 0) { Get-TomlCommand $lines[$cmdLine] }
    if ($null -ne $current -and (Test-OurCommand $current $(if ($info) { $info.command }))) {
        $previousLine = $null
        if ($info -and $info.previousLine -is [string]) { $previousLine = $info.previousLine }
        if (-not $previousLine -and $info -and $info.previousCommand -is [string] -and $info.previousCommand) {   # install.json from before previousLine
            $previousLine = 'command = "' + ($info.previousCommand -replace '\\', '\\' -replace '"', '\"') + '"'
        }
        if ($previousLine) {
            $lines[$cmdLine] = $previousLine
            Say "tui.toml: put back $($previousLine.Trim())"
        } else {
            # drop the [status_line] table too if install.ps1 added it and nothing else is in it now
            $empty = $info -and $info.createdTable -eq $true
            for ($i = $header + 1; $empty -and $i -lt $end; $i++) {
                if ($i -ne $cmdLine -and $lines[$i] -notmatch '^\s*(#.*)?$') { $empty = $false }
            }
            if ($empty) {
                $toEnd = $end -ge $lines.Count
                $last = $lines[$end - 1]
                Remove-Lines $header $end
                # At the end of a file without a final newline, install.ps1 put an empty line
                # before the table (and no newline after it): that goes too.
                if ($toEnd -and $header -gt 0 -and $last.Length -gt 0 -and $lines[$header - 1].Length -eq 0) { Remove-Lines ($header - 1) $header }
            } else { Remove-Lines $cmdLine ($cmdLine + 1) }
            Say 'tui.toml: removed the status line command; Kimi Code shows its own footer again'
        }
        # a backup of its own, also when an install backed tui.toml up this same second
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $b = "$TuiPath.bak-$stamp"; $n = 2
        while (Test-Path -LiteralPath $b) { $b = "$TuiPath.bak-$stamp-$n"; $n++ }
        Copy-Item -LiteralPath $TuiPath -Destination $b
        Say "Backed up $TuiPath"
        $sb = New-Object System.Text.StringBuilder
        for ($i = 0; $i -lt $lines.Count; $i++) { [void]$sb.Append($lines[$i]).Append($seps[$i]) }
        $out = $Utf8.GetBytes($sb.ToString())
        if ($bom) { $out = [byte[]](0xEF, 0xBB, 0xBF) + $out }
        [IO.File]::WriteAllBytes($TuiPath, $out)
    } elseif ($cmdLine -ge 0) {
        Say "tui.toml runs another status line command; left it alone: $($lines[$cmdLine].Trim())"
    }
}

# -------------------------------------------------------------------- files ---
foreach ($name in 'statusline.sh', 'statusline.cmd', 'jq-path.txt', 'install.json') {
    $p = Join-Path $AppDir $name
    if (Test-File $p) { Remove-Item -LiteralPath $p -Force }
}
if (Test-Path -LiteralPath $AppDir -PathType Container) {
    if (Get-ChildItem -LiteralPath $AppDir -Force | Select-Object -First 1) { Say "Kept the backups in $AppDir" }
    else { Remove-Item -LiteralPath $AppDir -Force }
}
# the cache; a background worker may still hold a file for a moment
$cache = Join-Path $KimiHome 'cache\statusline'
if (Test-Path -LiteralPath $cache) { Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
Write-Host 'Removed kimi-code-statusline-bash. Run /reload-tui in Kimi Code (or restart it).'
}
