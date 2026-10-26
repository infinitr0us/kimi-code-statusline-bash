<#
.SYNOPSIS
    Builds the assets of a release into dist\.

.DESCRIPTION
    dist\ gets statusline.sh with the tag stamped into KSL_VERSION, install.ps1,
    uninstall.ps1, install.sh, uninstall.sh, kimi-code-statusline-bash-<tag>.zip with all
    of it plus the docs,
    SHA256SUMS.txt, and NOTES.md (the CHANGELOG.md section of the tag, which must exist).
    The release workflow runs this on a pushed tag; run it locally to check a build.

.EXAMPLE
    ./tools/build-release.ps1 v0.1.0
#>
param([Parameter(Mandatory = $true)][string]$Tag)

$ErrorActionPreference = 'Stop'
if ($Tag -notmatch '^v(\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?)$') { throw "Tag $Tag is not of the form v1.2.3 or v1.2.3-rc.1." }
$number = $Matches[1]
$repo = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $repo 'dist'
$name = "kimi-code-statusline-bash-$Tag"
$pkg = Join-Path $dist $name
$utf8 = New-Object System.Text.UTF8Encoding $false

if (Test-Path -LiteralPath $dist) { Remove-Item -LiteralPath $dist -Recurse -Force }
New-Item -ItemType Directory -Path $pkg | Out-Null

$log = [IO.File]::ReadAllText((Join-Path $repo 'CHANGELOG.md')) -replace "`r`n", "`n"
$section = [regex]::Match($log, "(?ms)^## \[?$([regex]::Escape($number))\]?[^\n]*\n(.*?)(?=^## |\z)")
if (-not $section.Success) { throw "CHANGELOG.md has no section for $number." }
[IO.File]::WriteAllText((Join-Path $dist 'NOTES.md'), $section.Groups[1].Value.Trim() + "`n", $utf8)

$sh = [IO.File]::ReadAllText((Join-Path $repo 'statusline.sh')) -replace "`r`n", "`n"
if ($sh -notmatch '(?m)^KSL_VERSION=dev ') { throw 'statusline.sh has no KSL_VERSION=dev line to stamp.' }
$sh = $sh -replace '(?m)^KSL_VERSION=dev ', "KSL_VERSION=$Tag "
[IO.File]::WriteAllText((Join-Path $pkg 'statusline.sh'), $sh, $utf8)
foreach ($f in 'install.ps1', 'uninstall.ps1', 'install.sh', 'uninstall.sh', 'README.md', 'README.zh-CN.md', 'CHANGELOG.md', 'LICENSE') {
    Copy-Item -LiteralPath (Join-Path $repo $f) -Destination $pkg
}
New-Item -ItemType Directory -Path (Join-Path $pkg 'assets') | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'assets\screenshot.png') -Destination (Join-Path $pkg 'assets')   # the READMEs show it

Compress-Archive -Path $pkg -DestinationPath (Join-Path $dist "$name.zip")
foreach ($f in 'statusline.sh', 'install.ps1', 'uninstall.ps1', 'install.sh', 'uninstall.sh') { Copy-Item -LiteralPath (Join-Path $pkg $f) -Destination $dist }
Remove-Item -LiteralPath $pkg -Recurse -Force

$assets = Get-ChildItem -LiteralPath $dist -File | Where-Object { $_.Name -ne 'NOTES.md' } | Sort-Object Name
$sums = foreach ($a in $assets) { '{0}  {1}' -f (Get-FileHash -LiteralPath $a.FullName -Algorithm SHA256).Hash.ToLower(), $a.Name }
[IO.File]::WriteAllText((Join-Path $dist 'SHA256SUMS.txt'), ($sums -join "`n") + "`n", $utf8)

Get-ChildItem -LiteralPath $dist -File | ForEach-Object { '  {0,-45} {1,8} bytes' -f $_.Name, $_.Length }
