# Launch the repo's own Factorio on the dev save.
#
# Mods and saves are NOT inside factorio/: the install ships
# use-system-read-write-data-directories=true in config-path.cfg, so they stay in
# %APPDATA%\Factorio wherever the install itself sits -- which is the folder
# tools/setup/dev-mode.ps1 junctions src/ into. Every script here follows suit.

$repo        = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$factorioExe = Join-Path $repo "factorio\bin\x64\factorio.exe"
$save        = Join-Path $env:APPDATA "Factorio\saves\dev.zip"

if (-not (Test-Path $factorioExe)) {
    Write-Error "Factorio executable not found at: $factorioExe"
    exit 1
}

if (-not (Test-Path $save)) {
    Write-Error "Save file not found at: $save"
    exit 1
}

$argumentList = @(
    "--load-game", $save,
    "--disable-audio"
)

Start-Process -FilePath $factorioExe -ArgumentList $argumentList
