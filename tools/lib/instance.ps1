# Resolve where one Factorio instance keeps its state, so several can run at once.
#
# Factorio takes its write-data directory -- and the `.lock` file that admits one
# process at a time -- from the config it is given. Point two runs at two configs
# and they stop colliding. Dot-source this from a launcher, take `-Instance` from
# the caller, and pass `.LaunchArgs` to factorio.exe.
#
# With no -Instance the answer is %APPDATA%\Factorio and nothing changes. That is
# deliberate: it is the human's install, with their saves and their playtest, and
# keeping agents off it is the point of the whole file.

# What a fresh instance needs copied from the human's install before Factorio will
# start in it. One row per file; a missing Required source fails the seed by name.
$script:InstanceSeed = @(
    @{ Source = "saves\dev.zip";      Target = "saves\dev.zip";      Required = $true  },
    @{ Source = "mods\mod-list.json"; Target = "mods\mod-list.json"; Required = $true  },
    @{ Source = "player-data.json";   Target = "player-data.json";   Required = $false }
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

function Get-FactorioInstance {
    <#
        .SYNOPSIS
        Paths and launch arguments for one Factorio instance. Seeds it if new.
    #>
    param(
        [string]$Instance,
        [switch]$Reseed
    )

    $repo   = Get-FactorioRepo
    $system = Join-Path $env:APPDATA "Factorio"

    if ([string]::IsNullOrWhiteSpace($Instance)) {
        return @{
            Name       = ""
            WriteData  = $system
            Config     = ""
            LaunchArgs = @()
            Mods       = Join-Path $system "mods"
            Saves      = Join-Path $system "saves"
            Scenarios  = Join-Path $system "scenarios"
            Output     = Join-Path $system "script-output"
            Log        = Join-Path $system "factorio-current.log"
            State      = Join-Path $repo "tools\check\.verify"
        }
    }

    # The name becomes a directory, so anything that could climb out of .factorio\
    # is refused here rather than deleted from somewhere else later.
    if ($Instance -notmatch '^[A-Za-z0-9._-]+$') {
        throw "Instance name '$Instance' must be letters, digits, dot, dash or underscore."
    }

    $root  = Join-Path $repo ".factorio\$Instance"
    $data  = Join-Path $root "data"
    $state = Join-Path $root "state"
    $config = Join-Path $root "config.ini"

    foreach ($dir in @($state, $data, (Join-Path $data "mods"), (Join-Path $data "saves"))) {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }

    if ($Reseed -or -not (Test-Path $config)) {
        # Absolute paths, both of them. Factorio's own config.ini ships the tokens
        # __PATH__system-read-data__ / __PATH__system-write-data__, and a template
        # that keeps the write-data token resolves straight back to %APPDATA% --
        # the instance then loads, reports success, and quietly shares the one lock
        # file it exists to avoid.
        $readData  = (Join-Path $repo "factorio\data") -replace '\\', '/'
        $writeData = $data -replace '\\', '/'
        "[path]`nread-data=$readData`nwrite-data=$writeData" | Set-Content $config -Encoding utf8
    }

    foreach ($file in $script:InstanceSeed) {
        $target = Join-Path $data $file.Target
        $source = Join-Path $system $file.Source
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
        throw "Instance '$Instance' has no mods\mod-list.json; re-run with -Reseed."
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
