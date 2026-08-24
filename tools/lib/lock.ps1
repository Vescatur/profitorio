# One writer at a time on main, shared by every worktree.
#
# Held for seconds inside tools/agent/integrate.ps1 and land.ps1, and never
# across a review. An agent that holds it while waiting for a person turns a
# five-second serialiser into however long the human takes, and every other
# agent queues behind them -- which is most of the reason to run agents in
# parallel gone.

function Get-MergeLockPath {
    # --git-common-dir is the one directory linked worktrees share, so a lock
    # written here is visible from all of them and cannot be committed.
    $common = git rev-parse --git-common-dir 2>$null
    if (-not $common) { throw "Not inside a git repository." }
    Join-Path (Resolve-Path $common).Path "profitorio-merge.lock"
}

function Enter-MergeLock {
    param(
        [Parameter(Mandatory = $true)][string]$Holder,
        [int]$TimeoutSeconds = 600
    )

    $lock = Get-MergeLockPath
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $announced = $false

    while ($true) {
        try {
            # CreateNew is the whole mutex: two agents arriving together, exactly
            # one gets the stream and the other lands in the catch. Test-Path
            # followed by a write would let both through.
            $stream = [System.IO.File]::Open(
                $lock, [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $writer = [System.IO.StreamWriter]::new($stream)
            $writer.Write((@{
                holder = $Holder
                pid    = $PID
                taken  = (Get-Date).ToString("o")
            } | ConvertTo-Json -Compress))
            $writer.Close()
            return
        } catch [System.IO.IOException] {
            $state = $null
            try { $state = Get-Content $lock -Raw -ErrorAction Stop | ConvertFrom-Json } catch {}

            # A holder whose process is gone died mid-merge. Nothing is writing to
            # main any more, so the lock is reclaimable rather than a deadlock
            # somebody has to clear by hand.
            if ($state -and -not (Get-Process -Id $state.pid -ErrorAction SilentlyContinue)) {
                Write-Host "Reclaiming stale merge lock from '$($state.holder)' -- pid $($state.pid) is gone."
                Remove-Item $lock -Force -ErrorAction SilentlyContinue
                continue
            }

            # $state is null for the instant between the holder's CreateNew and
            # its Close -- the file exists but is opened FileShare::None, so it
            # reads as nothing. Only the messages care; the waiting is unaffected.
            if ((Get-Date) -gt $deadline) {
                $who = if ($state) { "'$($state.holder)' since $($state.taken)" } else { "another agent" }
                throw "Merge lock held by $who. Gave up after ${TimeoutSeconds}s."
            }
            if (-not $announced -and $state) {
                Write-Host "Waiting for the merge lock, held by '$($state.holder)'..."
                $announced = $true
            }
            Start-Sleep -Seconds 2
        }
    }
}

function Exit-MergeLock {
    param([Parameter(Mandatory = $true)][string]$Holder)

    $lock = Get-MergeLockPath
    if (-not (Test-Path $lock)) { return }

    # Releasing someone else's lock is how two agents end up writing main at
    # once, so it is refused rather than warned about.
    $state = Get-Content $lock -Raw | ConvertFrom-Json
    if ($state.holder -ne $Holder) {
        throw "Refusing to release the merge lock: held by '$($state.holder)', not '$Holder'."
    }
    Remove-Item $lock -Force
}
