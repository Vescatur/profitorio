# Put the reviewed, integrated work on main.
#
# Run this after review 2. It commits the merge that integrate.ps1 left staged,
# then merges this branch into main in the primary worktree with --no-ff, so each
# finished task is exactly one commit on main's first-parent line.
#
# The lock is held only for the merge itself.

$ErrorActionPreference = "Stop"

$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repo "tools\lib\lock.ps1")
. (Join-Path $repo "tools\lib\worktree.ps1")

$branch = (git -C $repo rev-parse --abbrev-ref HEAD).Trim()
if ($branch -notlike "agent/*") {
    Write-Error "On branch '$branch'. Run this from an agent worktree, not the primary one."
    exit 1
}
$task     = $branch -replace '^agent/', ''
$primary  = Get-PrimaryWorktree
$gitDir   = (Resolve-Path (git -C $repo rev-parse --git-dir)).Path
$baseFile = Join-Path $gitDir "profitorio-integrate-base"

if (Test-Path (Join-Path $gitDir "MERGE_HEAD")) {
    if (git -C $repo diff --name-only --diff-filter=U) {
        Write-Error "The merge still has conflicts. Resolve them and re-run tools/agent/integrate.ps1."
        exit 1
    }
    Invoke-Git -C $repo commit -q --no-edit
    Write-Host "Committed the integration merge."
}

if (git -C $repo status --porcelain) {
    Write-Error "Uncommitted changes here. Run tools/agent/integrate.ps1 first so they are reviewed."
    exit 1
}

# integrate.ps1 is what makes the merge into main conflict-free. Without it this
# branch has never seen main and the merge below could stop half-done in the
# human's worktree, which is the one place an agent must never leave a mess.
git -C $repo merge-base --is-ancestor main HEAD
if ($LASTEXITCODE -ne 0) {
    Write-Error "This branch does not contain the current main -- either you have not integrated, or main moved since you did. Run tools/agent/integrate.ps1 and re-review."
    exit 1
}

Enter-MergeLock -Holder $task
try {
    $dirty = git -C $primary status --porcelain
    if ($dirty) {
        Write-Host "The primary worktree has uncommitted changes:"
        $dirty | ForEach-Object { Write-Host "  $_" }
        Write-Error "Refusing to merge. That is the human's work -- ask them to commit or discard it."
        exit 1
    }

    if (Test-Path $baseFile) {
        $base = (Get-Content $baseFile -Raw).Trim()
        if ((git -C $repo rev-parse main).Trim() -ne $base) {
            Write-Error "main moved since you integrated. Run tools/agent/integrate.ps1 again, then re-review."
            exit 4
        }
    }

    Invoke-Git -C $primary merge --no-ff $branch -m "Merge $branch"
} finally {
    Exit-MergeLock -Holder $task
}

Remove-Item $baseFile -Force -ErrorAction SilentlyContinue
Write-Host ""
git -C $primary log --oneline --graph --first-parent -3
Write-Host ""
Write-Host "On main. Now: cd out of this worktree, then tools/agent/finish.ps1 -Task $task"
