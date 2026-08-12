--[[--------------------------------------------------------------------------
  ClassCodex Exporter  (Midnight 12.x)
  --------------------------------------------------------------------------
  Purpose: pull the *exact* spellID / cooldown / charges / cast time for every
  ability the current spec can access -- class + spec + hero talent trees, PvP
  talents, and known baseline spells -- straight from your live client, plus a
  best-effort capture of the buff / debuff auras those abilities apply.

  Why an addon and not a /script: the dataset is large and the clean way to get
  it out of the game is SavedVariables. Everything is written to
  CCXMapDB, which the client serializes to:

     _retail_\WTF\Account\<ACCOUNT>\SavedVariables\ClassCodexExporter.lua
     (after you log out or /reload)

  Usage (run OUT OF COMBAT):
     /ccx export     -> snapshot the CURRENT spec into the DB (run once per spec)
     /ccx watch      -> toggle live buff/debuff capture (see notes below)
     /ccx show       -> open a copy box with a compact paste-able summary
     /ccx status     -> what's been captured so far
     /ccx clear      -> wipe the DB and start over
     /ccx help

  Notes on aura capture (buff/debuff IDs):
     WoW does not expose "casting spell X applies aura Y" as static data, and in
     Midnight aura reads go *secret* in combat. So /ccx watch records the auras
     that appear right after each of your casts, but only while it can actually
     read the aura's spellID (out of combat / open world). Anything it can't
     read is left blank and flagged, to be filled from another source later.
     Nothing here reads a secret value or performs combat logic -- it is
     display/record only and safe under the 12.x rules.
----------------------------------------------------------------------------]]

local ADDON, ns = ...
local VERSION = "2.0.1"

-- Localize hot / frequently used APIs (nil-safe; we feature-detect below).
local C_Traits              = C_Traits
local C_ClassTalents        = C_ClassTalents
local C_Spell               = C_Spell
local C_SpecializationInfo  = C_SpecializationInfo
local C_SpellBook           = C_SpellBook
local issecretvalue         = issecretvalue
local canaccessvalue        = canaccessvalue

local PREFIX = "|cff00ccffClassCodex|r|cffffffffExporter|r: "
local function Print(msg) print(PREFIX .. tostring(msg)) end

-- Guard: is a value safe to read/compare from our (tainted) code?
local function CanRead(v)
  if issecretvalue and issecretvalue(v) then return false end
  if canaccessvalue and not canaccessvalue(v) then return false end
  return true
end

-- Safe wrapper: call fn(...) inside pcall, return nil on any error.
local function Try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, a, b, c, d = pcall(fn, ...)
  if ok then return a, b, c, d end
  return nil
end

--============================================================================
--  DB bootstrap
--============================================================================
local function EnsureDB()
  CCXMapDB = CCXMapDB or {}
  local db = CCXMapDB
  db.meta          = db.meta or {}
  db.classes       = db.classes or {}      -- [CLASSTOKEN][specID] = { ...abilities... }
  db.capturedAuras = db.capturedAuras or {} -- [castSpellID][auraSpellID] = {helpful,harmful,unit}
  return db
end

--============================================================================
--  Small helpers around the Spell API
--============================================================================
local function GetSpellName(spellID)
  local info = Try(C_Spell and C_Spell.GetSpellInfo, spellID)
  if type(info) == "table" then return info.name, info.castTime end
  return nil
end

local function GetCooldownMS(spellID)
  -- PRIMARY: GetSpellBaseCooldown(spellID) -> baseCooldownMS, gcdMS. This is the
  -- spell's *base* cooldown regardless of whether it is currently ready, is a
  -- global (confirmed present & non-secret in 12.0.x), and is what we actually
  -- want for a reference sheet.
  local baseMS, gcdMS = Try(GetSpellBaseCooldown, spellID)
  if baseMS ~= nil and CanRead(baseMS) then
    return math.floor(baseMS), (gcdMS and math.floor(gcdMS) or nil)
  end
  -- FALLBACK: C_Spell.GetSpellCooldown reports only the *remaining* cooldown
  -- (0 when ready), so it is a last resort. duration is in SECONDS.
  local cd = Try(C_Spell and C_Spell.GetSpellCooldown, spellID)
  if type(cd) == "table" and cd.duration ~= nil and CanRead(cd.duration) then
    return math.floor((cd.duration or 0) * 1000 + 0.5), nil
  end
  return nil, nil
end

local function GetCharges(spellID)
  -- Returns maxCharges, rechargeMS.
  --
  -- IMPORTANT: for charge-based spells GetSpellBaseCooldown reports the *inter-charge*
  -- cooldown (the brief lockout between casts), NOT the recharge time. Shield Block
  -- reads 1000ms there when the real recharge is 16s; Charge reads 1500ms vs 20s.
  -- cooldownDuration on GetSpellCharges is the actual recharge, so capture both and
  -- let the build pipeline prefer the recharge for charge abilities.
  local ch = Try(C_Spell and C_Spell.GetSpellCharges, spellID)
  if type(ch) == "table" and ch.maxCharges ~= nil and CanRead(ch.maxCharges) then
    local rechargeMS
    local dur = ch.cooldownDuration
    if dur ~= nil and CanRead(dur) and type(dur) == "number" and dur > 0 then
      -- duration is in SECONDS here; normalize to ms like every other field.
      rechargeMS = math.floor(dur * 1000 + 0.5)
    end
    return ch.maxCharges, rechargeMS
  end
  return nil, nil
end

local function GetOverride(spellID)
  -- Talents can REPLACE an ability with a renamed version (Thunder Clap -> Thunder
  -- Blast, Slam -> Heroic Strike). The client tracks this natively, so ask it
  -- rather than parsing tooltip text. Returns nil when nothing overrides.
  --
  -- Only resolves for the CURRENTLY ACTIVE talent build -- an override from an
  -- unselected talent will not appear until that build is captured.
  local getOverride = (C_Spell and C_Spell.GetOverrideSpell) or FindSpellOverrideByID
  local o = Try(getOverride, spellID)
  if type(o) == "number" and o ~= spellID and CanRead(o) then
    return o
  end
  return nil
end

local function IsPassive(spellID)
  local p = Try(C_Spell and C_Spell.IsSpellPassive, spellID)
  if p ~= nil then return p and true or false end
  return nil
end

local function GetDescription(spellID)
  -- Description text states what a talent augments ("Demolish deals ..."), which
  -- lets us group modifier passives with the ability they change. Static text,
  -- readable out of combat, not a secret value.
  local d = Try(C_Spell and C_Spell.GetSpellDescription, spellID)
  if type(d) == "string" and CanRead(d) then
    return (d:gsub("[\r\n]+", " "))   -- flatten newlines for clean serialization
  end
  return nil
end

--============================================================================
--  Collector: builds a de-duplicated list of abilities for the current spec
--============================================================================
local function NewCollector()
  local list, seen = {}, {}
  local function add(spellID, source, extra)
    if not spellID or type(spellID) ~= "number" then return end
    if seen[spellID] then
      -- keep the richest source label; talents win over spellbook
      local e = seen[spellID]
      if source == "talent" or source == "hero" or source == "pvp" then
        e.source = source
        if extra then for k, v in pairs(extra) do e[k] = v end end
      end
      return
    end
    local name, castTime = GetSpellName(spellID)
    local cooldownMS, gcdMS = GetCooldownMS(spellID)
    local charges, rechargeMS = GetCharges(spellID)
    local entry = {
      spellID   = spellID,
      name      = name,
      source    = source,
      cooldownMS= cooldownMS,
      rechargeMS= rechargeMS,   -- true cooldown for charge abilities (see GetCharges)
      gcdMS     = gcdMS,
      charges   = charges,
      castTimeMS= castTime,
      overrideSpellID = GetOverride(spellID),  -- talent renames this into another spell
      passive   = IsPassive(spellID),
      description = GetDescription(spellID),
    }
    if extra then for k, v in pairs(extra) do entry[k] = v end end
    seen[spellID] = entry
    list[#list + 1] = entry
  end
  return list, add
end

--============================================================================
--  1) Talent trees  (class + spec + hero, every node/choice, not just picked)
--============================================================================
local function CollectTalents(add)
  if not (C_ClassTalents and C_Traits) then return 0 end
  local configID = Try(C_ClassTalents.GetActiveConfigID)
  if not configID then return 0 end
  local configInfo = Try(C_Traits.GetConfigInfo, configID)
  if type(configInfo) ~= "table" or not configInfo.treeIDs then return 0 end

  local count = 0
  for _, treeID in ipairs(configInfo.treeIDs) do
    local nodes = Try(C_Traits.GetTreeNodes, treeID) or {}
    for _, nodeID in ipairs(nodes) do
      local nodeInfo = Try(C_Traits.GetNodeInfo, configID, nodeID)
      if type(nodeInfo) == "table" and nodeInfo.entryIDs then
        -- Hero (sub-tree) label, if this node belongs to one.
        local heroName
        if nodeInfo.subTreeID then
          local st = Try(C_Traits.GetSubTreeInfo, configID, nodeInfo.subTreeID)
          if type(st) == "table" then heroName = st.name end
        end
        local selected = (nodeInfo.activeRank and nodeInfo.activeRank > 0) or false
        for _, entryID in ipairs(nodeInfo.entryIDs) do
          local entryInfo = Try(C_Traits.GetEntryInfo, configID, entryID)
          local defID = type(entryInfo) == "table" and entryInfo.definitionID
          if defID then
            local def = Try(C_Traits.GetDefinitionInfo, defID)
            local spellID = type(def) == "table" and def.spellID
            if spellID then
              add(spellID, heroName and "hero" or "talent", {
                nodeID   = nodeID,
                treeID   = treeID,
                heroTree = heroName,
                selected = selected,
                isChoice = (#nodeInfo.entryIDs > 1) or nil,
              })
              count = count + 1
            end
          end
        end
      end
    end
  end
  return count
end

--============================================================================
--  2) PvP talents  (all available for this spec, across the 3 slots)
--============================================================================
local function CollectPvP(add)
  local getInfo = (C_SpecializationInfo and C_SpecializationInfo.GetPvpTalentInfoByID)
                  or GetPvpTalentInfoByID
  local getSlot = (C_SpecializationInfo and C_SpecializationInfo.GetPvpTalentSlotInfo)
  if not getSlot then return 0 end
  local count, added = 0, {}
  for slot = 1, 4 do
    local slotInfo = Try(getSlot, slot)
    local ids = type(slotInfo) == "table" and slotInfo.availableTalentIDs
    if ids then
      for _, tID in ipairs(ids) do
        if not added[tID] then
          added[tID] = true
          local info = Try(getInfo, tID)
          local spellID = type(info) == "table" and info.spellID
          if spellID then
            add(spellID, "pvp", { pvpTalentID = tID })
            count = count + 1
          end
        end
      end
    end
  end
  return count
end

--============================================================================
--  3) Baseline spellbook  (known active spells not already captured above)
--============================================================================
local function CollectSpellbook(add)
  if not C_SpellBook then return 0 end
  local bank = (Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player) or 0
  local numLines = Try(C_SpellBook.GetNumSpellBookSkillLines) or 0
  local spellType = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell
  local count = 0
  for line = 1, numLines do
    local li = Try(C_SpellBook.GetSpellBookSkillLineInfo, line)
    if type(li) == "table" and li.itemIndexOffset and li.numSpellBookItems then
      for i = li.itemIndexOffset + 1, li.itemIndexOffset + li.numSpellBookItems do
        local item = Try(C_SpellBook.GetSpellBookItemInfo, i, bank)
        if type(item) == "table" and item.spellID then
          local isSpell = (spellType == nil) or (item.itemType == spellType)
          if isSpell and not item.isPassive then
            add(item.spellID, "baseline", { skillLine = li.name })
            count = count + 1
          end
        end
      end
    end
  end
  return count
end

--============================================================================
--  Merge captured auras onto the ability list
--============================================================================
local function AttachAuras(db, list)
  for _, e in ipairs(list) do
    local caps = db.capturedAuras[e.spellID]
    if caps then
      local buffs, debuffs = {}, {}
      for auraSpellID, meta in pairs(caps) do
        if meta.harmful then
          debuffs[#debuffs + 1] = auraSpellID
        else
          buffs[#buffs + 1] = auraSpellID
        end
      end
      table.sort(buffs); table.sort(debuffs)
      e.buffIDs   = #buffs   > 0 and buffs   or nil
      e.debuffIDs = #debuffs > 0 and debuffs or nil
    end
  end
end

--============================================================================
--  EXPORT: snapshot current spec
--============================================================================
local function DoExport()
  if InCombatLockdown() then
    Print("|cffff5555Please leave combat first|r, then run /ccx export.")
    return
  end
  local db = EnsureDB()

  local _, classToken, classID = UnitClass("player")
  local specIndex = Try(GetSpecialization)
  local specID    = specIndex and Try(GetSpecializationInfo, specIndex)
  local specName  = specID and select(2, GetSpecializationInfoByID(specID)) or "Unknown"
  local role      = specID and select(5, GetSpecializationInfoByID(specID)) or nil

  if not classToken or not specID then
    Print("|cffff5555Could not read class/spec|r -- are you on a max-ish level character with a spec chosen?")
    return
  end

  local list, add = NewCollector()
  local nTal  = CollectTalents(add)
  local nPvP  = CollectPvP(add)
  local nBase = CollectSpellbook(add)
  AttachAuras(db, list)

  db.classes[classToken] = db.classes[classToken] or {}
  db.classes[classToken][specID] = {
    specName  = specName,
    role      = role,
    classID   = classID,
    exportedAt= time(),
    abilities = list,
  }

  db.meta.lastExport  = time()
  db.meta.build       = select(2, GetBuildInfo())     -- TOC/build number
  db.meta.version     = (GetBuildInfo())              -- e.g. "12.0.7"
  db.meta.exporterVer = VERSION

  -- Charge-recharge diagnostic. cooldownDuration can read 0 while a spell sits at
  -- full charges, so report coverage here instead of finding out 13 classes later.
  local nCharge, nRecharge = 0, 0
  for _, e in ipairs(list) do
    if e.charges then
      nCharge = nCharge + 1
      if e.rechargeMS then nRecharge = nRecharge + 1 end
    end
  end
  db.meta.chargeSpells   = nCharge
  db.meta.chargeRecharge = nRecharge

  local nOverride = 0
  for _, e in ipairs(list) do
    if e.overrideSpellID then nOverride = nOverride + 1 end
  end
  db.meta.overrides = nOverride

  Print(("Exported |cff00ff00%s / %s|r  ->  %d abilities  (talents %d, pvp %d, baseline %d)")
    :format(classToken, specName, #list, nTal, nPvP, nBase))
  if nOverride > 0 then
    Print(("talent overrides (renamed abilities): |cff00ff00%d|r in this build"):format(nOverride))
  end
  if nCharge > 0 then
    local colour = (nRecharge == nCharge) and "|cff00ff00" or "|cffff9900"
    Print(("charge abilities: %s%d/%d|r captured a true recharge time%s")
      :format(colour, nRecharge, nCharge,
              (nRecharge < nCharge) and " -- re-run once they are off cooldown" or ""))
  end
  Print("Saved to |cffffff00CCXMapDB|r. It writes to disk on |cffffff00/reload|r or logout.")
end

--============================================================================
--  WATCH: live buff/debuff capture
--============================================================================
local watcher = CreateFrame("Frame")
local recentCasts = {}       -- array of {spellID, t}
local WATCH_WINDOW = 1.5     -- seconds a cast stays "responsible" for new auras
local watching = false

local function PruneCasts(now)
  for i = #recentCasts, 1, -1 do
    if now - recentCasts[i].t > WATCH_WINDOW then
      table.remove(recentCasts, i)
    end
  end
end

local function RecordAura(auraSpellID, isHarmful, unit, duration)
  if not CanRead(auraSpellID) then return end        -- secret -> can't record the ID
  if type(auraSpellID) ~= "number" then return end
  local now = GetTime()
  PruneCasts(now)
  local db = EnsureDB()
  -- Attribute the aura to the most recent cast in the window.
  local cast = recentCasts[#recentCasts]
  if not cast then return end
  local bucket = db.capturedAuras[cast.spellID]
  if not bucket then bucket = {}; db.capturedAuras[cast.spellID] = bucket end

  -- unit + duration are what a 12.1 AuraContainer needs to be configured:
  -- which unit to watch, and how long the aura nominally lasts.
  local durationMS
  if duration ~= nil and CanRead(duration) and type(duration) == "number" and duration > 0 then
    durationMS = math.floor(duration * 1000 + 0.5)
  end
  local prev = bucket[auraSpellID]
  bucket[auraSpellID] = {
    harmful    = isHarmful and true or false,
    unit       = unit,
    durationMS = durationMS or (prev and prev.durationMS) or nil,
    seen       = ((prev and prev.seen) or 0) + 1,   -- repeat sightings = better attribution
  }
end

watcher:SetScript("OnEvent", function(_, event, ...)
  if event == "UNIT_SPELLCAST_SUCCEEDED" then
    local unit, _, spellID = ...
    if unit == "player" and type(spellID) == "number" then
      recentCasts[#recentCasts + 1] = { spellID = spellID, t = GetTime() }
      if #recentCasts > 8 then table.remove(recentCasts, 1) end
    end
  elseif event == "UNIT_AURA" then
    local unit, updateInfo = ...
    if not (unit == "player" or unit == "target") then return end
    if type(updateInfo) == "table" and updateInfo.addedAuras then
      for _, aura in ipairs(updateInfo.addedAuras) do
        -- isHelpful / isHarmful are NOT secret (un-secreted in 12.0.5).
        -- duration IS secret in combat, so it is guarded inside RecordAura and
        -- simply comes back nil there -- capture self-buffs out of combat.
        RecordAura(aura.spellId or aura.spellID, aura.isHarmful, unit, aura.duration)
      end
    end
  end
end)

local function ToggleWatch()
  watching = not watching
  if watching then
    watcher:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    watcher:RegisterUnitEvent("UNIT_AURA", "player", "target")
    Print("|cff00ff00Aura capture ON|r. Cast each ability on a dummy / on yourself, then /ccx export.")
    Print("Tip: many auras can only be read |cffffff00out of combat|r under 12.x -- cast self-buffs before pulling, and capture target debuffs on a dummy between hits where possible.")
  else
    watcher:UnregisterAllEvents()
    Print("Aura capture |cffff5555OFF|r.")
  end
end

--============================================================================
--  SHOW: paste-able copy box
--============================================================================
local copyFrame
local function BuildSummary()
  local db = EnsureDB()
  local out = {}
  out[#out+1] = "-- ClassCodexExporter dump  build=" .. tostring(db.meta.version)
  for classToken, specs in pairs(db.classes) do
    for specID, data in pairs(specs) do
      out[#out+1] = ("## %s / %s (specID %d) -- %d abilities")
        :format(classToken, data.specName or "?", specID, #data.abilities)
      for _, e in ipairs(data.abilities) do
        out[#out+1] = ("%d\t%s\t%s\tcd=%s\tch=%s\tbuff=%s\tdebuff=%s")
          :format(
            e.spellID, e.name or "?", e.source or "?",
            tostring(e.cooldownMS), tostring(e.charges),
            e.buffIDs   and table.concat(e.buffIDs, ",")   or "-",
            e.debuffIDs and table.concat(e.debuffIDs, ",") or "-")
      end
    end
  end
  return table.concat(out, "\n")
end

local function ShowCopy()
  if not copyFrame then
    copyFrame = CreateFrame("Frame", "ClassCodexExporterCopy", UIParent, "BackdropTemplate")
    copyFrame:SetSize(560, 420)
    copyFrame:SetPoint("CENTER")
    copyFrame:SetFrameStrata("DIALOG")
    copyFrame:SetMovable(true); copyFrame:EnableMouse(true)
    copyFrame:RegisterForDrag("LeftButton")
    copyFrame:SetScript("OnDragStart", copyFrame.StartMoving)
    copyFrame:SetScript("OnDragStop", copyFrame.StopMovingOrSizing)
    if copyFrame.SetBackdrop then
      copyFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
      })
    end
    local title = copyFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOP", 0, -10); title:SetText("ClassCodex Exporter -- Ctrl+A, Ctrl+C")
    local close = CreateFrame("Button", nil, copyFrame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)
    local scroll = CreateFrame("ScrollFrame", nil, copyFrame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, -40); scroll:SetPoint("BOTTOMRIGHT", -32, 14)
    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true); edit:SetFontObject(ChatFontNormal)
    edit:SetWidth(500); edit:SetAutoFocus(false)
    edit:SetScript("OnEscapePressed", function() copyFrame:Hide() end)
    scroll:SetScrollChild(edit)
    copyFrame.edit = edit
  end
  copyFrame.edit:SetText(BuildSummary())
  copyFrame.edit:HighlightText()
  copyFrame:Show()
end

--============================================================================
--  STATUS
--============================================================================
local function DoStatus()
  local db = EnsureDB()
  local nClasses, nSpecs, nAuras = 0, 0, 0
  for _ in pairs(db.classes) do nClasses = nClasses + 1 end
  for _, specs in pairs(db.classes) do for _ in pairs(specs) do nSpecs = nSpecs + 1 end end
  for _ in pairs(db.capturedAuras) do nAuras = nAuras + 1 end
  Print(("Captured: %d classes, %d specs, aura-map for %d cast spells. Build %s.")
    :format(nClasses, nSpecs, nAuras, tostring(db.meta.version)))
end

--============================================================================
--  Slash handler
--============================================================================
SLASH_CCX1 = "/ccx"
SLASH_CCX2 = "/classcodexexport"
SlashCmdList["CCX"] = function(msg)
  msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if msg == "export" or msg == "" then
    DoExport()
  elseif msg == "watch" then
    ToggleWatch()
  elseif msg == "show" then
    ShowCopy()
  elseif msg == "status" then
    DoStatus()
  elseif msg == "clear" then
    CCXMapDB = nil
    EnsureDB()
    Print("Database cleared.")
  else
    Print("commands: |cffffff00export|r (current spec), |cffffff00watch|r (aura capture on/off), |cffffff00show|r (copy box), |cffffff00status|r, |cffffff00clear|r")
  end
end

--============================================================================
--  Auto-export: capture the current spec automatically on every reload/login,
--  so the workflow is just "switch spec -> /reload". No slash command needed.
--============================================================================
local booted = false
local function SafeAutoExport()
  -- pcall so a runtime error (caught silently by BugSack) is RECORDED in the DB
  -- instead of vanishing. We can then read db.meta.autoError to diagnose.
  local db = EnsureDB()
  db.meta.autoRuns = (db.meta.autoRuns or 0) + 1
  local ok, err = pcall(DoExport)
  if ok then
    db.meta.autoError = nil
    db.meta.autoOK = time()
  else
    db.meta.autoError = tostring(err)
    Print("|cffff5555auto-capture error:|r " .. tostring(err))
  end
end

local function AutoExport()
  if InCombatLockdown() then
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_REGEN_ENABLED")
    f:SetScript("OnEvent", function(self)
      self:UnregisterAllEvents()
      SafeAutoExport()
    end)
    Print("in combat -- will auto-capture the moment you leave combat.")
    return
  end
  SafeAutoExport()
end

-- Capture on initial world-enter AND on every spec change. This does NOT depend
-- on /reload re-executing the addon (on some setups it doesn't) -- switching
-- spec fires PLAYER_SPECIALIZATION_CHANGED and captures the new spec on the spot.
-- One /reload (or logout) afterwards flushes everything to disk.
local function ScheduleCapture(label, delay)
  Try(C_Timer and C_Timer.After, delay or 1.0, function()
    Print("|cff00ff00CCXMap v" .. VERSION .. "|r capturing current spec (" .. label .. ")...")
    AutoExport()
  end)
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:RegisterEvent("PLAYER_ENTERING_WORLD")
boot:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
boot:SetScript("OnEvent", function(self, event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 ~= ADDON then return end
    local db = EnsureDB()
    db.meta.loadedVersion = VERSION
    db.meta.loadCount = (db.meta.loadCount or 0) + 1
    db.meta.lastLoad = time()
    return
  elseif event == "PLAYER_ENTERING_WORLD" then
    EnsureDB()
    if not booted then
      booted = true
      ScheduleCapture("login", 1.0)
    end
  elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
    ScheduleCapture("spec-change", 1.5)
  end
end)
