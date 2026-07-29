# AbilityMap

A shared data library for WoW **Midnight 12.0.7 (build 68453)**: every ability, talent and
PvP talent mapped to its **buff/debuff aura ID**, base cooldown, charges and description —
captured from a live client, not guessed.

Other addons read it at runtime through `_G.AbilityMap`. For reading by eye, the whole
dataset is also an Excel workbook at **`_project/output/AbilityMap.xlsx`** — a Summary tab
plus one tab per class, with abilities grouped and their modifier talents nested beneath.
The build pipeline lives in `_project/scripts/`.

---

## Using it from another addon

```lua
## OptionalDeps: AbilityMap          -- in your .toc
```

```lua
local AM = _G.AbilityMap
if AM then
    -- an ability's aura is usually a DIFFERENT spell ID than the cast
    local buff = AM:GetBuff(2565)          -- Shield Block  -> 132404
    local _, debuff = AM:GetAuras(12294)   -- Mortal Strike -> 213667 (Mortal Wounds)

    -- alternate spec/rank IDs resolve to the primary entry
    local e = AM:Get(163201)               -- -> Execute, spellID 5308

    -- an ability plus the talents that modify it
    for _, row in ipairs(AM:GetGroup("WARRIOR", "Demolish")) do
        print(row.kind, row.name, row.spellID)
    end

    for spellID, entry in AM:Iterate("WARRIOR") do ... end
end
```

### API

| Method | Returns |
|---|---|
| `GetClasses()` | array of loaded class tokens |
| `HasClass(class)` | boolean |
| `GetClass(class)` | raw `{ class, build, abilities, order, groups }` |
| `GetPlayerClass()` | the player's own class table |
| `Get(spellID [, class])` | entry, classToken — resolves alternate IDs |
| `GetBuff` / `GetDebuff` / `GetAuras` | aura spell ID(s) |
| `GetCooldown(spellID)` | base cooldown in seconds |
| `GetGroup(class, groupName)` | ability + its modifier talents, in sheet order |
| `GetGroups(class)` | ordered group names |
| `Iterate(class)` | `for spellID, entry in ...` |
| `GetUnverified(class)` | entries still needing an aura ID |
| `GetStats(class)` | total, verified, needsVerify, noAura |
| `GetLifecycle(spellID)` | everything a cooldown-manager slot needs (below) |
| `GetLifecycleAbilities(class [, "player"\|"target"])` | all abilities worth a slot |
| `ResolveOverride(spellID)` | follows talent rename chains |

---

## Lifecycle slots (cooldown managers)

A lifecycle slot shows an ability's **buff while it is up**, then falls back to the
**cooldown** once it drops.

**Do not implement that by asking "is the buff up?"** Under 12.1 aura reads are secret in
combat, and `AuraButton:IsShown()` is deliberately secret to block exactly that branch
(KB §4.3: *"Stop branching on aura presence"*). A `auraInstanceID ~= nil` test fails too —
nil-comparison against a secret is a prohibited operation and throws.

Build it by **layering** and let the engine decide visibility:

```
slot            plain frame, never fed a secret
 ├─ cooldown    your Cooldown frame, underneath
 └─ auraButton  AuraButton in an AuraContainer, on top
```

The container shows and hides the button itself, so the buff covers the cooldown while
active and reveals it when it drops. No branch, no secret read, works in combat.

> **Anchor both to `slot`.** Never anchor the cooldown *to* the aura button — secret anchors
> propagate to anchored children, and size/position queries on them then error (KB §2.6).

`GetLifecycle` supplies what you need to configure the container:

```lua
local l = AbilityMap:GetLifecycle(2565)
-- l.auraID    132404      the aura to track
-- l.auraKind  "buff"
-- l.auraUnit  "player"    which unit the container watches
-- l.duration  base seconds, when known
-- l.cd        13.6
-- l.override  spellID this is renamed into by the active talent build
-- l.modifiers passives that change this slot's TIMING only
-- l.verified  true = hand-checked aura ID, false = auto-captured

for _, l in ipairs(AbilityMap:GetLifecycleAbilities("WARRIOR", "player")) do
    -- one player-side AuraContainer tracking every l.auraID
end
```

**Target debuffs (Rend, Mortal Wounds, Colossus Smash):** an `AuraContainer` with
`SetUnit("target")` renders the debuff icon **and its duration text**. So displaying "how
long is Rend up" works. Reading that number, or branching on it, does not.

Permanent auras (the three stances) carry `aura.permanent = true` and no duration —
their `expirationTime` is 0 in the API, so countdown logic must not read them as expired.

### Warrior lifecycle coverage

17 player-buff slots · 12 target-debuff slots · 43 timing-relevant passives joined to them.
All aura IDs hand-verified on Wowhead except Interpose (see below).

### Entry fields

`spellID` · `name` · `group` · `kind` (Ability / Modifier / Passive) · `kind_type` (Active /
Passive) · `specs` · `cd` · `charges` · `buff` · `debuff` · `alt` · `triage` · `conf` · `desc`

Lifecycle fields: `aura` = `{ id, kind, unit, duration }` · `override` (spellID this is
renamed into) · `affects` = what a passive changes, `{"duration"|"cooldown"|"charges"|"proc"|"damage"}`

Static reference data only — no combat state, no secret values — so it is safe to query
in combat, where the live aura APIs go secret under 12.x.

`/amap` prints coverage · `/amap 2565` inspects a spell · `/amap Demolish` shows a group.

---

## Coverage

**All 13 classes present — 3,807 rows, 3,571 aura mappings, 479 player-buff / 327 target-debuff lifecycle slots.**

| Class | Rows | Auras | Player slots | Target slots |
|---|---|---|---|---|
| Death Knight | 265 | 251 | 36 | 23 |
| Demon Hunter | 290 | 278 | 49 | 18 |
| Druid | 381 | 353 | 55 | 34 |
| Evoker | 265 | 256 | 24 | 30 |
| Hunter | 280 | 261 | 25 | 25 |
| Mage | 266 | 246 | 27 | 21 |
| Monk | 344 | 326 | 46 | 25 |
| Paladin | 324 | 292 | 39 | 23 |
| Priest | 289 | 272 | 27 | 27 |
| Rogue | 295 | 282 | 38 | 25 |
| Shaman | 283 | 257 | 42 | 21 |
| Warlock | 265 | 250 | 33 | 27 |
| Warrior | 260 | 247 | 38 | 28 |

**Confidence is not uniform — check the `conf` field.** Only Warrior's 38 core auras are
hand-verified (`conf="Verified"`). Everything else is `conf="SimC (<signals>)"` — seeded from
SimulationCraft's extraction of Blizzard client data, which scored **38/38 with 28/28 correct
durations** against those hand-verified Warrior auras, but has not been independently checked
per class. Treat SimC-seeded entries as high-confidence, not proven.

Ability lists come from three sources, merged:

| Source | Supplies | Needs a character? |
|---|---|---|
| `/ccx export` | your own specs: PvP talents, baseline spellbook, live overrides | that class, played |
| `/ccx sweep` | class/spec/hero talent trees for all 13 classes | any one character |
| `simc_baseline.py` | **baseline abilities + rename chains** for all 13 classes | **no** |

**You do not need a character of a class at any level.** SimC's generated
`class_spells.inc` / `specialization_spells.inc` carry the baseline ability list *and* the
spell-replacement edges — the two things the sweep structurally cannot reach (`C_SpellBook`
is player-only; `GetOverrideSpell` resolves only for the active build). That closed the last
gap: Paladin's Shield of the Righteous now resolves 53600 → aura 132403 → override 415091
with no Paladin involved. Baselines add 33–76 spells per class.

Where the client supplied nothing, cooldowns and descriptions are backfilled from the SimC
dump; client data always wins where it exists.

### Known issues

- **Sub-2s cooldowns on chargeless abilities are flagged, not trusted.** SimC's text dump
  does not carry the charge category for every spell, so an ability like Shield of the
  Righteous reports `Cooldown: 1 seconds` — the inter-charge lockout, not its real recharge.
  Any active with a cooldown ≤1.6s and no charge count gets a `note` saying so and a
  `CooldownSuspect` flag. Verify those in-game before relying on the number.

- **Charge cooldowns are live values, not base values.** Fixed in v1.6 (they used to read
  the inter-charge lockout: Shield Block 1s, Charge 1.5s). `cooldownDuration` gives the
  *current* recharge — which includes the character's haste and talent reductions, so it
  reads consistently below the true base:

  | Ability | Captured | True base |
  |---|---|---|
  | Shield Block | 13.6s | 16s |
  | Charge | 17s | 20s |
  | Heroic Leap | 30s | 45s |
  | Shield Wall | 162s | 240s |
  | Spell Reflection | 22.5s | 25s |
  | Intervene / Interpose | 27s | 30s |
  | Overpower / Raging Blow / Bladestorm / Ravager | 12s / 8s / 90s / 90s | correct |

  Shield Block captured *two different values* across specs (12669ms and 13573ms) — proof
  these scale with live stats. `build_grouped.py` keeps the **largest** value seen (the
  least-reduced), so the numbers are close to base but not exact. Non-charge abilities are
  unaffected; `GetSpellBaseCooldown` gives them true base values.

  To make these exact you would need to record `UnitSpellHaste("player")` at capture time
  and divide it back out — worth doing only if exact base cooldowns matter to you.

  On export, v1.6 prints `charge abilities: N/M captured a true recharge time`. Amber means
  some were at full charges (where `cooldownDuration` can report 0) — use them and re-export.
- 7 Fury passives still captured without description text (Bloodcraze, Critical Thinking,
  Invigorating Fury, Kill or Be Killed, Ragedrinker, Rampaging Ruin, Surge of Adrenaline).
  They persisted through the v1.6 re-capture, so `GetSpellDescription` is likely returning
  empty for unlearned/inactive hero-talent nodes rather than it being a timing issue.
- **Interpose (1244088) aura ID unresolved.** Its cast spell has no aura effects at all on
  Wowhead (only "Charge to Object"), so the 8s damage-share must be a triggered aura with a
  separate ID — the same shape as Intervene 3411 → 147833. Needs an in-game probe: cast it
  on an ally and read `UNIT_AURA`. It is the only Warrior ability still unverified.
- **Intimidating Shout may be reversed.** 5246 is recorded as the AoE fear and 316593 as the
  primary-target cower/root, inferred from 316593 carrying a Root effect. Both pages list
  overlapping Fear effects, so the mapping could be the other way round. Confirm by fearing
  a pack and comparing the primary target's aura against a neighbour's.
- **Taunt auras may not be queryable.** Challenging Shout (1161) and Disrupting Shout (386071)
  apply `Apply Aura: Taunt` on the cast spell itself, but taunts are often implemented as a
  threat-table effect rather than a real unit aura — they may never surface via `UNIT_AURA`.
- **Ravager (228920)** shows its aura data on the cast spell; it may be an internal aura with
  no player-visible buff. Worth an in-game check before giving it a slot.
- **Auto-captured auras carry lower confidence than verified ones.** `/ccx watch` blames the
  most recent cast within 1.5s, so it produces cross-talk — it credited Colossus Smash with
  applying Sweeping Strikes, and blamed trinket procs on whatever was cast. Only self-evident
  captures (aura ID == cast ID on the expected unit) or well-established auras were accepted;
  see `AUTO` and `REJECTED_CAPTURES` in `refine.py`. Rejected so far: Thunder Clap and
  Piercing Howl both captured *player* buffs when their real auras are target debuffs.

---

## Rebuilding the data

Run from `_project/scripts/`:

```bash
lua extract.lua > warrior_full.tsv          # SavedVariables -> TSV (expects ccxmap.lua alongside; carries rechargeMS)
cp warrior_full.tsv warrior_abilities.tsv   # both inputs, one source since all specs are in one capture
python build_grouped.py                     # nest modifiers under their parent ability
python extract_auras.py                     # /ccx watch captures -> captured_auras.json
python refine.py                            # collapse + triage + classify modifiers
python build_workbook.py                    # -> ../output/AbilityMap.xlsx (all classes)
python build_lua.py Warrior warrior_rows_refined.json ../..   # -> Data/Warrior.lua
lua smoke.lua ../..                          # verify the library loads and the API works
```

Set `PYTHONIOENCODING=utf-8` on Windows — the `↳` glyph crashes a cp1252 console.

### Pipeline stages

1. **`extract.lua`** — reads the CCXMap SavedVariables, emits TSV.
2. **`build_grouped.py`** — dedupes across specs; nests each modifier passive under the
   ability its description names (earliest mention wins). Holds the `V` dict of
   hand-verified aura IDs — **extend this per class**.
3. **`extract_auras.py`** — pulls the `/ccx watch` aura captures (aura ID, unit, duration).
4. **`refine.py`** — three jobs:
   - *Collapse*: merges same-name rows only when both are Active, share a parent group,
     and their descriptions match ≥55% with numbers masked. This deliberately does **not**
     merge distinct talents that share a name (Master of Warfare, Phalanx, Rampaging
     Berserker, Bloodborne, Improved Execute, Massacre, Critical Thinking) — their effects
     differ and merging would destroy data.
   - *Triage*: sorts actives into `NEEDS VERIFY` / `NO AURA` so the Wowhead pass only
     covers abilities that actually apply an aura. Judgment calls that description text
     alone gets wrong live in an explicit `OVERRIDES` dict keyed by spell ID.
   - *Classify*: tags each passive with what it changes. Only `duration` / `cooldown` /
     `charges` can alter a lifecycle slot's timing; `damage` ones are noise for that purpose
     (Warrior: 43 of 181 passives matter).
5. **`build_workbook.py`** — the workbook: a Summary tab plus one tab per class.
6. **`build_lua.py`** — the runtime `Data/<Class>.lua` module.

### Capturing a new class

**You do not need a character of that class.** CCXMap v2.0 sweeps every class's talent
trees from whatever character you are on, using `C_ClassTalents.InitializeViewLoadout` +
`VIEW_TRAIT_CONFIG_ID` — the same mechanism Blizzard's talent-link inspect UI uses. The
viewed *level* is a parameter, so a level-10 character can read a max-level tree,
hero talents included.

1. Out of combat: `/ccx sweep` (once — it clobbers the config Blizzard's inspect UI uses).
2. `/ccx sweepfill` if it reports unresolved descriptions. Spell data loads lazily, so an
   empty description means "not loaded yet", not "no data" — the sweep queues those via
   `C_Spell.RequestLoadSpellData` and fills them on a second pass. Repeat until it reports 0.
3. `/reload` to flush, then copy the SavedVariables to `_project/data/ccxmap.lua`.
4. Run the pipeline above with the class token: `lua extract.lua PALADIN > paladin_full.tsv`.

`extract.lua` merges both sources: your own played specs (richer — PvP talents, baseline
spellbook, live overrides) take precedence, and the sweep fills in every other class. The
`origin` column records which supplied each row.

**Sweep limitations:** no PvP talents (player-and-active-spec only, no cross-class API) and
no baseline spellbook (`C_SpellBook` is player-only). Both need one login on that class, or
a static PvP talent ID table hydrated via `GetPvpTalentInfoByID`.

### Seeding aura IDs from SimulationCraft

`simc_import.py` parses the SimC `SpellDataDump/` class files into cast→aura candidates.
Scored against the 38 hand-verified Warrior auras it gets **38/38 correct, 28/28 durations**.
It works from four signals, since Blizzard hardcodes most of these links in script rather
than data (`SpellEffect.EffectTriggerSpell` is empty for the majority of player abilities):

| Signal | Evidence |
|---|---|
| `self` | the cast spell's own record carries Apply Aura — most common shape, ~20 of Warrior's 38 |
| `backref` | the aura's description is `$@spelldescNNNN`, pointing back at the cast |
| `descref` | the cast's description interpolates `$NNNNd` (the aura's duration) |
| `trigger` | an effect carries an explicit `Trigger Spell: NNNN` |

```bash
python simc_import.py ../simc/paladin.txt                       # candidates
python simc_import.py ../simc/warrior.txt --score ../data/warrior_rows_refined.json
```

Treat it as a high-quality seed to verify, not ground truth. It caught two errors in this
project's own inherited data (Rend and Thunder Clap both assumed aura == cast; neither cast
spell carries any aura at all) — but the same class of variant ambiguity can cut the other
way. Dumps are cached in `_project/simc/`, ~17 MB, build 12.0.7.68453.
4. Verify each `NEEDS VERIFY` aura on Wowhead — the aura page's `/spell=NNN` URL is the ID.
   **Never infer the aura ID from the cast ID**; even self-buffs differ.
5. Add `Data/<Class>.lua` to `AbilityMap.toc`.

Note `/reload` does not re-execute addons on this machine — only a full restart does.
`/reload` *does* still flush SavedVariables. Confirm the loaded build with
`CCXMapDB.meta.loadedVersion`.
