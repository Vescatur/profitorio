# Run Factorio headless to validate mod loading.
# Starts a server with the dev save, waits for it to fully load,
# then kills it and returns stdout/stderr so CI or Claude can check for errors.

param(
    [string]$Instance = ""
)

# The repo's own Factorio. tools/lib/instance.ps1 answers where the save is:
# inside factorio\ by default, or under .factorio\<name>\ for an -Instance.
$repo        = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$factorioExe = Join-Path $repo "factorio\bin\x64\factorio.exe"

. (Join-Path $repo "tools\lib\instance.ps1")
$target   = Get-FactorioInstance -Instance $Instance
$saveName = Join-Path $target.Saves "dev.zip"

# Beside the save, not in the caller's working directory. Two instances launched
# from one shell would otherwise read each other's log and each report whatever
# the other one did.
$stdoutFile = Join-Path $target.State "prototypes-stdout.txt"
$stderrFile = Join-Path $target.State "prototypes-stderr.txt"
if (-not (Test-Path $target.State)) { New-Item -ItemType Directory -Path $target.State -Force | Out-Null }

if (-not (Test-Path $factorioExe)) {
    Write-Error "Factorio executable not found at: $factorioExe"
    exit 1
}

if (-not (Test-Path $saveName)) {
    Write-Error "Save file not found at: $saveName"
    exit 1
}

# --start-server binds UDP 34197 unless told otherwise, so a second one fails on
# the bind rather than on anything to do with the mod.
$argumentList = @(
    "--start-server", $saveName,
    "--port", (Get-FreePort -Protocol Udp),
    "--disable-audio"
) + $target.LaunchArgs

Write-Host "Starting Factorio headless$(if ($target.Name) { " [instance $($target.Name)]" })..."

$process = Start-Process -FilePath $factorioExe -ArgumentList $argumentList `
    -NoNewWindow -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile `
    -PassThru

# Wait for the process to either exit on its own (error) or finish loading.
# Factorio prints a specific line when the map is fully loaded.
$timeout = 60  # seconds
$elapsed = 0
$loaded  = $false
$errored = $false

while ($elapsed -lt $timeout) {
    if ($process.HasExited) {
        $errored = $true
        break
    }

    if (Test-Path $stdoutFile) {
        $content = Get-Content $stdoutFile -Raw -ErrorAction SilentlyContinue
        if ($content -and $content -match "changing state from\(CreatingGame\) to\(InGame\)") {
            $loaded = $true
            break
        }
    }

    Start-Sleep -Milliseconds 500
    $elapsed += 0.5
}

# Kill the server now that we have our answer
if (-not $process.HasExited) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    $process.WaitForExit(5000) | Out-Null
}

# Print output
Write-Host "`n=== STDOUT ==="
if (Test-Path $stdoutFile) {
    Get-Content $stdoutFile
}

$stderr = ""
if (Test-Path $stderrFile) {
    $stderr = Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue
}
if ($stderr) {
    Write-Host "`n=== STDERR ==="
    Write-Host $stderr
}

# Clean up temp files
Remove-Item $stdoutFile -ErrorAction SilentlyContinue
Remove-Item $stderrFile -ErrorAction SilentlyContinue

# Determine exit code
if ($errored) {
    Write-Host "`nFactorio exited with code $($process.ExitCode) (mod load error likely)."
    exit 1
} elseif ($loaded) {
    Write-Host "`nFactorio loaded successfully."
    exit 0
} else {
    Write-Host "`nTimeout: Factorio did not finish loading within ${timeout}s."
    exit 2
}
