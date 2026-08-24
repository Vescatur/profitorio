# lib/

Shared by the scripts in the other folders. Nothing here is a job you run.

- `instance.ps1` — dot-sourced. `Get-FactorioInstance -Instance <name>` answers where one Factorio
  instance keeps its write-data, and hands back the `--config` argument that puts it there; with no
  name it answers `factorio/` itself, the standalone install in Factorio's portable layout. Also
  `Get-FreePort`, because `--start-server` binds UDP 34197 unless told otherwise and a second
  server dies on the bind rather than on anything about the mod.

Why a `lib/` at all: five launchers each need the same four answers (write-data, mods, saves,
script-output), and the failure mode of getting one wrong is silent. A config template keeping
Factorio's `__PATH__system-write-data__` token resolves by `config-path.cfg` instead — it loads, it
reports success, and it writes into whatever directory that file names. On an installer build that
is the Factorio you play. That belongs in one place, and so does the one write outside the repo:
`Set-PortableInstall` pins `factorio/config-path.cfg` so even a hand-launched `factorio.exe` stays
inside `factorio/`.

`instance.ps1` has a Python counterpart in two halves rather than a third copy: `probe_client.py`
resolves the same state file with `state_for()`, and `translations.py` with `instance_paths()`.
Both mirror the layout this file owns; change it here and those two follow.
