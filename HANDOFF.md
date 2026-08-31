<!-- FLEET
addon: AbilityMap
version: 2.1.0
status: SHIPPED
owner-chat: Sniffer
needs-marshall: none
next-action: refresh the SimC aura seed to 12.1 (only affects seeded, non-verified aura IDs)
broadcast-read: 2026-08-14
updated: 2026-08-14
-->

> **Sniffer is the hub as well as this addon's owner.** Hub state, build queue and rules live in `Projects\WoW\Sniffer\HANDOFF.md` — read that first, this second.

# AbilityMap — Handoff

**Owner: the Sniffer (hub) session.** Assigned by Marshall 2026-08-12 — AbilityMap
has no chat of its own. Earlier routing wrongly attributed its docs to the Skopos
chat; git shows the docs predate the repo and cannot be attributed to anyone.

## Shared references

Read `C:\Users\Marshall Sisler\Projects\WoW\SHARED-REFERENCES.md` at session
start — it indexes the Midnight knowledge base and the shared 12.1 docs.
Reading shared references is expected, not a lane violation.

⛔ `_project/knowledge/WoW-Midnight-Addon-Dev-KnowledgeBase.md` in THIS repo is a
frozen July archive. Use the maintained copy at `Projects\WoW\`.

## What it is

A read-only static dataset: every ability/talent → its buff/debuff aura ID,
cooldown, charges, talent-rename overrides. Public at `Lumenlytics/AbilityMap`.
`_G.AbilityMap` is the API (`Get`, `GetBuff`, `GetDebuff`, `GetCooldown`,
`GetGroup`, `Iterate`, `GetLifecycle`, `ResolveOverride`, `GetStats`).

It reads no combat state and no secret values, so it is safe to query in combat
— that is the whole point of it existing as static data.

## Layout

```
Core.lua              the API. VERSION 1.0.0, BUILD "12.0.7 (68453)"  <- stale
Data/*.lua            13 class files, ~1.4 MB, all captured 2026-07-19
CCXMap/               the in-game capture addon (deploys as its own addon)
_project/CAPTURE_CHECKLIST.md    per-class aura worklist
_project/data/        raw CCXMapDB dumps
_project/scripts/     extract/build pipeline (python + lua)
_project/simc/        ~17 MB simc dumps — GITIGNORED, refetch when needed
_project/output/      generated intermediates
```

**`CCXMap/` moved out of `_project/exporter/` on 2026-08-12.** It could never
load from there: WoW requires folder name == .toc name, and the folder was
called `exporter`. As a direct child of AbilityMap with its own `.toc`,
`deploy.ps1` mirrors it to `Interface\AddOns\CCXMap` as a separate addon —
the same `move-folders` pattern Gleaner_Data uses. Verified deploying 2026-08-12.

## Current state / open work

- **`Data/` is stale.** Captured 2026-07-19 on **12.0.7 build 68453**. 12.1
  (live 2026-08-11, build 69189) shipped large class tuning. The refresh is the
  addon's main open item. Marshall runs the in-game capture; the pipeline
  rebuilds `Data/` from the dump.
- `Core.lua` `BUILD` string must be updated to the 12.1 build **after** a
  successful re-capture, not before.
- `.toc` already declares `## Interface: 120000, 120100` — no bump needed.
- **Phalanx coupling is nominal** (verified 2026-08-12): it declares
  `## OptionalDeps: AbilityMap` and matches AbilityMap's class-token naming, but
  makes **no calls to the API**. The stale data blocks nothing in Phalanx.
- `_project/CAPTURE_CHECKLIST.md` still lists 17 unresolved Warrior auras from
  the v1.6 pass — worth another `/ccx watch` run.

## When does the data actually need re-capturing?

AbilityMap stores **cooldowns, charges, aura IDs, talent renames, descriptions**
— it does **not** store damage numbers. Most hotfixes are therefore invisible to
it. Confirmed 2026-08-12: the post-launch 12.1 hotfixes changed nothing in this
dataset.

| Change | Re-capture? |
|---|---|
| Damage/healing % tuning | ❌ no — not stored |
| PvP-only modifiers | ❌ no |
| Cooldown or charge changes | ✅ yes |
| New/changed aura, or a talent rename | ✅ yes |
| New patch (client build bumps) | ✅ yes |
| New spec or class | ✅ yes |

**Cheap way to decide without reading patch notes:** re-run `/ccx sweep`, then
diff the new dump's `meta` and per-class ability counts against
`_project/data/ccxmap-*.lua`. `sweepAt`, `sweepSpells` and `sweepSpecs` settle it
in seconds — and that same diff proves whether a sweep actually ran, since the
addon rewrites SavedVariables on every reload whether or not you swept.

Server-side hotfixes do **not** bump the client build, so an unchanged build in
`.build.info` is not evidence that nothing changed. Compare the capture, not the
build number.

## The refresh pipeline

1. In game: `/reload`, confirm **CCXMap** is enabled in the addon list.
2. `/ccx sweep` — reads all 13 classes' talent trees from one character.
3. `/ccx watch` (optional) — cast abilities to auto-resolve aura IDs. Cast
   **out of combat**, leaving ~2s between casts: the watcher blames the most
   recent cast within 1.5s, which caused cross-talk last time.
4. `/reload` to flush SavedVariables.
5. Copy `WTF/Account/RYRIN/SavedVariables/CCXMap.lua` →
   `_project/data/ccxmap.lua`.
6. Run the pipeline in `_project/scripts/` (see README → Rebuilding the data).
7. Update `Core.lua` `BUILD`, commit.

⚠ Captured cooldowns are *live* values including haste and talents, so they read
~10–30% under true base. Known issue, documented in the README.
