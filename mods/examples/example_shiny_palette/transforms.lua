-- Asset transform: the whole point of this example.  It runs once at
-- install inside the restricted context -- read the player's own imported
-- cache, write under save/mod-derived/<id>/ -- so the repo ships the
-- recipe and never a ROM-derived pixel.
--
-- The derived path mirrors the cache path, so Assets.resolve picks it up
-- for every consumer of assets/generated/sprites/red.png with no registry
-- entry at all.  A recolor is exactly this: read, recolor, write back
-- under the same relative name.
local SHEETS = {
  "sprites/red.png",
  "sprites/red_bike.png",
}

-- lightest shade first; the recolor buckets every ink pixel into one of
-- these four by luminance, matching the importer's own 4-gray split
local TEAL = {
  { 248, 248, 248 },
  { 120, 224, 216 },
  { 32, 128, 152 },
  { 8, 32, 64 },
}

return function(ctx)
  for _, rel in ipairs(SHEETS) do
    -- a player who has not imported yet simply gets no derived art; the
    -- vanilla sheet keeps rendering and the mod stays loaded
    if ctx.exists(rel) then
      ctx.writeImage(ctx.recolor(ctx.readImage(rel), TEAL), rel)
    end
  end
end
