# Resolve where one Factorio instance keeps its state, so several can run at once.
#
# Factorio takes its write-data directory -- and the `.lock` file that admits one
# process at a time -- from the config it is given. Point two runs at two configs
# and they stop colliding. Dot-source this from a launcher, take `-Instance` from
# the caller, and pass `.LaunchArgs` to factorio.exe.
#
# Nothing here may name %APPDATA%\Factorio. That is the human's Steam install,
# with their saves and their mod list, and development leaves it alone -- reads
# included, because a seed source is a dependency. The default instance is the
# standalone install itself, in Factorio's own portable layout.

# The two layouts, authored rather than derived. The default puts write-data at the
# install root beside read-data's data\ -- what the zip package does, and what
# `use-system-read-write-data-directories=false` means. An -Instance moves it into
# .factorio\ instead so several runs can each hold their own lock file.
$script:InstanceLayout = @{
    Default = @{
        Data   = "factorio"
        Config = "factorio\config\config.ini"
        State  = "tools\check\.verify"
    }
    Named = @{
        Data   = ".factorio\{0}\data"
        Config = ".factorio\{0}\config.ini"
        State  = ".factorio\{0}\state"
    }
}

# What a fresh instance needs before Factorio will start in it. One row per file:
# repo-relative source, target under the write-data directory, and whether its
# absence fails the seed by name.
$script:InstanceSeed = @(
    @{ Source = "factorio\saves\dev.zip";    Target = "saves\dev.zip";      Required = $true  },
    @{ Source = "tools\setup\mod-list.json"; Target = "mods\mod-list.json"; Required = $true  },
    @{ Source = "factorio\player-data.json"; Target = "player-data.json";   Required = $false }
)

function Get-FactorioRepo {
    Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
}

function Get-FreePort {
    param([ValidateSet("Tcp", "Udp")][string]$Protocol = "Tcp")

    # Ask the OS for an unused port rather than scanning a range: two launchers
    # scanning at the same moment both see the same port free and both hand it to
    # Factorio, and the loser dies on a bind error naming a port nothing else
    # appears to hold.
    if ($Protocol -eq "Tcp") {
        $socket = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $socket.Start()
        $port = $socket.LocalEndpoint.Port
        $socket.Stop()
    } else {
        $socket = [System.Net.Sockets.UdpClient]::new(0, [System.Net.Sockets.AddressFamily]::InterNetwork)
        $port = $socket.Client.LocalEndPoint.Port
        $socket.Close()
    }
    return $port
}

function Set-PortableInstall {
    <#
        .SYNOPSIS
        Pin factorio/config-path.cfg so a hand-launched factorio.exe stays portable.
    #>
    param([Parameter(Mandatory = $true)][string]$Repo)

    # Every tools/ launcher passes --config, which overrides this file outright. It
    # is pinned anyway for the one launch this file cannot reach: double-clicking
    # factorio.exe. The installer build ships `true` below, and that one word is
    # what sends mods and saves to %APPDATA%\Factorio -- the Steam install's own
    # directory -- however far from Program Files the copy sits.
    #
    # __PATH__executable__ is factorio\bin\x64, so ../../config is factorio\config.
    # Spelled out rather than left to __PATH__system-write-data__, which resolves by
    # the very flag on the line after it.
    $cfg = Join-Path $Repo "factorio\config-path.cfg"
    if (-not (Test-Path $cfg)) { return }

    $text  = Get-Content $cfg -Raw
    $fixed = $text -replace '(?m)^config-path=.*$', 'config-path=__PATH__executable__/../../config'
    $fixed = $fixed -replace '(?m)^use-system-read-write-data-directories=.*$', 'use-system-read-write-data-directories=false'
    if ($fixed -ne $text) {
        Set-Content $cfg -Value $fixed -Encoding utf8 -NoNewline
        Write-Host "Pinned factorio\config-path.cfg to the portable layout."
    }
}

function Get-FactorioInstance {
    <#
        .SYNOPSIS
        Paths and launch arguments for one Factorio instance. Seeds it if new.
    #>
    param(
        [string]$Instance,
        [switch]$Reseed
    )

    $repo = Get-FactorioRepo

    if ([string]::IsNullOrWhiteSpace($Instance)) {
        $layout = $script:InstanceLayout.Default
        Set-PortableInstall -Repo $repo
    } else {
        # The name becomes a directory, so anything that could climb out of
        # .factorio\ is refused here rather than deleted from somewhere else later.
        if ($Instance -notmatch '^[A-Za-z0-9._-]+$') {
            throw "Instance name '$Instance' must be letters, digits, dot, dash or underscore."
        }
        $layout = @{}
        foreach ($key in $script:InstanceLayout.Named.Keys) {
            $layout[$key] = $script:InstanceLayout.Named[$key] -f $Instance
        }
    }

    $data   = Join-Path $repo $layout.Data
    $config = Join-Path $repo $layout.Config
    $state  = Join-Path $repo $layout.State

    foreach ($dir in @($state, $data, (Split-Path $config -Parent),
                       (Join-Path $data "mods"), (Join-Path $data "saves"))) {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }

    # Absolute paths, both of them. Factorio's own config.ini ships the tokens
    # __PATH__system-read-data__ / __PATH__system-write-data__, and a template that
    # keeps the write-data token resolves by config-path.cfg instead -- the instance
    # then loads, reports success, and quietly writes into whatever directory that
    # file happens to name.
    $readData  = (Join-Path $repo "factorio\data") -replace '\\', '/'
    $writeData = $data -replace '\\', '/'
    $want = "[path]`nread-data=$readData`nwrite-data=$writeData"

    # Rewritten whenever it disagrees, not only when absent. Absolute paths go stale:
    # move the repo, or write the default instance's config from a worktree whose
    # factorio\ is a junction, and the file names a directory that is no longer the
    # one asked for. Factorio then loads from it and reports success.
    $have = if (Test-Path $config) { (Get-Content $config -Raw).TrimEnd() } else { "" }
    if ($Reseed -or $have -ne $want) {
        $want | Set-Content $config -Encoding utf8
    }

    foreach ($file in $script:InstanceSeed) {
        $target = Join-Path $data $file.Target
        $source = Join-Path $repo $file.Source
        # The default instance's write-data IS factorio\, so two of these rows name
        # the file they would be copied to. Nothing to do, and Copy-Item raises on
        # identical paths. A required one still has to be there.
        if ($source -eq $target) {
            if ($file.Required -and -not (Test-Path $target)) {
                throw "The standalone install has no $($file.Source) -- see docs/dev-setup.md."
            }
            continue
        }
        if ((Test-Path $target) -and -not $Reseed) { continue }
        if (-not (Test-Path $source)) {
            if ($file.Required) { throw "Cannot seed instance '$Instance': $source not found." }
            continue
        }
        Copy-Item $source $target -Force
    }

    # Seeded, never generated. Factorio writes a mod-list.json enabling everything
    # it finds in a fresh mods folder, which switches the four DLC data dirs back
    # on -- the mod is then tested against a prototype set it never ships with.
    $modList = Join-Path $data "mods\mod-list.json"
    if (-not (Test-Path $modList)) {
        throw "No mods\mod-list.json under $data; re-run with -Reseed."
    }

    return @{
        Name       = $Instance
        WriteData  = $data
        Config     = $config
        LaunchArgs = @("--config", $config)
        Mods       = Join-Path $data "mods"
        Saves      = Join-Path $data "saves"
        Scenarios  = Join-Path $data "scenarios"
        Output     = Join-Path $data "script-output"
        Log        = Join-Path $data "factorio-current.log"
        State      = $state
    }
}
