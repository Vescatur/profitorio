# Give one agent somewhere to work: a worktree, a branch and a Factorio instance.
#
# Run this from anywhere in the repo. Everything afterwards happens inside the
# worktree it prints -- the primary one holds main and is where the human plays.

param(
    [Parameter(Mandatory = $true)][string]$Task
)

$ErrorActionPreference = "Stop"

$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repo "tools\lib\worktree.ps1")

# The name becomes a directory, a branch and a Factorio instance, so it is held
# to the strictest of the three.
if ($Task -notmatch '^[A-Za-z0-9._-]+$') {
    Write-Error "Task name '$Task' must be letters, digits, dot, dash or underscore."
    exit 1
}

$primary = Get-PrimaryWorktree
$tree    = Get-AgentWorktree -Task $Task
$branch  = "agent/$Task"

if (Test-Path $tree) {
    Write-Error "A worktree already exists at $tree. Finish or remove it first."
    exit 1
}
if (git -C $primary branch --list $branch) {
    Write-Error "Branch $branch already exists. Finish or delete it first."
    exit 1
}

New-Item -ItemType Directory -Path (Get-AgentsRoot) -Force | Out-Null
Invoke-Git -C $primary worktree add -b $branch $tree main

# factorio/ is gitignored, so a fresh worktree has none -- and every script in
# tools/ resolves $repo\factorio\bin\x64\factorio.exe from its own root, so
# nothing here runs at all until this junction exists.
New-Item -ItemType Junction -Path (Join-Path $tree "factorio") -Target (Join-Path $primary "factorio") | Out-Null

# The worktree's own copy, not the primary's: instance.ps1 resolves the repo from
# its own location, so running the primary's would create the instance over there.
& (Join-Path $tree "tools\setup\dev-mode.ps1") -Instance $Task

Add-WorkspaceFolder -Task $Task

Write-Host ""
Write-Host "Worktree : $tree"
Write-Host "Branch   : $branch"
Write-Host "Instance : -Instance $Task  (pass it to every tools/ call)"
Write-Host ""
Write-Host "Work there, leave it uncommitted, run the ladder, then ask for review."
