--[[--------------------------------------------------------------------------
  CCXSweep -- cross-class talent tree sweep
  --------------------------------------------------------------------------
  Captures the class / spec / hero talent trees for ALL 13 classes from a single
  logged-in character, without needing an alt of each class.

  How: C_ClassTalents.InitializeViewLoadout(specID, level) + ViewLoadout({}) puts
  a *viewed* loadout into Constants.TraitConsts.VIEW_TRAIT_CONFIG_ID. Every
  downstream C_Traits call then works exactly as it does for your own spec. This
  is the same mechanism Blizzard's talent-link inspect UI uses, and what
  LibTalentTree-1.0 is built on.

  The viewed LEVEL is a parameter, so a level-10 character can read a max-level
  tree -- hero talents included.

  Two-phase, because spell data is loaded lazily:
    Phase 1  sweep every class/spec, collect spellIDs + node structure
    Phase 2  RequestLoadSpellData for anything whose description came back empty,
             wait for SPELL_DATA_LOAD_RESULT, then re-read

  An empty description does NOT mean "no data" -- it means "not loaded yet".
  Treating it as absent is what left holes in earlier captures.

  Usage:
     /ccx sweep        -> run the full cross-class sweep (out of combat)
     /ccx sweepstatus  -> progress / what landed

  CAUTION: InitializeViewLoadout clobbers the config Blizzard's inspect UI uses.
  Run the sweep once, deliberately, not on a timer.
----------------------------------------------------------------------------]]

local ADDON, ns = ...

local C_Traits             = C_Traits
local C_ClassTalents       = C_ClassTalents
local C_Spell              = C_Spell
local C_SpecializationInfo = C_SpecializationInfo

local PREFIX = "|cff00ccffCCX|r|cffffffffSweep|r: "
local function Print(msg) print(PREFIX .. tostring(msg)) end

local function Try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, a, b, c = pcall(fn, ...)
  if ok then return a, b, c end
  return nil
end

local function CanRead(v)
  if issecretvalue and issecretvalue(v) then return false end
  if canaccessvalue and not canaccessvalue(v) then return false end
  return true
end

--============================================================================
--  Feature detection -- fail loudly rather than half-working
--============================================================================
local function SweepSupported()
  return C_ClassTalents
     and type(C_ClassTalents.InitializeViewLoadout) == "function"
     and type(C_ClassTalents.ViewLoadout) == "function"
     and Constants and Constants.TraitConsts
     and Constants.TraitConsts.VIEW_TRAIT_CONFIG_ID ~= nil
end

--============================================================================
--  Spell-data load queue (phase 2)
--============================================================================
local pending, pendingCount = {}, 0
local loader = CreateFrame("Frame")

local function QueueSpellLoad(spellID)
  if pending[spellID] then return end
  if type(C_Spell.RequestLoadSpellData) ~= "function" then return end
  pending[spellID] = true
  pendingCount = pendingCount + 1
  C_Spell.RequestLoadSpellData(spellID)
end

--============================================================================
--  Read one spell's static data
--============================================================================
local function ReadSpell(spellID)
  local info = Try(C_Spell.GetSpellInfo, spellID)
  local name = type(info) == "table" and info.name or nil

  local desc = Try(C_Spell.GetSpellDescription, spellID)
  if type(desc) ~= "string" or not CanRead(desc) then desc = nil end
  -- "" means the client has not loaded this spell yet -- queue it, don't record it.
  if desc == "" then desc = nil; QueueSpellLoad(spellID) end
  if not name then QueueSpellLoad(spellID) end

  local baseMS, gcdMS = Try(GetSpellBaseCooldown, spellID)
  local charges, rechargeMS
  local ch = Try(C_Spell.GetSpellCharges, spellID)
  if type(ch) == "table" and ch.maxCharges ~= nil and CanRead(ch.maxCharges) then
    charges = ch.maxCharges
    local d = ch.cooldownDuration
    if type(d) == "number" and d > 0 and CanRead(d) then
      rechargeMS = math.floor(d * 1000 + 0.5)
    end
  end

  local override
  local getOverride = C_Spell.GetOverrideSpell or FindSpellOverrideByID
  local o = Try(getOverride, spellID)
  if type(o) == "number" and o ~= spellID and CanRead(o) then override = o end

  local passive = Try(C_Spell.IsSpellPassive, spellID)

  return {
    spellID     = spellID,
    name        = name,
    description = desc and (desc:gsub("[\r\n]+", " ")) or nil,
    cooldownMS  = baseMS and math.floor(baseMS) or nil,
    gcdMS       = gcdMS and math.floor(gcdMS) or nil,
    charges     = charges,
    rechargeMS  = rechargeMS,
    overrideSpellID = override,
    passive     = passive and true or false,
  }
end

--============================================================================
--  Sweep one spec via the viewed loadout
--============================================================================
local function SweepSpec(classToken, classID, specID, specName, level, out)
  Try(C_ClassTalents.InitializeViewLoadout, specID, level)
  Try(C_ClassTalents.ViewLoadout, {})

  local configID = Constants.TraitConsts.VIEW_TRAIT_CONFIG_ID
  local configInfo = Try(C_Traits.GetConfigInfo, configID)
  if type(configInfo) ~= "table" or not configInfo.treeIDs then
    return 0, "no config"
  end

  local list, seen = {}, {}
  for _, treeID in ipairs(configInfo.treeIDs) do
    local nodes = Try(C_Traits.GetTreeNodes, treeID) or {}
    for _, nodeID in ipairs(nodes) do
      local nodeInfo = Try(C_Traits.GetNodeInfo, configID, nodeID)
      if type(nodeInfo) == "table" and nodeInfo.entryIDs then
        local heroName
        if nodeInfo.subTreeID then
          local st = Try(C_Traits.GetSubTreeInfo, configID, nodeInfo.subTreeID)
          if type(st) == "table" then heroName = st.name end
        end
        for _, entryID in ipairs(nodeInfo.entryIDs) do
          local entryInfo = Try(C_Traits.GetEntryInfo, configID, entryID)
          local defID = type(entryInfo) == "table" and entryInfo.definitionID
          if defID then
            local def = Try(C_Traits.GetDefinitionInfo, defID)
            local spellID = type(def) == "table" and def.spellID
            if spellID and not seen[spellID] then
              seen[spellID] = true
              local e = ReadSpell(spellID)
              e.source   = heroName and "hero" or "talent"
              e.nodeID   = nodeID
              e.treeID   = treeID
              e.heroTree = heroName
              e.isChoice = (#nodeInfo.entryIDs > 1) or nil
              list[#list + 1] = e
            end
          end
        end
      end
    end
  end

  out[specID] = { specName = specName, classID = classID, abilities = list }
  return #list
end

--============================================================================
--  Full sweep, throttled one spec per frame-ish so we don't hitch
--============================================================================
local sweeping = false

local function RunSweep()
  if InCombatLockdown() then
    Print("|cffff5555leave combat first|r.")
    return
  end
  if not SweepSupported() then
    Print("|cffff5555InitializeViewLoadout / VIEW_TRAIT_CONFIG_ID unavailable|r -- "
       .. "this build does not support the cross-class sweep.")
    return
  end
  if sweeping then Print("already running."); return end
  sweeping = true

  local db = CCXMapDB or {}
  CCXMapDB = db
  db.sweep = {}
  db.meta  = db.meta or {}

  -- View at max level so hero talents (unlock ~71) are present regardless of
  -- the logged-in character's own level.
  local level = (MAX_PLAYER_LEVEL_TABLE and MAX_PLAYER_LEVEL_TABLE[LE_EXPANSION_LEVEL_CURRENT])
             or GetMaxPlayerLevel and GetMaxPlayerLevel() or 80

  -- Build the work list first: every (class, spec) pair.
  local work = {}
  local numClasses = GetNumClasses and GetNumClasses() or 13
  for classID = 1, numClasses do
    local className, classToken = GetClassInfo(classID)
    if classToken then
      local numSpecs = Try(C_SpecializationInfo.GetNumSpecializationsForClassID, classID)
                       or Try(GetNumSpecializationsForClassID, classID) or 0
      for specIndex = 1, numSpecs do
        local specID, specName = Try(GetSpecializationInfoForClassID, classID, specIndex)
        if specID then
          work[#work + 1] = { classID = classID, classToken = classToken,
                              specID = specID, specName = specName }
        end
      end
    end
  end

  Print(("sweeping |cffffff00%d|r class/spec combinations at level %d..."):format(#work, level))

  local i, totalSpells = 0, 0
  local function step()
    i = i + 1
    local w = work[i]
    if not w then
      db.meta.sweepAt      = time()
      db.meta.sweepSpecs   = #work
      db.meta.sweepSpells  = totalSpells
      db.meta.sweepVersion = "2.0.1"
      db.meta.sweepPending = pendingCount
      sweeping = false
      Print(("sweep complete: |cff00ff00%d|r specs, |cff00ff00%d|r spells.")
        :format(#work, totalSpells))
      if pendingCount > 0 then
        Print(("|cffff9900%d spells had unloaded data|r -- waiting for the client, "
            .. "then run |cffffff00/ccx sweepfill|r."):format(pendingCount))
      else
        Print("all descriptions resolved. |cffffff00/reload|r to write to disk.")
      end
      return
    end
    db.sweep[w.classToken] = db.sweep[w.classToken] or {}
    local n = SweepSpec(w.classToken, w.classID, w.specID, w.specName, level,
                        db.sweep[w.classToken])
    totalSpells = totalSpells + (n or 0)
    if i % 5 == 0 then
      Print(("  ...%d/%d (%s %s)"):format(i, #work, w.classToken, w.specName or "?"))
    end
    C_Timer.After(0.05, step)   -- throttle: a tree walk per tick, not all at once
  end
  step()
end

--============================================================================
--  Phase 2: re-read anything that was not loaded the first time
--============================================================================
-- Some spells legitimately have NO description in Blizzard's data at all -- talent
-- nodes backed by hidden implementation passives (flagged "Passive, Hidden" in the
-- client data, e.g. Mage's Imbued Warding 431066). Those can never resolve, so we
-- track attempts per spell and stop asking after RETRY_LIMIT rounds instead of
-- looping forever.
local RETRY_LIMIT = 3
local attempts = {}

local function FillPending()
  local db = CCXMapDB
  if not db or not db.sweep then Print("no sweep data -- run /ccx sweep first."); return end

  local filled = 0
  local unresolved, exhausted = {}, {}   -- keyed by spellID: count UNIQUE spells, not rows

  for classToken, specs in pairs(db.sweep) do
    for specID, data in pairs(specs) do
      for _, e in ipairs(data.abilities) do
        if not e.description or not e.name then
          local sid = e.spellID
          if not unresolved[sid] and not exhausted[sid] then
            attempts[sid] = (attempts[sid] or 0) + 1
          end
          local fresh = ReadSpell(sid)
          if fresh.description and not e.description then
            e.description = fresh.description; filled = filled + 1
          end
          if fresh.name and not e.name then e.name = fresh.name end
          if not e.description then
            if (attempts[sid] or 0) >= RETRY_LIMIT then
              exhausted[sid] = (e.name or "?")
            else
              unresolved[sid] = true
            end
          end
        end
      end
    end
  end

  local nUnresolved, nExhausted = 0, 0
  for _ in pairs(unresolved) do nUnresolved = nUnresolved + 1 end
  for _ in pairs(exhausted)  do nExhausted  = nExhausted  + 1 end

  db.meta.sweepPending = nUnresolved
  db.meta.sweepNoDesc  = nExhausted

  Print(("filled |cff00ff00%d|r descriptions."):format(filled))
  if nUnresolved > 0 then
    Print(("|cffff9900%d spell(s)|r still loading -- run |cffffff00/ccx sweepfill|r again.")
      :format(nUnresolved))
  end
  if nExhausted > 0 then
    Print(("|cff888888%d spell(s) have no description in the game data|r "
        .. "(hidden implementation passives) -- this is expected, not an error:")
      :format(nExhausted))
    for sid, nm in pairs(exhausted) do
      Print(("   |cff888888%s (%d)|r"):format(nm, sid))
    end
  end
  if nUnresolved == 0 then
    Print("nothing left to load. |cffffff00/reload|r to write to disk.")
  end
end

-- When the client finishes loading a spell we asked for, drop it from the queue.
loader:RegisterEvent("SPELL_DATA_LOAD_RESULT")
loader:SetScript("OnEvent", function(_, _, spellID, success)
  if pending[spellID] then
    pending[spellID] = nil
    pendingCount = math.max(0, pendingCount - 1)
  end
end)

--============================================================================
--  Status
--============================================================================
local function SweepStatus()
  local db = CCXMapDB
  if not db or not db.sweep then Print("no sweep data yet."); return end
  local classes, specs, spells, noDesc = 0, 0, 0, 0
  for _, sp in pairs(db.sweep) do
    classes = classes + 1
    for _, data in pairs(sp) do
      specs = specs + 1
      for _, e in ipairs(data.abilities) do
        spells = spells + 1
        if not e.description then noDesc = noDesc + 1 end
      end
    end
  end
  Print(("sweep: |cff00ff00%d|r classes, %d specs, %d spells, |cffff9900%d|r missing descriptions.")
    :format(classes, specs, spells, noDesc))
end

--============================================================================
--  Hook into the existing /ccx handler
--============================================================================
ns.RunSweep     = RunSweep
ns.FillPending  = FillPending
ns.SweepStatus  = SweepStatus

local prev = SlashCmdList["CCX"]
SlashCmdList["CCX"] = function(msg)
  local m = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if m == "sweep" then return RunSweep() end
  if m == "sweepfill" then return FillPending() end
  if m == "sweepstatus" then return SweepStatus() end
  return prev(msg)
end
