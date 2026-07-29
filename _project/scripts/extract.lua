-- CCXMap SavedVariables -> TSV.  Expects ccxmap.lua alongside (the copied SV file).
--
--   lua extract.lua WARRIOR > warrior_full.tsv
--
-- Two data sources, merged:
--   db.classes[TOKEN]  the character's OWN specs -- richest (PvP talents, baseline
--                      spellbook, live overrides), but only for classes you play.
--   db.sweep[TOKEN]    the cross-class /ccx sweep -- talent trees for all 13 classes
--                      from one character. No PvP talents, no baseline spellbook.
--
-- Own-spec data wins on conflict; sweep fills everything else in.
--
-- rechargeMS is the TRUE cooldown for charge abilities; cooldownMS is the
-- inter-charge lockout there and must not be used for them.
-- overrideSpellID = the spell this one is RENAMED INTO by the active talent build.

dofile("ccxmap.lua")
local db = CCXMapDB
local CLASS = (...) or "WARRIOR"

local rows, seen = {}, {}

local function emit(specID, specName, a, origin)
  local key = tostring(specID) .. ":" .. tostring(a.spellID)
  if seen[key] then return end
  seen[key] = true
  rows[#rows + 1] = {
    specID, specName or "?", a.source or "?", a.spellID or "?",
    (a.name or "?"):gsub("[\t\n]", " "),
    tostring(a.passive), tostring(a.selected or ""), tostring(a.charges or ""),
    tostring(a.cooldownMS or ""), tostring(a.rechargeMS or ""),
    tostring(a.overrideSpellID or ""),
    (tostring(a.description or ""):gsub("[\t\n]", " ")),
    origin,
  }
end

-- 1) own-spec capture (preferred -- richer)
if db.classes and db.classes[CLASS] then
  for specID, data in pairs(db.classes[CLASS]) do
    for _, a in ipairs(data.abilities) do
      emit(specID, data.specName, a, "own")
    end
  end
end

-- 2) cross-class sweep (fills the gaps)
if db.sweep and db.sweep[CLASS] then
  for specID, data in pairs(db.sweep[CLASS]) do
    for _, a in ipairs(data.abilities) do
      emit(specID, data.specName, a, "sweep")
    end
  end
end

if #rows == 0 then
  io.stderr:write("no data for class " .. CLASS ..
    " -- run /ccx export (own class) or /ccx sweep (any class)\n")
  os.exit(1)
end

io.write("specID\tspecName\tsource\tspellID\tname\tpassive\tselected\tcharges\t"
      .. "cooldownMS\trechargeMS\toverrideSpellID\tdescription\torigin\n")
for _, r in ipairs(rows) do
  io.write(table.concat(r, "\t") .. "\n")
end
