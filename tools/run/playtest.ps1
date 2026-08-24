# Launch the repo's own Factorio on the dev save.
#
# Mods and saves live inside factorio/ beside the executable -- the portable
# layout tools/lib/instance.ps1 pins, so nothing here reaches the Steam install.
#
# -Instance moves all of that into .factorio/<name>/ instead. Playing without it
# is the right default: this is the human's game, and an agent holding its lock
# file is exactly what instances exist to prevent.

param(
    [string]$Instance = ""
)

$repo        = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$factorioExe = Join-Path $repo "factorio\bin\x64\factorio.exe"

. (Join-Path $repo "tools\lib\instance.ps1")
$target = Get-FactorioInstance -Instance $Instance
$save   = Join-Path $target.Saves "dev.zip"

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
) + $target.LaunchArgs

Start-Process -FilePath $factorioExe -ArgumentList $argumentList
