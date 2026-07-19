-- FIX_TACKLE doubles as constants.fallbackMove, the move-slot repair floor
return {
  FIX_TACKLE = {
    id = "FIX_TACKLE", index = 1, name = "FIX TACKLE",
    type = "NORMAL", power = 40, accuracy = 100, pp = 35, effect = "NO_ADDITIONAL_EFFECT",
  },
  FIX_SCRATCH = {
    id = "FIX_SCRATCH", index = 2, name = "FIX SCRATCH",
    type = "NORMAL", power = 40, accuracy = 100, pp = 35, effect = "NO_ADDITIONAL_EFFECT",
  },
  FIX_EMBERISH = {
    id = "FIX_EMBERISH", index = 3, name = "FIX EMBER",
    type = "FIRE", power = 40, accuracy = 100, pp = 25,
    effect = "BURN_SIDE_EFFECT1",
  },
  FIX_CUT = {
    id = "FIX_CUT", index = 4, name = "FIX CUT",
    type = "NORMAL", power = 50, accuracy = 95, pp = 30, effect = "NO_ADDITIONAL_EFFECT",
  },
}
