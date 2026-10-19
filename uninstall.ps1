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

# ----------------------------------------------------------------- tui.toml ---
if (Test-File $TuiPath) {
    $bytes = [IO.File]::ReadAllBytes($TuiPath)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $raw = $Utf8.GetString($bytes).TrimStart([char]0xFEFF)
    $nl = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.AddRange([string[]]($raw -split "`r?`n"))

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
            $lines.RemoveAt($cmdLine); $end--
            # drop the [status_line] table too if install.ps1 added it and nothing else is in it now
            $empty = $info -and $info.createdTable -eq $true
            for ($i = $header + 1; $empty -and $i -lt $end; $i++) { if ($lines[$i] -notmatch '^\s*(#.*)?$') { $empty = $false } }
            if ($empty) { $lines.RemoveRange($header, $end - $header) }
            Say 'tui.toml: removed the status line command; Kimi Code shows its own footer again'
        }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Copy-Item -LiteralPath $TuiPath -Destination "$TuiPath.bak-$stamp"
        Say "Backed up $TuiPath"
        $out = $Utf8.GetBytes($lines -join $nl)
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
