-- Gallery #1 (Tweaker): pure data, no engine seams.  Everything here is
-- patch + each, so no record is ever copied whole and another mod editing
-- the same species keeps its own fields.
return function(mod)
  -- patch deep-merges only the leaves it names: learnset, sprites, types
  -- and evolutions all survive this speed change untouched
  for _, id in ipairs({ "VENUSAUR", "CHARIZARD", "BLASTOISE" }) do
    if mod.content.pokemon:get(id) then
      mod.content.pokemon:patch(id, { baseStats = { speed = 100 } })
    else
      -- degrade instead of crashing: a species mod loaded ahead of this
      -- one may have removed the vanilla starter line
      mod.log:warn("%s missing from the merged view; speed patch skipped", id)
    end
  end

  -- each() walks the merged view (engine records plus every mod ahead of
  -- this one), so the TM list is discovered rather than hard-coded
  local halved = 0
  for id, item in mod.content.items:each() do
    local machine = item.machine
    if machine and machine.kind == "TM" and type(item.price) == "number"
        and item.price > 0 then
      mod.content.items:patch(id, { price = math.floor(item.price / 2) })
      halved = halved + 1
    end
  end
  mod.log:info("halved %d TM prices", halved)

  -- lists replace wholesale even inside a patch, so a re-slotted encounter
  -- table is written out in full while the rate rides along as a leaf
  mod.content.encounters:patch("ROUTE_1", {
    grass = {
      rate = 20,
      slots = {
        { level = 3, species = "PIDGEY" }, { level = 3, species = "RATTATA" },
        { level = 4, species = "SPEAROW" }, { level = 2, species = "RATTATA" },
        { level = 2, species = "PIDGEY" }, { level = 3, species = "SPEAROW" },
        { level = 3, species = "PIDGEY" }, { level = 4, species = "RATTATA" },
        { level = 4, species = "PIDGEY" }, { level = 5, species = "SPEAROW" },
      },
    },
  })
end
