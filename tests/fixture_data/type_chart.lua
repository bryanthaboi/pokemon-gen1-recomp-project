-- the GRASS/FIRE/WATER triangle; type records themselves come from the
-- engine's own registrations (src/battle/TypeChart.TYPES)
return {
  matchups = {
    { attacker = "FIRE", defender = "GRASS", multiplier = 20 },
    { attacker = "GRASS", defender = "WATER", multiplier = 20 },
    { attacker = "WATER", defender = "FIRE", multiplier = 20 },
    { attacker = "FIRE", defender = "WATER", multiplier = 5 },
    { attacker = "WATER", defender = "GRASS", multiplier = 5 },
    { attacker = "GRASS", defender = "FIRE", multiplier = 5 },
  },
}
