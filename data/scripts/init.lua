-- Registry of hand-ported map scripts.  Map-specific behavior lives HERE,
-- never in engine classes (Critical Engineering Rule #9).
--
-- Each module returns { talk = { [TEXT_CONST] = script }, onEnter = fn,
-- onBoulderMoved = fn } where a script is a list of { "command", args... }
-- rows executed by src/script/ScriptRunner.lua.  Every hand-ported script
-- cites the pokered source it was ported from.

local registry = {
  PALLET_TOWN = require("data.scripts.pallet_town"),
  OAKS_LAB = require("data.scripts.oaks_lab"),
  REDS_HOUSE_1F = require("data.scripts.reds_house"),
  CELADON_MANSION_ROOF_HOUSE = require("data.scripts.celadon_eevee"),
}

-- story-critical scripts, one table per map.  Later files MERGE into
-- earlier ones: talk tables merge per TEXT constant, other hooks
-- (onEnter, onVictory, ...) are replaced,  so different files can each
-- add NPCs to the same map.
for _, file in ipairs({ "data.scripts.story", "data.scripts.story2",
                        "data.scripts.story3", "data.scripts.story4",
                        "data.scripts.story5", "data.scripts.story6",
                        "data.scripts.story7", "data.scripts.flavor_all",
                        "data.scripts.safari", "data.scripts.seafoam",
                        "data.scripts.gyms" }) do
  for mapId, mod in pairs(require(file)) do
    local existing = registry[mapId]
    if not existing then
      registry[mapId] = mod
    else
      for k, v in pairs(mod) do
        if k == "talk" and existing.talk then
          for textConst, script in pairs(v) do
            existing.talk[textConst] = script
          end
        else
          existing[k] = v
        end
      end
    end
  end
end

local M = {}

function M.get(mapId)
  return registry[mapId]
end

-- script to run when the player talks to an object with this TEXT_ constant
function M.talkScript(mapId, textConst)
  local mod = registry[mapId]
  return mod and mod.talk and mod.talk[textConst] or nil
end

return M
