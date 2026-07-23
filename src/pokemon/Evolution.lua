-- Evolution handling (engine/pokemon/evos_moves.asm semantics):
-- level evolutions trigger after battles once the level is reached,
-- stone evolutions on item use, and trade evolutions when a link trade
-- completes (src/link/Protocol.lua TradeSession:apply).
--
-- Method dispatch runs through the merged evolution_methods registry:
-- a record's check(game, mon, evo, trigger) answers whether that
-- evolutions[] row fires for the trigger ({ kind = "levelup" | "item" |
-- "trade" | "manual" | <mod>, item = id?, ... }), wrapped by the
-- evolution.check hook so a mod can cancel or force any evolution.

local Music = require("src.core.Music")
local Runtime = require("src.mods.Runtime")
local Screens = require("src.ui.Screens")
local Stats = require("src.pokemon.Stats")
local TextBox = require("src.render.TextBox")

local Evolution = {}

Evolution.METHODS = {
  LEVEL = {
    check = function(game, mon, evo, trigger)
      return trigger.kind == "levelup" and mon.level >= (evo.level or 0)
    end,
    describe = function(evo)
      return ("Level %d"):format(evo.level or 0)
    end,
  },
  ITEM = {
    check = function(game, mon, evo, trigger)
      return trigger.kind == "item" and trigger.item == evo.item
    end,
    describe = function(evo, data)
      return (data and data.items[evo.item] or {}).name or evo.item
    end,
    consumesItem = true,
  },
  TRADE = {
    check = function(game, mon, evo, trigger)
      return trigger.kind == "trade"
    end,
    describe = function() return "Trade" end,
  },
}

function Evolution.registerInto(registry, _, owner)
  for id, record in pairs(Evolution.METHODS) do
    registry:register(id, record, owner)
  end
end

-- Single dispatch point over the merged registry, wrapped by the
-- evolution.check hook.  Returns species, evo for the first matching
-- evolutions[] row, or nil.
function Evolution.pendingFor(game, mon, trigger)
  trigger = trigger or { kind = "manual" }
  local data = game.data
  local def = data.pokemon[mon.species]
  local methods = data.evolution_methods or Evolution.METHODS
  for _, evo in ipairs(def.evolutions or {}) do
    local method = methods[evo.method]
    if method and method.check then
      local should
      if Runtime.wantsHook("evolution.check") then
        should = Runtime.call("evolution.check", function(g, m, e, t)
          return method.check(g, m, e, t)
        end, game, mon, evo, trigger)
      else
        should = method.check(game, mon, evo, trigger)
      end
      if should then return evo.species, evo end
    end
  end
  return nil
end

-- Find a pending level evolution for a mon (nil if none).  Frozen v1
-- shim: callers pass a plain data table, so it stays a hookless LEVEL
-- check; game-holding callers use pendingFor.
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
-- via is the evolution method id when the caller knows it.
function Evolution.apply(game, mon, newSpecies, via)
  local newDef = game.data.pokemon[newSpecies]
  assert(newDef, "evolve into unknown species " .. tostring(newSpecies))
  local fromSpecies = mon.species
  local hpLost = mon.stats.hp - mon.hp
  mon.species = newSpecies
  mon.stats = Stats.calc(newDef, mon.level, mon.dvs, mon.statExp)
  mon.hp = math.max(1, mon.stats.hp - hpLost)
  if game.save.pokedex then
    game.save.pokedex.seen[newSpecies] = true
    game.save.pokedex.owned[newSpecies] = true
  end
  Runtime.emit("pokemon.evolved", {
    mon = mon, fromSpecies = fromSpecies, toSpecies = newSpecies, via = via,
  })
end

-- Play the evolution movie (flashing forms), then apply + text.
-- Headless (no real graphics) falls back to the plain text flow.
function Evolution.evolve(game, mon, newSpecies, onDone, via)
  if love.image and love.image.newImageData then
    Screens.push(game, "EvolutionState", mon, newSpecies, onDone)
    return
  end
  Music.play(game.data, Music.special(game.data, "evolution"))
  local oldName = mon.nickname or game.data.pokemon[mon.species].name
  Evolution.apply(game, mon, newSpecies, via)
  local msg = ("What?\n%s is\nevolving!\fCongratulations!\nYour %s\nevolved into\n%s!")
              :format(oldName, oldName, game.data.pokemon[newSpecies].name)
  game.stack:push(TextBox.new(game, msg, function()
    Music.restoreMap(game.data)
    if onDone then onDone() end
  end))
end

-- Entry point for mods whose methods fire outside the vanilla moments
-- (location or time triggers): runs pendingFor with the caller's trigger
-- and, on a match, plays the standard evolve movie.  Returns the target
-- species or nil.
function Evolution.request(game, mon, trigger, onDone)
  local species, evo = Evolution.pendingFor(game, mon, trigger)
  if not species then
    if onDone then onDone() end
    return nil
  end
  Evolution.evolve(game, mon, species, onDone, evo and evo.method)
  return species
end

-- After-battle hook: evolve everyone who qualifies (queued one at a time).
function Evolution.checkParty(game, onDone)
  local pending = {}
  for _, mon in ipairs(game.save.party) do
    local target, evo = Evolution.pendingFor(game, mon, { kind = "levelup" })
    if target then
      table.insert(pending, { mon = mon, to = target, via = evo and evo.method })
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
    Evolution.evolve(game, p.mon, p.to, nextOne, p.via)
  end
  nextOne()
  return #pending
end

return Evolution
