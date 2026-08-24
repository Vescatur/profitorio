# tools/

Dev scripts, grouped by what you are trying to do rather than by what they use. Nothing here
ships in the mod.

| Folder | Reach for it when |
| --- | --- |
| `setup/` | Setting up a machine, or getting back to dev mode after a release build |
| `agent/` | You are one of several Claude sessions working the repo at once |
| `lib/` | Shared by the other folders; nothing here is a job you run |
| `run/` | You want to play the mod |
| `check/` | You changed something and want to know whether it still works |
| `generate/` | You edited an SVG, or re-downloaded the API docs bundle |
| `release/` | Shipping to the mod portal |

Every script resolves the repo root from its own location, so all of them run correctly from any
working directory. Two gitignored directories here hold state: `.secrets/` (the mod portal API
key) and `check/.verify/` (a running probe server's connection details).

Every script that launches Factorio also takes `-Instance <name>`, which moves that run's whole
write-data directory — lock file included — into a gitignored `.factorio/<name>/` at the repo
root, so several can run at once. Omit it and the write-data directory is `factorio/` itself.
Either way nothing reaches the Factorio you play. See [architecture](../docs/architecture.md).
