-- FIX_TOWN (spawn, one warp, one NPC) and FIX_ROUTE (grass, one trainer)
local function flat(width, height, block)
  local blocks = {}
  for i = 1, width * height do blocks[i] = block end
  return blocks
end

local town = {
  id = "FIX_TOWN", label = "FixTown", index = 1000,
  tileset = "FIX_OUT",
  width = 10, height = 9,
  blocks = flat(10, 9, 1),
  borderBlock = 0,
  connections = {
    north = { map = "FIX_ROUTE", offset = 0 },
  },
  warps = {
    { x = 5, y = 5, destMap = "FIX_ROUTE", destWarp = 1 },
  },
  objects = {
    {
      index = 1, name = "FIXTOWN_GREETER", sprite = "SPRITE_FIX_NPC",
      movement = "STAY", range = "NONE",
      text = "TEXT_FIXTOWN_GREETER", x = 4, y = 4,
    },
  },
  signs = {
    { text = "TEXT_FIXTOWN_SIGN", x = 6, y = 6 },
  },
}

local route = {
  id = "FIX_ROUTE", label = "FixRoute", index = 1001,
  tileset = "FIX_OUT",
  width = 10, height = 18,
  blocks = flat(10, 18, 2),
  borderBlock = 0,
  connections = {
    south = { map = "FIX_TOWN", offset = 0 },
  },
  warps = {
    { x = 5, y = 1, destMap = "FIX_TOWN", destWarp = 1 },
  },
  objects = {
    {
      index = 1, name = "FIXROUTE_TRAINER", sprite = "SPRITE_FIX_NPC",
      movement = "STAY", range = "NONE",
      text = "TEXT_FIXROUTE_TRAINER", x = 5, y = 9,
    },
  },
  signs = {},
}

return { FIX_TOWN = town, FIX_ROUTE = route }
