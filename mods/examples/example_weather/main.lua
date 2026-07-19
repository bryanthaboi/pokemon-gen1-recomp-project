-- Gallery #5 (Mechanic designer): a new battle mechanic with no engine
-- fork.  A rain field effect scales WATER and FIRE damage, lives behind an
-- opt-in ruleset, and keeps its own counter in mod.save.
--
-- The parity lesson is the ruleset gate: install this mod, leave the
-- ruleset on gen1_faithful, and every battle is byte-for-byte vanilla
-- because the hook returns next(...) untouched.
local RULESET = "example_weather_battles"
local RAIN_TURNS = 5

local BOOST = { WATER = 1.5 }
local DAMPEN = { FIRE = 0.5 }

return function(mod)
  -- ------- the field effect, declared as a status record

  mod.content.statuses:register("EXAMPLE_RAIN", {
    id = "EXAMPLE_RAIN",
    label = "RAIN",
    hudLabel = "RAIN",
    -- a field effect is never inflicted on a battler; the record is the
    -- declaration the HUD and other mods read, the hook is the behavior
    canInflict = function() return false end,
  })

  -- ------- the ruleset that turns it on
  -- Read the vanilla record out of the merged registry rather than
  -- requiring the module: same table, no engine_internals permission.

  local base = mod.content.rulesets:get("gen1_faithful")
  if not base then
    mod.log:error("gen1_faithful missing from the rulesets registry; "
      .. "another mod removed it, so %s cannot be derived", RULESET)
    return
  end
  local weather = {}
  for key, value in pairs(base) do weather[key] = value end
  weather.name = "WEATHER"
  -- the marker the damage hook gates on; unknown fields ride through the
  -- schema untouched, which is what makes rulesets extensible
  weather.exampleWeather = true
  mod.content.rulesets:register(RULESET, weather)

  -- ------- rain lifecycle, in this mod's own save namespace

  local function raining()
    return (mod.save:get("turnsLeft", 0)) > 0
  end

  mod.events:on("battle.started", function(ev)
    local ruleset = ev.battle and ev.battle.ruleset
    if ruleset and ruleset.exampleWeather then
      mod.save:set("turnsLeft", RAIN_TURNS)
    else
      mod.save:set("turnsLeft", 0)
    end
  end)

  mod.events:on("battle.turn_started", function()
    local left = mod.save:get("turnsLeft", 0)
    if left > 0 then mod.save:set("turnsLeft", left - 1) end
  end)

  mod.events:on("battle.ended", function()
    mod.save:set("turnsLeft", 0)
  end)

  -- ------- the one behavior change

  mod.hooks:wrap("battle.damage", function(next, ctx)
    -- the two gates, cheapest first: the player has to have picked the
    -- ruleset, and it has to still be raining
    if not (ctx.ruleset and ctx.ruleset.exampleWeather and raining()) then
      return next(ctx)
    end
    local moveType = ctx.move and ctx.move.type
    local scale = BOOST[moveType] or DAMPEN[moveType]
    if not scale then return next(ctx) end

    -- Damage.compute returns (damage, info); pass the second value through
    -- untouched or the crit and type-effectiveness flags vanish
    local damage, info = next(ctx)
    if type(damage) ~= "number" then return damage, info end
    return math.max(1, math.floor(damage * scale)), info
  end)
end
