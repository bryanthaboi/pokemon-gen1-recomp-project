local Pokemon = require("src.pokemon.Pokemon")
local Stats = require("src.pokemon.Stats")
local Growth = require("src.pokemon.Growth")

local MonOps = {}

function MonOps.create(data, species, level)
  return Pokemon.new(data, species, level)
end

function MonOps.recalc(data, mon)
  local def = data.pokemon[mon.species]
  assert(def, "unknown species")
  mon.stats = Stats.calc(def, mon.level, mon.dvs, mon.statExp)
  mon.hp = math.max(0, math.min(mon.hp or mon.stats.hp, mon.stats.hp))
end

function MonOps.setLevel(data, mon, level)
  level = math.max(1, math.min(100, math.floor(level)))
  local def = data.pokemon[mon.species]
  mon.level = level
  mon.exp = Growth.expForLevel(def.growthRate, level)
  MonOps.recalc(data, mon)
end

function MonOps.setMove(data, mon, slot, moveId)
  assert(slot >= 1 and slot <= 4)
  local mdef = data.moves[moveId]
  assert(mdef, "unknown move")
  mon.moves = mon.moves or {}
  mon.moves[slot] = {
    id = moveId,
    pp = mdef.pp + ((mon.moves[slot] and mon.moves[slot].ppUps) or 0) * math.floor(mdef.pp / 5),
    ppUps = mon.moves[slot] and mon.moves[slot].ppUps or nil,
  }
end

-- HP DV is derived from the low bits of the other four (Stats.randomDVs).
function MonOps.syncHpDv(dvs)
  dvs.hp = (dvs.attack % 2) * 8 + (dvs.defense % 2) * 4
         + (dvs.speed % 2) * 2 + (dvs.special % 2)
  return dvs
end

function MonOps.setDv(data, mon, key, value)
  mon.dvs[key] = math.max(0, math.min(15, math.floor(value)))
  if key ~= "hp" then
    MonOps.syncHpDv(mon.dvs)
  end
  MonOps.recalc(data, mon)
end

-- Keep level; resync exp to the species growth curve (species changes).
function MonOps.setSpecies(data, mon, species)
  assert(data.pokemon[species], "unknown species")
  mon.species = species
  MonOps.setLevel(data, mon, mon.level)
end

return MonOps
