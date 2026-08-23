# Run Factorio headless to validate mod loading.
# Starts a server with the dev save, waits for it to fully load,
# then kills it and returns stdout/stderr so CI or Claude can check for errors.

# The repo's own Factorio. The save is not beside it: the install ships
# use-system-read-write-data-directories=true, so saves stay in %APPDATA%.
$repo        = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$factorioExe = Join-Path $repo "factorio\bin\x64\factorio.exe"
$saveName    = Join-Path $env:APPDATA "Factorio\saves\dev.zip"

if (-not (Test-Path $factorioExe)) {
    Write-Error "Factorio executable not found at: $factorioExe"
    exit 1
}

if (-not (Test-Path $saveName)) {
    Write-Error "Save file not found at: $saveName"
    exit 1
}

$argumentList = @(
    "--start-server", $saveName,
    "--disable-audio"
)

Write-Host "Starting Factorio headless..."

$process = Start-Process -FilePath $factorioExe -ArgumentList $argumentList `
    -NoNewWindow -RedirectStandardOutput "factorio-stdout.txt" -RedirectStandardError "factorio-stderr.txt" `
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

    if (Test-Path "factorio-stdout.txt") {
        $content = Get-Content "factorio-stdout.txt" -Raw -ErrorAction SilentlyContinue
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
if (Test-Path "factorio-stdout.txt") {
    Get-Content "factorio-stdout.txt"
}

$stderr = ""
if (Test-Path "factorio-stderr.txt") {
    $stderr = Get-Content "factorio-stderr.txt" -Raw -ErrorAction SilentlyContinue
}
if ($stderr) {
    Write-Host "`n=== STDERR ==="
    Write-Host $stderr
}

# Clean up temp files
Remove-Item "factorio-stdout.txt" -ErrorAction SilentlyContinue
Remove-Item "factorio-stderr.txt" -ErrorAction SilentlyContinue

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
