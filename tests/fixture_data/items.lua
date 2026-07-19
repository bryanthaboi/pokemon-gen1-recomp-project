-- one of each item seam: heal effect, ball, machine, badge
return {
  FIX_POTION = {
    id = "FIX_POTION", index = 1, name = "FIX POTION", price = 300,
    tossable = true,
  },
  FIX_BALL = {
    id = "FIX_BALL", index = 2, name = "FIX BALL", price = 200,
    ball = "POKE_BALL",
  },
  FIX_TM = {
    id = "FIX_TM", index = 3, name = "FIX TM01", price = 3000,
    machine = { kind = "TM", number = 1, move = "FIX_CUT" },
  },
  FIX_BADGE_1 = {
    id = "FIX_BADGE_1", index = 4, name = "FIX BADGE 1", price = 0,
  },
  FIX_BADGE_2 = {
    id = "FIX_BADGE_2", index = 5, name = "FIX BADGE 2", price = 0,
  },
}
