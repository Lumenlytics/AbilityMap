# World of Warcraft Retail (Midnight) — Addon Development Knowledge Base

**A practical reference manual for building modern Retail addons.**
Target client: **Midnight, patch 12.0.x → 12.1.0 "Curse of Ula'tek."** Interface `120000` (12.0) / `120100` (12.1).
Compiled June 30, 2026.

---

## How to read this document

This is a single master reference covering ten areas: the secure execution model, Secret Values, the 12.1 aura redesign, combat-automation restrictions, an old-vs-new comparison, a categorized API reference, architecture and performance best practices, a secure-coding checklist, common UI patterns, future-proofing, a compatibility matrix, and a strict coding ruleset.

**Accuracy convention.** Confirmed material (Blizzard blue posts, Warcraft Wiki API changelogs) is stated plainly. Items still on the 12.1 PTR and subject to change are marked **⚠ PTR**. When a method or template name comes from a Blizzard example rather than finalized docs, it is marked **(sample name)**. Re-verify PTR items against [warcraft.wiki.gg/wiki/Patch_12.1.0/API_changes](https://warcraft.wiki.gg/wiki/Patch_12.1.0/API_changes) before shipping.

> **The one-paragraph orientation.** Midnight is dominated by Blizzard's **"Addon Disarmament"** project. Its goal: stop addons from making combat *decisions* (automation, rotation assistance, hidden-mechanic reconstruction) while preserving look-and-feel customization. The mechanism is not mass API removal — it is *obfuscation*. Combat-relevant API returns become **Secret Values** that tainted (addon) code can hold and pass but cannot read, compare, or compute on. The combat log catch-all was removed. In 12.1, auras — the last big leak — move behind **Aura Containers** and **Private Script Objects**. Build every addon assuming any combat-derived value may be secret.

---

# Part 1 — The Secure Execution Model (still fully in force)

The classic security model from prior expansions is unchanged and underpins everything new. Source: [Secure Execution and Tainting](https://warcraft.wiki.gg/wiki/Secure_Execution_and_Tainting).

## 1.1 Taint

Execution begins **secure**. The moment the engine runs addon code (or `/script`, or reads addon-set data), that execution path becomes **tainted**. Taint spreads through return values, globals you write, and closures you create, and persists until `/reload`.

- **Protected functions refuse to run from a tainted path.** This is the root cause of "addon X is causing action-blocked" errors.
- **Never replace Blizzard functions or write Blizzard globals** — that taints them for everyone. **Hook** instead:
  - `hooksecurefunc([table,] "name", yourFn)` — runs your function *after* the secure one without tainting it.
  - `frame:HookScript("OnEvent", yourFn)` — adds to a script handler without replacing it.
- Inspection: `issecure()`, `issecurevariable([table,] "name")`, `securecall(fn, ...)`, `forceinsecure()`.

## 1.2 Combat lockdown

`InCombatLockdown()` returns true between `PLAYER_REGEN_DISABLED` (combat start) and `PLAYER_REGEN_ENABLED` (combat end). During lockdown you **cannot**:

- create secure frames,
- set or change attributes on secure frames,
- show / hide / move / re-parent **protected** frames.

Protection propagates to a protected frame's parent and to anchor targets. **Do all secure configuration out of combat.** The standard pattern is to queue secure changes and flush them on `PLAYER_REGEN_ENABLED`.

## 1.3 Protected functions and protected frames

A **protected function** (e.g. casting a spell, targeting, moving a protected frame) succeeds only from a secure path. A **protected frame** is locked in combat and can never be made unprotected. Addons cannot script the player's combat actions directly — they can only *offer* a button the human presses.

## 1.4 Secure templates — `SecureActionButtonTemplate`

The sanctioned way for an addon to trigger a protected action without deciding for the player. The human must click; the addon only pre-configures what the click does.

```lua
-- Create and configure OUT OF COMBAT:
local b = CreateFrame("Button", "MyCastButton", UIParent, "SecureActionButtonTemplate")
b:SetAttribute("type", "spell")       -- "item" | "macro" | "macrotext" | "target" | "focus" | ...
b:SetAttribute("spell", "Healing Surge")
b:SetAttribute("unit", "target")
-- Modifier variants: "shift-type2", "ctrl-spell", etc.
```

`InsecureActionButtonTemplate` exists but only functions out of combat.

## 1.5 Secure handlers, snippets, and the restricted environment

To make a frame react to game state **securely in combat**, use the secure-handler family. They run pre-approved Lua **snippets** inside a sandboxed **restricted environment** that stays secure even in combat.

- Templates: `SecureHandlerStateTemplate`, `SecureHandlerClickTemplate`, `SecureHandlerAttributeTemplate`, etc.
- Install snippets: `SecureHandlerExecute`, `SecureHandlerWrapScript`, `SecureHandlerSetFrameRef`.
- State drivers react to game macro-conditions without tainting:
  - `RegisterStateDriver(frame, "state", "[combat] x; [nocombat] y")` — fires the snippet `_onstate-state`.
  - `RegisterAttributeDriver(frame, "attr", "...")`.
- Inside snippets you get only a subset of API (`SecureCmdOptionParse`, `UnitExists`, modifier checks), frame *handles* (not real userdata), predefined `self`/`owner`, and `CallMethod`/`CallMethodSecure` to call back out.

## 1.6 The modern event + callback + timer model

- Events: `frame:RegisterEvent("EVENT")` and the filtered `frame:RegisterUnitEvent("UNIT_HEALTH", "player", "target")` (filters at the engine level — strictly preferred when you care about specific units).
- Native callback bus: `EventRegistry:RegisterCallback(...)` / `RegisterFrameEventAndCallback(...)`.
- Timers: `C_Timer.After(delay, fn)`, `C_Timer.NewTimer`, `C_Timer.NewTicker(interval, fn)`.
- Addon management is namespaced: `C_AddOns.LoadAddOn`, `C_AddOns.IsAddOnLoaded`, `C_AddOns.GetAddOnMetadata` (the old unnamespaced globals are gone).

---

# Part 2 — Secret Values

Source: [Secret Values](https://warcraft.wiki.gg/wiki/Secret_Values), [Patch 12.0.0/API changes](https://warcraft.wiki.gg/wiki/Patch_12.0.0/API_changes).

## 2.1 What they are

A Lua-level mechanism introduced in **12.0.0** that makes combat-relevant API returns **opaque**. A secret value is a real value the addon can store and pass around, but cannot inspect or compute on. Example: in combat, `UnitHealth("target")` returns a *secret number*.

**Secrets only bite on a tainted path.** When untainted Blizzard code reads the same value, it behaves normally. Taint is the trigger; Secret Values ride on top of it.

## 2.2 Why Blizzard built them

To "limit the ability for addons to perform complex logic and decision-making based off combat information" *without* removing APIs wholesale or forcing every frame into the secure environment. Secrets give passive, per-API protection that Blizzard can tune individually and relax over time (and they have — see §2.7).

## 2.3 When a value becomes secret

Governed by the new `C_Secrets.*` policy family, generally active **in combat, encounters, Mythic+, and rated PvP**. The API docs annotate functions with flags:

- `SecretReturns = true` — always secret.
- `ConditionalSecret` / `SecretWhenUnitIdentityRestricted` — e.g. `UnitName(unit)` is secret for **non-player/pet units in combat**; `UnitClass` first return is conditionally secret.
- `SecretWhenCooldownsRestricted` — cooldown reads (renamed from `SecretWhenSpellCooldownRestricted` in 12.0.5).
- On the **receiving** side, parameters are tagged `SecretArguments = AllowedWhenUntainted | AllowedWhenTainted | NotAllowed`.

Query policy directly: `C_Secrets.HasSecretRestrictions`, `ShouldUnitHealthMaxBeSecret`, `ShouldUnitPowerBeSecret`, `ShouldCooldownsBeSecret`, `ShouldAurasBeSecret`, `ShouldUnitComparisonBeSecret`, `ShouldUnitIdentityBeSecret`, `GetPowerTypeSecrecy`, etc.

## 2.4 What is PROHIBITED on a secret (from tainted code)

Each of these throws an immediate Lua error:

- arithmetic (`+ - * / %`)
- concatenation (`..`)
- comparison / boolean test (`==`, `<`, `>`, `if secret then`)
- length operator (`#`)
- using as a **table key**
- indexed access or assignment (`secret.foo`, `secret["x"] = 1`)
- calling it as a function

```lua
local hp = UnitHealth("target")             -- secret in combat
if hp < 1000 then ... end                   -- ERROR: comparison on a secret
local pct = hp / UnitHealthMax("target")    -- ERROR: arithmetic on a secret
```

## 2.5 What is ALLOWED — and how to display secrets

You **may** store a secret in a variable/upvalue/table value, and **pass** it to another Lua function or to a C API that accepts secrets. The intended use is **display**: feed the secret straight to a widget.

```lua
healthBar:SetValue(UnitHealth("target"))    -- OK: StatusBar:SetValue accepts secrets
nameText:SetText(UnitName("target"))        -- OK: FontString:SetText accepts secrets
```

To turn a secret into a *visual* without reading it, use the mapping objects added in 12.0:

- `C_CurveUtil.CreateCurve` / `CreateColorCurve` (with `EvaluateColorFromBoolean`, `EvaluateGameCurve`) — e.g. a ColorCurve drives a health bar green→red across 100%→0% while the addon never sees the number.
- Formatters: `AbbreviatedNumberFormatter`, `NumericRuleFormatter`, `SecondsFormatter` (12.0.5) — format secret numbers/durations for display.

## 2.6 Propagation ("infection")

Feeding a secret into a widget marks the widget. Two models:

- **Secret Aspects** — a tagged capability. `FontString:SetText(secret)` applies the `Text` aspect, so `FontString:GetText()` now also returns a secret. Test with `obj:HasSecretAspect(aspect)` (see `Enum.SecretAspect`); clear only with `obj:SetToDefaults()`.
- **Secret Anchors / "has secret values"** — setters with no associated aspect (e.g. `StatusBar:SetValue(secret)`) mark the **whole object** secret. Position/measurement APIs (`GetWidth`, anchor queries) on it then **error**, and secrecy **propagates to anchored children**. Test with `obj:HasSecretValues()` and `region:IsAnchoringSecret()`.

**Practical consequence:** never read a frame's size/anchors after feeding it a secret. Keep a separate, never-secret frame for any layout math you need.

## 2.7 Detection helpers and the relaxation history

Helpers: `issecretvalue(v)`, `canaccesssecrets()` (false when the caller is tainted), `canaccessvalue(v)`, `issecrettable(t)`, `canaccesstable(t)`, plus utilities `secretwrap`, `scrubsecretvalues`, `mapvalues`, `dropsecretaccess`.

Blizzard has *relaxed* the system as it matured — don't over-assume secrecy:

- **12.0.5:** `UnitHealthMax` / `UnitPowerMax` no longer secret for **player** units; player **secondary** resources no longer secret (primary still is); aura booleans `isHelpful/isHarmful/isRaid/isNameplateOnly/isFromPlayerOrPlayerPet` no longer secret; `Ambiguate` accepts secrets; `%.5s`-style width modifiers no longer truncate secret strings.

**Classic builds:** the secret system is entirely disabled — secret-returning APIs return plain values there.

---

# Part 3 — Private Script Objects & the Forbidden Partition (12.1) ⚠ PTR

Where Secret Values hide *data*, the 12.1 layer hides *parts of an object*. Source: [Patch 12.1.0/API changes](https://warcraft.wiki.gg/wiki/Patch_12.1.0/API_changes).

- **Private Script Objects** split a script object's Lua representation across multiple tables ("partitions"). One is the **Forbidden Partition**, which is *inaccessible to addons*. It can hold mixins, key/value pairs, functions, script handlers, and child objects — so Blizzard can hide arbitrary chunks of an object from addon code.
- **Forbidden Aspects** are the action-blocking analog of Secret Aspects. Instead of obfuscating data, they *forbid functionality*. Example: the `UntrustedScriptExecution` Forbidden Aspect means script handlers (`OnShow`/`OnLoad`/`OnSizeChanged`) set by addons **won't run** — only handlers living in the Forbidden Partition (and untainted) execute. Functions that enforce this are flagged `ChecksForbiddenAspects` in the docs.

This is the enforcement tech behind Aura Containers (Part 4): an addon can hold a reference to a protected object but cannot hook it, register events on it, or branch on its `IsShown()` (which returns a secret).

---

# Part 4 — Auras: Private Auras and the 12.1 Container Model

Auras are the spine of the disarmament effort, because **the mere presence of an aura often reveals that a hidden combat event happened.**

## 4.1 Private Auras (Dragonflight 10.1 → heavily used in Midnight)

A **private aura** is a buff/debuff Blizzard flags so the game draws it but **all data is hidden from addons** (no spell ID, name, duration, stacks). During Midnight, Blizzard found Secret Values alone could not stop aura-based automation, so they flagged **most encounter debuffs as private**. Limitations Blizzard itself lists: no addon customization, **no nameplate support**, and heavy per-encounter designer upkeep.

Limited display path — anchor a game-drawn icon to your frame without reading data:

```lua
local anchorID = C_UnitAuras.AddPrivateAuraAnchor({
  unitToken = "player",
  auraIndex = 1,
  parent = myFrame,
  showCountdownFrame = true,
  showCountdownNumbers = true,
  iconInfo = { iconWidth = 32, iconHeight = 32, iconAnchor = { point = "CENTER" } },
})
-- C_UnitAuras.RemovePrivateAuraAnchor(anchorID)
```

Companions: `SetPrivateWarningTextAnchor`, `AddPrivateAuraAppliedSound`, `AuraIsPrivate`. Not supported on nameplates.

## 4.2 The 12.1 redesign — Aura Containers & Aura Buttons ⚠ PTR

Authoritative source: Blizzard blue post **"Addons and Auras in Curse of Ula'tek"** (JHemphill, 2026-06-18), reproduced on [Patch 12.1.0/API changes](https://warcraft.wiki.gg/wiki/Patch_12.1.0/API_changes); coverage at [Wowhead](https://www.wowhead.com/news/blizzard-on-addons-and-auras-in-patch-12-1-customize-and-display-filtered-sets-381909) and [masterofwarcraft.net](https://www.masterofwarcraft.net/2026/06/patch-121-combat-addon-aura-api-changes.html).

Two new object types let addons render auras **without ever touching aura data**:

- **`AuraContainer`** handles tracking, filtering, and updating internally. The addon declares *what* to track and *how it looks* — it never queries, diffs, or refreshes aura state.
- **`AuraButton`** is the visual element (icon texture + duration font string) the container drives.

```lua
local container = CreateFrame("AuraContainer", nil, UIParent, "CustomAuraContainerTemplate") -- (sample name)
container:SetSize(1, 1)
container:SetPoint("CENTER")
container:SetUnit("target")
container:AddAuraFilter("HELPFUL", { maxFrameCount = 5 })   -- track first 5 helpful auras

for i = 1, 5 do
  local btn = CreateFrame("AuraButton", nil, container, "CustomAuraButtonTemplate")     -- (sample name)
  btn:SetSize(40, 40)
  btn:SetPoint("TOPLEFT", container, "TOPLEFT", (i - 1) * 42, 0)
  btn.Icon = btn:CreateTexture(nil, "OVERLAY"); btn.Icon:SetAllPoints(btn)
  btn:SetIcon(btn.Icon)                                       -- hand the texture to the engine
  btn.Text = btn:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  btn:SetDurationText(btn.Text)                               -- hand the duration fontstring to the engine
  container:AddAuraFrame(btn)                                 -- button enters the Forbidden Partition
end
```

Confirmed object/method names: `AuraContainer`, `AuraButton`, `SetUnit`, `AddAuraFilter(filterType, opts)`, `SetIcon`, `SetDurationText`, `AddAuraFrame`. Once a button is added via `AddAuraFrame`, it lives in the container's **Forbidden Partition** with Forbidden Aspects: the addon cannot install show/hide handlers, hook its mixins, or register events on it, and **`IsShown()` returns a secret** — so no logic can key off whether an aura is up. That is precisely what kills the "icon present = combat info" leak.

Also new/related: category-level group-buff visibility APIs `C_UnitAuras.GetGroupBuffVisualAlerts` / `SetGroupBuffVisualAlerts` / `GetHiddenGroupBuffs` / `SetHiddenGroupBuffs` — coarse category control, not spell-ID granularity.

## 4.3 What breaks and the migration path ⚠ PTR

The decisive change (arriving in later 12.1 PTR builds, **not** week 1): **when auras are secret (combat / encounters / M+ / PvP), all `UnitAura` APIs return full secrets or `nil` to addons.** `C_UnitAuras.GetUnitAuras` and `GetUnitAuraInstanceIDs` return a **secret vector** — you cannot read its length or iterate it. By extension, `GetAuraDataByIndex`, `GetAuraDataBySpellName`, `GetAuraDataByAuraInstanceID`, the legacy `UnitAura`/`UnitBuff`/`UnitDebuff`, and `AuraUtil` helpers become unusable for branching. **Escape hatch:** auras Blizzard explicitly flags **non-secret** still return normally; data is also readable out of combat / open world.

Migration for any "read auras → filter in Lua → drive my own frames" addon (WeakAuras, Plater, Cell, ElvUI raid frames):

1. Replace self-managed aura frames with `AuraContainer` + `AuraButton`.
2. Move presentation into container/button templates and mixins; provide `SetIcon`/`SetDurationText` targets instead of reading aura fields.
3. **Stop branching on aura presence** — button `IsShown()` is secret; "if buff up then…" automation is no longer possible for protected auras.
4. For genuinely needed visibility (healer dispel/defensive views), rely on flagged non-secret auras plus the category group-buff APIs.

There is **no deprecation grace period** — expect aura UIs to break on patch day until container-based rewrites ship. Blizzard is working with authors throughout PTR (`author-wishlist` Discord channel).

---

# Part 5 — Combat Automation Restrictions: blocked vs. legal

The throughline: **customizing how the UI looks is allowed; deriving combat decisions from hidden state is not.**

## 5.1 The combat log is gone (the biggest single break)

- `CombatLogGetCurrentEventInfo` and the entire `CombatLog*` global family are **removed**.
- `COMBAT_LOG_EVENT_UNFILTERED` is no longer available to addons; it was replaced by `COMBAT_LOG_EVENT_INTERNAL_UNFILTERED`, which is **internal to Blizzard code**.
- Addon-facing combat log now routes through a managed `C_CombatLog.*` namespace (`ApplyFilterSettings`, `IsCombatLogRestricted`, `SetMessageLimit`, …) and events `COMBAT_LOG_MESSAGE`, `COMBAT_LOG_ENTRIES_CLEARED`, etc.
- Blizzard added a **built-in `C_DamageMeter`** system + `DAMAGE_METER_*` events as the sanctioned path for damage/healing tracking. CLEU-parsing automation is effectively dead.

## 5.2 By addon category

- **Boss mods (DBM, BigWigs):** legitimate timers/warnings are fully supported via native Encounter/timeline APIs — custom event colors, a native event-sound + countdown API (audio cues and 5-4-3-2-1 countdowns), and spell-count/timeline data added in 12.0.x. What's removed is reconstructing *hidden* mechanic state from buffs/debuffs.
- **WeakAuras / Plater:** display still works through Aura Containers and curves/formatters. What breaks: triggers that branch on aura data or unit health/power math in combat, and nameplate debuff tracking of secret auras.
- **Rotation / automation helpers (Hekili-style "press this now"):** hardest hit. In combat/encounter/M+/PvP they can no longer read target/player aura state or do health/power/cooldown math to compute next actions. This is the explicit anti-automation target.

## 5.3 What can still be read legally

- Auras Blizzard explicitly flags as non-secret; all aura data **out of combat / open world**.
- Player's own max health/power and secondary resources (un-secreted in 12.0.5).
- Aura booleans `isHelpful/isHarmful/isRaid/isNameplateOnly/isFromPlayerOrPlayerPet`.
- Native boss-mod timeline/timer/sound/color APIs and Encounter Journal data.
- Category-level group-buff visibility APIs.
- Customized **display** of filtered auras, health, power, and cooldowns (you render them; you just can't read them back or branch on them).

---

# Part 6 — Old vs. New (≈ one year ago, TWW 11.x → Midnight 12.x)

| Area | One year ago (TWW 11.x) | Midnight (12.0 → 12.1) |
|---|---|---|
| **Combat log** | `COMBAT_LOG_EVENT_UNFILTERED` + `CombatLogGetCurrentEventInfo` | Removed; managed `C_CombatLog.*` + `C_DamageMeter`; raw stream is Blizzard-internal |
| **Unit health/power** | Plain numbers; free arithmetic in combat | **Secret** in combat (player max/secondary un-secreted in 12.0.5); display only |
| **Unit comparison / threat** | Compare units freely | Unit-comparison + threat return **secrets** for restricted token combos |
| **`UnitName` in combat** | Always a usable string | **Secret** for non-player/pet units in combat |
| **Auras** | Iterate `UnitAura`, branch on presence | **Secret vectors** in combat (12.1); display via **Aura Containers** only |
| **Cooldowns** | `GetSpellCooldown` → number for math | `C_Spell.GetSpellCooldown` → table; **secret** when restricted; Duration objects for display |
| **Spell / item / addon globals** | `GetSpellInfo`, `GetItemInfo`, `IsAddOnLoaded` | Removed → `C_Spell.*`, `C_Item.*`, `C_AddOns.*` |
| **Frame handlers on protected objects** | Hook `OnShow`/`OnUpdate`, register events freely | **Forbidden Aspects** block this on protected objects (12.1) |
| **Frame measurement** | Read size/anchors anytime | **Errors** on objects marked "has secret values" |
| **Config UI** | `InterfaceOptions_*` panels | **Settings API** (`Settings.Register*`); old path deprecated |
| **Manifest texture names** | Published to `ManifestInterfaceData` | New interface texture filenames no longer published (12.1) |
| **Interface version** | `110xxx` | `120000` (12.0) / `120100` (12.1) |

**Assumptions no longer safe:** reading raw CLEU; doing math on `UnitHealth`/`UnitPower` in combat; comparing two units' health/threat; getting a usable `UnitName('target')` in combat; iterating/branching on a unit's auras; computing remaining cooldown from a number; hooking `OnShow`/`OnUpdate` on any frame to detect state; calling global `GetSpellInfo`/`GetItemInfo`/`IsAddOnLoaded`; reading a frame's anchors after feeding it a secret; scraping new texture filenames from the manifest.

---

# Part 7 — Patch 12.1 "Curse of Ula'tek" focus ⚠ PTR

- **Aura redesign** (Part 4): Aura Containers/Buttons; `UnitAura` APIs go secret in combat; migration required, no grace period.
- **New security primitives** (Part 3): Private Script Objects + Forbidden Partition; Forbidden Aspects (`UntrustedScriptExecution`).
- **TOC additions:** per-file `[Bootstrap]` directive for Load-on-Demand addons; `<KeyValue type="local"/>`; `<Mixins source="local"/>`. Interface bumps to `120100`.
- **Manifest privacy:** new interface texture filenames no longer exported (`exportinterfacefiles art` won't see them).
- **Misc useful additions:** SVG textures + `VectorGraphics` object; `Frame:SetOnUpdateMode(mode)` (`Disabled`/`RunWhenVisible`/`RunWhenVisibleOnce`/`RunOnce`/`RunAlways`) — a sanctioned way to limit OnUpdate cost; radial-progress masking (`SetRadialProgressBarPercent`) replacing cooldown-swipe hacks; Roleset system (`C_Roleset.ApplyRolesetFilters`); chat-restriction state (`addonChatRestrictionsForced` CVar, `ADDON_RESTRICTION_STATE_CHANGED` event).
- **Renames:** `UIParentLoadAddOn` → `LoadAddOnWithErrorHandling`.

---

# Part 8 — API Reference (by category)

Namespaced `C_*` tables are canonical; unnamespaced globals are largely removed.

**Addon lifecycle:** `C_AddOns.LoadAddOn`, `IsAddOnLoaded`, `GetAddOnMetadata`, `EnableAddOn`; `LoadAddOnWithErrorHandling`.

**Events & timers:** `Frame:RegisterEvent`, `RegisterUnitEvent`, `UnregisterEvent`, `SetScript("OnEvent")`; `EventRegistry:RegisterCallback` / `RegisterFrameEventAndCallback`; `C_Timer.After/NewTimer/NewTicker`.

**Spells:** `C_Spell.GetSpellInfo`, `GetSpellCooldown` (returns table), `GetSpellCharges`, `GetSpellCooldownRemaining`, `GetSpellCooldownRemainingPercent`, `GetSpellCooldownDuration` (Duration object); `C_SpellBook.*`, `C_ActionBar.*`.

**Items:** `C_Item.GetItemInfo` (ret 18 = itemDescription), `GetItemCount`, `GetItemIconByID`.

**Units:** `UnitHealth` / `UnitHealthMax` / `UnitHealthPercent` / `UnitHealthMissing`; `UnitPower` / `UnitPowerMax` / `UnitPowerPercent` / `UnitPowerMissing` (combat returns secret per policy); `UnitName`, `UnitClass`, `UnitGUID`, `UnitExists`, `UnitCastingInfo`, `UnitChannelInfo`.

**Auras:** `C_UnitAuras.GetAuraDataByIndex` / `GetAuraDataBySpellName` / `GetAuraDataByAuraInstanceID` / `GetUnitAuras` / `GetUnitAuraInstanceIDs` (secret in combat 12.1); `AuraUtil.*`; private auras `C_UnitAuras.AddPrivateAuraAnchor` / `RemovePrivateAuraAnchor` / `AuraIsPrivate`; **12.1** `AuraContainer` / `AuraButton` objects; group-buff `C_UnitAuras.Get/SetHiddenGroupBuffs`, `Get/SetGroupBuffVisualAlerts`.

**Secrets:** `issecretvalue`, `canaccesssecrets`, `canaccessvalue`, `issecrettable`, `canaccesstable`, `secretwrap`, `scrubsecretvalues`, `mapvalues`, `dropsecretaccess`; `C_Secrets.HasSecretRestrictions` / `Should*BeSecret` / `GetPowerTypeSecrecy`; display via `C_CurveUtil.CreateCurve`/`CreateColorCurve`, `AbbreviatedNumberFormatter`, `SecondsFormatter`.

**Combat log / meters:** `C_CombatLog.IsCombatLogRestricted` / `ApplyFilterSettings` / `SetMessageLimit`; events `COMBAT_LOG_MESSAGE`, `COMBAT_LOG_ENTRIES_CLEARED`; `C_DamageMeter.*`, `DAMAGE_METER_*`.

**Secure UI:** `CreateFrame(..., "SecureActionButtonTemplate")`, `Frame:SetAttribute`, `hooksecurefunc`, `RegisterStateDriver`, `RegisterAttributeDriver`, `SecureHandlerExecute`/`WrapScript`/`SetFrameRef`, `InCombatLockdown`.

**Settings & media:** `Settings.RegisterCanvasLayoutCategory` / `RegisterVerticalLayoutCategory` / `RegisterAddOnCategory` / `OpenToCategory`; `Cooldown:SetCooldown`; `StatusBar:SetMinMaxValues`/`SetValue`; `Frame:SetOnUpdateMode`.

**Pools & mixins:** `Mixin`, `CreateFromMixins`, `CreateFramePool`, `CreateObjectPool`, `CreateFramePoolCollection`, `Pool_Hide`, `Pool_HideAndClearAnchors`.

---

# Part 9 — Modern Architecture & Best Practices

## 9.1 File layout and the `.toc`

The folder name must equal the `.toc` name. The `.toc` is an ordered load manifest — libraries and namespace code before consumers.

```
## Interface: 120100
## Title: MyAddon
## Notes: Does a thing
## Version: 1.0.0
## SavedVariables: MyAddonDB
## SavedVariablesPerCharacter: MyAddonCharDB
## OptionalDeps: Ace3, LibDBIcon-1.0

embeds.xml          # libraries first
Core.lua            # namespace + bootstrap
Modules/Bars.lua
Modules/Config.lua
```

Midnight supports comma-delimited multi-edition interface lines and edition-suffixed files (`Core_Mainline.lua`, `Core_Vanilla.lua`).

## 9.2 Namespace pattern

Every file receives the addon name and a shared private table as varargs. Aim to expose **at most one** global.

```lua
local addonName, ns = ...   -- ns is the SAME table across every file
ns.modules = ns.modules or {}
```

## 9.3 SavedVariables lifecycle

`## SavedVariables` is account-wide; `## SavedVariablesPerCharacter` is per character. Both are **nil at file load** and populated only when your `ADDON_LOADED` fires.

```lua
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(self, _, name)
  if name ~= addonName then return end
  MyAddonDB = MyAddonDB or {}
  for k, v in pairs(ns.defaults) do
    if MyAddonDB[k] == nil then MyAddonDB[k] = v end   -- merge defaults, don't clobber
  end
  self:UnregisterEvent("ADDON_LOADED")
end)
```

The client serializes SavedVariables automatically at logout — use `PLAYER_LOGOUT` only to flush in-memory state. For profiles/namespaces/smart defaults, **AceDB-3.0** does all of this.

## 9.4 Libraries vs. native APIs

| Need | Native (simple) | Library (complex) |
|---|---|---|
| Config UI | Settings API | AceConfig-3.0 (declarative auto-GUI) |
| SavedVariables | hand-rolled defaults | AceDB-3.0 (profiles, namespaces) |
| Events | EventRegistry, RegisterUnitEvent | AceEvent-3.0 |
| Timers | C_Timer | (native suffices) |
| Pooling/composition | CreateFramePool / Mixin | (native suffices) |
| Minimap/broker | — | LibDataBroker + LibDBIcon-1.0 |
| Shared fonts/textures | — | LibSharedMedia-3.0 |
| Inter-addon callbacks | EventRegistry | CallbackHandler-1.0 |

Ace3 is maintained in 2026 and right for large, profile-heavy, multi-module addons. For a lean single-purpose addon, native Settings + EventRegistry + C_Timer + frame pools + LibStub-loaded LibDBIcon/LibSharedMedia is the leanest future-proof stack. Embed libraries and load via **LibStub** so addons share one in-memory copy.

---

# Part 10 — Performance Guidelines (measurable rules + why)

| Rule | Why it exists |
|---|---|
| **Never allocate tables inside `OnUpdate`** | `OnUpdate` fires every drawn frame (hundreds/sec); per-frame `{}` floods the incremental GC and causes stutter. Reuse a table and `wipe()` it. |
| **Localize/cache globals in hot paths** (`local UnitHealth = UnitHealth`) | Global access is an env-table lookup; a local is a register/slot read. Measurable in tight loops. |
| **Avoid anonymous closures in hot paths** | Each closure is a fresh heap object capturing upvalues → allocation + GC pressure. Define once, reuse. |
| **Reuse tables with `wipe(t)`** not `t = {}` | Keeps capacity, avoids allocation and a GC cycle. |
| **Avoid `..` concatenation in hot paths** | Lua strings are immutable + interned; each concat allocates a new string. Precompute or format once. |
| **Throttle expensive scans** | Roster/aura scans are O(n); run them on events or a throttle, not every frame. |
| **Batch UI updates** | Coalesce N data changes into one layout pass per tick instead of N passes. |
| **Prefer events / `C_Timer` over `OnUpdate`** | A ticker at 0.1s does ~10 calls/sec vs hundreds; same result, a fraction of the cost. In 12.1, `Frame:SetOnUpdateMode("RunWhenVisible")` further bounds cost. |
| **Profile before optimizing** | `GetAddOnCPUUsage` / `GetFunctionCPUUsage` (needs `scriptProfile` CVar), `/etrace`, and Perfy tell you where time actually goes — optimize the measured hot path, not a guess. |

**Throttle pattern**
```lua
local THROTTLE, acc = 0.05, 0
frame:SetScript("OnUpdate", function(self, elapsed)
  acc = acc + elapsed
  if acc < THROTTLE then return end
  acc = 0
  -- throttled work
end)
-- Better still: C_Timer.NewTicker(0.1, DoWork)
```

**State machine (no-op guard avoids redundant work)**
```lua
local STATE = "idle"
local function setState(new)
  if new == STATE then return end
  STATE = new
  if new == "combat" then ns.Bars:Show()
  elseif new == "idle" then ns.Bars:Hide() end
end
```

---

# Part 11 — Secure Coding Checklist (reason · example · alternative)

1. **Never taint Blizzard frames or globals.**
   *Reason:* tainted protected functions refuse to run → action-blocked. *Example:* `UIParent.Show = myFn` taints UIParent. *Alternative:* `hooksecurefunc` / `HookScript`.
2. **Do all secure configuration out of combat.**
   *Reason:* attribute/show/hide on protected frames is blocked in lockdown. *Example:* `b:SetAttribute("spell", x)` mid-fight errors. *Alternative:* queue and flush on `PLAYER_REGEN_ENABLED`.
3. **Never compute on a possibly-secret value from tainted code.**
   *Reason:* arithmetic/compare/concat/index/`#` on a secret throws. *Example:* `if UnitHealth("target") < 1000`. *Alternative:* guard with `canaccessvalue()`; display via `SetValue`/ColorCurve.
4. **Never read a frame's size/anchors after feeding it a secret.**
   *Reason:* the object is marked "has secret values"; measurement APIs error and propagate to children. *Example:* `bar:SetValue(secret); bar:GetWidth()`. *Alternative:* keep a separate never-secret frame for layout math.
5. **Prefer secure templates for any player action.**
   *Reason:* casting/targeting are protected. *Example:* don't try to `CastSpellByName` from a click handler in combat. *Alternative:* `SecureActionButtonTemplate` + attributes set out of combat.
6. **Never attempt combat automation.**
   *Reason:* it's the explicit thing Midnight disarms, and it will break. *Example:* reading auras to decide the next spell. *Alternative:* display-only assistance; let the human decide.
7. **Don't hook script handlers / register events on protected (Aura) objects.**
   *Reason:* Forbidden Aspects block it; `IsShown()` is secret. *Example:* `auraButton:HookScript("OnShow", ...)`. *Alternative:* style via container/button templates and `SetIcon`/`SetDurationText`.
8. **Use `RegisterUnitEvent` over `RegisterEvent` when targeting specific units.**
   *Reason:* engine-level filtering avoids waking your handler for irrelevant units. *Alternative:* none — strictly better.
9. **Never depend on undefined behavior or removed globals.**
   *Reason:* `CombatLogGetCurrentEventInfo`, `GetSpellInfo`, etc. are gone. *Alternative:* `C_CombatLog`/`C_DamageMeter`, `C_Spell.*`, `C_Item.*`, `C_AddOns.*`.

---

# Part 12 — Common Addon Patterns (current implementations)

- **Status bars:** `CreateFrame("StatusBar")` + `SetMinMaxValues`/`SetValue`. `SetValue` accepts secrets, so a health bar can show secret HP it can't read.
- **Cooldown swipes:** `Cooldown` widget + `cd:SetCooldown(start, duration)`; or 12.1 `SetRadialProgressBarPercent`.
- **Cast bars:** drive a StatusBar from `UNIT_SPELLCAST_START/STOP/SUCCEEDED` + `UnitCastingInfo` (no CLEU).
- **Aura trackers:** **Aura Containers/Buttons** (12.1). Old hand-rolled `UnitAura` scanners are being disarmed.
- **Movable frames:** `SetMovable(true)`, `RegisterForDrag("LeftButton")`, `OnDragStart`/`OnDragStop`; persist `GetPoint()` to your DB. (Don't read points on a secret-marked frame.)
- **Config panels:** Settings API (`Settings.RegisterCanvasLayoutCategory` / `RegisterVerticalLayoutCategory`, `OpenToCategory`). `InterfaceOptionsFrame_OpenToCategory` is deprecated.
- **Slash commands:** `SLASH_MYADDON1 = "/myaddon"; SlashCmdList["MYADDON"] = function(msg) ... end`.
- **Minimap button + DataBroker:** a LibDataBroker launcher handed to **LibDBIcon-1.0**; store `minimapPos`/hide in your DB.
- **Shared media:** **LibSharedMedia-3.0** for user-selectable fonts/textures/sounds.

---

# Part 13 — Future-Proof Design

Midnight proved APIs vanish without warning. Defend accordingly:

1. **Feature detection, not version detection.** Test `if AuraContainer then` / `if C_Spell and C_Spell.GetSpellCooldown then`, not interface numbers or `WOW_PROJECT_ID`.
2. **Wrap every Blizzard call behind your own function** (`ns.api.GetHealth`, `ns.api.TrackAuras`). A breaking change becomes a one-file fix.
3. **Abstract aura, event, and secret access** behind single accessors so you can swap legacy scans for Aura Containers without touching modules. Guard combat reads with `issecretvalue`/`canaccessvalue` before any operation. Drive visuals with Curve/ColorCurve/Duration objects.
4. **Graceful degradation.** Optional libs via `## OptionalDeps` + `LibStub("Lib", true)`; if a feature's API is missing, disable that feature and keep the rest alive instead of erroring on load.
5. **Keep UI rendering separate from business logic** so the rendering layer can be rebuilt against new secure primitives without rewriting your data layer.

---

# Part 14 — Compatibility Guide

| Client | Interface | Secret Values | Auras | Notes |
|---|---|---|---|---|
| **Dragonflight (10.x)** | `100xxx` | none | full `UnitAura` read; private auras introduced 10.1 | Old global APIs largely present |
| **The War Within (11.x)** | `110xxx` | none | full `UnitAura` read | `C_AddOns` migration completed; many globals deprecated |
| **Midnight 12.0.0** | `120000` | introduced; health/power/cooldown/name secret in combat | most encounter debuffs flagged private | CLEU removed; `C_DamageMeter` added; globals removed |
| **Midnight 12.0.5** | `120005` | relaxed: player max/secondary un-secreted; aura booleans un-secreted | private auras + relaxed booleans | `SecretWhenCooldownsRestricted` rename; formatters |
| **Midnight 12.1.0 ⚠ PTR** | `120100` | Private Script Objects + Forbidden Partition/Aspects | **Aura Containers/Buttons**; `UnitAura` secret in combat | TOC `[Bootstrap]`/local KeyValue/Mixins; SVG textures; `SetOnUpdateMode` |
| **Future** | — | expect further obfuscation | expect aura API to keep evolving | rely on abstraction + feature detection |
| **Classic builds** | — | **disabled** (plain values) | full read | secret system off entirely |

---

# Part 15 — Strict Coding Ruleset (apply before writing any Lua)

1. Set the correct `## Interface:` (`120100` for 12.1, `120000` for 12.0).
2. Never use a deprecated/removed API without a documented fallback. Prefer `C_*` namespaces (`C_Spell`, `C_Item`, `C_AddOns`, `C_UnitAuras`, `C_CombatLog`).
3. Prefer event-driven logic over polling; replace `OnUpdate` with `C_Timer` tickers or `SetOnUpdateMode` where possible.
4. Treat every combat-derived value as possibly secret. Guard with `canaccessvalue`/`issecretvalue` before arithmetic, comparison, concatenation, indexing, or `#`. Display via widgets/curves, never branch.
5. Do all secure-frame configuration out of combat; queue and flush on `PLAYER_REGEN_ENABLED`.
6. Never taint Blizzard frames/globals — hook, don't replace.
7. Never attempt combat automation or hidden-state reconstruction. Assist by display only.
8. Migrate aura displays to Aura Containers/Buttons; never branch on a button's `IsShown()`.
9. Isolate all Blizzard API access behind wrapper functions; keep UI rendering separate from business logic.
10. Use feature detection, not version detection. Assume aura and secret APIs will keep evolving — design abstractions accordingly.
11. Minimize runtime frame creation; pool and recycle (`CreateFramePool`, `Pool_Hide`).
12. Profile before optimizing; reuse tables (`wipe`), cache globals, avoid closures/concat in hot paths.

---

# Part 16 — Field notes: real taint bugs and fixes

Case studies from shipping addons on 12.1. Concrete symptoms → root cause → lesson.

## Case: "Internal Bag Error" + blocked mount from a QoL addon (RyrinQoL, 2026-07-08)

**Symptoms.** After combat/looting in a dungeon, mounting was blocked ("Interrupted") and picking up items threw a yellow **"Internal Bag Error."** A `/reload` cleared it until the next combat/loot re-triggered it. Classic taint-induced action-blocking, but the *source* took a long hunt.

**There were two independent causes, both in the same addon:**

1. **Automated `C_Container.UseContainerItem` taints in instances.** An "auto-open loot bags" feature swept bags on `LOOT_CLOSED` and called `UseContainerItem` from the addon's (tainted) handler. In instanced content this produced "Internal Bag Error" and spread taint that blocked the *next* protected action (mounting). **Lesson: don't drive item/container *use* from addon code in secure/instanced contexts.** The feature was removed entirely — there's no safe way to auto-use bag items under Midnight.

2. **Comparing a Secret Value taints even inside `pcall`.** A stats panel picked the primary stat with `if eff > bestVal`, where `eff = select(2, UnitStat("player", id))` — secret in combat/instances. It was wrapped in `pcall`; the pcall caught the *error* but the **taint still spread** and blocked mount/bags every second (the panel polled on `OnUpdate`).

**Generalizable lessons:**
- **`pcall` does NOT stop taint.** It catches the Lua error from operating on a secret, but execution is already tainted and that taint propagates to secure actions. You must *prevent* the operation, not catch its error.
- **Guard order matters.** `if v == nil` on a secret is itself a blocked `==` comparison, so a naive `safeNum` throws on the value it's meant to protect. Test `issecretvalue(v)` / `canaccessvalue(v)` **first**, then the nil check.
- **`InCombatLockdown()` is not a sufficient gate.** Values stay secret in instances (dungeon/raid/M+/rated) even when you're *out* of combat lockdown — e.g. mounting between pulls. Also gate on `IsInInstance()`, or guard every value individually.
- **Prefer avoidance over guarding.** Only read/compare combat values where they're guaranteed plain (open world, out of combat); otherwise freeze the display at its last good value. Secrets may still be *fed to widgets* for display (`FontString:SetText`), just never compared/computed on.

## Note: custom texture formats (verified 2026-07-09)

`Texture:SetTexture` / TOC `## IconTexture` / minimap-button & addon-compartment icons accept **BLP, TGA, PNG, and JPEG**. PNG landed in **10.0.7 (2023)** — not a Midnight-new thing. Two gotchas: **PNG/JPG paths must include the file extension** (`...\icon.png`), unlike BLP/TGA which are extension-less; and images **must be power-of-two** in both dimensions (32/64/128/256…) or they silently fail to display (blank/green). A 3808×3854 PNG won't render — resize to e.g. 128×128 first.

**Diagnosis workflow that worked:**
- `/console taintLog 1`, reproduce, then **`/reload` or full logout to flush** `WoW/_retail_/Logs/taint.log` (it buffers — a stale read means it hasn't flushed, or `taintLog` is `0`).
- Each block names the exact `file:line function()` that made the blocked comparison — that is the *root* taint source; everything downstream is collateral.
- If the log's line numbers don't match your current source, the game is running an **old loaded build** — reload/relog. A per-load `Print()` marker confirms which build is live.
- Confirm scope by **disabling the addon entirely**; if clean, it's yours. Then bisect by toggling features and reading `SavedVariables` to see what's actually enabled (a shipped default-off feature the user turned on was the real culprit here).

---

# Sources

**Blizzard / official**
- [Patch 12.0.0/API changes](https://warcraft.wiki.gg/wiki/Patch_12.0.0/API_changes) — Secret Values core, CLEU removal, global removals
- [Patch 12.0.1/API changes](https://warcraft.wiki.gg/wiki/Patch_12.0.1/API_changes) · [12.0.5](https://warcraft.wiki.gg/wiki/Patch_12.0.5/API_changes) · [12.0.7](https://warcraft.wiki.gg/wiki/Patch_12.0.7/API_changes)
- [Patch 12.1.0/API changes](https://warcraft.wiki.gg/wiki/Patch_12.1.0/API_changes) — Private Script Objects, Forbidden Partition/Aspects, Aura Containers
- "Addons and Auras in Curse of Ula'tek" blue post (JHemphill, 2026-06-18), reproduced on the 12.1.0 page above; [Blue Tracker mirror](https://www.bluetracker.gg/wow/topic/us-en/2317456-addons-and-auras-in-curse-of-ulatek/)
- [Secret Values](https://warcraft.wiki.gg/wiki/Secret_Values) · [Secure Execution and Tainting](https://warcraft.wiki.gg/wiki/Secure_Execution_and_Tainting) · [SecureActionButtonTemplate](https://warcraft.wiki.gg/wiki/SecureActionButtonTemplate) · [RestrictedEnvironment](https://warcraft.wiki.gg/wiki/RestrictedEnvironment) · [Private aura](https://warcraft.wiki.gg/wiki/Private_aura) · [COMBAT_LOG_EVENT_INTERNAL_UNFILTERED](https://warcraft.wiki.gg/wiki/COMBAT_LOG_EVENT_INTERNAL_UNFILTERED)
- API pages: [C_UnitAuras.AddPrivateAuraAnchor](https://warcraft.wiki.gg/wiki/API_C_UnitAuras.AddPrivateAuraAnchor) · [C_Spell.GetSpellCooldown](https://warcraft.wiki.gg/wiki/API_C_Spell.GetSpellCooldown) · [RegisterUnitEvent](https://warcraft.wiki.gg/wiki/API_Frame_RegisterUnitEvent) · [Settings API](https://warcraft.wiki.gg/wiki/Settings_API)

**Reference / community**
- [TOC format](https://warcraft.wiki.gg/wiki/TOC_format) · [Using the AddOn namespace](https://wowpedia.fandom.com/wiki/Using_the_AddOn_namespace) · [Lua Coding Tips](https://warcraft.wiki.gg/wiki/Lua_Coding_Tips) · [Lua variable scoping](https://warcraft.wiki.gg/wiki/Lua_variable_scoping)
- [EventRegistry](https://warcraft.wiki.gg/wiki/EventRegistry) · [UIHANDLER_OnUpdate](https://warcraft.wiki.gg/wiki/UIHANDLER_OnUpdate) · [FramePoolMixin](https://warcraft.wiki.gg/wiki/FramePoolMixin) · [ObjectPoolMixin:Acquire](https://warcraft.wiki.gg/wiki/API_ObjectPoolMixin_Acquire)
- [Ace3 getting started](https://www.wowace.com/projects/ace3/pages/getting-started) · [AceDB-3.0](https://www.wowace.com/projects/ace3/pages/api/ace-db-3-0) · [LibDBIcon-1.0](https://www.curseforge.com/wow/addons/libdbicon-1-0) · [Perfy profiler](https://github.com/emmericp/Perfy)

**News / analysis**
- [Wowhead: Why Most Debuffs Are Private Auras in Midnight S1](https://www.wowhead.com/news/blizzard-explains-why-most-debuffs-are-private-auras-in-midnight-season-1-380762) · [Wowhead: Addons and Auras in 12.1](https://www.wowhead.com/news/blizzard-on-addons-and-auras-in-patch-12-1-customize-and-display-filtered-sets-381909)
- [masterofwarcraft.net: Patch 12.1 Takes Another Swing at Combat Addons](https://www.masterofwarcraft.net/2026/06/patch-121-combat-addon-aura-api-changes.html)
- [github.com/DennysOliveira/wow-addon-dev](https://github.com/DennysOliveira/wow-addon-dev) — community Midnight addon-dev skill

---

*Status note: Patch 12.1 "Curse of Ula'tek" was on the PTR as of June 30, 2026. Items marked ⚠ PTR — especially the Aura Container method names and the timing of `UnitAura` returning secrets in combat — may change before release. Re-verify against the 12.1.0 API-changes page before shipping production code.*
