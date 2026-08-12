-- Offline smoke test: load AbilityMap outside WoW and exercise the public API.
local AM_DIR = ...
local ns = {}

-- minimal WoW stubs Core.lua touches at load time
_G.UnitClass = function() return "Warrior", "WARRIOR", 1 end
_G.SlashCmdList = {}

local function run(file)
  local chunk, err = loadfile(AM_DIR .. "/" .. file)
  if not chunk then error("PARSE FAIL " .. file .. ": " .. tostring(err)) end
  chunk("AbilityMap", ns)
  print("  parsed OK: " .. file)
end

print("=== loading ===")
run("Core.lua")
run("Data/Warrior.lua")

local AM = _G.AbilityMap
print("\n=== API ===")
print("GetClasses:", table.concat(AM:GetClasses(), ", "))
local total, ver, needs, none = AM:GetStats("WARRIOR")
print(("GetStats: total=%d verified=%d needsVerify=%d noAura=%d"):format(total, ver, needs, none))

print("\n-- Get(2565) Shield Block --")
local e = AM:Get(2565)
print(("  %s  spellID=%d  cd=%s  buff=%s  conf=%s"):format(e.name, e.spellID, tostring(e.cd), tostring(e.buff), e.conf))

print("\n-- alt-ID resolution: Get(163201) should resolve to Execute 5308 --")
local x = AM:Get(163201)
print(("  -> %s  primary=%d  alt={%s}"):format(x.name, x.spellID, table.concat(x.alt, ",")))

print("\n-- GetAuras(12294) Mortal Strike --")
local b, d = AM:GetAuras(12294)
print(("  buff=%s debuff=%s"):format(tostring(b), tostring(d)))

print("\n-- GetGroup('WARRIOR','Demolish') --")
for _, r in ipairs(AM:GetGroup("WARRIOR", "Demolish")) do
  print(("  %-12s %-26s %d"):format(r.kind, r.name, r.spellID))
end

print("\n-- GetUnverified: first 5 of " .. #AM:GetUnverified("WARRIOR") .. " --")
for i, r in ipairs(AM:GetUnverified("WARRIOR")) do
  if i > 5 then break end
  print(("  %-24s %d"):format(r.name, r.spellID))
end

print("\n-- Iterate order sanity (first 3) --")
local n = 0
for spellID, entry in AM:Iterate("WARRIOR") do
  n = n + 1
  if n <= 3 then print(("  %d -> %s"):format(spellID, entry.name)) end
end
print("  iterated " .. n .. " entries")

print("\n-- GetPlayerClass --")
print("  " .. AM:GetPlayerClass().class)

-- A floor, not an exact count: every legitimate re-capture changes the row total
-- (12.1 took Warrior 236 -> 263). This still catches the failure that matters,
-- which is the data collapsing to a handful of rows or none.
assert(total > 200, "row count collapsed -- expected 200+, got " .. tostring(total))
assert(x.spellID == 5308, "alt resolution failed")
assert(d == 213667, "Mortal Wounds debuff wrong")
assert(n == total, "iterator skipped rows")
print("\nALL ASSERTIONS PASSED")

print("\n=== LIFECYCLE API ===")
local lc = AM:GetLifecycle(2565)
print(("  Shield Block -> aura=%s kind=%s unit=%s cd=%s verified=%s")
  :format(tostring(lc.auraID), tostring(lc.auraKind), tostring(lc.auraUnit),
          tostring(lc.cd), tostring(lc.verified)))
print("  timing modifiers: " .. #lc.modifiers)
for _, m in ipairs(lc.modifiers) do
  print(("    %-26s (%d) affects=%s"):format(m.name, m.spellID, table.concat(m.affects, ",")))
end

local rend = AM:GetLifecycle(772)
print(("\n  Rend -> aura=%s kind=%s unit=%s"):format(
  tostring(rend.auraID), tostring(rend.auraKind), tostring(rend.auraUnit)))

local player = AM:GetLifecycleAbilities("WARRIOR", "player")
local target = AM:GetLifecycleAbilities("WARRIOR", "target")
print(("\n  lifecycle slots: %d player-buff, %d target-debuff"):format(#player, #target))
print("  player container would track:")
for _, l in ipairs(player) do
  print(("    %-22s cast=%-9d aura=%d"):format(l.name, l.spellID, l.auraID))
end

print("\n  ResolveOverride(2565) = " .. AM:ResolveOverride(2565))
assert(lc.auraID == 132404 and lc.auraUnit == "player", "Shield Block lifecycle wrong")
assert(rend.auraUnit == "target", "Rend should be target-side")
assert(#player > 0 and #target > 0, "expected both containers populated")
print("\nLIFECYCLE ASSERTIONS PASSED")
