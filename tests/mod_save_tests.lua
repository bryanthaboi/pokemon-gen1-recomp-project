-- Save data and migrations: the data-only serializer grammar, the meta
-- stamp, atomic write recovery, the migration registry (core steps + mod
-- chains), the validation/quarantine pass and the per-mod persistence
-- namespaces.  Self-contained: own bootstrap, assert-based checks,
-- error() on any failure.
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local SaveSerializer = require("src.core.SaveSerializer")
local SaveData = require("src.core.SaveData")
local Version = require("src.core.Version")
local Runtime = require("src.mods.Runtime")
local Events = require("src.mods.Events")
local Hooks = require("src.mods.Hooks")
local Game = require("src.core.Game")

local S = require("tests.harness").suite("mod save")
local check = S.check

local function deepEqual(a, b, path)
  path = path or "root"
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false, path end
  for k, v in pairs(a) do
    local ok, where = deepEqual(v, b[k], path .. "." .. tostring(k))
    if not ok then return false, where end
  end
  for k in pairs(b) do
    if a[k] == nil then return false, path .. "." .. tostring(k) end
  end
  return true
end

-- a swappable love.filesystem so every write/read below is isolated from
-- the shared stub state other suites touch; remove included, so the
-- atomic-write sequence runs exactly as it does under real LOVE
local function memfs(files)
  return {
    files = files,
    write = function(path, content) files[path] = content return true end,
    read = function(path) return files[path] end,
    remove = function(path) files[path] = nil return true end,
    getInfo = function(path)
      if files[path] then return { type = "file" } end
      return nil
    end,
  }
end

-- ---------------------------------------------- serializer grammar

do
  local rich = {
    money = 3000,
    frac = 0.125,
    neg = -42,
    big = 1e+300,
    flag = true,
    off = false,
    name = 'quo"te [bra{ck}et]\nline2\ttab',
    ctrl = "a\r\0b",
    list = { "x", "y" },
    nested = { deep = { er = { level = 4 } } },
    [1] = "numkey",
    [2.5] = "floatkey",
    [true] = "boolkey",
  }
  local encoded = SaveSerializer.encode(rich)
  local back, err = SaveSerializer.decode(encoded)
  check(back, "rich table decodes: " .. tostring(err))
  local same, where = deepEqual(rich, back)
  check(same, "rich table round-trips exactly (differs at " .. tostring(where) .. ")")
  check(SaveSerializer.encode(back) == encoded, "re-encode is byte-identical")

  -- the reader accepts exactly what the old load()-based decode accepted
  -- for writer output: same table, byte for byte
  local chunk = assert((loadstring or load)(encoded))
  local viaLoad = chunk()
  same, where = deepEqual(viaLoad, back)
  check(same, "safe parse matches load()-based decode (differs at " .. tostring(where) .. ")")
end

do
  -- code never executes: each of these fails with a byte offset instead
  local hostile = {
    'os.execute("rm -rf /")',
    'return ("x"):rep(9)',
    "return setmetatable({}, {})",
    "return { x = evil() }",
    "return 1 + 1",
    "return { f = function() end }",
    "return {} return {}",
    "return { [os.time()] = 1 }",
    "return { x = nil }",
    "not lua {{{",
  }
  for _, src in ipairs(hostile) do
    local out, err = SaveSerializer.decode(src)
    check(out == nil, "rejected: " .. src)
    check(type(err) == "string", "error string for: " .. src)
  end
  check(select(2, SaveSerializer.decode("return { x = evil() }")):match("byte %d+"),
    "parse errors carry a byte offset")
  local out = SaveSerializer.decode('return 5\n')
  check(out == nil, "non-table root rejected")
  -- a brace bomb fails closed instead of blowing the stack
  local bomb = "return " .. ("{ a = "):rep(4000) .. "1" .. (" }"):rep(4000)
  check(SaveSerializer.decode(bomb) == nil, "deep nesting fails closed")
end

-- ---------------------------------------------- meta stamp + atomic write

local realFS = love.filesystem

do
  local files = {}
  love.filesystem = memfs(files)

  local mods = {
    { id = "zeta_mod", version = "0.4.1", api = 2 },
    { id = "alpha_mod", version = "1.2.0", api = 2 },
  }
  local save = SaveData.newGame()
  save.money = 111
  check(SaveData.save(save, mods), "stamped save writes")
  local written = SaveSerializer.decode(files["save.lua"])
  check(written.meta.format == Version.saveFormat, "meta.format stamped")
  check(written.meta.engine == Version.engine, "meta.engine stamped")
  check(type(written.meta.savedAt) == "number", "meta.savedAt stamped")
  check(written.meta.mods[1].id == "alpha_mod" and written.meta.mods[2].id == "zeta_mod",
    "meta.mods sorted by id")
  check(written.meta.mods[2].version == "0.4.1", "meta.mods carries versions")
  check(files["save.lua.tmp"] == nil, "clean write leaves no .tmp")
  check(files["save.lua.bak"] == nil, "first write has nothing to back up")

  -- second write rolls the previous save into the .bak
  save.money = 222
  check(SaveData.save(save, mods), "second save writes")
  local bak = SaveSerializer.decode(files["save.lua.bak"])
  check(bak.money == 111, "backup holds the previous save")

  -- a headless writer with no mod list keeps the stored mod set
  save.money = 333
  check(SaveData.save(save), "modless save keeps stamping")
  written = SaveSerializer.decode(files["save.lua"])
  check(#written.meta.mods == 2, "nil mods list preserves the stored set")

  -- corrupt main file: load promotes the .bak (no .tmp survives a clean
  -- write) and heals save.lua
  files["save.lua"] = "return { hacked = os.execute }"
  local loaded, recovered = SaveData.load()
  check(loaded and loaded.money == 222, "load recovers from .bak")
  check(recovered == "bak", "recovery source reported")
  check(SaveSerializer.decode(files["save.lua"]).money == 222,
    "recovered bytes are written back to save.lua")

  -- crash between remove and rewrite: only the .tmp holds the new bytes
  files["save.lua.tmp"] = SaveSerializer.encode({ money = 444, player = {} })
  files["save.lua"] = nil
  loaded, recovered = SaveData.load()
  check(loaded and loaded.money == 444, "load promotes the .tmp witness")
  check(recovered == "tmp", "tmp recovery reported")

  -- everything corrupt or gone: load gives up cleanly
  files["save.lua"] = "junk("
  files["save.lua.tmp"] = "junk("
  files["save.lua.bak"] = "junk("
  check(SaveData.load() == nil, "unrecoverable save returns nil")

  love.filesystem = realFS
end

-- ---------------------------------------------- core migrations

do
  local files = {}
  love.filesystem = memfs(files)

  -- a pre-meta (format 1) save with every legacy shape at once
  local legacy = {
    player = { map = "PALLET_TOWN", x = 5, y = 6, facing = "down", name = "RED" },
    flags = {},
    objectToggles = { ROUTE_12 = { ROUTE12_SNORLAX = false } },
    box = { { species = "PIDGEY", level = 3 } },
    options = { musicVol = 2 },
    inventory = {},
    party = {},
    money = 100,
  }
  files["save.lua"] = SaveSerializer.encode(legacy)
  local loaded = SaveData.load()
  check(loaded, "format-1 save loads")
  check(type(loaded.player.id) == "number", "player.id backfilled")
  check(loaded.flags.EVENT_BEAT_ROUTE12_SNORLAX == true, "Snorlax flag backfilled from toggle")
  check(loaded.meta and loaded.meta.format == Version.saveFormat, "meta.format landed at current")
  check(#loaded.meta.mods == 0, "old vanilla save records an empty mod set")
  check(loaded.boxes and loaded.boxes[1][1].species == "PIDGEY", "box list folded into boxes[1]")
  check(loaded.box == nil, "legacy box key gone")
  check(loaded.version == "red", "untagged save defaults to the Red version")
  local opts = SaveSerializer.decode(files["options.lua"])
  check(opts and opts.musicVol == 2, "embedded options split into options.lua")

  -- a save already at the current format skips every core step
  local current = { meta = { format = Version.saveFormat, mods = {} },
                    player = { map = "PALLET_TOWN", x = 1, y = 1 } }
  SaveData.runMigrations(current)
  check(current.player.id == nil, "current-format save skips the id backfill")

  -- a format-2 save (Blue support not yet shipped) gains the Red tag;
  -- a save that already names a version keeps it
  local untagged = { meta = { format = 2, mods = {} }, player = {} }
  SaveData.runMigrations(untagged)
  check(untagged.version == "red", "pre-version save defaults to Red")
  local tagged = { meta = { format = 2, mods = {} }, version = "blue", player = {} }
  SaveData.runMigrations(tagged)
  check(tagged.version == "blue", "an existing version tag is left untouched")

  love.filesystem = realFS
end

-- ---------------------------------------------- mod migration chains

do
  local ran = {}
  local chains = {
    weather = {
      { since = "1.0.0", apply = function(modSave) ran[#ran + 1] = "1.0.0"; modSave.v = 2 end },
      { since = "0.9.5", apply = function(modSave) ran[#ran + 1] = "0.9.5"; modSave.v = 1 end },
    },
  }
  local active = { { id = "weather", version = "1.0.0" } }
  local save = {
    meta = { format = Version.saveFormat,
             mods = { { id = "weather", version = "0.9.0" } } },
    modData = { weather = { v = 0 } },
  }
  SaveData.runMigrations(save, chains, active)
  check(#ran == 2 and ran[1] == "0.9.5" and ran[2] == "1.0.0",
    "chain replays in semver order from the stored version")
  check(save.modData.weather.v == 2, "migrations mutate the mod's namespace")

  -- stored == current: nothing to replay
  ran = {}
  save.meta.mods[1].version = "1.0.0"
  SaveData.runMigrations(save, chains, active)
  check(#ran == 0, "up-to-date mod replays nothing")

  -- current version caps the chain
  ran = {}
  save.meta.mods[1].version = "0.9.0"
  SaveData.runMigrations(save, chains, { { id = "weather", version = "0.9.5" } })
  check(#ran == 1 and ran[1] == "0.9.5", "steps past the current version stay dormant")

  -- no modData: nothing to migrate, nothing crashes
  SaveData.runMigrations({ meta = { format = 2, mods = {} } }, chains, active)
end

-- ---------------------------------------------- validation and quarantine

-- the merged view validation folds against, tiny on purpose
local function fixtureData()
  return {
    pokemon = { PIDGEY = { dex = 16 }, RATTATA = { dex = 19 } },
    moves = { TACKLE = { pp = 35 }, GUST = { pp = 35 } },
    items = { POTION = {}, POKE_BALL = {} },
    maps = { TOWN = {}, HOUSE = {} },
    constants = { fallbackMove = "TACKLE" },
    field = { boot = { startMap = "TOWN", startX = 1, startY = 2 } },
  }
end

do
  local data = fixtureData()
  local save = {
    player = { map = "GONE_MAP", x = 9, y = 9, facing = "down", id = 7 },
    party = {
      { species = "PIDGEY", level = 5, dvs = { attack = 20 },
        moves = { { id = "GUST", pp = 10 }, { id = "MODMOVE", pp = 5 } } },
      { species = "MODMON", level = 12 },
    },
    boxes = { { { species = "MODMON2", level = 3 } }, {} },
    daycare = { mon = { species = "MODMON3", level = 8 }, steps = 4 },
    inventory = { POTION = 2, MODITEM = 3 },
    pcItems = { MODITEM2 = 1 },
    bagOrder = { "POTION", "MODITEM" },
    lastHeal = { map = "GONE_HEAL", x = 1, y = 1 },
    lastOutdoor = { id = "GONE_MAP", x = 2, y = 2 },
    pokedex = { seen = { PIDGEY = true, MODMON = true }, owned = { PIDGEY = true } },
    hallOfFame = { { { species = "MODMON", level = 50 }, { species = "PIDGEY", level = 40 } } },
  }
  local report = SaveData.validate(save, data)

  check(#save.party == 1 and save.party[1].species == "PIDGEY",
    "unknown party species quarantined")
  check(#save.boxes[1] == 0, "unknown box species quarantined")
  check(save.daycare.mon == nil, "unknown daycare species quarantined")
  check(#save.orphaned.mons == 3, "all three mons kept in the LOST box")
  check(#report.lostMons == 3, "lost mons reported")
  check(save.party[1].dvs.attack == 15, "out-of-range dv clamped")
  check(#save.party[1].moves == 1 and save.party[1].moves[1].id == "GUST",
    "unknown move slot dropped")
  check(save.inventory.MODITEM == nil and save.inventory.POTION == 2,
    "unknown item removed, known kept")
  check(save.pcItems.MODITEM2 == nil, "unknown pc item removed")
  check(#report.lostItems == 2, "removed items reported")
  check(#save.bagOrder == 1 and save.bagOrder[1] == "POTION", "bag order pruned")
  check(save.lastHeal.map == "TOWN" and save.lastHeal.x == 1 and save.lastHeal.y == 2,
    "unknown heal map falls back to the boot spawn")
  check(save.player.map == "TOWN", "unknown player map falls back to the heal point")
  check(save.lastOutdoor == nil, "unknown lastOutdoor dropped")
  check(#report.remappedMaps == 3, "map fallbacks reported")
  check(save.pokedex.seen.MODMON == nil and save.pokedex.seen.PIDGEY == true,
    "unknown dex entry dropped")
  check(#save.hallOfFame[1] == 2, "hall of fame roster keeps its size")
  check(save.hallOfFame[1][1].species == nil and save.hallOfFame[1][1].level == 50,
    "unknown hall of fame species blanked in place")
  check(save.hallOfFame[1][2].species == "PIDGEY", "known hall of fame mon untouched")
  check(not SaveData.emptyReport(report), "report is non-empty")

  -- a mon whose whole moveset vanished heals with the data-driven fallback
  local wiped = { player = { map = "TOWN" },
                  party = { { species = "RATTATA", level = 4,
                              moves = { { id = "MODMOVE", pp = 1 } } } } }
  SaveData.validate(wiped, data)
  check(wiped.party[1].moves[1].id == "TACKLE" and wiped.party[1].moves[1].pp == 35,
    "emptied moveset repaired with constants.fallbackMove")

  -- the mod comes back: quarantine reverses on the next load
  data.pokemon.MODMON = { dex = 152 }
  data.items.MODITEM = {}
  local report2 = SaveData.validate(save, data)
  check(#report2.restoredMons == 1, "returned species reclaimed")
  local found
  for _, box in ipairs(save.boxes) do
    for _, mon in ipairs(box) do
      if mon.species == "MODMON" then found = true end
    end
  end
  check(found, "reclaimed mon deposited into the PC")
  check(#save.orphaned.mons == 2, "still-unknown mons stay quarantined")
  check(save.inventory.MODITEM == 3, "returned item reclaimed into the bag")
end

do
  -- vanilla parity: a clean save is returned untouched, byte for byte
  local data = fixtureData()
  local save = {
    meta = { format = Version.saveFormat, mods = {} },
    player = { map = "TOWN", x = 1, y = 2, facing = "down", id = 7, name = "RED" },
    party = { { species = "PIDGEY", level = 5,
                dvs = { attack = 10, hp = 4 },
                statExp = { attack = 100 },
                moves = { { id = "GUST", pp = 10 } } } },
    inventory = { POTION = 1 },
    bagOrder = { "POTION" },
    lastHeal = { map = "TOWN", x = 1, y = 2 },
    pokedex = { seen = { PIDGEY = true }, owned = {} },
    modData = {},
    money = 3000,
  }
  local before = SaveSerializer.encode(save)
  local report = SaveData.validate(save, data)
  check(SaveData.emptyReport(report), "clean save yields an empty report")
  check(save.orphaned == nil, "no orphaned residue on a clean save")
  check(SaveSerializer.encode(save) == before, "clean save re-encodes byte-identically")
end

-- ---------------------------------------------- migrate before validate

do
  -- a mod that renamed a species repairs its data before the scrub, so
  -- nothing lands in quarantine on upgrade
  local data = fixtureData()
  data.pokemon.PIDGEY_MOD = { dex = 300 }
  local save = {
    meta = { format = Version.saveFormat,
             mods = { { id = "renamer", version = "1.0.0" } } },
    player = { map = "TOWN" },
    party = { { species = "OLD_PIDGEY", level = 9 } },
    modData = { renamer = {} },
  }
  local chains = { renamer = { { since = "1.1.0", apply = function(_, s)
    for _, mon in ipairs(s.party) do
      if mon.species == "OLD_PIDGEY" then mon.species = "PIDGEY_MOD" end
    end
  end } } }
  SaveData.runMigrations(save, chains, { { id = "renamer", version = "1.1.0" } })
  local report = SaveData.validate(save, data)
  check(save.party[1].species == "PIDGEY_MOD", "migration renamed the species")
  check(#report.lostMons == 0, "migrated mon is never quarantined")
end

-- ---------------------------------------------- mod-set diff

do
  local save = { meta = { format = 2, mods = {
    { id = "kept", version = "1.0.0" },
    { id = "gone", version = "2.0.0" },
    { id = "bumped", version = "1.0.0" },
  } } }
  local diff = SaveData.modsDiff(save, {
    { id = "kept", version = "1.0.0" },
    { id = "bumped", version = "1.1.0" },
    { id = "fresh", version = "0.1.0" },
  })
  check(#diff.added == 1 and diff.added[1] == "fresh", "added mod detected")
  check(#diff.removed == 1 and diff.removed[1] == "gone", "removed mod detected")
  check(#diff.changed == 1 and diff.changed[1].id == "bumped"
    and diff.changed[1].from == "1.0.0" and diff.changed[1].to == "1.1.0",
    "version change detected")
  local clean = SaveData.modsDiff({ meta = { mods = {} } }, {})
  check(#clean.added == 0 and #clean.removed == 0 and #clean.changed == 0,
    "vanilla diff is empty")
end

do
  -- a mod-set diff with nothing quarantined must still surface the report
  local report = { lostMons = {}, lostItems = {}, remappedMaps = {},
                   restoredMons = {}, restoredItems = {} }
  check(SaveData.emptyReport(report), "diff-less report stays empty")
  report.modsDiff = { added = {}, removed = {}, changed = {} }
  check(SaveData.emptyReport(report), "empty diff keeps the report empty")
  report.modsDiff.changed = { { id = "bumped", from = "1.0.0", to = "1.1.0" } }
  check(not SaveData.emptyReport(report), "version bump alone makes the report non-empty")
  report.modsDiff.changed = {}
  report.modsDiff.removed = { "gone" }
  check(not SaveData.emptyReport(report), "removed mod alone makes the report non-empty")

  local meta = { mods = { { id = "kept", version = "1.0.0" },
                          { id = "gone", version = "2.0.0" } } }
  check(SaveData.modsDiffNotice({ added = {}, removed = { "gone" }, changed = {} }, meta)
      == "This save was made with 2 mods; 1 is no longer active",
    "removed-mod notice matches the design line")
  check(SaveData.modsDiffNotice(
      { added = { "fresh" }, removed = { "gone", "gone2" },
        changed = { { id = "bumped", from = "1.0.0", to = "1.1.0" } } }, meta)
      == "This save was made with 2 mods; 2 are no longer active, 1 changed version, 1 newly active",
    "notice lists every category")
  check(SaveData.modsDiffNotice({ added = {}, removed = {}, changed = {} }, meta) == nil,
    "empty diff yields no notice")
  check(SaveData.modsDiffNotice(nil, meta) == nil, "nil diff yields no notice")
end

-- ---------------------------------------------- per-mod namespaces

do
  -- adoptSave points the loader's mod.save backing at save.modData
  local loader = { modSave = { seeded_mod = { counter = 7 } } }
  local game = { mods = loader, adoptSave = Game.adoptSave }
  local boot = {}
  game:adoptSave(boot, true)
  check(boot.modData.seeded_mod.counter == 7, "entry-time buckets seed the boot skeleton")
  check(loader.modSave == boot.modData, "loader backing aliases save.modData")

  -- writes through the alias land in the save and survive the serializer
  loader.modSave.seeded_mod.counter = 8
  local back = SaveSerializer.decode(SaveSerializer.encode(boot))
  check(back.modData.seeded_mod.counter == 8, "mod.save state persists with the save")

  -- NEW GAME replaces the backing without leaking the old session
  local fresh = { modData = {} }
  game:adoptSave(fresh)
  check(fresh.modData.seeded_mod == nil, "no bucket carry-over into a fresh slot")
  check(loader.modSave == fresh.modData, "backing follows the new save")

  -- CONTINUE points the backing at the loaded save's persisted state
  local restored = { modData = { seeded_mod = { counter = 99 } } }
  game:adoptSave(restored)
  check(loader.modSave.seeded_mod.counter == 99, "loaded modData becomes the backing")

  -- a loader-less game still normalizes the namespace
  local bare = { adoptSave = Game.adoptSave }
  local plain = {}
  bare:adoptSave(plain)
  check(type(plain.modData) == "table", "modData exists without a loader")
end

do
  -- modOptions round-trips deeply: a partial write keeps sibling mods
  local files = {}
  local fs = memfs(files)
  SaveData.saveOptions({ modOptions = { alpha = { x = 1, keep = true } } }, fs)
  SaveData.saveOptions({ modOptions = { beta = { y = 2 } } }, fs)
  SaveData.saveOptions({ modOptions = { alpha = { x = 5 } } }, fs)
  local opts = SaveData.loadOptions(fs)
  check(opts.modOptions.alpha.x == 5, "newest value wins per key")
  check(opts.modOptions.alpha.keep == true, "sibling keys survive a partial write")
  check(opts.modOptions.beta.y == 2, "sibling mods survive a partial write")

  -- vanilla options never grow a modOptions key
  local vfiles = {}
  local vfs = memfs(vfiles)
  SaveData.saveOptions(SaveData.defaultOptions(), vfs)
  check(vfiles["options.lua"]:find("modOptions", 1, true) == nil,
    "vanilla options.lua carries no modOptions")
end

-- ---------------------------------------------- save lifecycle wiring

do
  -- save.created seeds a subtable through the live bus; save.new_game
  -- reshapes the skeleton; both are no-ops unhooked
  local priorEvents, priorHooks, priorErrors =
    Runtime.events, Runtime.hooks, Runtime.errors
  local events, hooks = Events.new(), Hooks.new()
  Runtime.install(events, hooks, {})

  local files = {}
  love.filesystem = memfs(files)

  hooks:wrap("save.new_game", function(nextFn, save)
    local out = nextFn(save)
    out.money = 9999
    return out
  end, nil, "tc_mod")
  events:on("save.created", function(ev)
    ev.save.modData.weather = { forecast = "rain" }
  end, nil, "weather_mod")

  local save = SaveData.newGame({ startMap = "TOWN", startX = 3, startY = 4 })
  check(save.money == 9999, "save.new_game hook reshapes the skeleton")
  check(save.player.map == "TOWN" and save.player.x == 3, "field.boot spawn threads through")

  -- the emit sites in Game fire save.created with { save = ... }
  Runtime.emit("save.created", { save = save })
  check(save.modData.weather.forecast == "rain",
    "save.created listener seeds a save subtable")

  Runtime.install(priorEvents, priorHooks, priorErrors)
  love.filesystem = realFS

  -- unhooked parity: the skeleton comes back vanilla
  local plain = SaveData.newGame()
  check(plain.money == 3000, "unhooked newGame is vanilla")
  check(type(plain.modData) == "table" and next(plain.modData) == nil,
    "newGame starts an empty modData")
  check(plain.meta.format == Version.saveFormat and #plain.meta.mods == 0,
    "newGame stamps a vanilla meta")
  check(plain.pcItems and plain.pcItems.POTION == 1,
    "unhooked newGame seeds 1 Potion in pcItems (issue #109)")
end

-- issue #109: loading a pre-fix save that never had pcItems must not
-- invent a free Potion (player may already have withdrawn/tossed it, or
-- the empty PC is intentional).  Seeding is New Game only.
do
  local files = {}
  love.filesystem = memfs(files)
  local legacy = {
    meta = { format = Version.saveFormat, mods = {} },
    player = { map = "PALLET_TOWN", x = 5, y = 6, facing = "down",
               name = "RED", rival = "BLUE", id = 1 },
    flags = {}, inventory = {}, party = {}, box = {}, money = 3000,
    defeatedTrainers = {}, pokedex = { seen = {}, owned = {} },
    lastHeal = { map = "PALLET_TOWN", x = 5, y = 6 },
    options = SaveData.defaultOptions(),
  }
  check(legacy.pcItems == nil, "fixture omits pcItems on purpose")
  check(SaveData.save(legacy), "legacy save without pcItems writes")
  local loaded = SaveData.load()
  check(loaded ~= nil, "legacy save loads")
  check(loaded.pcItems == nil or loaded.pcItems.POTION == nil,
    "load does not invent a PC Potion for existing saves")
  love.filesystem = realFS
end

-- a throwing mod migration is skipped, never fatal: an uncaught error here
-- re-raises on every load and locks the player out of the save
do
  local save = {
    meta = { format = Version.saveFormat, mods = {
      { id = "buggy", version = "1.0.0" }, { id = "good", version = "1.0.0" } } },
    modData = { buggy = {}, good = {} },
  }
  local chains = {
    buggy = { { since = "1.1.0", apply = function() error("migration bug") end },
              { since = "1.2.0", apply = function(ms) ms.reached = true end } },
    good = { { since = "1.1.0", apply = function(ms) ms.migrated = true end } },
  }
  local active = { { id = "buggy", version = "2.0.0" }, { id = "good", version = "2.0.0" } }
  local ok = pcall(SaveData.runMigrations, save, chains, active)
  check(ok, "a throwing mod migration does not fail the load")
  check(save.modData.buggy.reached == nil,
    "the rest of a failed migration chain is skipped")
  check(save.modData.good.migrated == true,
    "one mod's failed migration does not block another mod's")
end

S.finish()
