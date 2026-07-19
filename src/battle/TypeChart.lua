-- Gen 1 type effectiveness from generated data (multipliers x10).
-- Like the original, each matchup row applies independently, so dual types
-- multiply (e.g. 20 * 5 -> neutral).

local TypeChart = {}

local index -- [atk][def] -> x10 multiplier
local matchups -- ROM-ordered TypeEffects rows
local types -- merged type records (physical/special category, display name)

function TypeChart.load(data)
  index = {}
  matchups = data.type_chart.matchups
  for _, m in ipairs(matchups) do
    index[m.attacker] = index[m.attacker] or {}
    index[m.attacker][m.defender] = m.multiplier
  end
  types = data.type_chart.types
end

-- the merged type record's category; falls back to the vanilla records
-- so pure-module callers need no load
function TypeChart.category(typeId)
  local record = types and types[typeId] or TypeChart.TYPES[typeId]
  return record and record.category or nil
end

-- display name for the move-select TYPE/ box (mod types render their
-- name instead of their raw id)
function TypeChart.displayName(typeId)
  local record = types and types[typeId] or TypeChart.TYPES[typeId]
  return record and record.name or typeId
end

-- The x10 multipliers of every TypeEffects row that applies, in ROM
-- order.  AdjustDamageForMoveType applies each row to the running
-- damage separately (one application per row even when both defender
-- types match it), so callers must floor after every row.
function TypeChart.rows(moveType, defenderTypes)
  assert(matchups, "TypeChart.load not called")
  local out = {}
  for _, m in ipairs(matchups) do
    if m.attacker == moveType then
      for _, dt in ipairs(defenderTypes) do
        if m.defender == dt then
          out[#out + 1] = m.multiplier
          break
        end
      end
    end
  end
  return out
end

-- Returns the combined x10 multiplier of moveType against a types list
-- (x100 for dual matchups is normalized back: each application is /10).
function TypeChart.effectiveness(moveType, defenderTypes)
  assert(index, "TypeChart.load not called")
  local mult = 10
  local row = index[moveType]
  if not row then return mult end
  for _, dt in ipairs(defenderTypes) do
    local m = row[dt]
    if m ~= nil then
      mult = math.floor(mult * m / 10)
    end
  end
  return mult
end

-- Gen 1 splits physical from special by TYPE, not by move: the seven types
-- from FIRE up are special (engine/battle/effect_commands.asm compares the
-- type id against SPECIAL).  The list Damage.isSpecial carries is the same
-- one, restated here as the type records the type_chart registry serves.
TypeChart.TYPES = {
  NORMAL       = { name = "NORMAL",   category = "physical" },
  FIGHTING     = { name = "FIGHTING", category = "physical" },
  FLYING       = { name = "FLYING",   category = "physical" },
  POISON       = { name = "POISON",   category = "physical" },
  GROUND       = { name = "GROUND",   category = "physical" },
  ROCK         = { name = "ROCK",     category = "physical" },
  BUG          = { name = "BUG",      category = "physical" },
  GHOST        = { name = "GHOST",    category = "physical" },
  FIRE         = { name = "FIRE",     category = "special" },
  WATER        = { name = "WATER",    category = "special" },
  GRASS        = { name = "GRASS",    category = "special" },
  ELECTRIC     = { name = "ELECTRIC", category = "special" },
  PSYCHIC_TYPE = { name = "PSYCHIC",  category = "special" },
  ICE          = { name = "ICE",      category = "special" },
  DRAGON       = { name = "DRAGON",   category = "special" },
}

-- The matchup rows come from the generated chart, so a dataset with a
-- different table registers a different world without touching this file.
function TypeChart.registerInto(registry, data, owner)
  for id, record in pairs(TypeChart.TYPES) do
    registry:register(id, record, owner)
  end
  local chart = data and data.type_chart
  for _, row in ipairs(chart and chart.matchups or {}) do
    registry:register(row.attacker .. ">" .. row.defender,
      { multiplier = row.multiplier }, owner)
  end
end

return TypeChart
