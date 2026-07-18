-- Gen 1 type effectiveness from generated data (multipliers x10).
-- Like the original, each matchup row applies independently, so dual types
-- multiply (e.g. 20 * 5 -> neutral).

local TypeChart = {}

local index -- [atk][def] -> x10 multiplier
local matchups -- ROM-ordered TypeEffects rows

function TypeChart.load(data)
  index = {}
  matchups = data.type_chart.matchups
  for _, m in ipairs(matchups) do
    index[m.attacker] = index[m.attacker] or {}
    index[m.attacker][m.defender] = m.multiplier
  end
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

return TypeChart
