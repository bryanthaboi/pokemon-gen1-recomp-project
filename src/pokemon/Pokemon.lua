-- A Pokémon instance (plain table so it serializes straight into the save).

local Growth = require("src.pokemon.Growth")
local Stats = require("src.pokemon.Stats")

local Pokemon = {}

-- Starting moves: level-1 moves plus learnset entries at or below the level,
-- keeping the most recent four (engine/pokemon/learn_move.asm behavior).
function Pokemon.movesAtLevel(speciesDef, level)
  local moves = {}
  local function add(id)
    for _, existing in ipairs(moves) do
      if existing == id then return end
    end
    table.insert(moves, id)
  end
  for _, m in ipairs(speciesDef.level1Moves) do
    add(m)
  end
  for _, entry in ipairs(speciesDef.learnset) do
    if entry.level <= level then
      add(entry.move)
    end
  end
  while #moves > 4 do
    table.remove(moves, 1)
  end
  return moves
end

function Pokemon.new(data, species, level, rng)
  local def = data.pokemon[species]
  assert(def, "unknown species " .. tostring(species))
  local dvs = Stats.randomDVs(rng)
  local stats = Stats.calc(def, level, dvs)
  local moves = {}
  for _, id in ipairs(Pokemon.movesAtLevel(def, level)) do
    local mdef = data.moves[id]
    table.insert(moves, { id = id, pp = mdef and mdef.pp or 0 })
  end
  return {
    species = species,
    level = level,
    exp = Growth.expForLevel(def.growthRate, level),
    dvs = dvs,
    statExp = { hp = 0, attack = 0, defense = 0, speed = 0, special = 0 },
    stats = stats,
    hp = stats.hp,
    status = nil, -- "SLP"|"PSN"|"BRN"|"FRZ"|"PAR"
    moves = moves,
  }
end

-- Pokémon Center / blackout heal (engine/events/heal_party.asm
-- HealParty): full HP, status cleared, and every move's PP restored to
-- its base plus the PP-Up bonus (RestoreBonusPP adds maxPP/5 per PP UP).
function Pokemon.heal(mon)
  mon.hp = mon.stats.hp
  mon.status = nil
  local moves = require("src.core.Data").moves
  if moves then
    for _, mv in ipairs(mon.moves) do
      local mdef = moves[mv.id]
      if mdef then
        mv.pp = mdef.pp + (mv.ppUps or 0) * math.floor(mdef.pp / 5)
      end
    end
  end
end

function Pokemon.isFainted(mon)
  return mon.hp <= 0
end

return Pokemon
