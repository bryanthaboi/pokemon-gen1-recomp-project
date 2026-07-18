-- Example native mod.  It demonstrates both a runtime event and a content
-- override without requiring any private engine module.
return function(mod)
  local mew = mod.content.pokemon:get("MEW")
  assert(mew, "Mew is missing from the imported base data")

  -- Keep every vanilla Mew field, changing only the two battle sprite paths.
  local invertedMew = {}
  for key, value in pairs(mew) do invertedMew[key] = value end
  invertedMew.spriteFront = mod.path .. "/assets/mew_front_inverted.png"
  invertedMew.spriteBack = mod.path .. "/assets/mew_back_inverted.png"
  mod.content.pokemon:override("MEW", invertedMew)

  mod.events:on("pokemon.before_give", function(gift)
    -- Only change the Oak's Lab Charmander gift; wild encounters and other
    -- story gifts remain vanilla.
    local map = gift.ctx.overworld and gift.ctx.overworld.map
    if gift.species == "CHARMANDER" and map and map.id == "OAKS_LAB"
       and not gift.ctx.save.flags.EVENT_GOT_STARTER then
      gift.species = "MEW"
      gift.level = 20
      gift.nickname = "HOGHEAD"
      mod.log:info("replaced Oak's Lab Charmander starter with level 20 Mew")
    end
  end)
end
