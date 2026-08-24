# release/

- `zip.py` — builds the reproducible zip into `export/`, and nowhere else. It installs nothing:
  a mods folder that would accept the build belongs to a Factorio somebody plays. To test a
  release build, copy it into `factorio/mods` yourself and remove the dev junction first.
- `publish.py` — the whole release in one command: bumps the version in `src/info.json`, calls
  `zip.py`, uploads. Reads its API key from `../.secrets/mod-portal-api-key`.

`publish.py` imports `zip.py` as a same-directory sibling, so the two cannot be separated. That
import must stay in the `from zip import ...` form — the module shadows the `zip()` builtin, and
a bare `import zip` would make it unreachable for the rest of the file.

Publish and upload are separate API key scopes. A key holding only one answers the other
endpoint with Forbidden rather than anything more specific.
