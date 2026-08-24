# Take one agent's worktree, branch and Factorio instance back off the machine.
#
# Success only. A task that failed or was rejected keeps everything: the worktree
# in the state it stopped in is what the human debugs from, and the branch is what
# makes the work recoverable.
#
# Run it from the primary worktree -- Windows will not delete a directory that a
# shell is sitting in.

param(
    [Parameter(Mandatory = $true)][string]$Task,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repo "tools\lib\worktree.ps1")

$primary = Get-PrimaryWorktree
$tree    = Get-AgentWorktree -Task $Task
$branch  = "agent/$Task"

if (-not (Test-Path $tree)) {
    Write-Error "No worktree at $tree."
    exit 1
}

$here = (Get-Location).Path
if ($here -eq $tree -or $here.StartsWith($tree + [System.IO.Path]::DirectorySeparatorChar)) {
    Write-Error "You are inside $tree. cd to $primary first -- Windows cannot delete the directory you are standing in."
    exit 1
}

# Cleanup is the reward for landing. -Force is for abandoning a task on purpose,
# and it throws the branch away with everything else.
$merged = git -C $primary branch --merged main --format="%(refname:short)" | Where-Object { $_ -eq $branch }
if (-not $merged -and -not $Force) {
    Write-Error "$branch is not merged into main. Land it first, or pass -Force to abandon the task and discard it."
    exit 1
}

# Junctions first, always. Measured: git worktree remove --force FOLLOWS a
# junction and deletes what it points at, and this worktree holds two that point
# out of it -- factorio\ at the install and .factorio\<task>\data\mods\<mod> at
# the primary src\.
Write-Host "Unlinking junctions..."
Remove-JunctionsUnder -Path $tree

$instance = Join-Path $tree ".factorio"
if (Test-Path $instance) {
    Remove-Item $instance -Recurse -Force
    Write-Host "Removed the Factorio instance."
}

# Checked rather than trusted: the next line hands the worktree to the one tool
# measured to follow a junction, so nothing may still be linked when it runs.
$stillLinked = Get-JunctionsUnder -Path $tree
if ($stillLinked) {
    $stillLinked | ForEach-Object { Write-Host "  still linked: $($_.FullName) -> $($_.Target)" }
    Write-Error "Refusing to run 'git worktree remove --force' while junctions remain -- it would delete what they point at."
    exit 1
}

Invoke-Git -C $primary worktree remove --force $tree

Invoke-Git -C $primary branch $(if ($Force) { "-D" } else { "-d" }) $branch | Out-Null
Remove-WorkspaceFolder -Task $Task

# The junction hazard, checked rather than trusted: if a delete had followed one
# of them, this is where it shows.
$srcFiles = (Get-ChildItem (Join-Path $primary "src") -Recurse -File).Count
$installOk = Test-Path (Join-Path $primary "factorio\bin\x64\factorio.exe")
Write-Host ""
Write-Host "Done. Primary src/ still holds $srcFiles files; factorio/ install $(if ($installOk) { 'intact' } else { 'MISSING' })."
