# AbilityMap — handoff

A shared **data library**, not a UI addon. Every ability, talent and PvP talent mapped
to its buff/debuff aura ID, base cooldown, charges and description — captured from a
live client rather than guessed. Other addons read it at runtime through
`_G.AbilityMap`; nothing here draws a frame.

## Shared references — read at session start

**Read `C:\Users\Marshall Sisler\Projects\WoW\SHARED-REFERENCES.md` at session start.**
It indexes the Midnight knowledge base and the other shared docs. **Reading shared
references is expected, not a lane violation** — the one-chat-per-addon rule restricts
writing, never reading.

⛔ **Do not cite `_project\knowledge\WoW-Midnight-Addon-Dev-KnowledgeBase.md`** — the
copy inside this repo is a frozen 2026-07-19 snapshot, pre-12.1, and now carries an
ARCHIVE banner. It is kept only as an artifact of the research phase. The live doc is
`Projects\WoW\WoW-Midnight-Addon-Dev-KnowledgeBase.md`.

## Status

- **v2.0.0**, repo #11, public at `github.com/Lumenlytics/AbilityMap`. Promoted
  2026-07-29 from an unversioned live folder — before that it existed **only** in
  `Interface\AddOns`, unbacked, and was the one real exception to "the live folder is
  disposable". That is resolved: it is ordinary build output now like the other repos.
- `.toc` declares `## Interface: 120000, 120100`, so it is already flagged for 12.1.
- Ships `Core.lua` plus `Data\<Class>.lua` for all **13** classes.

⚠ **The data is captured against 12.0.7 (build 68453)** — README says so in its first
line. 12.1 went live 2026-08-11 at build `120100` with class tuning, so **`Data/` needs
a refresh pass** and the README's build reference is stale. Nothing is broken; the data
is simply describing the previous patch.

## Consumers

`Phalanx` declares `## OptionalDeps: AbilityMap` — verified in its `.toc`.

⚠ **The coupling is looser than that declaration suggests.** An earlier version of this
section said a breaking change to `_G.AbilityMap` would break Phalanx silently at load.
That was inferred from the `.toc` line without checking whether anything calls the API.
It does not. Grepping Phalanx finds the `OptionalDeps` declaration, two source
*comments* noting that its class tokens follow AbilityMap's convention, and prose in its
own docs — **no call into `_G.AbilityMap` anywhere**. Phalanx's `HANDOFF.md` states it
outright: *"it can consume AbilityMap via `## OptionalDeps` but doesn't need it for this
phase"*, and its taxonomy data is *"independent of the aura pipeline"*.

So today the relationship is a declared optional dependency plus naming-convention
alignment, not a live data consumer. **Do not treat the runtime shape as frozen on
Phalanx's behalf** until something actually reads it. Re-check before assuming either
way — this is exactly the kind of claim that gets repeated once written down.

## Layout

| Path | What it is |
|---|---|
| `Core.lua`, `Data\*.lua` | the shipped addon — this is what other addons read |
| `_project\scripts\` | the build pipeline that regenerates `Data/` |
| `_project\output\AbilityMap.xlsx` | human-readable dataset: Summary tab + one per class |
| `_project\simc\` | **gitignored** — ~17 MB of SimulationCraft spell dumps |
| `_project\knowledge\` | research artifacts, including the archived pre-12.1 KB |
| `_project\CAPTURE_CHECKLIST.md` | the capture procedure |

`_project/simc/` is deliberately not committed: it is regenerable third-party output.
Re-fetch it from the matching simc release when refreshing `Data/`.

## Notes

**OWNER: the Sniffer / hub session** (assigned by Marshall, 2026-08-11). Route work here.

This repo had no chat of its own, which is why it went without a HANDOFF until
2026-08-11. This file was written from the Skopos chat under a temporary routing that
has since been superseded — Skopos does **not** own this addon and should not be sent
its work.

⚠ That routing was justified on the grounds that the Skopos chat authored AbilityMap's
documentation. **Git does not support that claim** and it should not be repeated: the
promotion commit `da08ee9` (2026-07-29) is co-authored by a *Fable 5* session, not this
one, and its message says the addon was "promoted from unversioned live folder" — so
`README.md` predates version control and its author is not recorded anywhere. Treat
authorship of the pre-2026-07-29 docs as unknown.

**AbilityMap is Marshall's addon** (`## Author: Ryrin`). Phalanx *consumes* it via
`OptionalDeps`; it did not write it. Skopos has no relationship to it beyond this
routing.
