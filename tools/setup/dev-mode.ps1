# Symlink src/ into the Factorio mods folder as <name>_<version> from src/info.json.
#
# The target is resolved from this script's own location, not the shell's
# working directory -- a relative path silently produced a junction pointing at
# a folder that does not exist, and Factorio then loads without the mod at all,
# which looks exactly like a clean run.

param(
    [string]$Instance = ""
)

$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$src  = Join-Path $repo "src"

if (-not (Test-Path $src)) {
    Write-Error "Mod source not found at: $src"
    exit 1
}

# Read rather than hardcode: Factorio refuses a mod whose folder name disagrees
# with the name in its info.json, so a rename here has to follow that file.
$info = Get-Content (Join-Path $src "info.json") -Raw | ConvertFrom-Json

. (Join-Path $repo "tools\lib\instance.ps1")
$mods = (Get-FactorioInstance -Instance $Instance).Mods
$link = Join-Path $mods "$($info.name)_$($info.version)"

if (Test-Path $link) {
    # rmdir removes the junction itself; Remove-Item -Recurse would follow it.
    cmd /c "rmdir `"$link`""
}

# tools/release/zip.py copies its build in here too. While both exist the folder
# wins and the zip does nothing -- until the junction goes, and Factorio loads
# that frozen copy instead without saying so, so edits to src stop taking effect.
if (Test-Path $mods) {
    Get-ChildItem -Path $mods -Filter "$($info.name)_*.zip" -File |
        ForEach-Object {
            Write-Host "Removing built zip: $($_.Name)"
            Remove-Item $_.FullName -Force
        }
}

cmd /c "mklink /J `"$link`" `"$src`""
