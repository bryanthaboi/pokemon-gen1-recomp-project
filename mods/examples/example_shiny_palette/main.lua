-- Gallery #2 (Artist): a recolor that ships no pixels.  transforms.lua
-- derives the sheets from the player's own cache; this file only declares
-- the palette records and the one flag the recolor needs.
return function(mod)
  -- v2 record shape: a named table of four colors, lightest first
  mod.content.palettes:register("EXAMPLE_SHINY", {
    colors = {
      { r = 248, g = 248, b = 248 },
      { r = 120, g = 224, b = 216 },
      { r = 32, g = 128, b = 152 },
      { r = 8, g = 32, b = 64 },
    },
  })

  -- vanilla raw shape: four {r,g,b} triples.  Overriding a town palette is
  -- the smallest visible artist change there is -- no assets involved.
  mod.content.palettes:override("PALLET", {
    { 248, 248, 248 }, { 152, 232, 224 }, { 64, 152, 168 }, { 8, 32, 64 },
  })

  -- trueColor opts SPRITE_RED out of the 4-shade re-shade so the teal the
  -- transform baked in survives to the screen.  patch, not override: the
  -- image path and frame count stay whatever the merged view already has,
  -- which is how the derived sheet keeps supplying the pixels.
  mod.content.sprites:patch("SPRITE_RED", { trueColor = true })
  mod.content.sprites:patch("SPRITE_RED_BIKE", { trueColor = true })

  mod.events:on("assets.transformed", function(ev)
    if ev.modId ~= mod.id then return end
    if ev.count == 0 then
      mod.log:warn("no sheets derived -- import your ROM first, then "
        .. "delete save/mod-derived/%s to re-run the transform", mod.id)
    else
      mod.log:info("derived %d recolored sheets", ev.count)
    end
  end)
end
