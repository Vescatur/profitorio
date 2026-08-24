"""Publish this mod to the Factorio mod portal, or upload a new release of it.

Two separate APIs behind two separate key scopes: `publish` needs a key with
"ModPortal: Publish Mods", `update` needs "ModPortal: Upload Mods". Keys are made
at https://factorio.com/profile, and a key holding only one of the two answers
the other endpoint with Forbidden rather than anything more specific.

  python tools/release/publish.py publish --yes    # create the mod page (once, ever)
  python tools/release/publish.py update           # bump the patch version, build, upload
  python tools/release/publish.py update --bump minor
  python tools/release/publish.py update --version 2.0.0
  python tools/release/publish.py update --zip export/profitorio_1.4.2.zip   # as-is
"""

import argparse
import json
import os
import re
import secrets
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

from zip import create_release_zip

BASE_DIR = Path(__file__).resolve().parents[2]
KEY_FILE = BASE_DIR / "tools" / ".secrets" / "mod-portal-api-key"
KEY_ENV = "FACTORIO_API_KEY"

INIT_PUBLISH_URL = "https://mods.factorio.com/api/v2/mods/init_publish"
INIT_UPLOAD_URL = "https://mods.factorio.com/api/v2/mods/releases/init_upload"

# The portal's own enums; anything else comes back as InvalidRequest.
CATEGORIES = (
    "",
    "no-category",
    "content",
    "overhaul",
    "tweaks",
    "utilities",
    "scenarios",
    "mod-packs",
    "localizations",
    "internal",
)
LICENSES = (
    "default_mit",
    "default_gnugplv3",
    "default_gnulgplv3",
    "default_mozilla2",
    "default_apache2",
    "default_unlicense",
)

DEFAULT_CATEGORY = "overhaul"

INIT_TIMEOUT = 60
UPLOAD_TIMEOUT = 600

INFO_PATH = BASE_DIR / "src" / "info.json"

# Factorio's version grammar: exactly three numbers. A two-part or four-part
# version is refused at load with "Invalid version string", and the portal
# rejects the release before that.
VERSION_PATTERN = r"\d+\.\d+\.\d+"
VERSION_LINE = re.compile(
    rf'(?P<head>"version"\s*:\s*")(?P<version>{VERSION_PATTERN})(?P<tail>")'
)


def read_api_key() -> str:
    key = os.environ.get(KEY_ENV, "").strip()
    if key:
        return key
    if not KEY_FILE.exists():
        raise SystemExit(
            f"No API key. Set ${KEY_ENV}, or put the key on the first line of\n"
            f"  {KEY_FILE}\n"
            "Create one at https://factorio.com/profile -- 'ModPortal: Publish Mods'\n"
            "for `publish`, 'ModPortal: Upload Mods' for `update`."
        )
    key = KEY_FILE.read_text(encoding="utf-8").strip()
    if not key:
        raise SystemExit(f"{KEY_FILE} is empty.")
    return key


def read_info() -> dict:
    with INFO_PATH.open(encoding="utf-8") as f:
        return json.load(f)


def next_version(current: str, part: str) -> str:
    if not re.fullmatch(VERSION_PATTERN, current):
        raise SystemExit(
            f'src/info.json has version "{current}"; expected major.minor.patch.'
        )
    major, minor, patch = (int(n) for n in current.split("."))
    if part == "major":
        return f"{major + 1}.0.0"
    if part == "minor":
        return f"{major}.{minor + 1}.0"
    return f"{major}.{minor}.{patch + 1}"


def write_version(version: str) -> None:
    """Rewrite just the version string in src/info.json.

    A substitution rather than json.dump: re-serialising reformats the whole
    file, so every release would carry a diff of unrelated churn. newline="\\n"
    is what keeps it out of the CRLF trap zip.py refuses to build from --
    on Windows the default would translate every line ending in the file.
    """
    text = INFO_PATH.read_text(encoding="utf-8")
    new_text, count = VERSION_LINE.subn(rf'\g<head>{version}\g<tail>', text, count=1)
    if count != 1:
        raise SystemExit(f"No version field found in {INFO_PATH}")
    INFO_PATH.write_text(new_text, encoding="utf-8", newline="\n")


def prepare_release(args: argparse.Namespace) -> dict:
    """Bump the version if asked, build the zip, and return the fresh info.json."""
    info = read_info()
    target = args.version or (
        None if args.bump == "none" else next_version(info["version"], args.bump)
    )
    if target and target != info["version"]:
        if not re.fullmatch(VERSION_PATTERN, target):
            raise SystemExit(f"--version must be major.minor.patch, not {target!r}")
        write_version(target)
        print(f"Version: {info['version']} -> {target}")

    create_release_zip()
    return read_info()


def git_origin_url() -> str | None:
    """The origin remote as a browsable https URL, for the portal's source_url."""
    try:
        url = subprocess.run(
            ["git", "remote", "get-url", "origin"],
            cwd=BASE_DIR,
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None
    if url.startswith("git@github.com:"):
        url = "https://github.com/" + url[len("git@github.com:") :]
    if url.endswith(".git"):
        url = url[: -len(".git")]
    return url or None


def _decode(body: bytes, status: int) -> dict:
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        raise SystemExit(
            f"Mod portal returned HTTP {status} with a non-JSON body:\n"
            f"{body[:2000].decode('utf-8', 'replace')}"
        )


def _send(request: urllib.request.Request, timeout: int) -> dict:
    """POST and return the parsed body.

    Both APIs put the useful part of a failure in the body of a 4xx, as
    `error` and `message`, so the body is read on the error path too --
    urllib's own message is only ever the status line.
    """
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = _decode(response.read(), response.status)
    except urllib.error.HTTPError as exc:
        payload = _decode(exc.read(), exc.code)
        raise SystemExit(
            f"{payload.get('error', 'Unknown')}: "
            f"{payload.get('message', f'HTTP {exc.code}')}"
        )
    except urllib.error.URLError as exc:
        raise SystemExit(f"Could not reach the mod portal: {exc.reason}")

    if "error" in payload:
        raise SystemExit(f"{payload['error']}: {payload.get('message', '')}")
    return payload


def post_form(url: str, fields: dict, api_key: str) -> dict:
    body = urllib.parse.urlencode(fields).encode()
    request = urllib.request.Request(
        url,
        data=body,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/x-www-form-urlencoded",
        },
        method="POST",
    )
    return _send(request, INIT_TIMEOUT)


def post_multipart(url: str, fields: dict, zip_path: Path) -> dict:
    """The upload leg.

    The URL the init call handed back is itself the credential -- it is
    single-use and pre-authorised, so this request carries no Authorization
    header, and the URL must never be printed or logged.
    """
    boundary = "----factorio-mod-portal" + secrets.token_hex(16)
    parts = []
    for name, value in fields.items():
        parts.append(
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="{name}"\r\n\r\n'
            f"{value}\r\n".encode()
        )
    parts.append(
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{zip_path.name}"\r\n'
        "Content-Type: application/zip\r\n\r\n".encode()
    )
    parts.append(zip_path.read_bytes())
    parts.append(f"\r\n--{boundary}--\r\n".encode())
    body = b"".join(parts)

    request = urllib.request.Request(
        url,
        data=body,
        headers={
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "Content-Length": str(len(body)),
        },
        method="POST",
    )
    return _send(request, UPLOAD_TIMEOUT)


def resolve_zip(info: dict, override: str | None) -> Path:
    name, version = info["name"], info["version"]
    zip_path = (
        Path(override) if override else BASE_DIR / "export" / f"{name}_{version}.zip"
    )
    if not zip_path.exists():
        raise SystemExit(
            f"No zip at {zip_path}\n"
            "Drop --zip to build one, or point it at an existing archive."
        )

    # A zip left from an earlier version uploads without complaint and lands on
    # the portal as a release of *that* version, so trust the archive's own
    # info.json rather than the filename.
    with zipfile.ZipFile(zip_path) as zf:
        members = [m for m in zf.namelist() if m.endswith("info.json")]
        if len(members) != 1:
            raise SystemExit(
                f"{zip_path.name} holds {len(members)} info.json files; expected exactly 1."
            )
        packed = json.loads(zf.read(members[0]))
    if (packed["name"], packed["version"]) != (name, version):
        raise SystemExit(
            f"{zip_path.name} contains {packed['name']} {packed['version']}, "
            f"but src/info.json says {name} {version}.\n"
            "Rebuild it:  python tools/release/zip.py"
        )
    return zip_path


def cmd_publish(args: argparse.Namespace) -> None:
    info = read_info()

    if args.category not in CATEGORIES:
        raise SystemExit(f"--category must be one of: {', '.join(CATEGORIES[1:])}")
    if args.license is not None and args.license not in LICENSES:
        raise SystemExit(f"--license must be one of: {', '.join(LICENSES)}")

    fields = {"category": args.category}
    if args.license:
        fields["license"] = args.license
    source_url = args.source_url or git_origin_url()
    if source_url:
        fields["source_url"] = source_url
    if args.description_file:
        fields["description"] = Path(args.description_file).read_text(encoding="utf-8")

    # Gate before prepare_release: without --yes this is a dry run, and it would
    # otherwise bump the version in src/info.json for a command that then does nothing.
    if not args.yes:
        raise SystemExit(
            f"This creates the public mod page for '{info['name']}' and cannot be undone.\n"
            f"  version:  {info['version']}\n"
            f"  category: {fields['category']}\n"
            f"  license:  {fields.get('license', '(unset)')}\n"
            f"  source:   {fields.get('source_url', '(unset)')}\n"
            "Re-run with --yes to go ahead."
        )

    if not args.zip:
        info = prepare_release(args)
    zip_path = resolve_zip(info, args.zip)

    api_key = read_api_key()
    print(f"Publishing {info['name']} {info['version']} ...")
    init = post_form(INIT_PUBLISH_URL, {"mod": info["name"]}, api_key)
    result = post_multipart(init["upload_url"], fields, zip_path)
    print(f"Published: https://mods.factorio.com/mod/{info['name']}")
    if "url" in result:
        print(f"Details: {result['url']}")


def cmd_update(args: argparse.Namespace) -> None:
    api_key = read_api_key()  # before the bump, so a missing key costs nothing
    info = read_info() if args.zip else prepare_release(args)
    zip_path = resolve_zip(info, args.zip)

    print(f"Uploading {zip_path.name} as a release of {info['name']} ...")
    try:
        init = post_form(INIT_UPLOAD_URL, {"mod": info["name"]}, api_key)
        post_multipart(init["upload_url"], {}, zip_path)
    except SystemExit:
        # The bump is deliberately not rolled back: a failure after the portal
        # accepted the release looks the same from here, and re-using the version
        # would then collide. Retrying the same version is the explicit choice.
        if not args.zip:
            print(
                f"src/info.json is at {info['version']} and the zip is built.\n"
                "Retry that same version with:  --bump none",
                file=sys.stderr,
            )
        raise

    print(f"Released {info['version']}: https://mods.factorio.com/mod/{info['name']}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    subparsers = parser.add_subparsers(dest="command", required=True)

    publish = subparsers.add_parser(
        "publish", help="create the mod page on the portal (once)"
    )
    publish.add_argument("--yes", action="store_true", help="confirm the public listing")
    publish.add_argument(
        "--category", default=DEFAULT_CATEGORY, help=f"default: {DEFAULT_CATEGORY}"
    )
    publish.add_argument("--license", help=f"one of: {', '.join(LICENSES)}")
    publish.add_argument("--source-url", help="default: the origin git remote")
    publish.add_argument(
        "--description-file", help="markdown file for the portal description"
    )
    publish.add_argument("--zip", help="upload this zip as-is instead of building")
    # Creating the page publishes whatever version src/info.json is at; there is
    # nothing on the portal yet to bump past.
    publish.set_defaults(func=cmd_publish, bump="none", version=None)

    update = subparsers.add_parser(
        "update", help="bump the version, build the zip, upload it as a release"
    )
    release = update.add_mutually_exclusive_group()
    release.add_argument(
        "--bump",
        choices=("major", "minor", "patch", "none"),
        default="patch",
        help="version part to increment before building (default: patch)",
    )
    release.add_argument("--version", help="build this exact version instead of bumping")
    release.add_argument("--zip", help="upload this zip as-is; no bump, no build")
    update.set_defaults(func=cmd_update)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    sys.exit(main())
