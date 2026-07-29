--[[--------------------------------------------------------------------------
  AbilityMap -- shared ability -> buff/debuff data library
  --------------------------------------------------------------------------
  A read-only dataset any addon can consume. Every entry was captured from a
  live client (WoW 12.0.7 / build 68453) rather than guessed, and each aura ID
  is individually verified -- an ability's aura is very often a DIFFERENT spell
  ID than the cast (Shield Block 2565 -> buff 132404).

  USAGE from another addon:

     ## OptionalDeps: AbilityMap        <- in your .toc

     local AM = _G.AbilityMap
     if AM then
       local e = AM:Get(2565)                  -- by spell ID, any class
       print(e.name, e.cd, AM:GetBuff(2565))   -- "Shield Block", 16, 132404

       for spellID, entry in AM:Iterate("WARRIOR") do ... end

       local kit = AM:GetGroup("WARRIOR", "Demolish")  -- ability + its modifiers
     end

  This library holds STATIC reference data only. It reads no combat state and
  no secret values, so it is safe to query at any time under the 12.x rules --
  including in combat, where live aura APIs go secret.
----------------------------------------------------------------------------]]

local ADDON, ns = ...
ns.data = ns.data or {}

local AbilityMap = {}
_G.AbilityMap = AbilityMap

AbilityMap.VERSION = "1.0.0"
AbilityMap.BUILD   = "12.0.7 (68453)"

-- Normalize "warrior" / "Warrior" / "WARRIOR" to the class token.
local function tok(class)
  if type(class) ~= "string" then return nil end
  return (class:upper():gsub("%s+", ""))
end

--- List the class tokens currently bundled.
-- @return array of class tokens, e.g. { "WARRIOR" }
function AbilityMap:GetClasses()
  local out = {}
  for token in pairs(ns.data) do out[#out + 1] = token end
  table.sort(out)
  return out
end

--- True if data for this class is loaded.
function AbilityMap:HasClass(class)
  return ns.data[tok(class)] ~= nil
end

--- Raw class table: { class, build, abilities, order, groups }.
function AbilityMap:GetClass(class)
  return ns.data[tok(class)]
end

--- The player's own class data, or nil.
function AbilityMap:GetPlayerClass()
  local _, classToken = UnitClass("player")
  return classToken and ns.data[classToken] or nil
end

--- Look up one ability by spell ID.
-- Searches the given class if supplied, otherwise every loaded class.
-- Also resolves alternate (spec/rank variant) IDs to their primary entry.
-- @return entry table, class token
function AbilityMap:Get(spellID, class)
  if type(spellID) ~= "number" then return nil end
  local search = class and { [tok(class)] = ns.data[tok(class)] } or ns.data
  for token, cdata in pairs(search) do
    if cdata and cdata.abilities then
      local e = cdata.abilities[spellID]
      if e then return e, token end
    end
  end
  -- fall back to alternate IDs (e.g. Execute 163201 -> primary 5308)
  for token, cdata in pairs(search) do
    if cdata and cdata.abilities then
      for primaryID, e in pairs(cdata.abilities) do
        if e.alt then
          for _, altID in ipairs(e.alt) do
            if altID == spellID then return e, token end
          end
        end
      end
    end
  end
  return nil
end

--- Buff aura ID an ability applies, or nil.
function AbilityMap:GetBuff(spellID, class)
  local e = self:Get(spellID, class)
  return e and e.buff or nil
end

--- Debuff aura ID an ability applies, or nil.
function AbilityMap:GetDebuff(spellID, class)
  local e = self:Get(spellID, class)
  return e and e.debuff or nil
end

--- Both auras at once.
-- @return buffID, debuffID
function AbilityMap:GetAuras(spellID, class)
  local e = self:Get(spellID, class)
  if not e then return nil, nil end
  return e.buff, e.debuff
end

--- Base cooldown in seconds (nil when the ability has none).
function AbilityMap:GetCooldown(spellID, class)
  local e = self:Get(spellID, class)
  return e and e.cd or nil
end

--- Every row in one ability group -- the ability plus the talents that modify
--- it (e.g. "Demolish" -> Demolish, Colossal Might, Decimator, ...).
-- @return array of entries, in sheet order
function AbilityMap:GetGroup(class, groupName)
  local cdata = ns.data[tok(class)]
  if not cdata then return {} end
  local out = {}
  for _, spellID in ipairs(cdata.order or {}) do
    local e = cdata.abilities[spellID]
    if e and e.group == groupName then
      out[#out + 1] = e
    end
  end
  return out
end

--- Names of every ability group for a class, in sheet order.
function AbilityMap:GetGroups(class)
  local cdata = ns.data[tok(class)]
  return cdata and cdata.groups or {}
end

--- Iterator over a class's abilities in sheet order.
-- for spellID, entry in AbilityMap:Iterate("WARRIOR") do ... end
function AbilityMap:Iterate(class)
  local cdata = ns.data[tok(class)]
  if not cdata then return function() return nil end end
  local order, i = cdata.order or {}, 0
  return function()
    i = i + 1
    local spellID = order[i]
    if not spellID then return nil end
    return spellID, cdata.abilities[spellID]
  end
end

--============================================================================
--  Lifecycle API -- built for cooldown-manager slots (Kairos)
--============================================================================
--
--  A "lifecycle" slot shows an ability's buff while it is up, then falls back to
--  the cooldown once it drops. Under 12.1 you must NOT implement that by asking
--  "is the buff up?" -- aura reads are secret in combat and AuraButton:IsShown()
--  is deliberately secret to block exactly that branch.
--
--  Build it by LAYERING instead, and let the engine decide what is visible:
--
--      slot            (plain frame, never fed a secret)
--       |- cooldown    (your Cooldown frame, drawn underneath)
--       |- auraButton  (AuraButton in an AuraContainer, drawn on top)
--
--  The container shows/hides the button itself, so the buff covers the cooldown
--  while active and reveals it when it drops. No branch, no secret read.
--
--  Anchor both to `slot` -- never anchor the cooldown TO the aura button. Secret
--  anchors propagate to anchored children and size/position queries then error.
--
--  This function supplies what you need to CONFIGURE that container.

--- Everything a lifecycle slot needs for one ability.
-- @return table or nil:
--    spellID    the ability you cast
--    auraID     the aura to track (nil if this ability applies none)
--    auraKind   "buff" | "debuff"
--    auraUnit   "player" | "target" -- which unit the container watches
--    duration   base aura duration in seconds, when known
--    cd         base cooldown in seconds
--    charges    max charges, when charge-based
--    override   spellID this ability is RENAMED INTO by the active talent build
--    modifiers  passives that alter this slot's TIMING (duration/cooldown/charges)
--    verified   true when the aura ID was hand-checked rather than auto-captured
function AbilityMap:GetLifecycle(spellID, class)
  local e, token = self:Get(spellID, class)
  if not e then return nil end

  local mods = {}
  for _, m in ipairs(self:GetGroup(token, e.group)) do
    if m.affects and m.spellID ~= e.spellID then
      for _, tag in ipairs(m.affects) do
        if tag == "duration" or tag == "cooldown" or tag == "charges" then
          mods[#mods + 1] = m
          break
        end
      end
    end
  end

  return {
    spellID   = e.spellID,
    name      = e.name,
    auraID    = e.aura and e.aura.id or nil,
    auraKind  = e.aura and e.aura.kind or nil,
    auraUnit  = e.aura and e.aura.unit or nil,
    duration  = e.aura and e.aura.duration or nil,
    cd        = e.cd,
    charges   = e.charges,
    override  = e.override,
    modifiers = mods,
    verified  = (e.conf == "Verified"),
  }
end

--- Every ability of a class that has a buff/debuff worth a lifecycle slot.
-- @param unitFilter optional "player" or "target" to get just one container's worth
function AbilityMap:GetLifecycleAbilities(class, unitFilter)
  local out = {}
  for _, e in self:Iterate(class) do
    if e.aura and e.kind_type == "Active" then
      if not unitFilter or e.aura.unit == unitFilter then
        out[#out + 1] = self:GetLifecycle(e.spellID, class)
      end
    end
  end
  return out
end

--- Follow a talent rename chain to the spell actually cast in this build.
--- Thunder Clap -> Thunder Blast, Slam -> Heroic Strike, etc.
function AbilityMap:ResolveOverride(spellID, class)
  local seen = {}
  local cur = spellID
  while true do
    local e = self:Get(cur, class)
    if not e or not e.override or seen[cur] then return cur end
    seen[cur] = true
    cur = e.override
  end
end

--- Abilities still awaiting aura-ID verification ("NEEDS VERIFY").
--- Useful for driving the verification pass; empty once a class is finished.
function AbilityMap:GetUnverified(class)
  local out = {}
  for spellID, e in self:Iterate(class) do
    if e.triage == "NEEDS VERIFY" then out[#out + 1] = e end
  end
  return out
end

--- Coverage summary for a class.
-- @return total, verified, needsVerify, noAura
function AbilityMap:GetStats(class)
  local total, verified, needs, none = 0, 0, 0, 0
  for _, e in self:Iterate(class) do
    total = total + 1
    if e.buff or e.debuff then verified = verified + 1
    elseif e.triage == "NEEDS VERIFY" then needs = needs + 1
    elseif e.triage == "NO AURA" then none = none + 1 end
  end
  return total, verified, needs, none
end

--============================================================================
--  /abilitymap -- quick console check that the data loaded
--============================================================================
SLASH_ABILITYMAP1 = "/abilitymap"
SLASH_ABILITYMAP2 = "/amap"
SlashCmdList["ABILITYMAP"] = function(msg)
  local P = "|cff00ccffAbilityMap|r: "
  msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")

  if msg == "" then
    local classes = AbilityMap:GetClasses()
    print(P .. "v" .. AbilityMap.VERSION .. "  build " .. AbilityMap.BUILD)
    if #classes == 0 then
      print(P .. "|cffff5555no class data loaded|r")
      return
    end
    for _, c in ipairs(classes) do
      local t, v, n, x = AbilityMap:GetStats(c)
      print(("  %s: %d rows -- |cff00ff00%d verified|r, %d need aura ID, %d no aura")
        :format(c, t, v, n, x))
    end
    print(P .. "try |cffffff00/amap 2565|r or |cffffff00/amap Demolish|r")
    return
  end

  local spellID = tonumber(msg)
  if spellID then
    local e, token = AbilityMap:Get(spellID)
    if not e then print(P .. "no entry for spell " .. spellID); return end
    print(("%s|cffffff00%s|r (%s) -- %s"):format(P, e.name, token, e.kind_type or "?"))
    if e.cd then print("  cooldown: " .. e.cd .. "s") end
    if e.buff then print("  buff aura: |cff00ff00" .. e.buff .. "|r") end
    if e.debuff then print("  debuff aura: |cffff5555" .. e.debuff .. "|r") end
    if e.alt then print("  alt IDs: " .. table.concat(e.alt, ", ")) end
    if not e.buff and not e.debuff then
      print("  aura: " .. (e.triage == "NO AURA" and "none" or "|cffff9900not yet verified|r"))
    end
    if e.desc then print("  " .. e.desc) end
    return
  end

  -- treat as a group name on the player's class
  local _, classToken = UnitClass("player")
  local rows = AbilityMap:GetGroup(classToken, msg)
  if #rows == 0 then
    print(P .. "no ability group named '" .. msg .. "' for " .. tostring(classToken))
    return
  end
  print(P .. "|cffffff00" .. msg .. "|r (" .. #rows .. " rows)")
  for _, e in ipairs(rows) do
    local tag = (e.kind == "Ability") and "" or "   \226\134\179 "
    print(("  %s%s |cff888888(%d)|r"):format(tag, e.name, e.spellID or 0))
  end
end
