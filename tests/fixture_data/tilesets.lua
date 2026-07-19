-- one outdoor tileset; blocks are 16-tile rows like the generated cache
local function row(tile)
  local out = {}
  for i = 1, 16 do out[i] = tile end
  return out
end

return {
  FIX_OUT = {
    id = "FIX_OUT",
    image = "tests/fixture_data/assets/fix_out.png",
    blocks = { row(0), row(1), row(2), row(3) },
    walkable = { [0] = true, [1] = true, [2] = true },
    counterTiles = {},
    doorTiles = {},
    warpTiles = { 3 },
    grassTile = 2,
  },
}
