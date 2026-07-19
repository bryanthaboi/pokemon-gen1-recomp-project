-- Fly destination picker: visited towns, landing at the real fly-warp
-- spots from data/maps/special_warps.asm.

local ListMenu = require("src.ui.ListMenu")
local Map = require("src.world.Map")

local FlyMenu = {}

function FlyMenu.new(game)
  local items = {}
  local visited = game.save.visited or {}
  local seen = {}
  for _, mapId in ipairs(game.data.field.flyOrder or {}) do
    -- towns only (dungeon escape spots share the table), each listed once
    local def = game.data.maps[mapId]
    if visited[mapId] and def and Map.isOutdoor(def) and not seen[mapId] then
      seen[mapId] = true
      table.insert(items, {
        value = mapId,
        label = mapId:gsub("_", " "),
      })
    end
  end
  return ListMenu.new(game, "FLY TO?", items, {
    onChoose = function(item, list)
      list:close()
      game.overworld:flyTo(item.value)
    end,
  })
end

return FlyMenu
