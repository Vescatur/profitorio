#!/usr/bin/env python3
"""Find missing translations by asking Factorio itself.

Factorio can dump both sides of the problem:

  --dump-data              every prototype that exists, by type
  --dump-prototype-locale  every prototype whose name/description resolves to
                           real locale text ("if they have a valid value")

A prototype that appears in the first dump but not the second is exactly what
shows up in game as "Unknown key: ...". Comparing the two catches translations
missing for prototypes the mod generates in loops, which is where they hide.

Base game internals (projectiles, explosions, stickers, noise expressions) have
no locale on purpose, so the script also dumps a base-only baseline and reports
only prototypes the mod itself adds. Pass --all to see the base gaps too.

On top of the prototype check it runs three static checks over src/locale/:

  * stale keys      -- locale keys naming a prototype that no longer exists
  * runtime keys    -- {"profitorio.foo"} strings in Lua with no locale entry
  * language parity -- keys present in the reference language, missing in another

Descriptions are optional in Factorio, and several of ours are deliberately
absent -- a building called Import needs no sentence explaining that it
imports. Those live in INTENTIONALLY_UNDESCRIBED below and are filtered out, so
the advisory list stays at zero and means something when it is not.

Usage:
    python tools/check/translations.py             # full check, runs Factorio
    python tools/check/translations.py --skip-dump # reuse the cached dumps
    python tools/check/translations.py --all       # include base game gaps
    python tools/check/translations.py --show-suppressed  # list what is filtered
    python tools/check/translations.py --json      # machine-readable report

Exit codes: 0 clean, 1 missing translations found, 2 the check could not run.
"""

from __future__ import annotations

import argparse
import fnmatch
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
MOD_NAME = "profitorio"
DEFAULT_FACTORIO = str(REPO / "factorio" / "bin" / "x64" / "factorio.exe")
REFERENCE_LANGUAGE = "en"


def instance_paths(name: str | None) -> dict[str, Path]:
    """Where one instance keeps its state. No name means the standalone install.

    Mirrors tools/lib/instance.ps1, including that the default is an instance like
    any other rather than a passthrough -- it too gets a config, so every dump
    carries --config and none of them can land in the Steam install's
    script-output. tools/setup/dev-mode.ps1 is what creates the directory.
    """
    if not name:
        root = REPO / "factorio"
        paths = {"config": root / "config" / "config.ini", "user_data": root,
                 "cache": root / "locale-cache"}
        hint = "powershell tools/setup/dev-mode.ps1"
    else:
        root = REPO / ".factorio" / name
        paths = {"config": root / "config.ini", "user_data": root / "data",
                 "cache": root / "locale-cache"}
        hint = f"powershell tools/setup/dev-mode.ps1 -Instance {name}"
    if not paths["config"].is_file():
        raise CheckError(f"No Factorio config at {paths['config']}. Create it with: {hint}")
    return paths

# Locale dump file -> the prototype base class whose descendants it covers.
# Every data.raw type is walked up its "Inherits from" chain (read out of
# factorio-docs/) until it hits one of these; types that hit none -- item
# subgroups, recipe categories, sprites -- are never localised and are skipped.
BASE_CLASS_TO_CATEGORY = {
    "AchievementPrototype": "achievement",
    "AirbornePollutantPrototype": "airborne-pollutant",
    "AmmoCategory": "ammo-category",
    "AutoplaceControl": "autoplace-control",
    "DamageType": "damage-type",
    "DecorativePrototype": "decorative",
    "EntityPrototype": "entity",
    "EquipmentPrototype": "equipment",
    "FluidPrototype": "fluid",
    "FuelCategory": "fuel-category",
    "ItemGroup": "item-group",
    "ItemPrototype": "item",
    "NamedNoiseExpression": "noise-expression",
    "QualityPrototype": "quality",
    "RecipePrototype": "recipe",
    "ShortcutPrototype": "shortcut",
    "SpaceLocationPrototype": "space-location",
    "SurfacePropertyPrototype": "surface-property",
    "TechnologyPrototype": "technology",
    "TilePrototype": "tile",
    "VirtualSignalPrototype": "virtual-signal",
}

# Descriptions are optional almost everywhere in vanilla, so a missing one is
# reported as advice rather than an error unless --strict is passed.
#
# These are the ones we have decided to leave out for good. Entries are the
# exact strings the report prints, so a genuine gap can be silenced by pasting
# the line here; "*" globs, which is what covers prototypes generated in a loop.
# An entry that stops matching anything is reported, so the list cannot rot
# quietly after a rename.
INTENTIONALLY_UNDESCRIBED = [
    # The building's name is the whole explanation.
    "entity-description.import",
    "entity-description.export",
    "item-description.import",
    "item-description.export",
    # Recipes that build one of those, or a customer. The item they produce
    # carries the description; repeating it on the recipe helps nobody.
    "recipe-description.import",
    "recipe-description.export",
    "recipe-description.entrance",
    # Generated per customer type by the loop in services/economy/customers/export.lua. The
    # customer item says what the order is and what it leaves behind.
    "recipe-description.customer_*_deliver",
    # Item groups show a name in the crafting tab and nothing else.
    "item-group-description.customer-group",
]

INHERITS_RE = re.compile(r"\*\*Inherits from:\*\* \[([A-Za-z0-9_]+)\]")
TYPE_STRING_RE = re.compile(r'\*\*Prototype type string:\*\* `type = "([^"]+)"`')
# The localised-string idiom: { "section.key", ... }. Anchoring on the brace
# keeps require("services.foo") and "__base__/graphics/x.png" out of the match.
RUNTIME_KEY_RE = re.compile(r'\{\s*"([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)"')


class CheckError(Exception):
    """Something stopped the check from running at all (exit code 2)."""


# --------------------------------------------------------------------------
# Running Factorio
# --------------------------------------------------------------------------


def run_factorio(exe: Path, args: list[str]) -> None:
    result = subprocess.run(
        [str(exe), *args],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if result.returncode != 0:
        tail = "\n".join((result.stdout or "").splitlines()[-25:])
        raise CheckError(
            f"factorio {' '.join(args)} failed with exit code {result.returncode}\n"
            f"{tail}\n{result.stderr or ''}"
        )


def collect(script_output: Path, pattern: str, dest: Path) -> None:
    """Move dumped files out of script-output before the next run overwrites them."""
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    found = list(script_output.glob(pattern))
    if not found:
        raise CheckError(f"Factorio wrote no {pattern} into {script_output}")
    for path in found:
        shutil.copy2(path, dest / path.name)


def baseline_mod_dir(cache: Path) -> Path:
    """A mod directory with everything but base disabled.

    The bundled expansions live in the game install and default to enabled, so
    the list is written once from whatever Factorio discovers -- no need to
    hardcode which DLC exist in this install.
    """
    mod_dir = cache / "baseline-mods"
    mod_dir.mkdir(parents=True, exist_ok=True)
    return mod_dir


def disable_all_but_base(mod_dir: Path) -> bool:
    """Rewrite the generated mod-list.json to base-only. True if it changed."""
    list_path = mod_dir / "mod-list.json"
    if not list_path.exists():
        return False
    mods = json.loads(list_path.read_text(encoding="utf-8")).get("mods", [])
    changed = False
    for mod in mods:
        wanted = mod["name"] in ("base", "core")
        if mod.get("enabled") != wanted:
            mod["enabled"] = wanted
            changed = True
    if changed:
        list_path.write_text(json.dumps({"mods": mods}, indent=2), encoding="utf-8")
    return changed


def dump_everything(exe: Path, user_data: Path, mod_dir: Path | None, cache: Path,
                    config: Path | None = None) -> None:
    script_output = user_data / "script-output"
    mod_args = ["--mod-directory", str(mod_dir)] if mod_dir else []
    # Prefixed to every run, not just the modded ones: --config is what places
    # script-output, so a baseline dumped without it lands wherever
    # config-path.cfg points and collect() then reads whatever is already there.
    base_args = ["--config", str(config)] if config else []

    print("Dumping base-only prototypes (baseline)...")
    baseline_mods = baseline_mod_dir(cache)
    run_factorio(exe, [*base_args, "--mod-directory", str(baseline_mods), "--dump-data"])
    if disable_all_but_base(baseline_mods):
        # First run generated the list with the DLC enabled; redo it base-only.
        run_factorio(exe, [*base_args, "--mod-directory", str(baseline_mods), "--dump-data"])
    collect(script_output, "data-raw-dump.json", cache / "baseline")

    print("Dumping modded prototypes...")
    run_factorio(exe, [*base_args, *mod_args, "--dump-data"])
    collect(script_output, "data-raw-dump.json", cache / "modded")

    print("Dumping prototype locale...")
    run_factorio(exe, [*base_args, *mod_args, "--dump-prototype-locale"])
    collect(script_output, "*-locale.json", cache / "locale")


# --------------------------------------------------------------------------
# Prototype -> locale category mapping, read from the shipped API docs
# --------------------------------------------------------------------------


def load_type_categories() -> dict[str, str | None]:
    docs = REPO / "factorio-docs" / "markdown" / "prototypes"
    if not docs.is_dir():
        raise CheckError(
            f"API docs not found at {docs}. Regenerate them with "
            "python tools/generate/api_docs.py --clean"
        )

    parent: dict[str, str] = {}
    class_of_type: dict[str, str] = {}
    for path in docs.glob("*.md"):
        if path.stem == "index":
            continue
        head = path.read_text(encoding="utf-8")[:2000]
        inherits = INHERITS_RE.search(head)
        if inherits:
            parent[path.stem] = inherits.group(1)
        type_string = TYPE_STRING_RE.search(head)
        if type_string:
            class_of_type[type_string.group(1)] = path.stem

    categories: dict[str, str | None] = {}
    for type_name, cls in class_of_type.items():
        seen: set[str] = set()
        category = None
        while cls and cls not in seen:
            seen.add(cls)
            if cls in BASE_CLASS_TO_CATEGORY:
                category = BASE_CLASS_TO_CATEGORY[cls]
                break
            cls = parent.get(cls)
        categories[type_name] = category
    return categories


def load_locale_dump(cache: Path) -> dict[str, dict[str, set[str]]]:
    dump: dict[str, dict[str, set[str]]] = {}
    for path in (cache / "locale").glob("*-locale.json"):
        category = path.name[: -len("-locale.json")]
        data = json.loads(path.read_text(encoding="utf-8"))
        dump[category] = {
            "names": set(data.get("names", {})),
            "descriptions": set(data.get("descriptions", {})),
        }
    return dump


def load_raw(cache: Path, which: str) -> dict[str, dict]:
    path = cache / which / "data-raw-dump.json"
    if not path.exists():
        raise CheckError(f"No cached dump at {path}. Run without --skip-dump first.")
    return json.loads(path.read_text(encoding="utf-8"))


# --------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------


def matching_suppression(key: str) -> str | None:
    """The INTENTIONALLY_UNDESCRIBED entry covering this key, if any."""
    for pattern in INTENTIONALLY_UNDESCRIBED:
        if fnmatch.fnmatchcase(key, pattern):
            return pattern
    return None


def check_prototypes(cache: Path, include_base: bool) -> dict:
    type_categories = load_type_categories()
    locale = load_locale_dump(cache)
    modded = load_raw(cache, "modded")
    baseline = load_raw(cache, "baseline")

    vanilla = {
        (type_name, name)
        for type_name, protos in baseline.items()
        for name in protos
    }

    missing_names: list[dict] = []
    missing_descriptions: list[dict] = []
    suppressed_descriptions: list[dict] = []
    used_suppressions: set[str] = set()
    unknown_types: set[str] = set()

    for type_name, protos in sorted(modded.items()):
        if type_name not in type_categories:
            if any((type_name, name) not in vanilla for name in protos):
                unknown_types.add(type_name)
            continue
        category = type_categories[type_name]
        if category is None:
            continue  # prototype kind carries no localisation at all
        entries = locale.get(category, {"names": set(), "descriptions": set()})
        for name in protos:
            own = (type_name, name) not in vanilla
            if not own and not include_base:
                continue
            record = {"type": type_name, "name": name, "category": category, "mod": own}
            if name not in entries["names"]:
                missing_names.append(record)
            elif name not in entries["descriptions"] and own:
                pattern = matching_suppression(cfg_line(record, "description"))
                if pattern:
                    used_suppressions.add(pattern)
                    suppressed_descriptions.append(record)
                else:
                    missing_descriptions.append(record)

    return {
        "missing_names": missing_names,
        "missing_descriptions": missing_descriptions,
        "suppressed_descriptions": suppressed_descriptions,
        "unused_suppressions": [
            pattern
            for pattern in INTENTIONALLY_UNDESCRIBED
            if pattern not in used_suppressions
        ],
        "unknown_types": sorted(unknown_types),
        "prototype_names": prototype_names_by_category(modded, type_categories),
    }


def prototype_names_by_category(
    raw: dict[str, dict], type_categories: dict[str, str | None]
) -> dict[str, set[str]]:
    by_category: dict[str, set[str]] = {}
    for type_name, protos in raw.items():
        category = type_categories.get(type_name)
        if category:
            by_category.setdefault(category, set()).update(protos)
    return by_category


def parse_cfg(path: Path) -> dict[str, dict[str, str]]:
    """Read a Factorio .cfg into {section: {key: value}}."""
    sections: dict[str, dict[str, str]] = {}
    current = ""
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith((";", "#")):
            continue
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1]
            sections.setdefault(current, {})
        elif "=" in line:
            key, value = line.split("=", 1)
            sections.setdefault(current, {})[key.strip()] = value.strip()
    return sections


def load_language(locale_dir: Path) -> dict[str, dict[str, str]]:
    merged: dict[str, dict[str, str]] = {}
    for cfg in sorted(locale_dir.glob("*.cfg")):
        for section, entries in parse_cfg(cfg).items():
            merged.setdefault(section, {}).update(entries)
    return merged


def check_stale_keys(prototype_names: dict[str, set[str]]) -> list[dict]:
    """Locale keys pointing at a prototype that no longer exists."""
    stale: list[dict] = []
    reference = REPO / "src" / "locale" / REFERENCE_LANGUAGE
    if not reference.is_dir():
        return stale
    for cfg in sorted(reference.glob("*.cfg")):
        for section, entries in parse_cfg(cfg).items():
            for suffix in ("-name", "-description"):
                if not section.endswith(suffix):
                    continue
                category = section[: -len(suffix)]
                known = prototype_names.get(category)
                if known is None:
                    continue  # custom section, not a prototype category
                for key in entries:
                    if key not in known:
                        stale.append(
                            {"file": cfg.name, "section": section, "key": key}
                        )
    return stale


def base_locale_keys(exe: Path) -> set[str]:
    """section.key pairs shipped by core and base, so their use isn't flagged."""
    keys: set[str] = set()
    data_dir = exe.parent.parent.parent / "data"
    for cfg in glob.glob(str(data_dir / "*" / "locale" / REFERENCE_LANGUAGE / "*.cfg")):
        for section, entries in parse_cfg(Path(cfg)).items():
            keys.update(f"{section}.{key}" for key in entries)
    return keys


def check_runtime_keys(exe: Path) -> list[dict]:
    """{"section.key"} strings in Lua with no matching locale entry."""
    known = set()
    for language_dir in sorted((REPO / "src" / "locale").glob("*")):
        if language_dir.is_dir():
            for section, entries in load_language(language_dir).items():
                known.update(f"{section}.{key}" for key in entries)
    try:
        known |= base_locale_keys(exe)
    except OSError:
        pass  # game locale unreadable; mod keys are still checked

    missing: list[dict] = []
    for lua in sorted((REPO / "src").rglob("*.lua")):
        for number, line in enumerate(
            lua.read_text(encoding="utf-8").splitlines(), start=1
        ):
            for key in RUNTIME_KEY_RE.findall(line):
                if key not in known:
                    missing.append(
                        {
                            "file": str(lua.relative_to(REPO)).replace("\\", "/"),
                            "line": number,
                            "key": key,
                        }
                    )
    return missing


def check_languages() -> list[dict]:
    """Keys the reference language has that another language is missing."""
    locale_root = REPO / "src" / "locale"
    reference_dir = locale_root / REFERENCE_LANGUAGE
    if not reference_dir.is_dir():
        raise CheckError(f"Reference language {REFERENCE_LANGUAGE} not found in {locale_root}")
    reference = load_language(reference_dir)

    gaps: list[dict] = []
    for language_dir in sorted(locale_root.glob("*")):
        if not language_dir.is_dir() or language_dir.name == REFERENCE_LANGUAGE:
            continue
        translated = load_language(language_dir)
        for section, entries in reference.items():
            for key in entries:
                if key not in translated.get(section, {}):
                    gaps.append(
                        {
                            "language": language_dir.name,
                            "section": section,
                            "key": key,
                        }
                    )
    return gaps


# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------


def cfg_line(record: dict, kind: str) -> str:
    return f"{record['category']}-{kind}.{record['name']}"


def report(result: dict, strict: bool, show_suppressed: bool) -> int:
    missing_names = result["missing_names"]
    stale = result["stale_keys"]
    runtime = result["runtime_keys"]
    languages = result["language_gaps"]
    descriptions = result["missing_descriptions"]
    suppressed = result["suppressed_descriptions"]
    unused_suppressions = result["unused_suppressions"]

    if missing_names:
        print(f"\nMISSING NAMES ({len(missing_names)})")
        print("  These render as 'Unknown key' in game. Add to src/locale/en/*.cfg:")
        by_section: dict[str, list[dict]] = {}
        for record in missing_names:
            by_section.setdefault(f"{record['category']}-name", []).append(record)
        for section, records in sorted(by_section.items()):
            print(f"\n  [{section}]")
            for record in sorted(records, key=lambda r: r["name"]):
                origin = "" if record["mod"] else "   (base game)"
                print(f"  {record['name']}={origin}")

    if runtime:
        print(f"\nMISSING RUNTIME KEYS ({len(runtime)})")
        print("  Lua asks for these localised strings, no .cfg defines them:")
        for record in runtime:
            print(f"  {record['file']}:{record['line']}  {record['key']}")

    if languages:
        print(f"\nUNTRANSLATED KEYS ({len(languages)})")
        for record in languages:
            print(f"  {record['language']}: [{record['section']}] {record['key']}")

    if stale:
        print(f"\nSTALE LOCALE KEYS ({len(stale)})")
        print("  No prototype by this name exists any more; safe to delete:")
        for record in stale:
            print(f"  {record['file']}  [{record['section']}] {record['key']}")

    if descriptions:
        print(f"\nMISSING DESCRIPTIONS ({len(descriptions)}, optional)")
        print("  Write one, or add the line to INTENTIONALLY_UNDESCRIBED in this script:")
        for record in sorted(descriptions, key=lambda r: (r["category"], r["name"])):
            print(f"  {cfg_line(record, 'description')}")

    if show_suppressed and suppressed:
        print(f"\nDESCRIPTIONS INTENTIONALLY LEFT OUT ({len(suppressed)})")
        for record in sorted(suppressed, key=lambda r: (r["category"], r["name"])):
            print(f"  {cfg_line(record, 'description')}")

    if unused_suppressions:
        print(f"\nUNUSED SUPPRESSIONS ({len(unused_suppressions)})")
        print("  INTENTIONALLY_UNDESCRIBED entries matching nothing. The prototype was")
        print("  renamed or has a description now; delete the entry:")
        for pattern in unused_suppressions:
            print(f"  {pattern}")

    if result["unknown_types"]:
        print("\nUNCHECKED PROTOTYPE TYPES")
        print("  Not in the API docs, so their locale category is unknown:")
        for type_name in result["unknown_types"]:
            print(f"  {type_name}")

    failures = len(missing_names) + len(runtime) + len(languages)
    if strict:
        failures += len(descriptions) + len(stale) + len(unused_suppressions)

    print()
    if failures:
        print(f"FAIL: {failures} missing translation(s).")
        return 1
    if stale or descriptions or unused_suppressions:
        print("OK: no missing translations (see advisories above).")
    else:
        suffix = f" ({len(suppressed)} description(s) intentionally left out)" if suppressed else ""
        print(f"OK: no missing translations{suffix}.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--factorio", default=os.environ.get("FACTORIO_EXE", DEFAULT_FACTORIO),
                        help="path to factorio.exe")
    parser.add_argument("--user-data-dir", default=str(REPO / "factorio"),
                        help="Factorio user data directory (holds script-output)")
    parser.add_argument("--mod-directory", default=None,
                        help="mod directory to load the mod from (default: Factorio's own)")
    parser.add_argument("--cache", default=str(Path(tempfile.gettempdir()) / "factorio-locale-check"),
                        help="where dumps are kept between runs")
    parser.add_argument("--skip-dump", action="store_true",
                        help="reuse the cached dumps instead of running Factorio")
    parser.add_argument("--all", action="store_true",
                        help="also report base game prototypes with no locale")
    parser.add_argument("--strict", action="store_true",
                        help="fail on missing descriptions, stale keys and unused suppressions too")
    parser.add_argument("--show-suppressed", action="store_true",
                        help="list the descriptions INTENTIONALLY_UNDESCRIBED filters out")
    parser.add_argument("--json", action="store_true", help="print the report as JSON")
    parser.add_argument("--instance", default=None,
                        help="run against .factorio/<name>/ instead of the standalone install")
    args = parser.parse_args()

    try:
        instance = instance_paths(args.instance)
        config = instance["config"]
        # The default cache is one fixed directory under the system temp dir, so
        # two concurrent runs overwrite each other's dumps and each reports on
        # half the other's prototypes. Per-instance runs get their own.
        if parser.get_default("cache") == args.cache:
            args.cache = str(instance["cache"])
        if parser.get_default("user_data_dir") == args.user_data_dir:
            args.user_data_dir = str(instance["user_data"])

        cache = Path(args.cache)
        cache.mkdir(parents=True, exist_ok=True)

        if not args.skip_dump:
            exe = Path(args.factorio)
            if not exe.is_file():
                raise CheckError(
                    f"Factorio not found at {exe}. Pass --factorio or set FACTORIO_EXE."
                )
            user_data = Path(args.user_data_dir)
            if not (user_data / "script-output").is_dir():
                (user_data / "script-output").mkdir(parents=True, exist_ok=True)
            mod_dir = Path(args.mod_directory) if args.mod_directory else None
            dump_everything(exe, user_data, mod_dir, cache, config)

        result = check_prototypes(cache, include_base=args.all)
        result["stale_keys"] = check_stale_keys(result.pop("prototype_names"))
        result["runtime_keys"] = check_runtime_keys(Path(args.factorio))
        result["language_gaps"] = check_languages()
    except CheckError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps(result, indent=2))
        failures = (
            len(result["missing_names"])
            + len(result["runtime_keys"])
            + len(result["language_gaps"])
        )
        return 1 if failures else 0
    return report(result, strict=args.strict, show_suppressed=args.show_suppressed)


if __name__ == "__main__":
    sys.exit(main())
