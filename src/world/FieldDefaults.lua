-- Vanilla values for the data.field / Data.constants keys this milestone
-- lifts out of src/world/ literals.  The importer does not stamp them yet,
-- so every read site folds its own table over these and behaves exactly as
-- the literal did on a stale cache; seed() fills the gaps in Data before
-- the mod merge so a mod's patch has a vanilla base to merge over instead
-- of replacing Kanto wholesale.
-- Pure Lua, no love.*, so the headless loader and offline tools can require it.

local FieldDefaults = {}

-- ------- data.field

-- SGB overworld palette (engine/gfx/palettes.asm SetPal_Overworld): towns
-- own theirs, routes PAL_ROUTE, interiors inherit the last outdoor map,
-- with the Pokemon Tower / cave tileset and Elite Four cases on top.
local PALETTES = {
  byMap = {
    PALLET_TOWN = "PALLET", VIRIDIAN_CITY = "VIRIDIAN",
    PEWTER_CITY = "PEWTER", CERULEAN_CITY = "CERULEAN",
    LAVENDER_TOWN = "LAVENDER", VERMILION_CITY = "VERMILION",
    CELADON_CITY = "CELADON", FUCHSIA_CITY = "FUCHSIA",
    CINNABAR_ISLAND = "CINNABAR", INDIGO_PLATEAU = "INDIGO",
    SAFFRON_CITY = "SAFFRON",
    LORELEIS_ROOM = "PALLET", BRUNOS_ROOM = "CAVE",
  },
  -- Pokemon Tower / Agatha, then the caves
  byTileset = { CEMETERY = "GRAYMON", CAVERN = "CAVE" },
  byPrefix = { { prefix = "ROUTE_", palette = "ROUTE" } },
  default = "ROUTE",
}

-- data/tilesets/bookshelf_tile_ids.asm: tileset id + collision tile ->
-- what facing up into it prints.  `kind` names an engine flavor (the
-- vanilla five); mods author `text` (a data.text key) or `screen`
-- (a screens-registry id) instead.
local BOOKSHELVES = {
  PLATEAU = { [0x30] = { kind = "statues" } },
  HOUSE = { [0x3D] = { screen = "TownMap" }, [0x1E] = { kind = "books" } },
  MANSION = { [0x32] = { kind = "books" } },
  REDS_HOUSE_1 = { [0x32] = { kind = "books" } },
  LAB = { [0x28] = { kind = "books" } },
  LOBBY = { [0x16] = { kind = "elevator" }, [0x50] = { kind = "stuff" },
            [0x52] = { kind = "stuff" } },
  GYM = { [0x1D] = { kind = "books" } },
  DOJO = { [0x1D] = { kind = "books" } },
  GATE = { [0x22] = { kind = "books" } },
  MART = { [0x54] = { kind = "stuff" }, [0x55] = { kind = "stuff" } },
  POKECENTER = { [0x54] = { kind = "stuff" }, [0x55] = { kind = "stuff" } },
  SHIP = { [0x36] = { kind = "books" } },
}

-- Rod tables (item_effects.asm ItemUseOldRod/GoodRod, data/wild/good_rod.asm).
-- The rejection-loop odds stay engine behavior: they are Gen-1 mechanics,
-- not content.  perMap names the field key holding the per-map groups.
local FISHING = {
  OLD_ROD = { always = { species = "MAGIKARP", level = 5 } },
  GOOD_ROD = { pool = { { species = "GOLDEEN", level = 10 },
                        { species = "POLIWAG", level = 10 } } },
  SUPER_ROD = { perMap = "superRod" },
}

-- The step counter gates on EVENT_IN_SAFARI_ZONE, not the map, so every
-- interior counts and the gate itself never does (home/overworld.asm).
local SAFARI = {
  stepMaps = {
    "SAFARI_ZONE_CENTER", "SAFARI_ZONE_EAST",
    "SAFARI_ZONE_NORTH", "SAFARI_ZONE_WEST",
    "SAFARI_ZONE_CENTER_REST_HOUSE", "SAFARI_ZONE_EAST_REST_HOUSE",
    "SAFARI_ZONE_NORTH_REST_HOUSE", "SAFARI_ZONE_WEST_REST_HOUSE",
    "SAFARI_ZONE_SECRET_HOUSE",
  },
  exitWarp = { map = "SAFARI_ZONE_GATE", x = 4, y = 3, facing = "down" },
}

-- home/overworld.asm LoadPlayerSpriteGraphics / LoadSurfingPlayerSprite-
-- Graphics / player_animations.asm LoadBirdSpriteGraphics
local PLAYER_SPRITES = {
  walk = "SPRITE_RED", surf = "SPRITE_SEEL",
  bike = "SPRITE_RED_BIKE", fly = "SPRITE_BIRD",
}

-- Route22Gate_Script rewrites wLastMap from the player's Y every frame, so
-- the north exit leaves onto Route 23 and the south onto Route 22.  Rules
-- are ordered, first match wins, the last row is the default.
local LAST_MAP_REWRITES = {
  ROUTE_22_GATE = { axis = "y", rules = { { below = 4, map = "ROUTE_23" },
                                          { map = "ROUTE_22" } } },
}

FieldDefaults.FIELD = {
  palettes = PALETTES,
  bookshelves = BOOKSHELVES,
  fishing = FISHING,
  safari = SAFARI,
  playerSprites = PLAYER_SPRITES,
  lastMapRewrites = LAST_MAP_REWRITES,
  -- CheckIfInOutsideMap: what counts as "outside" for the wLastMap memory
  outsideTilesets = { "OVERWORLD", "PLATEAU" },
  -- the Route 16/18 gate scripts `res BIT_ALWAYS_ON_BIKE` every frame
  forcedMovement = { clearMaps = { "ROUTE_16_GATE_1F", "ROUTE_18_GATE_1F" } },
  -- the one-shot flag the gate's pass text is gated on; a gate a mod adds
  -- gets "PASSED_<mapId>" instead of this pre-v2 spelling
  badgeGates = { ROUTE_22_GATE = { passedFlag = "PASSED_ROUTE22_GATE" } },
  -- VermilionGymSetDoorTile opens the motorized door once both locks are hit
  hiddenExtras = {
    trashCans = { map = "VERMILION_GYM",
                  doorBlock = { bx = 2, by = 2, block = 5 } },
  },
  -- IsSurfingAllowed refuses SURF on the B4F stairs square until both
  -- plug boulders are down (engine/overworld/field_move_messages.asm)
  seafoam = {
    SEAFOAM_ISLANDS_B4F = {
      surfBlocked = { { x = 7, y = 11, untilEvents = {
        "EVENT_SEAFOAM4_BOULDER1_DOWN_HOLE",
        "EVENT_SEAFOAM4_BOULDER2_DOWN_HOLE" } } },
    },
  },
}

-- ------- Data.constants

FieldDefaults.CONSTANTS = {
  world = {
    poisonStepInterval = 4,   -- ApplyOutOfBattlePoisonDamage
    poisonDamage = 1,
    blackoutMoneyDivisor = 2,
    daycareExpPerStep = 1,
    neighborHops = 2,         -- connection hops drawn around the current map
    stepFrames = 16,          -- 1px per frame, 16 frames per tile
    bikeStepFrames = 8,       -- the bicycle doubles walking speed
    turnFrames = 2,           -- the extra OverworldLoop pass after a turn
  },
  -- cumulative slot thresholds out of 256 (engine/battle/wild_encounters.asm)
  encounterBuckets = { 51, 102, 141, 166, 191, 216, 229, 242, 253, 256 },
  -- the badge each HM's field move is gated on; distinct from
  -- constants.hmMoves, which is the forget-gate move set
  hmBadges = {
    CUT = { badge = "CASCADEBADGE" }, SURF = { badge = "SOULBADGE" },
    STRENGTH = { badge = "RAINBOWBADGE" }, FLY = { badge = "THUNDERBADGE" },
    FLASH = { badge = "BOULDERBADGE" },
  },
}

-- ------- accessors

-- data.field[key] with the vanilla table as the stale-cache fallback
function FieldDefaults.field(data, key)
  local field = data and data.field
  local value = field and field[key]
  if value ~= nil then return value end
  return FieldDefaults.FIELD[key]
end

local function walk(node, n, ...)
  for i = 1, n do
    if type(node) ~= "table" then return nil end
    node = node[(select(i, ...))]
  end
  return node
end

-- one leaf inside a field sub-table, falling back per path so a cache that
-- stamps the record but not this key still resolves the vanilla value
function FieldDefaults.fieldValue(data, key, ...)
  local n = select("#", ...)
  local value = walk(data and data.field and data.field[key], n, ...)
  if value ~= nil then return value end
  return walk(FieldDefaults.FIELD[key], n, ...)
end

function FieldDefaults.constant(data, key)
  local constants = data and data.constants
  local value = constants and constants[key]
  if value ~= nil then return value end
  return FieldDefaults.CONSTANTS[key]
end

-- one world constant, falling back per key so a cache that stamps half of
-- constants.world still resolves the other half
function FieldDefaults.world(data, key)
  local world = data and data.constants and data.constants.world
  local value = world and world[key]
  if value ~= nil then return value end
  return FieldDefaults.CONSTANTS.world[key]
end

-- ------- seeding

-- fill-if-absent, never overwrite: an importer that learns to stamp one of
-- these silently takes over, and re-running is a no-op.  Lists are leaves.
local function fill(dst, src)
  for key, value in pairs(src) do
    if dst[key] == nil then
      if type(value) == "table" then
        local copy = {}
        fill(copy, value)
        dst[key] = copy
      else
        dst[key] = value
      end
    elseif type(value) == "table" and type(dst[key]) == "table"
        and #value == 0 then
      fill(dst[key], value)
    end
  end
end

-- Called before the mod merge (Data:seedDefaults): puts the vanilla values
-- in data.field / data.constants so mod.content.field:patch("palettes", ...)
-- deep-merges over Kanto instead of replacing it.
function FieldDefaults.seed(data)
  data.field = data.field or {}
  data.constants = data.constants or {}
  fill(data.field, FieldDefaults.FIELD)
  fill(data.constants, FieldDefaults.CONSTANTS)
  return data
end

return FieldDefaults
