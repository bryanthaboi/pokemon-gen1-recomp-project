-- Fly destination picker: visited towns, landing at the real fly-warp
-- spots from data/maps/special_warps.asm.

local ListMenu = require("src.ui.ListMenu")

local FlyMenu = {}

function FlyMenu.new(game)
  local items = {}
  local visited = game.save.visited or {}
  for _, mapId in ipairs(game.data.field.flyOrder) do
    -- towns only (dungeon escape spots share the table)
    if visited[mapId] and game.data.maps[mapId]
       and game.data.maps[mapId].tileset == "OVERWORLD" then
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
