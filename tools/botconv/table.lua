-- Classification table for the PokeBotBad route converter.
--
-- Every strategy/control name the route references maps to exactly one
-- bucket. convert.lua errors on anything missing, so this file is the
-- single place that decides what a PokeBotBad step becomes.
--
--   DROP   speedrun or streaming only; no gameplay effect. Removing it
--          cannot make the run unwinnable, only slower.
--   BATTLE resolve the fight with the generic battle handler. We are not
--          optimizing turns, so every named fight collapses to one op.
--   VERB   a generic parameterized action; params are rewritten below.
--   MANUAL progression-critical and not inferable from the route data.
--          Emitted as a stub op the runtime must implement, and listed in
--          the coverage report.

local T = {}

-- ---------------------------------------------------------------------
-- DROP
-- ---------------------------------------------------------------------
-- Timer splits, Twitch/LiveSplit bridge chatter, emulator speed control.
-- Stat-boost item pickups (carbos/rare candy) exist to hit damage
-- breakpoints on an optimal route; a bot that grinds normally outlevels
-- the need. "redbar" deliberately parks a mon at low HP for the Gen 1
-- low-HP speed trick and is actively harmful when not speedrunning.
-- "dodge*" routes around trainer sight lines to skip fights -- we let
-- those trainers engage and the generic battle handler takes them.
local DROP = {
  "split", "splitBrock", "changeSpeed", "battleModeSet", "guess",
  "tweetBrock", "tweetMisty", "tweetSurge", "tweetVictoryRoad",
  "reportMtMoon", "announceMachop", "announceOddish", "announceVenonat",
  "epicCutscene", "centerSkip", "jingleSkip",
  "dodgeCerulean", "dodgePalletBoy", "dodgeDepartment", "dodgeGirl",
  "dodgeViridianOldMan",
  "redbarCubone", "redbarMankey",
  "cinnabarCarbos", "safariCarbos", "silphCarbos",
  "drivebyRareCandy", "rareCandyEarly", "rareCandyGiovanni",
  "tossInSafari", "tossInVictoryRoad",
  "swapXSpecials", "swapXSpeeds",
  -- pre-emptive heals sized to an optimal route; the runtime's own
  -- "heal when below threshold" rule supersedes all of them.
  "potionBeforeMisty", "potionBeforeCocoons", "potionBeforeHypno",
  "potionBeforeLorelei", "potionBeforeRaticate", "potionBeforeRocket",
  "potionBeforeShorts", "potionBeforeSurge", "potionForMankey",
  "extraFullRestore", "checkEther", "checkGiovanni",
  -- turn-by-turn battle tactics, superseded by the generic battle AI
  "thunderboltFirst", "fourTurnThrash", "thrashGeodude", "rivalSandAttack",
  "swapThrash", "fightGiovanniMachoke", "fightSilphMachoke",
}

-- ---------------------------------------------------------------------
-- BATTLE
-- ---------------------------------------------------------------------
-- Named fights. Each becomes {op="battle"} -- walk in, fight until the
-- battle state pops. Rival/gym/E4 fights are all the same op; the route
-- has already put us in front of the right trainer.
local BATTLE = {
  "fightBrock", "fightMisty", "fightSurge", "fightErika", "fightKoga",
  "fightGiovanni", "fightSilphGiovanni", "fightBulbasaur", "fightMetapod",
  "fightWeedle", "fightGrimer", "fightHypno", "fightX",
  "lorelei", "bruno", "agatha", "lance", "blue", "champion",
  "viridianRival", "lavenderRival", "silphRival",
  "bugCatcher", "shortsKid", "digFight", "waitToFight",
  "hornAttackCaterpie", "catchFlierBackup",
}
-- NOTE: squirtleIChooseYou is NOT here. Despite sitting between two fights
-- in the route it is the starter pick -- walk to the ball, press A, accept
-- the prompt -- and is classified as a talk below.

-- ---------------------------------------------------------------------
-- VERB
-- ---------------------------------------------------------------------
-- name -> { op, params = { botKey = ourKey } }
-- Params not listed are dropped. `face` values are rewritten from
-- PokeBotBad's "Up"/"Down"/"Left"/"Right" to our "up"/"down"/"left"/"right".
local VERB = {
  talk        = { op = "talk",     params = { dir = "face" } },
  waitToTalk  = { op = "talk",     params = { dir = "face" } },
  interact    = { op = "talk",     params = { dir = "face" } },
  dialogue    = { op = "talk",     params = { dir = "face", decline = "decline" } },
  take        = { op = "pickup",   params = { dir = "face" } },
  grabAntidote     = { op = "pickup" },
  grabForestPotion = { op = "pickup" },
  grabMaxEther     = { op = "pickup" },
  grabTreePotion   = { op = "pickup" },
  bicycle     = { op = "bike" },
  procureBicycle = { op = "talk" },
  -- the starter pick: face the ball, A, accept the prompt
  squirtleIChooseYou = { op = "talk" },
  fly         = { op = "fly",      params = { dest = "dest", map = "map" } },
  push        = { op = "push",     params = { dir = "face", x = "x", y = "y" } },
  teach       = { op = "teach",    params = { move = "move", poke = "mon", replace = "replace" } },
  -- these two name the move rather than passing it as a param
  teachThrash = { op = "teach",    fixed = { move = "thrash" } },
  learnThrash = { op = "teach",    fixed = { move = "thrash" } },
  swapMove    = { op = "swapMove", params = { move = "move", to = "to" } },
  swap        = { op = "swapItem", params = { item = "item", dest = "dest" } },
  item        = { op = "useItem",  params = { item = "item", poke = "mon", all = "all" } },
  potion      = { op = "heal",     params = { hp = "hp", full = "full" } },
  elixer      = { op = "useItem",  params = { move = "move" } },
  ether       = { op = "useItem",  params = { max = "max" } },
  hikerElixer = { op = "useItem" },
  lassEther   = { op = "useItem" },
  undergroundElixer = { op = "useItem" },
  healParalysis = { op = "heal" },
  -- shops: the route knows the location, the runtime knows the list
  shopPewterMart        = { op = "shop", fixed = { list = "pewter" } },
  shopViridianPokeballs = { op = "shop", fixed = { list = "viridianBalls" } },
  shopVermilionMart     = { op = "shop", fixed = { list = "vermilion" } },
  shopRepels            = { op = "shop", fixed = { list = "repels" } },
  shopTM07              = { op = "shop", fixed = { list = "tm07" } },
  shopPokeDoll          = { op = "shop", fixed = { list = "pokeDoll" } },
  shopVending           = { op = "shop", fixed = { list = "vending" } },
  shopExtraWater        = { op = "shop", fixed = { list = "water" } },
  shopBuffs             = { op = "shop", fixed = { list = "buffs" } },
  -- Not shops, despite the names. prepareForBlue/prepareForLance are
  -- thin wrappers over strategyFunctions.potion (they fire in Lance's
  -- and Agatha's rooms, where no mart exists). equipForBrock is a
  -- level-8 reset gate plus a cure-poison, and the gate is speedrun-only
  -- -- a bot that grinds normally arrives overlevelled.
  prepareForBlue        = { op = "heal", fixed = { full = true } },
  prepareForLance       = { op = "heal", fixed = { full = true } },
  equipForBrock         = { op = "heal", fixed = { status = true } },
  -- "skill" is the route's field-move verb (cut/surf/strength/dig/flash)
  skill       = { op = "fieldMove", params = { move = "move", dir = "face",
                                               x = "x", y = "y", map = "map" } },
}

-- ---------------------------------------------------------------------
-- MANUAL
-- ---------------------------------------------------------------------
-- Progression gates. A generic verb cannot infer these from route data:
-- they involve party composition, puzzle state, or menus the route only
-- names. Each emits {op="manual", name=...} and the runtime dispatches to
-- a hand-written handler keyed by name.
local MANUAL = {
  "catchNidoran", "catchOddish",         -- party composition the route assumes
  "evolveNidoking", "evolveNidorino",    -- level/stone gating
  "trashcans",                           -- Surge gym can-search puzzle
  "depositPokemon",                      -- PC box menu
  "deptElevator", "silphElevator",       -- elevator floor menus
  "giveWater",                           -- Saffron guard gate
  "playPokeFlute",                       -- Snorlax
  "pokeDoll",                            -- Lavender Rocket blocker
  "talkToBill",                          -- S.S. Ticket gate
  "exitForest",                          -- Viridian Forest exit routing
  "trainerSightSkip",
}

-- ---------------------------------------------------------------------
-- CONTROLS  ({c="..."} steps)
-- ---------------------------------------------------------------------
-- Almost all of these are reset conditions or run telemetry. {c="a"} is
-- Bridge.chat -- Twitch commentary, 50 of the 98 control calls.
local CONTROL_DROP = {
  "a", "encounters", "trackEncounters", "allowDeath", "pp", "thrash",
  "moon1Exp", "moon2Exp", "moon3Exp", "startMtMoon",
  "nidoranBackupExp", "viridianBackupExp", "viridianExp",
}
-- Catch permission toggles do affect what the bot ends up with.
local CONTROL_VERB = {
  catchNidoran = { op = "allowCatch", mon = "nidoran" },
  catchOddish  = { op = "allowCatch", mon = "oddish" },
  catchParas   = { op = "allowCatch", mon = "paras" },
  catchFlier   = { op = "allowCatch", mon = "flier" },
  disableCatch = { op = "allowCatch", mon = false },
  potion       = { op = "heal" },
}

-- ---------------------------------------------------------------------

local function set(list)
  local t = {}
  for _, name in ipairs(list) do t[name] = true end
  return t
end

T.drop         = set(DROP)
T.battle       = set(BATTLE)
T.verb         = VERB
T.manual       = set(MANUAL)
T.controlDrop  = set(CONTROL_DROP)
T.controlVerb  = CONTROL_VERB

T.face = { Up = "up", Down = "down", Left = "left", Right = "right" }

return T
