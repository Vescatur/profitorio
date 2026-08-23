#!/usr/bin/env python3
"""Convert the Factorio API docs bundle into a markdown reference tree.

Source of truth is the machine-readable API dump that ships with the docs
(`prototype-api.json` / `runtime-api.json`) -- the same data the HTML site is
generated from. Only the 14 prose pages under `auxiliary/` have no JSON
representation, so those are converted from HTML.

The bundle ships inside the install as `factorio/doc-html`, which is the default
source: nothing to download, and the reference cannot drift from the engine it
documents.

Usage:
    python tools/generate/api_docs.py [--src factorio/doc-html] [--out factorio-docs/markdown]

Stdlib only, deterministic, idempotent.
"""

from __future__ import annotations

import argparse
import html
import json
import re
import shutil
import sys
from html.parser import HTMLParser
from pathlib import Path

# --------------------------------------------------------------------------
# Registry: maps an API name to the file that documents it, so that the
# `prototype:Foo` / `runtime:Bar` links embedded in descriptions can be
# rewritten into relative markdown links.
# --------------------------------------------------------------------------

SECTIONS = {
    "prototypes": "prototypes",
    "types": "types",
    "classes": "classes",
    "concepts": "concepts",
    "events": "events",
}


class Registry:
    def __init__(self) -> None:
        # (stage, name) -> path relative to the output root
        self._map: dict[tuple[str, str], str] = {}

    def add(self, stage: str, name: str, relpath: str) -> None:
        self._map[(stage, name)] = relpath

    def lookup(self, stage: str, name: str) -> str | None:
        hit = self._map.get((stage, name))
        if hit:
            return hit
        # Defines live in a single page; links use dotted paths.
        if name.startswith("defines."):
            return "defines/defines.md"
        # A few links cross stages (a runtime concept naming a prototype type).
        other = "runtime" if stage == "prototype" else "prototype"
        return self._map.get((other, name))

    def targets(self) -> set[str]:
        return set(self._map.values())


def slug(text: str) -> str:
    """GitHub-style heading anchor."""
    text = text.strip().lower()
    text = re.sub(r"[^\w\s-]", "", text)
    return re.sub(r"[\s_]+", "-", text)


def relative(from_dir: str, target: str) -> str:
    """Relative link from a file inside `from_dir` to `target` (both root-relative)."""
    if not from_dir:
        return target
    depth = from_dir.count("/") + 1
    return "../" * depth + target


# --------------------------------------------------------------------------
# Description rewriting
# --------------------------------------------------------------------------

LINK_RE = re.compile(r"\[([^\]]*)\]\((prototype|runtime|auxiliary):([^)\s]+)\)")


def truncate_md(text: str, limit: int = 160) -> str:
    """Shorten without leaving a half-open markdown link behind."""
    if len(text) <= limit:
        return text
    cut = text[: limit - 3]
    open_bracket = cut.rfind("[")
    if open_bracket != -1 and ")" not in cut[open_bracket:]:
        cut = cut[:open_bracket]
    return cut.rstrip() + "..."


def plain(text: str | None) -> str:
    """First line, links flattened to their label -- safe inside a table cell."""
    first = (text or "").split("\n")[0]
    return LINK_RE.sub(lambda m: m.group(1), first).replace("|", "\\|")


def rewrite(text: str | None, reg: Registry, from_dir: str) -> str:
    """Rewrite `stage:Name` / `stage:Name::member` links to relative paths."""
    if not text:
        return ""

    def repl(m: re.Match[str]) -> str:
        label, stage, target = m.group(1), m.group(2), m.group(3)
        name, _, member = target.partition("::")
        if stage == "auxiliary":
            member = ""
        path = reg.lookup(stage, name)
        if not path:
            # Unknown target: keep the label, drop the dead link.
            return label or name
        link = relative(from_dir, path)
        if member:
            link += "#" + slug(member)
        return f"[{label}]({link})"

    text = LINK_RE.sub(repl, text)

    # A few descriptions link to a prose page by bare filename.
    def repl_html(m: re.Match[str]) -> str:
        label, stem = m.group(1), m.group(2)
        path = reg.lookup("auxiliary", stem)
        return f"[{label}]({relative(from_dir, path)})" if path else label

    return re.sub(r"\[([^\]]*)\]\(([\w-]+)\.html\)", repl_html, text)


# --------------------------------------------------------------------------
# Type rendering
# --------------------------------------------------------------------------


def render_type(t, reg: Registry, stage: str, from_dir: str) -> str:
    """Render a type descriptor (string or complex_type dict) as markdown."""
    if t is None:
        return ""
    if isinstance(t, str):
        path = reg.lookup(stage, t)
        if path:
            return f"[{t}]({relative(from_dir, path)})"
        return f"`{t}`"

    kind = t.get("complex_type")
    r = lambda x: render_type(x, reg, stage, from_dir)  # noqa: E731

    if kind == "literal":
        val = t.get("value")
        if isinstance(val, str):
            return f'`"{val}"`'
        if isinstance(val, bool):
            return f"`{str(val).lower()}`"
        return f"`{val}`"
    if kind == "array":
        return f"array[{r(t.get('value'))}]"
    if kind == "union":
        return " ∣ ".join(r(o) for o in t.get("options", []))
    if kind == "tuple":
        return "tuple[" + ", ".join(r(v) for v in t.get("values", [])) + "]"
    if kind == "dictionary":
        return f"dictionary[{r(t.get('key'))} → {r(t.get('value'))}]"
    if kind == "LuaCustomTable":
        return f"LuaCustomTable[{r(t.get('key'))} → {r(t.get('value'))}]"
    if kind == "LuaLazyLoadedValue":
        return f"LuaLazyLoadedValue[{r(t.get('value'))}]"
    if kind == "function":
        return "function(" + ", ".join(r(p) for p in t.get("parameters", [])) + ")"
    if kind == "type":
        base = r(t.get("value"))
        desc = rewrite(t.get("description"), reg, from_dir)
        return f"{base} — {desc}" if desc else base
    if kind == "table":
        names = [p.get("name", "?") for p in t.get("parameters", [])]
        return "table{" + ", ".join(names) + "}" if names else "table"
    if kind == "LuaStruct":
        names = [a.get("name", "?") for a in t.get("attributes", [])]
        return "LuaStruct{" + ", ".join(names) + "}" if names else "LuaStruct"
    if kind == "struct":
        return "struct (see properties below)"
    if kind == "builtin":
        return "builtin"
    return f"`{kind or 'unknown'}`"


# --------------------------------------------------------------------------
# Markdown building blocks
# --------------------------------------------------------------------------


class Doc:
    def __init__(self) -> None:
        self.parts: list[str] = []

    def add(self, text: str = "") -> None:
        self.parts.append(text)

    def render(self) -> str:
        out = "\n".join(self.parts).rstrip() + "\n"
        return re.sub(r"\n{3,}", "\n\n", out)


def member_block(
    doc: Doc,
    entry: dict,
    reg: Registry,
    stage: str,
    from_dir: str,
    level: int = 3,
    type_key: str = "type",
) -> None:
    """Render one property / parameter / attribute as an anchor-able section."""
    name = entry.get("name") or "(return value)"
    doc.add(f"{'#' * level} {name}")
    doc.add()

    facts = []
    if type_key == "read_write":
        rt, wt = entry.get("read_type"), entry.get("write_type")
        if rt is not None:
            facts.append(f"**Read:** {render_type(rt, reg, stage, from_dir)}")
        if wt is not None:
            facts.append(f"**Write:** {render_type(wt, reg, stage, from_dir)}")
        if rt is not None and wt is None:
            facts.append("_read-only_")
    else:
        rendered = render_type(entry.get(type_key), reg, stage, from_dir)
        if rendered:
            facts.append(f"**Type:** {rendered}")
    if entry.get("optional"):
        facts.append("_optional_")
    if entry.get("override"):
        facts.append("_overrides parent_")
    if entry.get("default") is not None:
        facts.append(f"**Default:** `{entry['default']}`")
    if facts:
        doc.add(" · ".join(facts))
        doc.add()

    desc = rewrite(entry.get("description"), reg, from_dir)
    if desc:
        doc.add(desc)
        doc.add()
    for extra in entry.get("lists", []) or []:
        doc.add(rewrite(extra, reg, from_dir))
        doc.add()
    add_examples(doc, entry, reg, from_dir)
    if entry.get("raises"):
        doc.add("**Raises:**")
        doc.add()
        for rz in entry["raises"]:
            doc.add(f"- `{rz.get('name')}` — {rewrite(rz.get('description'), reg, from_dir)}")
        doc.add()


def add_examples(doc: Doc, entry: dict, reg: Registry, from_dir: str) -> None:
    ex = entry.get("examples") or []
    if not ex:
        return
    doc.add("**Example" + ("s" if len(ex) > 1 else "") + ":**")
    doc.add()
    for e in ex:
        doc.add(rewrite(e, reg, from_dir))
        doc.add()


def summary_table(
    doc: Doc, entries: list[dict], reg: Registry, stage: str, from_dir: str, type_key: str = "type"
) -> None:
    """Compact scan-table so a reader can see every field without reading each block."""
    if not entries:
        return
    doc.add("| Name | Type | Optional |")
    doc.add("| --- | --- | --- |")
    for e in entries:
        if type_key == "read_write":
            rendered = render_type(e.get("read_type") or e.get("write_type"), reg, stage, from_dir)
        else:
            rendered = render_type(e.get(type_key), reg, stage, from_dir)
        rendered = rendered.replace("|", "\\|")
        name = e.get("name", "")
        doc.add(f"| [{name}](#{slug(name)}) | {rendered} | {'yes' if e.get('optional') else ''} |")
    doc.add()


def header(doc: Doc, entity: dict, reg: Registry, from_dir: str, kind: str) -> None:
    doc.add(f"# {entity['name']}")
    doc.add()

    badges = [f"_{kind}_"]
    if entity.get("abstract"):
        badges.append("**abstract**")
    if entity.get("deprecated"):
        badges.append("**deprecated**")
    for v in entity.get("visibility", []) or []:
        badges.append(f"**{v}**")
    doc.add(" · ".join(badges))
    doc.add()

    if entity.get("typename"):
        doc.add(f'**Prototype type string:** `type = "{entity["typename"]}"`')
        doc.add()
    parent = entity.get("parent")
    if parent:
        doc.add(f"**Inherits from:** {render_type(parent, reg, 'prototype', from_dir)}")
        doc.add()

    desc = rewrite(entity.get("description"), reg, from_dir)
    if desc:
        doc.add(desc)
        doc.add()
    for extra in entity.get("lists", []) or []:
        doc.add(rewrite(extra, reg, from_dir))
        doc.add()
    for img in entity.get("images", []) or []:
        cap = img.get("caption", "")
        doc.add(f"_Image: `{img.get('filename')}`{' — ' + cap if cap else ''}_")
        doc.add()
    add_examples(doc, entity, reg, from_dir)


# --------------------------------------------------------------------------
# Per-entity renderers
# --------------------------------------------------------------------------


def render_prototype(p: dict, reg: Registry) -> str:
    d, sec = Doc(), "prototypes"
    header(d, p, reg, sec, "prototype")
    props = sorted(p.get("properties", []), key=lambda x: x.get("name", ""))
    if props:
        d.add("## Properties")
        d.add()
        summary_table(d, props, reg, "prototype", sec)
        for prop in props:
            member_block(d, prop, reg, "prototype", sec)
    return d.render()


def render_type_page(t: dict, reg: Registry) -> str:
    d, sec = Doc(), "types"
    header(d, t, reg, sec, "type" + (" (inline)" if t.get("inline") else ""))
    definition = render_type(t.get("type"), reg, "prototype", sec)
    if definition:
        d.add(f"**Definition:** {definition}")
        d.add()
    props = sorted(t.get("properties", []) or [], key=lambda x: x.get("name", ""))
    if props:
        d.add("## Properties")
        d.add()
        summary_table(d, props, reg, "prototype", sec)
        for prop in props:
            member_block(d, prop, reg, "prototype", sec)
    return d.render()


def render_method(d: Doc, m: dict, reg: Registry, sec: str, level: int = 3) -> None:
    params = m.get("parameters", []) or []
    takes_table = (m.get("format") or {}).get("takes_table")
    sig = ", ".join(p.get("name", "?") for p in params)
    if takes_table:
        sig = "{" + sig + "}"
    d.add(f"{'#' * level} {m['name']}")
    d.add()
    d.add(f"`{m['name']}({sig})`")
    d.add()
    desc = rewrite(m.get("description"), reg, sec)
    if desc:
        d.add(desc)
        d.add()
    for extra in m.get("lists", []) or []:
        d.add(rewrite(extra, reg, sec))
        d.add()

    if params:
        d.add(f"{'#' * (level + 1)} Parameters")
        d.add()
        for p in params:
            member_block(d, p, reg, "runtime", sec, level=level + 2)
    if m.get("variadic_parameter"):
        vp = m["variadic_parameter"]
        d.add(f"{'#' * (level + 1)} Variadic parameter")
        d.add()
        d.add(f"**Type:** {render_type(vp.get('type'), reg, 'runtime', sec)}")
        d.add()
        if vp.get("description"):
            d.add(rewrite(vp["description"], reg, sec))
            d.add()
    if m.get("variant_parameter_groups"):
        d.add(f"{'#' * (level + 1)} Variant parameter groups")
        d.add()
        if m.get("variant_parameter_description"):
            d.add(rewrite(m["variant_parameter_description"], reg, sec))
            d.add()
        for g in m["variant_parameter_groups"]:
            d.add(f"{'#' * (level + 2)} {g.get('name')}")
            d.add()
            if g.get("description"):
                d.add(rewrite(g["description"], reg, sec))
                d.add()
            for p in g.get("parameters", []):
                member_block(d, p, reg, "runtime", sec, level=level + 3)
    if m.get("return_values"):
        d.add(f"{'#' * (level + 1)} Return values")
        d.add()
        for rv in m["return_values"]:
            rendered = render_type(rv.get("type"), reg, "runtime", sec)
            opt = " _(optional)_" if rv.get("optional") else ""
            desc = rewrite(rv.get("description"), reg, sec)
            d.add(f"- {rendered}{opt}{' — ' + desc if desc else ''}")
        d.add()
    if m.get("raises"):
        d.add(f"{'#' * (level + 1)} Raises")
        d.add()
        for rz in m["raises"]:
            d.add(f"- `{rz.get('name')}` — {rewrite(rz.get('description'), reg, sec)}")
        d.add()
    add_examples(d, m, reg, sec)


def render_class(c: dict, reg: Registry) -> str:
    d, sec = Doc(), "classes"
    header(d, c, reg, sec, "class")
    attrs = sorted(c.get("attributes", []) or [], key=lambda x: x.get("name", ""))
    methods = sorted(c.get("methods", []) or [], key=lambda x: x.get("name", ""))
    ops = sorted(c.get("operators", []) or [], key=lambda x: x.get("name", ""))

    if attrs:
        d.add("## Attributes")
        d.add()
        summary_table(d, attrs, reg, "runtime", sec, type_key="read_write")
        for a in attrs:
            member_block(d, a, reg, "runtime", sec, type_key="read_write")
    if methods:
        d.add("## Methods")
        d.add()
        d.add("| Method | Summary |")
        d.add("| --- | --- |")
        for m in methods:
            d.add(f"| [{m['name']}](#{slug(m['name'])}) | {plain(m.get('description'))} |")
        d.add()
        for m in methods:
            render_method(d, m, reg, sec)
    if ops:
        d.add("## Operators")
        d.add()
        for o in ops:
            render_method(d, o, reg, sec)
    return d.render()


def render_concept(c: dict, reg: Registry) -> str:
    d, sec = Doc(), "concepts"
    header(d, c, reg, sec, "concept")
    definition = render_type(c.get("type"), reg, "runtime", sec)
    if definition:
        d.add(f"**Definition:** {definition}")
        d.add()
    # Concepts whose type is a table/struct carry their fields inline.
    t = c.get("type")
    if isinstance(t, dict):
        params = t.get("parameters") or t.get("attributes") or []
        if params:
            d.add("## Fields")
            d.add()
            key = "read_write" if t.get("complex_type") == "LuaStruct" else "type"
            params = sorted(params, key=lambda x: x.get("name", ""))
            summary_table(d, params, reg, "runtime", sec, type_key=key)
            for p in params:
                member_block(d, p, reg, "runtime", sec, type_key=key)
    return d.render()


def render_event(e: dict, reg: Registry) -> str:
    d, sec = Doc(), "events"
    header(d, e, reg, sec, "event")
    if e.get("filter"):
        d.add(f"**Filter:** {render_type(e['filter'], reg, 'runtime', sec)}")
        d.add()
    data = sorted(e.get("data", []) or [], key=lambda x: x.get("name", ""))
    if data:
        d.add("## Event data")
        d.add()
        summary_table(d, data, reg, "runtime", sec)
        for p in data:
            member_block(d, p, reg, "runtime", sec)
    return d.render()


def render_defines(defines: list[dict], reg: Registry) -> str:
    d, sec = Doc(), "defines"
    d.add("# defines")
    d.add()
    d.add("Runtime `defines.*` enumerations.")
    d.add()

    def walk(node: dict, prefix: str, level: int) -> None:
        name = f"{prefix}.{node['name']}"
        d.add(f"{'#' * min(level, 6)} {name}")
        d.add()
        desc = rewrite(node.get("description"), reg, sec)
        if desc:
            d.add(desc)
            d.add()
        for v in sorted(node.get("values", []) or [], key=lambda x: x.get("name", "")):
            vd = rewrite(v.get("description"), reg, sec)
            d.add(f"- `{name}.{v['name']}`{' — ' + vd if vd else ''}")
        if node.get("values"):
            d.add()
        for sub in sorted(node.get("subkeys", []) or [], key=lambda x: x.get("name", "")):
            walk(sub, name, level + 1)

    for top in sorted(defines, key=lambda x: x.get("name", "")):
        walk(top, "defines", 2)
    return d.render()


def render_globals(runtime: dict, reg: Registry) -> str:
    d, sec = Doc(), ""
    d.add("# Runtime globals")
    d.add()
    d.add("## Global objects")
    d.add()
    for g in sorted(runtime.get("global_objects", []), key=lambda x: x.get("name", "")):
        rendered = render_type(g.get("type"), reg, "runtime", sec)
        desc = rewrite(g.get("description"), reg, sec)
        d.add(f"- `{g['name']}` :: {rendered} — {desc}")
    d.add()
    d.add("## Global functions")
    d.add()
    for f in sorted(runtime.get("global_functions", []), key=lambda x: x.get("name", "")):
        render_method(d, f, reg, sec, level=3)
    return d.render()


# --------------------------------------------------------------------------
# Auxiliary HTML -> markdown
# --------------------------------------------------------------------------

BLOCK_TAGS = {"p", "div", "section", "ul", "ol", "table", "tr", "blockquote", "br"}
HEADINGS = {f"h{i}": i for i in range(1, 7)}


class AuxParser(HTMLParser):
    """Converts the <main> content of an auxiliary docs page into markdown."""

    def __init__(self, resolve=None) -> None:
        super().__init__(convert_charrefs=True)
        self.resolve = resolve or (lambda href: href)
        self.depth = 0          # nesting depth once inside <main>
        self.capture = False
        self.out: list[str] = []
        self.skip_depth = 0     # inside <script>/<style>/nav chrome
        self.list_stack: list[str] = []
        self.li_index: list[int] = []
        self.pre = False
        self.href: str | None = None
        self.link_text: list[str] = []
        self.row: list[str] | None = None
        self.cell: list[str] | None = None
        self.table_rows: list[list[str]] = []
        self.in_header_row = False

    # -- helpers ---------------------------------------------------------
    def emit(self, text: str) -> None:
        if self.cell is not None:
            self.cell.append(text)
        elif self.link_text is not None and self.href is not None:
            self.link_text.append(text)
        else:
            self.out.append(text)

    def newline(self, count: int = 1) -> None:
        if self.cell is not None:
            return
        self.out.append("\n" * count)

    # -- parser callbacks ------------------------------------------------
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "main":
            self.capture = True
            return
        if not self.capture:
            return
        self.depth += 1
        if tag in ("script", "style", "nav", "button"):
            self.skip_depth += 1
            return
        if self.skip_depth:
            return

        if tag in HEADINGS:
            self.newline(2)
            self.out.append("#" * HEADINGS[tag] + " ")
        elif tag == "p":
            self.newline(2)
        elif tag == "br":
            self.newline(1)
        elif tag == "pre":
            self.pre = True
            self.newline(2)
            self.out.append("```\n")
        elif tag == "code" and not self.pre:
            self.emit("`")
        elif tag in ("ul", "ol"):
            self.list_stack.append(tag)
            self.li_index.append(0)
            self.newline(2)
        elif tag == "li":
            indent = "  " * (len(self.list_stack) - 1)
            if self.list_stack and self.list_stack[-1] == "ol":
                self.li_index[-1] += 1
                marker = f"{self.li_index[-1]}. "
            else:
                marker = "- "
            self.newline(1)
            self.out.append(indent + marker)
        elif tag == "a":
            self.href = a.get("href")
            self.link_text = []
        elif tag in ("strong", "b"):
            self.emit("**")
        elif tag in ("em", "i"):
            self.emit("*")
        elif tag == "table":
            self.table_rows = []
        elif tag == "tr":
            self.row = []
        elif tag in ("td", "th"):
            self.cell = []
            if tag == "th":
                self.in_header_row = True

    def handle_endtag(self, tag):
        if tag == "main":
            self.capture = False
            return
        if not self.capture:
            return
        if tag in ("script", "style", "nav", "button"):
            self.skip_depth = max(0, self.skip_depth - 1)
            self.depth = max(0, self.depth - 1)
            return
        if self.skip_depth:
            self.depth = max(0, self.depth - 1)
            return

        if tag in HEADINGS:
            self.newline(2)
        elif tag == "p":
            self.newline(2)
        elif tag == "pre":
            self.out.append("\n```\n")
            self.pre = False
        elif tag == "code" and not self.pre:
            self.emit("`")
        elif tag in ("ul", "ol"):
            if self.list_stack:
                self.list_stack.pop()
                self.li_index.pop()
            self.newline(2)
        elif tag == "a":
            text = "".join(self.link_text).strip()
            href, self.href, self.link_text = self.href, None, []
            if text:
                resolved = self.resolve(href) if href else None
                if resolved:
                    self.emit(f"[{text}]({resolved})")
                else:
                    self.emit(text)
        elif tag in ("strong", "b"):
            self.emit("**")
        elif tag in ("em", "i"):
            self.emit("*")
        elif tag in ("td", "th"):
            if self.row is not None and self.cell is not None:
                self.row.append(" ".join("".join(self.cell).split()))
            self.cell = None
        elif tag == "tr":
            if self.row:
                self.table_rows.append(self.row)
            self.row = None
        elif tag == "table":
            self.flush_table()
        self.depth = max(0, self.depth - 1)

    def flush_table(self) -> None:
        if not self.table_rows:
            return
        width = max(len(r) for r in self.table_rows)
        rows = [r + [""] * (width - len(r)) for r in self.table_rows]
        self.newline(2)
        head = rows[0] if self.in_header_row else [""] * width
        body = rows[1:] if self.in_header_row else rows
        self.out.append("| " + " | ".join(head) + " |\n")
        self.out.append("| " + " | ".join(["---"] * width) + " |\n")
        for r in body:
            self.out.append("| " + " | ".join(r) + " |\n")
        self.newline(1)
        self.table_rows = []
        self.in_header_row = False

    def handle_data(self, data):
        if not self.capture or self.skip_depth:
            return
        if self.pre:
            self.out.append(data)
            return
        if not data.strip():
            # Preserve a single separating space between inline elements.
            if self.out and not self.out[-1].endswith((" ", "\n")):
                self.emit(" ")
            return
        self.emit(re.sub(r"\s+", " ", data))

    def result(self) -> str:
        text = "".join(self.out)
        text = re.sub(r"[ \t]+\n", "\n", text)
        text = re.sub(r"\n{3,}", "\n\n", text)
        return text.strip() + "\n"


def make_aux_resolver(reg: Registry, out: Path, aux_stems: set[str]):
    """Turn an href from an auxiliary HTML page into a working markdown link.

    Returns None when the target does not exist, so the caller can keep the
    link text and drop the dead link.
    """

    def resolve(href: str) -> str | None:
        if not href:
            return None
        if href.startswith(("http://", "https://", "mailto:")):
            return href
        path, _, frag = href.partition("#")
        anchor = "#" + slug(frag) if frag else ""
        if not path:
            return anchor or None

        # Scheme-style links that survived from the HTML source.
        m = re.match(r"^(prototype|runtime|auxiliary):(.+)$", path)
        if m:
            stage, target = m.group(1), m.group(2)
            name, _, member = target.partition("::")
            if stage == "auxiliary":
                return f"{name}.md" if name in aux_stems else None
            hit = reg.lookup(stage, name)
            if not hit:
                return None
            return relative("auxiliary", hit) + (("#" + slug(member)) if member else anchor)

        if not path.endswith(".html"):
            return None
        candidate = path[: -len(".html")] + ".md"

        # Sibling auxiliary page (not yet written to disk at this point).
        if "/" not in candidate and candidate[:-3] in aux_stems:
            return candidate + anchor

        base = out / "auxiliary"
        if (base / candidate).exists():
            return candidate + anchor
        # Section landing pages: `../prototypes.html` -> `../prototypes/index.md`
        section = (base / candidate).parent / (Path(candidate).stem + "/index.md")
        if section.exists():
            rel = Path(candidate).parent / Path(candidate).stem / "index.md"
            return rel.as_posix() + anchor
        return None

    return resolve


def convert_aux(path: Path, resolve=None) -> str:
    parser = AuxParser(resolve)
    parser.feed(path.read_text(encoding="utf-8", errors="replace"))
    return parser.result()


# --------------------------------------------------------------------------
# Index pages
# --------------------------------------------------------------------------


def write_index(out: Path, section: str, entries: list[dict], reg: Registry, title: str) -> None:
    d = Doc()
    d.add(f"# {title}")
    d.add()
    d.add(f"{len(entries)} entries. Read the individual file for full detail.")
    d.add()
    d.add("| Name | Summary |")
    d.add("| --- | --- |")
    for e in sorted(entries, key=lambda x: x.get("name", "")):
        summary = truncate_md(plain(e.get("description")))
        d.add(f"| [{e['name']}]({e['name']}.md) | {summary} |")
    d.add()
    write(out / section / "index.md", d.render())


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    root = Path(__file__).resolve().parents[2]
    # The install ships the bundle in doc-html/, so the source and the running
    # engine are the same version by construction rather than by remembering to
    # re-download after an upgrade.
    ap.add_argument("--src", type=Path, default=root / "factorio" / "doc-html")
    ap.add_argument("--out", type=Path, default=root / "factorio-docs" / "markdown")
    ap.add_argument("--clean", action="store_true", help="wipe the output dir first")
    args = ap.parse_args()

    src, out = args.src, args.out
    proto_json, runtime_json = src / "prototype-api.json", src / "runtime-api.json"
    for f in (proto_json, runtime_json):
        if not f.exists():
            print(f"error: missing {f}", file=sys.stderr)
            return 1

    proto = json.loads(proto_json.read_text(encoding="utf-8"))
    runtime = json.loads(runtime_json.read_text(encoding="utf-8"))
    version = proto.get("application_version", "unknown")

    if args.clean and out.exists():
        shutil.rmtree(out)

    # 1. Registry --------------------------------------------------------
    reg = Registry()
    groups = [
        ("prototype", "prototypes", proto["prototypes"], render_prototype),
        ("prototype", "types", proto["types"], render_type_page),
        ("runtime", "classes", runtime["classes"], render_class),
        ("runtime", "concepts", runtime["concepts"], render_concept),
        ("runtime", "events", runtime["events"], render_event),
    ]
    for stage, section, entries, _ in groups:
        for e in entries:
            if "/" in e["name"] or "\\" in e["name"]:
                print(f"error: unsafe entity name {e['name']!r}", file=sys.stderr)
                return 1
            reg.add(stage, e["name"], f"{section}/{e['name']}.md")

    aux_dir = src / "auxiliary"
    aux_files = sorted(aux_dir.glob("*.html")) if aux_dir.is_dir() else []
    for f in aux_files:
        reg.add("auxiliary", f.stem, f"auxiliary/{f.stem}.md")

    # 2. Entity pages ----------------------------------------------------
    counts: dict[str, int] = {}
    for _, section, entries, renderer in groups:
        for e in entries:
            write(out / section / f"{e['name']}.md", renderer(e, reg))
        counts[section] = len(entries)
        write_index(out, section, entries, reg, section.capitalize())

    write(out / "defines" / "defines.md", render_defines(runtime["defines"], reg))
    write(out / "runtime-globals.md", render_globals(runtime, reg))

    # 3. Auxiliary prose pages -------------------------------------------
    aux_names: list[str] = []
    if aux_files:
        resolve = make_aux_resolver(reg, out, {f.stem for f in aux_files})
        for f in aux_files:
            write(out / "auxiliary" / f"{f.stem}.md", convert_aux(f, resolve))
            aux_names.append(f.stem)
    counts["auxiliary"] = len(aux_names)

    # 4. Root README -----------------------------------------------------
    d = Doc()
    d.add(f"# Factorio API reference (markdown) — {version}")
    d.add()
    d.add(
        "Generated from the official API dump by `tools/generate/api_docs.py`. "
        "Do not edit by hand; rerun the script instead."
    )
    d.add()
    d.add("**This tree is far too large to read in full. Navigate it, do not load it:**")
    d.add()
    d.add("1. If you know the exact name, open the file directly, e.g. `prototypes/SegmentedUnitPrototype.md`.")
    d.add("2. Otherwise grep the relevant `index.md`, then open the single file you need.")
    d.add()
    d.add("| Section | Entries | Index |")
    d.add("| --- | --- | --- |")
    for section, label in [
        ("prototypes", "Prototype definitions (data stage)"),
        ("types", "Prototype property types"),
        ("classes", "Runtime `Lua*` classes (control stage)"),
        ("concepts", "Runtime concepts"),
        ("events", "Runtime events"),
    ]:
        d.add(f"| {label} | {counts[section]} | [{section}/index.md]({section}/index.md) |")
    d.add(f"| Runtime defines | {len(runtime['defines'])} | [defines/defines.md](defines/defines.md) |")
    d.add(f"| Prose guides | {counts['auxiliary']} | see below |")
    d.add()
    d.add("Also: [runtime-globals.md](runtime-globals.md) — `game`, `script`, `defines`, ...")
    d.add()
    d.add("## Prose guides")
    d.add()
    for name in aux_names:
        d.add(f"- [{name}](auxiliary/{name}.md)")
    d.add()
    write(out / "README.md", d.render())

    # 5. Verification ----------------------------------------------------
    written = {p.relative_to(out).as_posix() for p in out.rglob("*.md")}
    problems = []
    for target in reg.targets():
        if target not in written:
            problems.append(f"registry target never written: {target}")

    link_re = re.compile(r"\]\(([^)]+)\)")
    fence_re = re.compile(r"```.*?```", re.S)
    code_re = re.compile(r"`[^`\n]*`")
    broken = 0
    for p in sorted(out.rglob("*.md")):
        text = p.read_text(encoding="utf-8")
        # Links quoted inside code are documentation of link syntax, not links.
        text = code_re.sub("", fence_re.sub("", text))
        for m in link_re.finditer(text):
            href = m.group(1)
            if href.startswith(("http://", "https://", "#")):
                continue
            target = (p.parent / href.split("#")[0]).resolve()
            if not target.exists():
                broken += 1
                if broken <= 5:
                    problems.append(f"broken link in {p.relative_to(out).as_posix()}: {href}")
    if broken > 5:
        problems.append(f"...and {broken - 5} more broken links")

    total = len(written)
    print(f"Factorio {version} -> {out}")
    for section in ("prototypes", "types", "classes", "concepts", "events", "auxiliary"):
        print(f"  {section:<12} {counts[section]:>4}")
    print(f"  {'total files':<12} {total:>4}")
    if problems:
        print("\nVERIFICATION FAILED:", file=sys.stderr)
        for p in problems:
            print("  " + p, file=sys.stderr)
        return 1
    print("  verification  OK (no broken internal links)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
