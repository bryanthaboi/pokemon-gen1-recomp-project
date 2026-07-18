-- Per-trainer-class battle AI: item use and switching.
-- Hand-ported from data/trainers/ai_pointers.asm (uses per Pokémon +
-- routine) and engine/battle/trainer_ai.asm (the routines).  Classes
-- not listed use GenericAI (never uses items or switches).
--
-- chance is out of 256 (the routine's `cp X percent` threshold on a
-- random byte).  hpBelow means "only when HP < max/N".  onStatus means
-- "always, but only when the active mon has a status condition".

return {
  OPP_JUGGLER      = { uses = 3, chance = 64,  switch = true },
  OPP_BLACKBELT    = { uses = 2, chance = 32,  item = "X_ATTACK" },
  OPP_GIOVANNI     = { uses = 1, chance = 64,  item = "GUARD_SPEC" },
  OPP_COOLTRAINER_M = { uses = 2, chance = 64, item = "X_ATTACK" },
  -- CooltrainerF's 25% roll is dead code in the original (the ret nc is
  -- commented out); she heals below 1/10 and switches below 1/5
  OPP_COOLTRAINER_F = { uses = 1, item = "HYPER_POTION", hpBelow = 10,
                        switchBelow = 5 },
  OPP_BRUNO        = { uses = 2, chance = 64,  item = "X_DEFEND" },
  OPP_BROCK        = { uses = 5, onStatus = true, item = "FULL_HEAL" },
  OPP_MISTY        = { uses = 1, chance = 64,  item = "X_DEFEND" },
  OPP_LT_SURGE     = { uses = 1, chance = 64,  item = "X_SPEED" },
  OPP_ERIKA        = { uses = 1, chance = 128, item = "SUPER_POTION", hpBelow = 10 },
  OPP_KOGA         = { uses = 2, chance = 64,  item = "X_ATTACK" },
  OPP_BLAINE       = { uses = 2, chance = 64,  item = "SUPER_POTION" },
  OPP_SABRINA      = { uses = 1, chance = 64,  item = "HYPER_POTION", hpBelow = 10 },
  OPP_RIVAL2       = { uses = 1, chance = 32,  item = "POTION", hpBelow = 5 },
  OPP_RIVAL3       = { uses = 1, chance = 32,  item = "FULL_RESTORE", hpBelow = 5 },
  OPP_LORELEI      = { uses = 2, chance = 128, item = "SUPER_POTION", hpBelow = 5 },
  OPP_AGATHA       = { uses = 2, switchChance = 20, chance = 128,
                       item = "SUPER_POTION", hpBelow = 4 },
  OPP_LANCE        = { uses = 1, chance = 128, item = "HYPER_POTION", hpBelow = 5 },
}
