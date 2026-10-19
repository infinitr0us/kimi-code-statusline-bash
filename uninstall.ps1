<#
.SYNOPSIS
    Removes kimi-code-statusline-bash from Kimi Code.

.DESCRIPTION
    Takes the [status_line] command out of <Kimi home>\tui.toml, or puts back the command
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
$TuiPath = Join-Path $KimiHome 'tui.toml'
$infoPath = Join-Path $AppDir 'install.json'
$previous = $null
if (Test-File $infoPath) { $previous = (Get-Content -LiteralPath $infoPath -Raw | ConvertFrom-Json).previousCommand }

# ----------------------------------------------------------------- tui.toml ---
if (Test-File $TuiPath) {
    $bytes = [IO.File]::ReadAllBytes($TuiPath)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $raw = $Utf8.GetString($bytes).TrimStart([char]0xFEFF)
    $nl = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.AddRange([string[]]($raw -split "`r?`n"))

    $header = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*\[\s*status_line\s*\]\s*(#.*)?$') { $header = $i; break } }
    $cmdLine = -1
    $end = $lines.Count
    if ($header -ge 0) {
        for ($i = $header + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*\[') { $end = $i; break }
            if ($cmdLine -lt 0 -and $lines[$i] -match '^\s*command\s*=') { $cmdLine = $i }
        }
    }
    $ours = $cmdLine -ge 0 -and ($lines[$cmdLine] -replace '\^', '' -replace '\\\\', '/') -imatch '/statusline-bash/statusline\.cmd"'
    if ($ours) {
        if ($previous) {
            $lines[$cmdLine] = 'command = "' + ($previous -replace '\\', '\\' -replace '"', '\"') + '"'
            Say "tui.toml: put back the earlier status line command $previous"
        } else {
            $lines.RemoveAt($cmdLine); $end--
            # drop the [status_line] header too if nothing but blanks and comments is left under it
            $empty = $true
            for ($i = $header + 1; $i -lt $end; $i++) { if ($lines[$i] -notmatch '^\s*(#.*)?$') { $empty = $false; break } }
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
foreach ($name in 'statusline.sh', 'statusline.cmd', 'install.json') {
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
