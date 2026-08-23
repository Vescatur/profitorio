# Start or stop a throwaway Factorio server with RCON open, for tools/check/probe_client.py.
#
# Takes parameters, unlike the other scripts here, because it is a runner rather
# than a single fixed job.
#
# It serves a COPY of the save and deletes it on stop. Verification builds test
# rigs and mutates inventories; doing that to dev.zip would quietly wreck a real
# game, and an autosave would make it permanent.
#
# Two things this exists to get right, both of which look like something else
# when you get them wrong:
#
#   * `--no-auto-pause` is not a command-line flag. Auto-pause lives in a
#     server-settings file (tools/check/probe-settings.json), and without
#     `auto_pause: false` a server with no players connected never advances a
#     tick -- a harness then builds its rig and waits forever for items that
#     cannot move.
#
#   * a running server holds Factorio's lock file, so tools/check/prototypes.ps1
#     fails with "Couldn't create lock file" and reads exactly like a mod error.
#     Always -Action stop when finished.

param(
    [ValidateSet("start", "stop")]
    [string]$Action = "start",
    [string]$Save = "dev.zip",
    [int]$Port = 27015
)

# The repo's own Factorio. Saves are not beside it: the install ships
# use-system-read-write-data-directories=true, so they stay in %APPDATA%.
$repo        = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$factorioExe = Join-Path $repo "factorio\bin\x64\factorio.exe"
$savesDir    = Join-Path $env:APPDATA "Factorio\saves"
$stateDir    = Join-Path $PSScriptRoot ".verify"
$stateFile   = Join-Path $stateDir "rcon.json"
$logFile     = Join-Path $stateDir "server-stdout.txt"
$settings    = Join-Path $PSScriptRoot "probe-settings.json"

function Stop-Server {
    if (-not (Test-Path $stateFile)) {
        Write-Host "No server state at $stateFile; nothing to stop."
        return
    }
    $state = Get-Content $stateFile -Raw | ConvertFrom-Json
    try { Stop-Process -Id $state.pid -Force -ErrorAction Stop } catch {}
    Start-Sleep -Seconds 2
    if (Test-Path $state.copy) { Remove-Item $state.copy -Force -ErrorAction SilentlyContinue }
    Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
    Write-Host "Stopped server and removed $($state.copy)."
}

if ($Action -eq "stop") {
    Stop-Server
    exit 0
}

if (-not (Test-Path $factorioExe)) { Write-Error "Factorio executable not found at: $factorioExe"; exit 1 }

$source = Join-Path $savesDir $Save
if (-not (Test-Path $source)) { Write-Error "Save not found at: $source"; exit 1 }

# A previous run that was never stopped would hold the lock file, and the second
# server dies on startup with a message about the lock rather than about itself.
if (Test-Path $stateFile) {
    Write-Error "A server is already tracked in $stateFile. Run -Action stop first."
    exit 1
}

if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir | Out-Null }

$copy = Join-Path $savesDir ($Save -replace '\.zip$', '') 
$copy = "$copy.verify.zip"
Copy-Item $source $copy -Force

# Loopback only. --rcon-port binds every interface, which is more than a local
# test harness has any business doing.
$password = [System.Guid]::NewGuid().ToString("N")
$argumentList = @(
    "--start-server", $copy,
    "--server-settings", $settings,
    "--rcon-bind", "127.0.0.1:$Port",
    "--rcon-password", $password,
    "--disable-audio"
)

$process = Start-Process -FilePath $factorioExe -ArgumentList $argumentList `
    -NoNewWindow -RedirectStandardOutput $logFile `
    -RedirectStandardError (Join-Path $stateDir "server-stderr.txt") -PassThru

$timeout = 60
$elapsed = 0
$ready = $false
while ($elapsed -lt $timeout) {
    if ($process.HasExited) { break }
    if (Test-Path $logFile) {
        $log = Get-Content $logFile -Raw -ErrorAction SilentlyContinue
        if ($log -and $log -match "Starting RCON interface") { $ready = $true; break }
    }
    Start-Sleep -Milliseconds 500
    $elapsed += 0.5
}

if (-not $ready) {
    Write-Host "=== SERVER LOG ==="
    if (Test-Path $logFile) { Get-Content $logFile }
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item $copy -Force -ErrorAction SilentlyContinue
    Write-Error "Server did not open RCON within ${timeout}s."
    exit 1
}

@{ host = "127.0.0.1"; port = $Port; password = $password; pid = $process.Id; copy = $copy } |
    ConvertTo-Json | Set-Content $stateFile -Encoding utf8

Write-Host "Server up on 127.0.0.1:$Port serving $copy (pid $($process.Id))."
Write-Host "Drive it with: python tools/check/probe_client.py"
Write-Host "Stop it with:  powershell tools/check/probe.ps1 -Action stop"
