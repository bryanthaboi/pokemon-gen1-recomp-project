-- Evolution handling (engine/pokemon/evos_moves.asm semantics):
-- level evolutions trigger after battles once the level is reached,
-- stone evolutions on item use, and trade evolutions when a link trade
-- completes (src/link/Protocol.lua TradeSession:apply).

local Stats = require("src.pokemon.Stats")
local TextBox = require("src.render.TextBox")

local Evolution = {}

-- Find a pending level evolution for a mon (nil if none).
function Evolution.pendingLevelEvo(data, mon)
  local def = data.pokemon[mon.species]
  for _, evo in ipairs(def.evolutions) do
    if evo.method == "LEVEL" and mon.level >= evo.level then
      return evo.species
    end
  end
  return nil
end

-- Mutate the mon into the new species (stats, HP delta, dex flags).
function Evolution.apply(game, mon, newSpecies)
  local newDef = game.data.pokemon[newSpecies]
  assert(newDef, "evolve into unknown species " .. tostring(newSpecies))
  local hpLost = mon.stats.hp - mon.hp
  mon.species = newSpecies
  mon.stats = Stats.calc(newDef, mon.level, mon.dvs, mon.statExp)
  mon.hp = math.max(1, mon.stats.hp - hpLost)
  if game.save.pokedex then
    game.save.pokedex.seen[newSpecies] = true
    game.save.pokedex.owned[newSpecies] = true
  end
end

-- Play the evolution movie (flashing forms), then apply + text.
-- Headless (no real graphics) falls back to the plain text flow.
function Evolution.evolve(game, mon, newSpecies, onDone)
  if love.image and love.image.newImageData then
    local EvolutionState = require("src.ui.EvolutionState")
    game.stack:push(EvolutionState.new(game, mon, newSpecies, onDone))
    return
  end
  local oldName = mon.nickname or game.data.pokemon[mon.species].name
  Evolution.apply(game, mon, newSpecies)
  local msg = ("What?\n%s is\nevolving!\fCongratulations!\nYour %s\nevolved into\n%s!")
              :format(oldName, oldName, game.data.pokemon[newSpecies].name)
  game.stack:push(TextBox.new(game, msg, onDone))
end

-- After-battle hook: evolve everyone who qualifies (queued one at a time).
function Evolution.checkParty(game, onDone)
  local pending = {}
  for _, mon in ipairs(game.save.party) do
    local target = Evolution.pendingLevelEvo(game.data, mon)
    if target then
      table.insert(pending, { mon = mon, to = target })
    end
  end
  local i = 0
  local function nextOne()
    i = i + 1
    local p = pending[i]
    if not p then
      if onDone then onDone() end
      return
    end
    Evolution.evolve(game, p.mon, p.to, nextOne)
  end
  nextOne()
  return #pending
end

return Evolution
