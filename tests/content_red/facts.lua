-- The pinned Red facts, as data (21-testing-and-ci "test taxonomy" T3).
--
-- The content tier asserts values that are true of Pokemon Red and of
-- nothing else -- map sizes, encounter slots, exact pokered strings.  Held
-- as a table rather than spread through assertion code, a total conversion
-- can drop in tests/content_<mod>/facts.lua, point the same suites at it,
-- and keep the pinned-value style without touching the engine tier.
--
-- This is deliberately not a copy of every assertion in run_tests.lua:
-- it is the machine-readable spine that new content assertions are written
-- against, so the pinned numbers live in one reviewable place.

return {
  -- Data:load must produce these before anything else is meaningful
  requiredModules = {
    "constants", "maps", "tilesets", "text", "text_pointers",
    "trainer_headers", "font", "sprites", "pokemon", "moves", "items",
    "type_chart", "trainers", "encounters", "field", "battle_anims",
  },

  dexSize = 151,
  typeCount = 15,

  -- map dimensions in cells (MapLoader reports widthCells/heightCells)
  maps = {
    PALLET_TOWN = { widthCells = 20, heightCells = 18 },
    VIRIDIAN_CITY = { widthCells = 40, heightCells = 36 },
    OAKS_LAB = { widthCells = 10, heightCells = 12 },
  },

  -- known walkability and warp ground truth in Pallet Town
  pallet = {
    spawn = { x = 5, y = 6 },
    walkable = { { 5, 6 }, { 5, 5 } },
    blocked = { { 4, 4 }, { 0, 3 } },
    doorWarp = { x = 5, y = 5, destMap = "REDS_HOUSE_1F" },
    oakSign = { x = 13, y = 13, text = "TEXT_PALLETTOWN_OAKSLAB_SIGN" },
  },

  -- the starter trio and their level-5 stats at zero DVs.  DVs must be
  -- pinned or the numbers move: Pokemon.new rolls them, so these are
  -- Stats.calc against an explicit zero set, the same way the behavior
  -- suite's fixedMon does it.
  starters = {
    BULBASAUR = { dex = 1, types = { "GRASS", "POISON" },
                  statsAt5 = { hp = 19, attack = 9, defense = 9, speed = 9, special = 11 } },
    CHARMANDER = { dex = 4, types = { "FIRE" },
                  statsAt5 = { hp = 18, attack = 10, defense = 9, speed = 11, special = 10 } },
    SQUIRTLE = { dex = 7, types = { "WATER" },
                  statsAt5 = { hp = 19, attack = 9, defense = 11, speed = 9, special = 10 } },
  },

  -- party-icon dex mapping (data/icon_pointers.asm)
  icons = {
    [1] = "GRASS", [10] = "BUG", [19] = "QUADRUPED", [23] = "SNAKE",
  },

  -- the engine's own fallback move and the HM set
  fallbackMove = "TACKLE",
  hmMoves = { "CUT", "FLY", "SURF", "STRENGTH", "FLASH" },

  badges = {
    "BOULDERBADGE", "CASCADEBADGE", "THUNDERBADGE", "RAINBOWBADGE",
    "SOULBADGE", "MARSHBADGE", "VOLCANOBADGE", "EARTHBADGE",
  },

  -- the shipped example mod and what it is supposed to do
  exampleMod = {
    path = "mods/example_mew_starter",
    id = "example_mew_starter",
    species = "MEW",
    frontSprite = "mods/example_mew_starter/assets/mew_front_inverted.png",
    backSprite = "mods/example_mew_starter/assets/mew_back_inverted.png",
  },
}
