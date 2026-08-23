---
name: verify-in-engine
description: Verify Profitorio's runtime or data-stage behaviour by driving the real Factorio engine and asserting observable effects — items delivered, products crafted, entities bound — rather than API readbacks. Use when asked to verify, test, or prove that a change works in game; when a runtime/control-stage change needs checking beyond "does it load"; when the user reports "it doesn't work for me" and the claim needs reproducing on their save; when a Factorio API's real behaviour is unclear and the docs are ambiguous or suspect; or when a disputed claim needs visual evidence.
---

# Verify in-engine

`tools/check/prototypes.ps1` answers one question: does the data stage load. It cannot
tell you whether anything *works*. This skill is for behaviour.

## Assert the effect, not the readback

**Assert the observable effect, never the API readback.**

The loaders shipped broken past a suite that scored 10/10. It asserted
`loader_type == "input"`, which was true, while zero items moved — assigning
`loader_type` swings the arrow 180° and leaves the loader bound to the neighbour it
cannot use. Counting plates in the destination chest found it in one run.

So assert: destination `get_item_count`, `products_finished`, transport-line
contents, a fluid level. Something the player would see. If an assertion could pass
while the feature is dead, it is not an assertion.

**Always include a control** that bypasses the code under test and script-creates
the intended end state. Control passes and the real case fails → the bug is in your
code. Both fail → your model of the engine is wrong. Nothing else separates those,
and guessing wrong costs a round trip through the user.

## Pick a harness

| What you need | Use |
| --- | --- |
| Does the data stage load, no behaviour | `tools/check/prototypes.ps1` — not this skill |
| Probe state, run a simulation, count items, inspect a save | **RCON** — `tools/check/probe.ps1` + `tools/check/probe_client.py` |
| A real player: `build_from_cursor`, cursor stack, reach, rotate-by-player | **Scenario** — `tools/check/player.ps1` |
| Pixels: screenshots as evidence | **Scenario** — headless renders nothing |

Prefer RCON. It needs no window, starts in ~10s, and takes ad-hoc queries. Reach for
a scenario only for the two things RCON cannot reach.

Anything that script-creates the entity under test **bypasses `on_built_entity` and
proves nothing about a hand placement**. That is what `build_from_cursor` is for, and
it needs a character — which a headless server cannot give you: `create_character` on
an offline player fails outright with *"User isn't connected; can't create
character."* That is the whole reason the scenario path exists.

## RCON

```
powershell tools/check/probe.ps1 -Action start   # serves a COPY of dev.zip
echo '/silent-command rcon.print(game.tick)' | python tools/check/probe_client.py
python tools/check/probe_client.py < probe.lua   # blocks split on a --- line
powershell tools/check/probe.ps1 -Action stop    # not optional; see traps
```

Start from `templates/probe.lua` for "how does this actually behave". Measure first,
then write code against what you measured.

## Scenario

```
powershell tools/check/player.ps1 -Lua <scratchpad>/harness.lua -Scenario verify
```

Start from `templates/harness.lua`. It is phased **build → settle → assert**, and
that structure is load-bearing: an entity resolves its connections on its first
update, so `loader_container`, belt neighbours and machine status all read nil or
empty on the tick you created them. An early probe of this session reported "no
container on any side" for a *vanilla* loader — pure measurement error, two rounds
lost to it.

The harness writes its own verdict with `helpers.write_file`; the artefact appearing
is the completion signal, because the client has no useful exit code.

## Cover the false positives

The happy path is the easy half. Each of these is a plausible-looking case that must
*not* trigger, and each caught a real bug in the loader binding:

- a belt that is adjacent but **perpendicular** is not feeding you
- an underground belt's **entry** end swallows items in the direction it faces
- the **player's own character** stands next to what they just built and is not a container
- a loader **mid belt-line** is useless in either mode — there is nothing to fix

## Evidence for a human

When the user disputes a claim, measurements in a transcript do not settle it. Draw
the invisible state into the world and photograph it:

- `rendering.draw_text` for live values, `rendering.draw_rectangle` around the entity
  something is *actually* bound to — bindings are invisible and are usually the thing
  in dispute
- `game.take_screenshot{ show_entity_info = true, force_render = true, anti_alias = true }`
- read the PNG back and look at it before sending it

Render objects survive save/load, so a demo save keeps its labels.

## "It doesn't work for me"

Reproduce before theorising. Three wrong theories died to one query here:

1. Copy their save, serve the copy: `tools/check/probe.ps1 -Action start -Save dev.zip`
2. Enumerate the entities in question **with their real state** — position, direction,
   mode, what they are bound to, what is in each neighbouring tile
3. Only then explain

The answer was a loader bound to a belt, visible immediately in the dump. Never
inspect the user's save in place; `-Action start` copies it and `stop` deletes the copy.

## Traps

Each of these cost a round trip:

- **One line per command.** The console splits the command name on the first
  whitespace, and a newline counts: multi-line Lua returns `Unknown command
  "silent-command`. `probe_client.py` flattens blocks for you — so a `--` comment
  inside one swallows the rest of it.
- **`--no-auto-pause` is not a flag.** It is `auto_pause: false` in a server-settings
  file. Without it a server with no players never advances a tick, and a harness waits
  forever for items that cannot move. `tools/check/probe-settings.json` handles it.
- **A running server holds the lock file.** `prototypes.ps1` then fails with
  `Couldn't create lock file`, which reads exactly like a mod error. Always stop.
- **Headless renders nothing.** `take_screenshot` silently does nothing there.
- **The artefact is the pass signal, not the exit code.** Every script launches
  `factorio/bin/x64/factorio.exe` directly, so `player.ps1` holds a real process
  handle — but the client keeps running after a harness finishes, so there is no exit
  to wait for. The handle buys the failure case: a client that dies during load fails
  in seconds instead of at the timeout.
- **`pcall` probe bodies and write the report regardless.** A renamed API kills the
  whole run otherwise — `game.active_mods` became `script.active_mods` in 2.0 and took
  one scenario down with nothing to read.
- **2.0 renamed defines.** `assembling_machine_input` → `crafter_input`, and
  `furnace_source` is gone. Read `factorio-docs/markdown/defines/defines.md`; do not
  guess.
- **Directions are 16-valued.** North 0, east 4, south 8, west 12. An 8-valued
  mapping silently mislabels every reading — it made an early report say "east" for
  every loader that was facing south.
- **The docs can be wrong.** `belt_length` "should be the same as `belt_distance`";
  setting it to the documented `0` crashes at `TransportLine.cpp:891`. Prefer a probe
  over a sentence.

## Clean up

Delete the scenario directory (`player.ps1` does unless `-Keep`), the
`script-output/<scenario>` artefacts, and any save copy (`-Action stop` does).
Nothing of yours stays in the user's saves folder.
