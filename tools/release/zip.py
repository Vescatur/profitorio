import hashlib
import json
import zipfile
from pathlib import Path

# The zip is reproducible: the same commit must produce the same bytes on every
# machine. That rules out anything the filesystem contributes but the content --
# mtimes and permission bits both land in the archive otherwise. The date is the
# earliest a zip can encode (the format has no room for a pre-1980 timestamp);
# the mode is a plain non-executable 0644 under a Unix create_system, so a
# Windows build and a Linux one agree.
ZIP_EPOCH = (1980, 1, 1, 0, 0, 0)
ZIP_MODE = 0o644 << 16
ZIP_CREATE_SYSTEM = 3  # Unix

# Explicit rather than zlib's default, so the archive does not shift if that
# default ever moves.
COMPRESS_LEVEL = 9


def get_mod_info(base_dir: Path) -> dict:
    info_path = base_dir / "src" / "info.json"
    with info_path.open("r", encoding="utf-8") as f:
        return json.load(f)


def is_binary(blob: bytes) -> bool:
    """Git's own text/binary rule: a NUL byte anywhere near the start."""
    return b"\x00" in blob[:8000]


def assert_lf_only(entries):
    """Refuse to build from a working tree that still has CRLF in it.

    `.gitattributes` pins the checkout to LF, but attributes only apply when git
    actually writes a file. A clone that predates them keeps whatever bytes are
    already on disk, and `text=auto` normalises CRLF back to LF on add -- so
    `git status` stays clean and nothing anywhere warns. Two machines on the same
    commit then build different zips. Catch it here instead of in a diff of the
    artifacts afterwards.

    Binary files are skipped: their bytes are none of our business, and a PNG
    signature literally starts with \\r\\n.
    """
    offenders = [
        (arcname, blob.count(b"\r\n"))
        for arcname, blob in entries
        if b"\r\n" in blob and not is_binary(blob)
    ]
    if not offenders:
        return

    listing = "\n".join(f"  {name}  ({count} CRLF)" for name, count in offenders)
    raise SystemExit(
        f"Refusing to build: {len(offenders)} file(s) have CRLF line endings.\n"
        f"{listing}\n\n"
        "This zip would not match one built from an LF checkout of the same commit.\n"
        "Re-materialise the working tree -- commit or stash first, this discards\n"
        "uncommitted changes:\n"
        "  git rm --cached -r . -q\n"
        "  git reset --hard\n"
        "Then confirm it is clear:\n"
        '  git ls-files --eol | grep -c "w/crlf"   # must print 0'
    )


def create_release_zip():
    """Build the reproducible release zip into export/, and nowhere else."""
    base_dir = Path(__file__).resolve().parents[2]
    src_dir = base_dir / "src"
    export_dir = base_dir / "export"
    export_dir.mkdir(parents=True, exist_ok=True)

    # The portal and the game both key off info.json: the zip must be named
    # {name}_{version}, while the folder inside it is unconstrained.
    mod_info = get_mod_info(base_dir)
    name, version = mod_info["name"], mod_info["version"]
    zip_filename = f"{name}_{version}.zip"
    zip_path = export_dir / zip_filename

    # Sorted on the archive name, so the entry order comes from the paths alone
    # and not from the order the filesystem happens to hand them back.
    entries = sorted(
        (
            (Path(name) / p.relative_to(src_dir)).as_posix(),
            p.read_bytes(),
        )
        for p in src_dir.rglob("*")
        if p.is_file()
    )

    # Before the archive is opened, so a rejected build leaves no zip behind.
    assert_lf_only(entries)

    with zipfile.ZipFile(
        zip_path,
        "w",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=COMPRESS_LEVEL,
    ) as zipf:
        for arcname, blob in entries:
            info = zipfile.ZipInfo(arcname, date_time=ZIP_EPOCH)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = ZIP_CREATE_SYSTEM
            info.external_attr = ZIP_MODE
            zipf.writestr(info, blob)

    digest = hashlib.sha256(zip_path.read_bytes()).hexdigest()

    # export/ is the only destination, deliberately: nothing here installs the
    # build. A mods folder that would accept one belongs to a Factorio somebody
    # plays, so a build landing there swaps the mod under a running game.
    print(f"Successfully created {zip_filename} at {zip_path}")
    # Two machines on the same commit must print the same digest. If they do
    # not, the working trees differ -- check `git ls-files --eol` first.
    print(f"sha256: {digest}")
    return str(zip_path)


if __name__ == "__main__":
    create_release_zip()