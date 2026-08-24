# Commit the reviewed work, pull main into this branch, and prove the result loads.
#
# Run this after review 1. It leaves the integration STAGED AND UNCOMMITTED, which
# is review 2: the human reads the merged tree in VSCode before anything about it
# is permanent.
#
# The merge lock is taken here and released before this script returns. It is
# never held while a person is reading a diff.
#
# Re-running after resolving conflicts is the same command -- a merge already in
# progress is detected and continued rather than restarted.

param(
    [string]$Message
)

$ErrorActionPreference = "Stop"

$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repo "tools\lib\lock.ps1")
. (Join-Path $repo "tools\lib\worktree.ps1")

$branch = (git -C $repo rev-parse --abbrev-ref HEAD).Trim()
if ($branch -notlike "agent/*") {
    Write-Error "On branch '$branch'. Run this from an agent worktree, not the primary one."
    exit 1
}
$task    = $branch -replace '^agent/', ''
$primary = Get-PrimaryWorktree
$gitDir  = (Resolve-Path (git -C $repo rev-parse --git-dir)).Path
# Per-worktree, not the shared git dir: each agent records its own base.
$baseFile = Join-Path $gitDir "profitorio-integrate-base"

function Assert-PrimaryClean {
    $dirty = git -C $primary status --porcelain
    if ($dirty) {
        Write-Host "The primary worktree has uncommitted changes:"
        $dirty | ForEach-Object { Write-Host "  $_" }
        Write-Error "Refusing to integrate. That is the human's work -- ask them to commit or discard it."
        exit 1
    }
}

function Invoke-Ladder {
    # Every check is piped to Out-Host, not left to fall through. Anything a
    # function writes to the pipeline becomes part of its return value, so
    # `$green = Invoke-Ladder` would collect the checks' own stdout and hand back
    # a non-empty array -- and `-not <array>` is false, which reports a FAILING
    # ladder as green. That is the one gate the whole process rests on.
    Write-Host "`n--- docs.py ---"
    python (Join-Path $repo "tools\check\docs.py") | Out-Host
    if ($LASTEXITCODE -ne 0) { return $false }
    Write-Host "`n--- prototypes.ps1 ---"
    & (Join-Path $repo "tools\check\prototypes.ps1") -Instance $task | Select-Object -Last 1 | Out-Host
    if ($LASTEXITCODE -ne 0) { return $false }
    Write-Host "`n--- translations.py ---"
    python (Join-Path $repo "tools\check\translations.py") --instance $task | Out-Host
    return ($LASTEXITCODE -eq 0)
}

Assert-PrimaryClean

$resuming = Test-Path (Join-Path $gitDir "MERGE_HEAD")

if (-not $resuming) {
    if (git -C $repo status --porcelain) {
        if (-not $Message) {
            Write-Error "There are uncommitted changes. Pass -Message '<terse one-liner>' once review 1 is approved."
            exit 1
        }
        Invoke-Git -C $repo add -A
        Invoke-Git -C $repo commit -q -m $Message
        Write-Host "Committed: $Message"
    }

    Enter-MergeLock -Holder $task
    try {
        git -C $repo rev-parse main | Set-Content $baseFile -Encoding utf8
        $ErrorActionPreference = "Continue"
        git -C $repo merge --no-commit --no-ff main
        $ErrorActionPreference = "Stop"
        $conflicts = git -C $repo diff --name-only --diff-filter=U
        if ($conflicts) {
            # Released before the agent starts resolving: that takes minutes, and
            # nothing is being written to main while it happens.
            Exit-MergeLock -Holder $task
            Write-Host "`nConflicts to resolve here, in this worktree:"
            $conflicts | ForEach-Object { Write-Host "  $_" }
            Write-Host "`nResolve them, 'git add' each one, then run this script again with no arguments."
            exit 3
        }
    } catch {
        Exit-MergeLock -Holder $task
        throw
    }
} else {
    $unresolved = git -C $repo diff --name-only --diff-filter=U
    if ($unresolved) {
        Write-Host "Still unresolved:"
        $unresolved | ForEach-Object { Write-Host "  $_" }
        Write-Error "Resolve these before re-running."
        exit 3
    }
    # Checked for conflicts first, then staged: `git add -A` on an unmerged file
    # marks it resolved whatever it still contains, so running it before the check
    # above would wave conflict markers straight through. After the check it is
    # what folds a ladder fix from a previous failed run into the pending merge.
    Invoke-Git -C $repo add -A
    Enter-MergeLock -Holder $task
    # main may have moved while the conflicts were being resolved, and the
    # resolution was made against the old one.
    $base = (Get-Content $baseFile -Raw).Trim()
    if ((git -C $repo rev-parse main).Trim() -ne $base) {
        Exit-MergeLock -Holder $task
        Write-Error "main moved while you were resolving. Run: git merge --abort, then this script again."
        exit 4
    }
}

try {
    $green = Invoke-Ladder
} finally {
    Exit-MergeLock -Holder $task
}

if (-not $green) {
    Write-Host "`nThe integrated tree does not pass. Fix it here, then run this script again."
    exit 1
}

Write-Host "`nIntegrated and green, staged but not committed."
Write-Host "This is review 2 -- ask the human to read it, then run tools/agent/land.ps1."
