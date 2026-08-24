# Run a Lua harness as a scenario in the real Factorio client and collect what it wrote.
#
# Takes parameters, unlike the other scripts here, because it is a runner rather
# than a single fixed job.
#
# The headless server (tools/check/probe.ps1) is the cheaper way to ask the game
# questions and should be preferred. This exists for the two things it cannot do:
#
#   * a real player. build_from_cursor, the cursor stack, build/reach distance and
#     rotate-by-player only exist for a character, and a headless server cannot
#     make one -- create_character on an offline player fails outright with "User
#     isn't connected; can't create character." A harness that script-creates
#     entities instead bypasses on_built_entity and proves nothing about a hand
#     placement.
#
#   * rendering. game.take_screenshot silently does nothing headless, so visual
#     evidence has to come from the client.
#
# The harness writes its own verdict with helpers.write_file into script-output,
# and that artefact appearing IS the completion signal: the client keeps running
# once the harness is done, so there is no exit to wait for. What the process
# handle does give is the other half -- a client that dies during load exits, and
# waiting the full timeout for a report that can never arrive is the difference
# between a 4-second failure and a 4-minute one.
#
# This one does not parallelise even with -Instance: it opens a real window, so a
# second copy fights the first for focus and the human's screen.

param(
    [Parameter(Mandatory = $true)][string]$Lua,
    [string]$Scenario = "verify",
    [string[]]$Expect = @("report.txt"),
    [int]$Timeout = 240,
    [string]$Instance = "",
    [switch]$Keep
)

# The repo's own Factorio, and it has to be the non-Steam build: launch a Steam
# copy directly and it raises a confirmation dialog no script can answer, after
# which the run reports "Scenario ... not found" for a directory plainly on disk.
$repo         = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$factorioExe  = Join-Path $repo "factorio\bin\x64\factorio.exe"

. (Join-Path $repo "tools\lib\instance.ps1")
$target       = Get-FactorioInstance -Instance $Instance
$scenariosDir = $target.Scenarios
$outputDir    = $target.Output
$stateFile    = Join-Path $target.State "rcon.json"

if (-not (Test-Path $factorioExe)) { Write-Error "Factorio executable not found at: $factorioExe"; exit 1 }
if (-not (Test-Path $Lua)) { Write-Error "Harness not found at: $Lua"; exit 1 }

# Both processes want the same user data directory, and the loser reports a lock
# file problem rather than a conflict. Only this instance's server matters: a
# server under another -Instance name holds a different lock.
if (Test-Path $stateFile) {
    Write-Error "A verification server is running. Run tools/check/probe.ps1 -Action stop first."
    exit 1
}

$scenarioDir = Join-Path $scenariosDir $Scenario
$collected   = Join-Path $outputDir $Scenario

New-Item -ItemType Directory -Path $scenarioDir -Force | Out-Null
Copy-Item $Lua (Join-Path $scenarioDir "control.lua") -Force
Remove-Item $collected -Recurse -Force -ErrorAction SilentlyContinue

$process = Start-Process -FilePath $factorioExe -ArgumentList (@(
    "--load-scenario", $Scenario, "--disable-audio") + $target.LaunchArgs) -PassThru

$elapsed = 0
$ready = $false
$died  = $false
while ($elapsed -lt $Timeout) {
    Start-Sleep -Seconds 2
    $elapsed += 2
    $present = $true
    foreach ($name in $Expect) {
        if (-not (Test-Path (Join-Path $collected $name))) { $present = $false }
    }
    if ($present) { $ready = $true; break }
    # Checked after the artefacts, not before: a harness that writes its report
    # and then closes the game is a pass, and losing the race would call it a
    # crash.
    if ($process.HasExited) { $died = $true; break }
}

if (-not $process.HasExited) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    $process.WaitForExit(5000) | Out-Null
}
if (-not $Keep) { Remove-Item $scenarioDir -Recurse -Force -ErrorAction SilentlyContinue }

if (-not $ready) {
    # A harness that dies takes its report with it, which is why the templates
    # pcall their bodies and write the report regardless. Failing that, the game's
    # own log is the only witness.
    Write-Host "=== last errors from factorio-current.log ==="
    if (Test-Path $target.Log) { Select-String -Path $target.Log -Pattern "Error|Exception" | Select-Object -Last 8 }
    if ($died) {
        Write-Error "Factorio exited with code $($process.ExitCode) before writing $($Expect -join ', ')."
    } else {
        Write-Error "Harness did not produce $($Expect -join ', ') within ${Timeout}s."
    }
    exit 1
}

foreach ($name in $Expect) {
    $path = Join-Path $collected $name
    Write-Host "=== $name ==="
    if ($name -match '\.(txt|json|log|csv)$') { Get-Content $path } else { Write-Host $path }
}
Write-Host ""
Write-Host "Artefacts in $collected -- delete it when done."
