# lib/

Shared by the scripts in the other folders. Nothing here is a job you run.

- `instance.ps1` — dot-sourced. `Get-FactorioInstance -Instance <name>` answers where one Factorio
  instance keeps its write-data, and hands back the `--config` argument that puts it there; with no
  name it answers the shared `%APPDATA%\Factorio` install and no arguments, so every launcher's
  default behaviour is unchanged. Also `Get-FreePort`, because `--start-server` binds UDP 34197
  unless told otherwise and a second server dies on the bind rather than on anything about the mod.

Why a `lib/` at all: five launchers each need the same four answers (write-data, mods, saves,
script-output), and the failure mode of getting one wrong is silent. An instance whose config
template keeps Factorio's `__PATH__system-write-data__` token resolves straight back to `%APPDATA%`
— it loads, it reports success, and it shares the lock file it was created to avoid. That belongs
in one place.

`instance.ps1` has a Python counterpart in two halves rather than a third copy: `probe_client.py`
resolves the same state file with `state_for()`, and `translations.py` with `instance_paths()`.
Both mirror the layout this file owns; change it here and those two follow.
