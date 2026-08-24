# Where the agent worktrees live, and the VSCode workspace that shows them.
#
# The worktrees sit beside the repo rather than inside it. Nested ones would put
# a second and third copy of the whole codebase under the repo root, and every
# agent's own grep would then return each file several times.

# One folder per agent, all under here, beside the primary worktree.
$script:AgentsFolderName  = "profitorio-agents"
$script:WorkspaceFileName = "profitorio.code-workspace"

function Invoke-Git {
    <#
        .SYNOPSIS
        Run git, failing on its exit code rather than on anything it prints.
    #>
    # Windows PowerShell 5.1 turns a native command's stderr into an ErrorRecord
    # whenever output is being redirected, and under $ErrorActionPreference =
    # 'Stop' that record is fatal. git writes ordinary progress to stderr --
    # "Preparing worktree", "Switched to branch" -- so a caller who merely pipes
    # one of these scripts would abort it halfway through, leaving a worktree
    # created but unprovisioned. The exit code is the only real signal.
    $ErrorActionPreference = "Continue"
    # Unwrapped to plain text as well as made non-fatal: left as ErrorRecords,
    # "Preparing worktree" prints as a red NativeCommandError block that reads
    # like a failure to whoever is watching, and these scripts are read by agents.
    & git @args 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { Write-Host $_.Exception.Message }
        else { Write-Host $_ }
    }
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed (exit $LASTEXITCODE)" }
}

function Get-PrimaryWorktree {
    <#
        .SYNOPSIS
        The worktree holding main. git lists it first; linked ones follow.
    #>
    $first = (git worktree list --porcelain) | Where-Object { $_ -like "worktree *" } | Select-Object -First 1
    if (-not $first) { throw "Not inside a git repository." }
    (Resolve-Path ($first -replace '^worktree ', '')).Path
}

function Get-AgentsRoot {
    Join-Path (Split-Path (Get-PrimaryWorktree) -Parent) $script:AgentsFolderName
}

function Get-AgentWorktree {
    param([Parameter(Mandatory = $true)][string]$Task)
    Join-Path (Get-AgentsRoot) $Task
}

function Get-WorkspaceFile {
    # Beside the repo, not in it: it holds machine-local paths, and a tracked file
    # every agent edits on every task would conflict on every task.
    Join-Path (Split-Path (Get-PrimaryWorktree) -Parent) $script:WorkspaceFileName
}

function Read-Workspace {
    $file = Get-WorkspaceFile
    if (Test-Path $file) {
        return Get-Content $file -Raw | ConvertFrom-Json
    }
    # Relative paths, so the file survives the repo being moved. The primary is a
    # root in its own right rather than the parent folder being opened -- folder
    # settings only apply to workspace roots, and profitorio/.vscode holds the Lua
    # library path the Problems panel depends on.
    return [pscustomobject]@{
        folders = @([pscustomobject]@{ path = "./$(Split-Path (Get-PrimaryWorktree) -Leaf)" })
    }
}

function Write-Workspace {
    param([Parameter(Mandatory = $true)]$Workspace)
    $Workspace | ConvertTo-Json -Depth 5 | Set-Content (Get-WorkspaceFile) -Encoding utf8
}

function Add-WorkspaceFolder {
    param([Parameter(Mandatory = $true)][string]$Task)

    $relative = "./$script:AgentsFolderName/$Task"
    $workspace = Read-Workspace
    if ($workspace.folders | Where-Object { $_.path -eq $relative }) { return }
    $workspace.folders = @($workspace.folders) + [pscustomobject]@{ path = $relative }
    Write-Workspace $workspace
    Write-Host "Added $relative to $(Get-WorkspaceFile)."
}

function Remove-WorkspaceFolder {
    param([Parameter(Mandatory = $true)][string]$Task)

    $file = Get-WorkspaceFile
    if (-not (Test-Path $file)) { return }
    $relative = "./$script:AgentsFolderName/$Task"
    $workspace = Read-Workspace
    $workspace.folders = @($workspace.folders | Where-Object { $_.path -ne $relative })
    Write-Workspace $workspace
    Write-Host "Removed $relative from $file."
}

function Get-JunctionsUnder {
    <#
        .SYNOPSIS
        Every junction below a path.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path $Path)) { return @() }
    # Plain -Recurse is safe for the search: measured on Windows PowerShell 5.1,
    # Get-ChildItem -Recurse does not descend through a junction, so this never
    # walks into the 21k-file Factorio install.
    @(Get-ChildItem $Path -Recurse -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.LinkType -eq 'Junction' })
}

function Remove-JunctionsUnder {
    <#
        .SYNOPSIS
        Unlink every junction below a path, leaving what they point at alone.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    # This is the guard that makes tools/agent/finish.ps1 safe, and the danger is
    # narrower than folklore says. Measured, on this machine:
    #
    #   git worktree remove --force  FOLLOWS a junction and deletes the target
    #   Remove-Item -Recurse -Force  does not
    #   Get-ChildItem -Recurse       does not
    #
    # So an agent worktree handed to git while it still holds factorio\ and
    # .factorio\<task>\data\mods\<mod> loses the real install and the primary
    # src\. Unlink first, every time, and never reach for -Force as a shortcut.
    #
    # Directory.Delete with recursive:$false removes the reparse point only.
    foreach ($junction in Get-JunctionsUnder -Path $Path) {
        [System.IO.Directory]::Delete($junction.FullName, $false)
        Write-Host "  unlinked $($junction.FullName)"
    }
}
