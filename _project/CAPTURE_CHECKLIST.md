# Warrior capture checklist (CCXMap v1.6)

## ✅ Done — charge cooldowns fixed

The v1.6 re-capture landed: `chargeRecharge = 10/10`. All 11 charge abilities now carry a
real recharge time instead of the inter-charge lockout (Shield Block 1s → 13.6s, Charge
1.5s → 17s, Heroic Leap 1.5s → 30s, Shield Wall 8s → 162s).

Caveat: these are *live* values including haste and talents, so they read ~10–30% under
true base. See README → Known issues.

## ✅ Done — 10 auras auto-captured

`/ccx watch` resolved these, dropping the Wowhead worklist from 27 to 17:

| Ability | Aura | |
|---|---|---|
| Charge | 105771 | debuff (root) |
| Taunt | 355 | debuff |
| Shield Wall | 871 | buff |
| Intervene | 147833 | buff on ally |
| Berserker Rage | 18499 | buff |
| Spell Reflection | 23920 | buff |
| Die by the Sword | 118038 | buff |
| Sweeping Strikes | 260708 | buff |
| Battle Stance | 386164 | buff |
| Defensive Stance | 386208 | buff |

## ⬜ Remaining — 17 auras still to resolve

Worth one more `/ccx watch` pass before falling back to Wowhead. Cast **out of combat**
where possible and leave a gap between casts — the watcher blames the most recent cast
within 1.5 seconds, which is what caused the cross-talk last time.

| ✔ | Ability | ID | Applies |
|---|---|---|---|
| [ ] | Berserker Shout | 384100 | fear immunity buff |
| [ ] | Berserker Stance | 386196 | stance buff (Fury) |
| [ ] | Bladestorm | 227847 | immunity + DoT |
| [ ] | Challenging Shout | 1161 | AoE taunt |
| [ ] | Champion's Spear | 376079 | tether + DoT |
| [ ] | Demolish | 436358 | channel damage reduction |
| [ ] | Disrupting Shout | 386071 | taunt |
| [ ] | Hamstring | 1715 | snare debuff |
| [ ] | Ignore Pain | 190456 | absorb buff |
| [ ] | Interpose | 1244088 | ally damage reduction — **needs a friendly target** |
| [ ] | Intimidating Shout | 5246 | fear |
| [ ] | Odyn's Fury | 385059 | DoT |
| [ ] | Piercing Howl | 12323 | snare debuff — first capture was wrong, see below |
| [ ] | Ravager | 228920 | DoT + self buff |
| [ ] | Revenge | 6572 | free-cast proc (needs a dodge/parry) |
| [ ] | Shield Charge | 385952 | stun |
| [ ] | Shockwave | 46968 | stun |

### Rejected captures — do NOT trust these

| Ability | Captured | Why rejected |
|---|---|---|
| Thunder Clap 6343 | player buff 1278009 | Thunder Clap applies a **target** debuff; this is a proc |
| Piercing Howl 12323 | player buff 1244157 | Piercing Howl applies a **target** snare; this is a proc |
| Colossus Smash 167105 | 260708, 1261189 | 260708 is Sweeping Strikes — 1.5s window cross-talk |

For target debuffs (Hamstring, Piercing Howl, Shockwave, Shield Charge, Champion's Spear),
cast on a dummy and pause a couple of seconds between casts so attribution stays clean.

## Then

1. `/reload` to flush.
2. Copy `WTF/Account/RYRIN/SavedVariables/CCXMap.lua` → `_project/data/ccxmap.lua`.
3. Re-run the pipeline (README → Rebuilding the data).
