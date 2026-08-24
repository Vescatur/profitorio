#!/usr/bin/env python3
"""Catch documentation drift before it ships.

Prose rots differently from code: nothing fails when a doc names a file that was
renamed three commits ago, so the wrong name sits there being read. This repo has
already lost that argument twice --

  bef0908  renamed cost -> verify_orders, updated 2 of 3 copies
  ddabc77  renamed starter_recipes.lua -> recipes.lua, updated 0 of 2

-- which is why the fix is a check rather than another sentence asking nicely.

Five checks over CLAUDE.md, docs/ and the skills:

  * broken paths        -- a backticked path that does not exist on disk
  * broken links        -- a markdown link or #anchor that does not resolve
  * duplicate ownership -- the same heading in two files, which is how a second
                           copy of a section starts
  * over budget         -- a file past its word budget in BUDGETS below
  * orphans             -- a source file no doc mentions, a doc nothing links to

The budget is the anti-bloat lever and the reason this script exists. CLAUDE.md
is loaded into every context window, so its length is a running cost paid on
every turn. A budget makes it append-hostile: a new section fails this check
until something is removed, moved to docs/, or moved to a skill.

Raising a budget is a decision, not a fix. If you raise one, say why in the
table -- the same discipline as a suppression.

Needs no Factorio and touches nothing but the filesystem, so it is the cheapest
check in the repo and belongs first in the ladder.

Usage:
    python tools/check/docs.py                  # the check
    python tools/check/docs.py --strict         # fail on advisories too
    python tools/check/docs.py --show-suppressed
    python tools/check/docs.py --json

Exit codes: 0 clean, 1 drift found, 2 the check could not run.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# Words. A file over its budget fails the check. One row per file, every field
# written out, because these are tuning knobs and the next change should be a
# diff of digits. A file with no row here is reported rather than defaulted, so
# adding a doc is a deliberate act.
BUDGETS = {
    # ~1600 of this is the Rules block, which is verbatim engine constraints and does
    # not compress -- the tunable headroom is the other ~1300. Trimmed twice to get
    # here; the next section that wants in should displace one, not raise this.
    #
    # Raised once, from 2900, for "Working in parallel". Deliberately not a pointer
    # to a doc: every agent in a parallel session must read that section before it
    # touches anything, so an external file would be loaded on every turn too --
    # the same cost, plus a hop. The four tools/agent/ scripts are what keep it to
    # a few hundred words instead of twenty git invocations.
    #
    # Raised again, from 3200, for the working agreement that development never
    # touches the Factorio the human plays. Same argument: it guards the one thing
    # in reach that is outside the repo, the old tooling defaulted to violating it,
    # and every failure mode is silent -- so an agent has to know it before it edits
    # a tools/ script, not after being pointed at a doc.
    "CLAUDE.md": 3260,
    "docs/architecture.md": 2000,
    "docs/customer-system.md": 3000,
    # Grew on purpose: it gained an install procedure and a fourth check. Unlike
    # CLAUDE.md this is read on demand, so its budget guards sprawl, not token cost.
    "docs/dev-setup.md": 2000,
    "docs/game-design.md": 1000,
    ".claude/skills/verify-in-engine/SKILL.md": 1600,
    ".claude/skills/add-customer-order/SKILL.md": 1200,
    ".claude/skills/tune-economy/SKILL.md": 1200,
}

# Backticked strings that look like paths but are not ours to have on disk.
# "*" globs. An entry matching nothing is reported, so this list cannot rot
# quietly after a rename.
INTENTIONALLY_ABSENT: list[str] = []

# Headings generic enough to repeat honestly. Anything else appearing twice is
# a second copy of a section starting.
SHARED_HEADINGS = [
    "Context",
    "Overview",
    "Usage",
    "Verification",
    "Further Reading",
    "Validate",
]

CODE_SPAN = re.compile(r"`([^`\n]+)`")
LINK = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*$", re.MULTILINE)
FENCE = re.compile(r"^```.*?^```", re.MULTILINE | re.DOTALL)
LINE_SUFFIX = re.compile(r":\d+(-\d+)?$")

PATH_EXTENSIONS = {
    ".lua", ".py", ".ps1", ".md", ".json", ".cfg", ".png", ".svg", ".txt", ".zip",
}

# Characters that mean the token is code or a glob rather than a path claim.
NOT_IN_A_PATH = "()[]{}<>*?|\"'"


class CheckError(Exception):
    """The check could not run at all."""


def docs() -> list[Path]:
    """Every file this check governs, in a stable order for the report."""
    found = [ROOT / "CLAUDE.md"]
    found += sorted((ROOT / "docs").glob("*.md"))
    found += sorted((ROOT / ".claude" / "skills").glob("*/SKILL.md"))
    return [p for p in found if p.is_file()]


def rel(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def prose(text: str) -> str:
    """The document with fenced code blocks blanked out.

    A fence holds shell transcripts and example output -- paths in there are
    illustrations, not claims about this repo. Blanked line-for-line rather than
    deleted, so the line numbers in the report still match the file.
    """
    return FENCE.sub(lambda m: "\n" * m.group(0).count("\n"), text)


def suppressed(value: str) -> bool:
    return any(fnmatch.fnmatchcase(value, pattern) for pattern in INTENTIONALLY_ABSENT)


def looks_like_path(token: str) -> bool:
    """Is this backticked token a claim that a file exists?

    Needs a slash, so Lua require paths (services.economy.shop.recipes) and bare
    prototype names stay out. Needs an extension or a trailing slash, so prose
    like "input mode" and code fragments do too.
    """
    if "/" not in token or " " in token or "%" in token or "$" in token:
        return False
    if any(c in token for c in NOT_IN_A_PATH):
        return False
    if token.startswith(("http://", "https://", "//")):
        return False
    stem = LINE_SUFFIX.sub("", token)
    if stem.endswith("/"):
        return True
    return Path(stem).suffix in PATH_EXTENSIONS


def resolve(token: str, near: Path) -> bool:
    """Does the token name something on disk?

    Docs abbreviate the way a reader does -- `logistics/loaders.lua` for the file
    under src/services/, `check/probe.ps1` for the one under tools/. Each of those
    roots is tried, plus the directory of the file doing the naming, so a skill can
    say `templates/probe.lua` about its own folder.
    """
    stem = LINE_SUFFIX.sub("", token).rstrip("/")
    bases = (
        ROOT,
        ROOT / "src",
        ROOT / "src" / "services",
        ROOT / "tools",
        ROOT / "factorio-docs" / "markdown",
        near.parent,
    )
    return any((base / stem).exists() for base in bases)


def slug(heading: str) -> str:
    """GitHub's anchor slug: lowercase, punctuation dropped, spaces hyphenated."""
    text = re.sub(r"`([^`]*)`", r"\1", heading).strip().lower()
    text = re.sub(r"[^\w\s-]", "", text)
    return re.sub(r"\s+", "-", text)


def anchors(path: Path) -> set[str]:
    if not path.is_file():
        return set()
    return {slug(m.group(2)) for m in HEADING.finditer(path.read_text(encoding="utf-8"))}


def check_paths(sources: dict[Path, str]) -> tuple[list[str], set[str]]:
    """Every backticked path that is not on disk, plus what was silenced."""
    findings: list[str] = []
    silenced: set[str] = set()
    for path, text in sources.items():
        for line_no, line in enumerate(prose(text).splitlines(), start=1):
            for token in CODE_SPAN.findall(line):
                if not looks_like_path(token) or resolve(token, path):
                    continue
                if suppressed(LINE_SUFFIX.sub("", token)) or suppressed(token):
                    silenced.add(token)
                    continue
                findings.append(f"{rel(path)}:{line_no}  `{token}`")
    return findings, silenced


def check_links(sources: dict[Path, str]) -> list[str]:
    """Every markdown link target and #anchor that does not resolve."""
    findings: list[str] = []
    for path, text in sources.items():
        for line_no, line in enumerate(prose(text).splitlines(), start=1):
            for target in LINK.findall(line):
                target = target.strip()
                if target.startswith(("http://", "https://", "mailto:")):
                    continue
                file_part, _, anchor = target.partition("#")
                destination = path if not file_part else (path.parent / file_part).resolve()
                if file_part and not destination.is_file():
                    findings.append(f"{rel(path)}:{line_no}  -> {target} (no such file)")
                    continue
                if anchor and anchor not in anchors(destination):
                    findings.append(f"{rel(path)}:{line_no}  -> {target} (no such heading)")
    return findings


def check_ownership(sources: dict[Path, str]) -> list[str]:
    """The same heading in two files, which is how a second copy of a section starts."""
    findings: list[str] = []

    headings: dict[str, list[str]] = {}
    for path, text in sources.items():
        seen = {m.group(2).strip() for m in HEADING.finditer(prose(text)) if len(m.group(1)) <= 3}
        for heading in seen:
            if heading in SHARED_HEADINGS:
                continue
            headings.setdefault(heading, []).append(rel(path))
    for heading, owners in sorted(headings.items()):
        if len(owners) > 1:
            findings.append(f'"{heading}" in {", ".join(sorted(owners))}')

    return findings


def check_budgets(sources: dict[Path, str]) -> list[str]:
    """A file past its budget, or with no budget at all."""
    findings: list[str] = []
    for path, text in sources.items():
        name = rel(path)
        words = len(text.split())
        if name not in BUDGETS:
            findings.append(f"{name}  {words} words, no budget -- add a row to BUDGETS")
        elif words > BUDGETS[name]:
            over = words - BUDGETS[name]
            findings.append(f"{name}  {words} words, budget {BUDGETS[name]} (over by {over})")
    return findings


def check_orphans(sources: dict[Path, str]) -> list[str]:
    """A source file no doc mentions, or a doc nothing links to."""
    findings: list[str] = []
    blob = "\n".join(prose(text) for text in sources.values())

    for lua in sorted((ROOT / "src").rglob("*.lua")):
        name = lua.relative_to(ROOT / "src").as_posix()
        if name not in blob and lua.name not in blob:
            findings.append(f"src/{name} is described by no doc")

    linked: set[Path] = set()
    for path, text in sources.items():
        for target in LINK.findall(prose(text)):
            file_part = target.partition("#")[0].strip()
            if file_part and not file_part.startswith(("http", "mailto")):
                resolved = (path.parent / file_part).resolve()
                if resolved.is_file():
                    linked.add(resolved)
    for doc in sorted((ROOT / "docs").glob("*.md")):
        if doc.resolve() not in linked:
            findings.append(f"{rel(doc)} is linked from nowhere")
    return findings


def run() -> dict:
    files = docs()
    if not files:
        raise CheckError(f"no documentation found under {ROOT}")
    sources = {path: path.read_text(encoding="utf-8") for path in files}

    broken_paths, silenced = check_paths(sources)
    unused = [
        pattern for pattern in INTENTIONALLY_ABSENT
        if not any(
            fnmatch.fnmatchcase(LINE_SUFFIX.sub("", s), pattern) or fnmatch.fnmatchcase(s, pattern)
            for s in silenced
        )
    ]
    return {
        "checked": [rel(p) for p in files],
        "broken_paths": broken_paths,
        "broken_links": check_links(sources),
        "duplicate_ownership": check_ownership(sources),
        "over_budget": check_budgets(sources),
        "orphans": check_orphans(sources),
        "suppressed": sorted(silenced),
        "unused_suppressions": unused,
        "words": {rel(p): len(t.split()) for p, t in sources.items()},
    }


BLOCKS = [
    ("BROKEN PATHS", "broken_paths", "a backticked path that is not on disk"),
    ("BROKEN LINKS", "broken_links", "a link or anchor that does not resolve"),
    ("DUPLICATE OWNERSHIP", "duplicate_ownership", "the same thing documented twice"),
    ("OVER BUDGET", "over_budget", "trim it, or move a section to docs/ or a skill"),
]


def report(result: dict, strict: bool, show_suppressed: bool) -> int:
    for title, key, hint in BLOCKS:
        if result[key]:
            print(f"\n{title} ({len(result[key])}) -- {hint}")
            for line in result[key]:
                print(f"  {line}")

    if result["orphans"]:
        print(f"\nORPHANS ({len(result['orphans'])}, advisory)")
        for line in result["orphans"]:
            print(f"  {line}")
    if result["unused_suppressions"]:
        print(f"\nUNUSED SUPPRESSIONS ({len(result['unused_suppressions'])}, advisory)")
        print("  Matched nothing -- delete the entry.")
        for line in result["unused_suppressions"]:
            print(f"  {line}")
    if show_suppressed:
        print(f"\nSUPPRESSED ({len(result['suppressed'])})")
        for line in result["suppressed"]:
            print(f"  {line}")

    failures = sum(len(result[key]) for _, key, _ in BLOCKS)
    advisories = len(result["orphans"]) + len(result["unused_suppressions"])
    if strict:
        failures += advisories

    print()
    if failures:
        print(f"FAIL: {failures} documentation problem(s).")
        return 1
    if advisories:
        print("OK: no documentation drift (see advisories above).")
    else:
        words = result["words"].get("CLAUDE.md", 0)
        print(f"OK: no documentation drift (CLAUDE.md {words}/{BUDGETS['CLAUDE.md']} words).")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--strict", action="store_true",
                        help="fail on orphans and unused suppressions too")
    parser.add_argument("--show-suppressed", action="store_true",
                        help="list the absent paths INTENTIONALLY_ABSENT filters out")
    parser.add_argument("--json", action="store_true", help="print the report as JSON")
    args = parser.parse_args()

    try:
        result = run()
    except CheckError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps(result, indent=2))
        broke = any(result[key] for _, key, _ in BLOCKS)
        return 1 if broke else 0
    return report(result, strict=args.strict, show_suppressed=args.show_suppressed)


if __name__ == "__main__":
    sys.exit(main())
