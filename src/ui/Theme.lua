-- The cursor/border/geometry constants every menu used to redeclare
-- locally, centralized so field.theme can restyle all of them at once.
-- Defaults are the current literals; the merge never runs without a mod,
-- so a vanilla boot draws byte-identically.

local Font = require("src.render.Font")
local Merge = require("src.mods.Merge")
local Renderer = require("src.render.Renderer")

local Theme = {
  cursor = 0xED,        -- the filled arrow (charmap.asm $ED)
  cursorHollow = 0xEC,  -- the unfilled arrow left on chosen rows
  moreArrow = 0xEE,     -- more-below marker (charmap.asm $EE)
  tile = 8,
  cols = Renderer.WIDTH / 8,
  rows = Renderer.HEIGHT / 8,
  textBox = { tx = 0, ty = 12, tw = 20, th = 6, maxCols = 18 },
  choiceBox = { tx = 0, ty = 7, tw = 6, th = 5 },
}

function Theme.load(data)
  -- Font.load rebuilds its border table, so pick it up here rather than at
  -- require time
  Theme.border = Font.BORDER
  local t = data and data.field and data.field.theme
  if t then
    Merge.deepMerge(Theme, t)
    Font.BORDER = Theme.border
  end
end

return Theme
