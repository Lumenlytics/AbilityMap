-- luacheck config for AbilityMap.  Run from this repo root:  luacheck .
--
-- luac -p only proves a file PARSES.  luacheck checks whether it makes SENSE:
-- undefined globals (a mistyped or Midnight-renamed API), locals never assigned,
-- values overwritten before use.  Gleaner's first run found a shipped-and-
-- silently-dead code path nothing else in the toolchain could see.
--
-- Blizzard's API surface is shared in ../wow-globals.lua so ten copies cannot
-- drift.  Only AbilityMap's OWN globals live here.

local base
for _, p in ipairs({ "../wow-globals.lua", "../../wow-globals.lua", "wow-globals.lua" }) do
  local f = loadfile(p)
  if f then base = f(); break end
end

std = "lua51"                       -- WoW runs Lua 5.1
if base then
  stds.wow = { read_globals = base.read }
  std = "lua51+wow"
end
max_line_length = false
ignore = { "211/addonName", "212/self" }

globals = {}
if base then for _, g in ipairs(base.write) do globals[#globals + 1] = g end end
for _, g in ipairs({
    "CCXMapDB",
    "AbilityMap",
    "CCXMapDB",
    "SLASH_ABILITYMAP1",
    "SLASH_ABILITYMAP2",
    "SLASH_CCX1",
    "SLASH_CCX2",
    "SlashCmdList",
    "UnitClass",
}) do globals[#globals + 1] = g end

exclude_files = { "_project/", "Tests/" }
