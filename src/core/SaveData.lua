-- Save/load via love.filesystem.  Game progress lives in save.lua;
-- Options (audio, display, battle preferences) live in a separate
-- options.lua so they survive New Game and aren't tied to a save slot.
-- Both are plain Lua tables serialized as Lua source (deterministic
-- key order) and read back through SaveSerializer's data-only parser,
-- so a save can never execute code.
--
-- The load pipeline is read -> parse -> migrate -> validate/quarantine
-- -> restore; Game:restoreSave drives the last two phases with the
-- merged Data threaded in, because this module must not reach into
-- Data itself.

local Logger = require("src.core.Logger")
local Version = require("src.core.Version")
local SaveSerializer = require("src.core.SaveSerializer")
local Runtime = require("src.mods.Runtime")
local Semver = require("src.mods.Semver")
local Boxes = require("src.pokemon.Boxes")
local Bag = require("src.inventory.Bag")

local SaveData = {}

local FILENAME = "save.lua"
local OPTIONS_FILENAME = "options.lua"
-- one rolling backup plus the staged-write witness; load promotes either
-- when the main file is missing or fails to parse
local BACKUP_FILENAME = FILENAME .. ".bak"
local TMP_FILENAME = FILENAME .. ".tmp"

-- Port + original Options menu defaults.  Missing keys on load are filled
-- from this table so old options.lua files stay compatible.
function SaveData.defaultOptions()
  return {
    -- textSpeed 3 = MEDIUM, matching InitOptions' TEXT_DELAY_MEDIUM
    -- in wOptions (engine/menus/main_menu.asm)
    textSpeed = 3,
    animations = true,
    battleStyle = "shift",
    ruleset = "gen1_faithful",
    -- 0-7 like the GB's NR50 master volume
    musicVol = 7,
    sfxVol = 7,
    musicFilter = 0,
    -- port display options (OptionsMenu / hotkeys 2/3/5)
    colors = "gbc",
    tilt = 0,
    gbcfx = 0,
    -- Native mod enablement is an installation option, not save-slot data.
    -- Missing entries mean enabled so newly installed mods work by default.
    mods = {},
  }
end

-- Merge loaded keys over defaults (shallow).  Unknown keys are kept so
-- future options aren't dropped by older builds writing the file back.
function SaveData.mergeOptions(loaded)
  local opts = SaveData.defaultOptions()
  if type(loaded) == "table" then
    for k, v in pairs(loaded) do
      opts[k] = v
    end
  end
  return opts
end

function SaveData.encode(data)
  return SaveSerializer.encode(data)
end

function SaveData.decode(str)
  return SaveSerializer.decode(str)
end

local function readTable(fs, name)
  if not fs.getInfo(name) then return nil, "no file: " .. name end
  local body = fs.read(name)
  if type(body) ~= "string" then return nil, "unreadable: " .. name end
  return SaveSerializer.decode(body)
end

-- the stub filesystem some headless harnesses inject has no remove; a
-- lingering tmp/bak there is harmless
local function remove(fs, name)
  if fs.remove then fs.remove(name) end
end

-- ------- options

-- Both take an optional fs (write/getInfo/read) defaulting to
-- love.filesystem, so the mod loader's injected filesystem can carry the
-- options round-trip headless (no love global).
function SaveData.saveOptions(opts, fs)
  fs = fs or love.filesystem
  opts = SaveData.mergeOptions(opts)
  -- modOptions is per-mod nested state: fold the on-disk sub-tree
  -- underneath (newest value winning per key) so one caller's partial
  -- write cannot clobber another mod's persisted keys.  Every other
  -- option stays on the shallow path.
  local onDisk = readTable(fs, OPTIONS_FILENAME)
  if onDisk and type(onDisk.modOptions) == "table" then
    local merged = {}
    for modId, bucket in pairs(onDisk.modOptions) do
      merged[modId] = bucket
    end
    for modId, bucket in pairs(opts.modOptions or {}) do
      if type(bucket) == "table" and type(merged[modId]) == "table" then
        for k, v in pairs(bucket) do merged[modId][k] = v end
      else
        merged[modId] = bucket
      end
    end
    opts.modOptions = merged
  end
  local ok, err = fs.write(OPTIONS_FILENAME, SaveSerializer.encode(opts))
  if not ok then
    Logger.error("options save failed: %s", tostring(err))
  end
  return ok and opts or nil
end

function SaveData.loadOptions(fs)
  fs = fs or love.filesystem
  local data, err = readTable(fs, OPTIONS_FILENAME)
  if not data then
    if fs.getInfo(OPTIONS_FILENAME) then
      Logger.error("options load failed: %s", tostring(err))
    end
    return SaveData.defaultOptions()
  end
  return SaveData.mergeOptions(data)
end

-- ------- meta

-- the version/engine/mod-set stamp every v2 save carries; mods is the
-- loaded list sorted by id and is the ground truth for the load-time
-- mod-set diff.  A nil mods list keeps the previous stamp's set so a
-- headless writer (the save editor) never wipes it.
function SaveData.buildMeta(mods, previous)
  local list
  if mods ~= nil then
    list = {}
    for _, mod in ipairs(mods) do
      list[#list + 1] = { id = mod.id, version = mod.version, api = mod.api }
    end
    table.sort(list, function(a, b) return a.id < b.id end)
  else
    list = (type(previous) == "table" and previous.mods) or {}
  end
  return {
    format = Version.saveFormat,
    engine = Version.engine,
    savedAt = os.time(),
    mods = list,
  }
end

-- {added, removed, changed} between the set that wrote the save
-- (meta.mods) and the active loaded set; all three empty on a vanilla
-- load under vanilla
function SaveData.modsDiff(save, activeMods)
  local stored = {}
  for _, entry in ipairs((save.meta and save.meta.mods) or {}) do
    if type(entry) == "table" and entry.id then
      stored[entry.id] = entry.version or ""
    end
  end
  local diff = { added = {}, removed = {}, changed = {} }
  for _, mod in ipairs(activeMods or {}) do
    local was = stored[mod.id]
    if was == nil then
      diff.added[#diff.added + 1] = mod.id
    elseif was ~= mod.version then
      diff.changed[#diff.changed + 1] = { id = mod.id, from = was, to = mod.version }
    end
    stored[mod.id] = nil
  end
  for id in pairs(stored) do diff.removed[#diff.removed + 1] = id end
  table.sort(diff.added)
  table.sort(diff.removed)
  table.sort(diff.changed, function(a, b) return a.id < b.id end)
  return diff
end

-- one-line load notice for a non-empty diff ("This save was made with
-- 2 mods; 1 is no longer active"); nil when empty so a vanilla load
-- stays silent
function SaveData.modsDiffNotice(diff, meta)
  if type(diff) ~= "table" then return nil end
  local removed = #(diff.removed or {})
  local changed = #(diff.changed or {})
  local added = #(diff.added or {})
  if removed == 0 and changed == 0 and added == 0 then return nil end
  local wrote = #((type(meta) == "table" and meta.mods) or {})
  local parts = {}
  if removed > 0 then
    parts[#parts + 1] = removed .. (removed == 1 and " is" or " are") .. " no longer active"
  end
  if changed > 0 then
    parts[#parts + 1] = changed .. " changed version"
  end
  if added > 0 then
    parts[#parts + 1] = added .. " newly active"
  end
  return ("This save was made with %d mod%s; %s"):format(
    wrote, wrote == 1 and "" or "s", table.concat(parts, ", "))
end

-- ------- migrations

-- Ordered engine steps keyed on meta.format, each reproducing the inline
-- migration it replaced; a save already at the current format skips them
-- all.  Mod chains (recorded by Loader from mod.migrations:add) replay
-- against the version stored in meta.mods, in semver order, before the
-- validation pass -- so a mod repairs its own data instead of watching
-- it get quarantined.
local coreMigrations = {}

function SaveData.addCoreMigration(fromFormat, fn)
  coreMigrations[#coreMigrations + 1] =
    { from = fromFormat, seq = #coreMigrations + 1, fn = fn }
end

local function storedVersion(save, modId)
  for _, entry in ipairs((save.meta and save.meta.mods) or {}) do
    if type(entry) == "table" and entry.id == modId then
      return entry.version
    end
  end
  return nil
end

local function semverLt(a, b)
  local order = Semver.compare(a, b)
  return order ~= nil and order < 0
end

function SaveData.runMigrations(save, modChains, activeMods)
  table.sort(coreMigrations, function(a, b)
    if a.from ~= b.from then return a.from < b.from end
    return a.seq < b.seq
  end)
  -- every step whose from-format the save has not passed yet runs, in
  -- (from, registration) order; a save at the current format runs none
  local fmt = (save.meta and save.meta.format) or 1
  for _, m in ipairs(coreMigrations) do
    if m.from >= fmt then m.fn(save) end
  end
  -- a save that predates meta records an empty mod set: an old vanilla
  -- save becomes a v2 vanilla save
  save.meta = save.meta or { mods = {} }
  save.meta.format = Version.saveFormat
  for _, active in ipairs(activeMods or {}) do
    local modSave = save.modData and save.modData[active.id]
    local recorded = modChains and modChains[active.id]
    if modSave and recorded then
      local chain = {}
      for _, m in ipairs(recorded) do chain[#chain + 1] = m end
      table.sort(chain, function(a, b) return semverLt(a.since, b.since) end)
      local stored = storedVersion(save, active.id) or "0.0.0"
      for _, m in ipairs(chain) do
        if semverLt(stored, m.since) and not semverLt(active.version, m.since) then
          -- a throwing migration is skipped, not fatal: it would otherwise
          -- re-raise on every load and lock the player out of the save
          local ok, err = pcall(m.apply, modSave, save)
          if not ok then
            Logger.error("[%s] migration %s: %s -- skipped",
              active.id, tostring(m.since), tostring(err))
            break
          end
        end
      end
    end
  end
  return save
end

-- saves from before the trainer ID existed: backfill once on load
-- (like the OT backfill for old saves)
SaveData.addCoreMigration(1, function(save)
  if save.player and not save.player.id then
    save.player.id = math.random(0, 65535)
  end
end)

-- saves from before EVENT_BEAT_ROUTE12/16_SNORLAX existed: the object
-- was already hidden (Snorlax beaten) but the flag was never added,
-- and it can never be set again since the hidden object is
-- unreachable -- backfill it from the toggle so it isn't stuck forever
SaveData.addCoreMigration(1, function(save)
  if save.objectToggles and save.flags then
    local snorlaxRoutes = {
      { map = "ROUTE_12", obj = "ROUTE12_SNORLAX", flag = "EVENT_BEAT_ROUTE12_SNORLAX" },
      { map = "ROUTE_16", obj = "ROUTE16_SNORLAX", flag = "EVENT_BEAT_ROUTE16_SNORLAX" },
    }
    for _, r in ipairs(snorlaxRoutes) do
      local toggles = save.objectToggles[r.map]
      if toggles and toggles[r.obj] == false and not save.flags[r.flag] then
        save.flags[r.flag] = true
      end
    end
  end
end)

-- Migrate options that still live inside an old save.lua into the
-- standalone options file (once); load always re-attaches options.lua
-- afterwards either way
SaveData.addCoreMigration(1, function(save)
  if type(save.options) == "table"
      and not love.filesystem.getInfo(OPTIONS_FILENAME) then
    SaveData.saveOptions(save.options)
  end
end)

-- settle the box shape (single `box` list -> 12 boxes) before the
-- validation pass walks it; Boxes keeps the lazy ensure for play paths
SaveData.addCoreMigration(1, function(save)
  Boxes.ensure(save)
end)

-- ------- write

-- Game progress only; options are written separately via saveOptions.
-- If `data.options` is present it is also flushed to options.lua so an
-- F1 / in-game save keeps the live settings in sync, then stripped from
-- the game file.  mods (when given) refreshes the meta stamp; the write
-- itself rolls the last good save into .bak and stages the new bytes as
-- a .tmp witness before the swap, so a crash mid-write is recoverable.
function SaveData.save(data, mods)
  if data.options then
    SaveData.saveOptions(data.options)
  end
  if mods ~= nil or data.meta == nil then
    data.meta = SaveData.buildMeta(mods, data.meta)
  end
  local gameOnly = {}
  for k, v in pairs(data) do
    if k ~= "options" then gameOnly[k] = v end
  end
  local encoded = SaveSerializer.encode(gameOnly)
  local fs = love.filesystem
  if fs.getInfo(FILENAME) then
    local prev = fs.read(FILENAME)
    if prev then fs.write(BACKUP_FILENAME, prev) end
  end
  local ok, err = fs.write(TMP_FILENAME, encoded)
  if not ok then
    Logger.error("save failed: %s", tostring(err))
    return false
  end
  -- love.filesystem has no atomic rename: remove + rewrite, with the
  -- .tmp copy as the recovery witness in between
  remove(fs, FILENAME)
  ok, err = fs.write(FILENAME, encoded)
  if not ok then
    Logger.error("save failed: %s", tostring(err))
    return false
  end
  remove(fs, TMP_FILENAME)
  Logger.info("saved game")
  return true
end

-- ------- read

-- returns the parsed save plus "tmp"/"bak" when the main file was gone
-- or corrupt and a staged/backup copy was promoted; Game surfaces the
-- recovery on the load report
function SaveData.load()
  local fs = love.filesystem
  local data, err = readTable(fs, FILENAME)
  local recovered
  if not data then
    local tmp = readTable(fs, TMP_FILENAME)
    if tmp then
      data, recovered = tmp, "tmp"
    else
      local bak = readTable(fs, BACKUP_FILENAME)
      if bak then data, recovered = bak, "bak" end
    end
    if data then
      Logger.warn("save.lua %s; recovered from %s copy",
        fs.getInfo(FILENAME) and "corrupt" or "missing", recovered)
      fs.write(FILENAME, SaveSerializer.encode(data))
    end
  end
  if not data then
    if fs.getInfo(FILENAME) then
      Logger.error("load failed: %s", tostring(err))
    end
    return nil
  end
  SaveData.runMigrations(data)
  data.options = SaveData.loadOptions()
  Logger.info("loaded save")
  return data, recovered
end

-- ------- validation and quarantine

local function known(tbl, id)
  return id ~= nil and type(tbl) == "table" and tbl[id] ~= nil
end

-- only out-of-range values move; a vanilla save passes through untouched
local function clamp(n, lo, hi, fallback)
  if type(n) ~= "number" then return fallback end
  if n < lo then return lo end
  if n > hi then return hi end
  return n
end

local function ensureOrphaned(save)
  if not save.orphaned then
    save.orphaned = { mons = {}, items = {} }
  end
  save.orphaned.mons = save.orphaned.mons or {}
  save.orphaned.items = save.orphaned.items or {}
  return save.orphaned
end

-- quarantined ids whose content reappeared (mod re-enabled) go home
-- again: mons through the PC deposit, items through the bag with the PC
-- as overflow
local function reclaim(save, data, report)
  local orphaned = save.orphaned
  if not orphaned then return end
  for i = #(orphaned.mons or {}), 1, -1 do
    local mon = orphaned.mons[i]
    if type(mon) == "table" and known(data.pokemon, mon.species) then
      table.remove(orphaned.mons, i)
      local box = Boxes.deposit(save, mon)
      if box then
        report.restoredMons[#report.restoredMons + 1] =
          { species = mon.species, box = box }
      else
        -- every box full: stays quarantined rather than vanishing
        table.insert(orphaned.mons, i, mon)
      end
    end
  end
  for i = #(orphaned.items or {}), 1, -1 do
    local entry = orphaned.items[i]
    if type(entry) == "table" and known(data.items, entry.id) then
      table.remove(orphaned.items, i)
      if entry.from == "pcItems" or type(save.inventory) ~= "table"
          or not Bag.add(save, entry.id, entry.count or 1) then
        save.pcItems = save.pcItems or {}
        save.pcItems[entry.id] = (save.pcItems[entry.id] or 0) + (entry.count or 1)
      end
      report.restoredItems[#report.restoredItems + 1] =
        { id = entry.id, count = entry.count or 1 }
    end
  end
end

-- mirrors Protocol.unpackMon's clamp discipline for the fields play
-- indexes; the level floor widens to 1 because a freshly caught level-1
-- mon can legitimately sit in a save
local function scrubKnownMon(mon, data)
  if type(mon.dvs) == "table" then
    for stat, v in pairs(mon.dvs) do mon.dvs[stat] = clamp(v, 0, 15, 0) end
  end
  if type(mon.statExp) == "table" then
    for stat, v in pairs(mon.statExp) do mon.statExp[stat] = clamp(v, 0, 65535, 0) end
  end
  mon.level = clamp(mon.level, 1, 100, 1)
  local moves = mon.moves
  if type(moves) ~= "table" then return end
  local hadMoves = #moves > 0
  for j = #moves, 1, -1 do
    local slot = moves[j]
    local id = type(slot) == "table" and slot.id or slot
    if not known(data.moves, id) then table.remove(moves, j) end
  end
  while #moves > 4 do table.remove(moves) end
  if hadMoves and #moves == 0 then
    -- data-driven repair so a total conversion without TACKLE still heals
    local fallback = (data.constants and data.constants.fallbackMove) or "TACKLE"
    local def = data.moves and data.moves[fallback]
    if def then
      moves[1] = { id = fallback, pp = def.pp }
    end
  end
end

local function scrubMonList(list, where, save, data, report)
  if type(list) ~= "table" then return end
  for i = #list, 1, -1 do
    local mon = list[i]
    if type(mon) ~= "table" or not known(data.pokemon, mon.species) then
      table.remove(list, i)
      ensureOrphaned(save)
      save.orphaned.mons[#save.orphaned.mons + 1] = mon
      report.lostMons[#report.lostMons + 1] =
        { species = type(mon) == "table" and mon.species or nil, from = where }
    else
      scrubKnownMon(mon, data)
    end
  end
end

local function scrubItemMap(map, where, save, data, report)
  if type(map) ~= "table" then return end
  for id, count in pairs(map) do
    if not known(data.items, id) then
      map[id] = nil
      ensureOrphaned(save)
      save.orphaned.items[#save.orphaned.items + 1] =
        { id = id, count = count, from = where }
      report.lostItems[#report.lostItems + 1] =
        { id = id, count = count, from = where }
    end
  end
end

local function scrubMaps(save, data, report)
  local boot = (data.field and data.field.boot) or {}
  local spawn = { map = boot.startMap or "PALLET_TOWN",
                  x = boot.startX or 5, y = boot.startY or 6 }
  -- heal point first, so the player fallback below always lands somewhere
  -- valid; boot's heal cell (threaded from field.boot) is the last resort
  if save.lastHeal and not known(data.maps, save.lastHeal.map) then
    local heal = boot.lastHeal or spawn
    report.remappedMaps[#report.remappedMaps + 1] =
      { id = save.lastHeal.map, to = heal.map, field = "lastHeal" }
    save.lastHeal = { map = heal.map, x = heal.x, y = heal.y }
  end
  if save.player and not known(data.maps, save.player.map) then
    local heal = save.lastHeal or spawn
    report.remappedMaps[#report.remappedMaps + 1] =
      { id = save.player.map, to = heal.map, field = "player" }
    save.player.map, save.player.x, save.player.y = heal.map, heal.x, heal.y
  end
  if save.lastOutdoor and not known(data.maps, save.lastOutdoor.id) then
    report.remappedMaps[#report.remappedMaps + 1] =
      { id = save.lastOutdoor.id, field = "lastOutdoor" }
    save.lastOutdoor = nil
  end
  if save.lastHeal and type(save.lastHeal.outdoor) == "table"
      and not known(data.maps, save.lastHeal.outdoor.id) then
    save.lastHeal.outdoor = nil
  end
end

-- Walks every content id the save references against the merged data and
-- quarantines unknowns instead of letting them nil-index later: mons move
-- to save.orphaned (the LOST box), items are removed with a report row,
-- locations fall back to the heal point.  Reclaims quarantined content
-- whose id reappeared first.  On a mod-free save every membership test
-- passes and the save comes back untouched.
function SaveData.validate(save, data)
  local report = { lostMons = {}, lostItems = {}, remappedMaps = {},
                   restoredMons = {}, restoredItems = {} }
  reclaim(save, data, report)
  scrubMonList(save.party, "party", save, data, report)
  for b, box in ipairs(save.boxes or {}) do
    scrubMonList(box, "box " .. b, save, data, report)
  end
  local daycare = save.daycare
  if type(daycare) == "table" and type(daycare.mon) == "table" then
    if not known(data.pokemon, daycare.mon.species) then
      ensureOrphaned(save)
      save.orphaned.mons[#save.orphaned.mons + 1] = daycare.mon
      report.lostMons[#report.lostMons + 1] =
        { species = daycare.mon.species, from = "daycare" }
      daycare.mon = nil
    else
      scrubKnownMon(daycare.mon, data)
    end
  end
  scrubItemMap(save.inventory, "inventory", save, data, report)
  scrubItemMap(save.pcItems, "pcItems", save, data, report)
  if type(save.bagOrder) == "table" then
    for i = #save.bagOrder, 1, -1 do
      if not known(data.items, save.bagOrder[i]) then
        table.remove(save.bagOrder, i)
      end
    end
  end
  scrubMaps(save, data, report)
  local dex = save.pokedex
  if type(dex) == "table" then
    for _, key in ipairs({ "seen", "owned" }) do
      if type(dex[key]) == "table" then
        for id in pairs(dex[key]) do
          if not known(data.pokemon, id) then dex[key][id] = nil end
        end
      end
    end
  end
  -- hall of fame rosters keep their shape: an unknown species blanks in
  -- place so the team stays the size it won at, with the rest of the mon
  -- (level etc.) intact for display
  for _, entry in ipairs(save.hallOfFame or {}) do
    if type(entry) == "table" then
      for i = 1, #entry do
        local mon = entry[i]
        if type(mon) == "table" and mon.species ~= nil
            and not known(data.pokemon, mon.species) then
          mon.species = nil
        end
      end
    end
  end
  -- an empty quarantine leaves no residue, so a vanilla save re-encodes
  -- byte-identically
  local orphaned = save.orphaned
  if orphaned and #(orphaned.mons or {}) == 0 and #(orphaned.items or {}) == 0 then
    save.orphaned = nil
  end
  return report
end

function SaveData.emptyReport(report)
  -- a bare validate report (the save editor's probe) carries no modsDiff;
  -- restoreSave attaches one so a version bump alone still surfaces
  local diff = report.modsDiff
  return #report.lostMons == 0 and #report.lostItems == 0
    and #report.remappedMaps == 0 and #report.restoredMons == 0
    and #report.restoredItems == 0 and not report.recovered
    and (not diff or (#diff.added == 0 and #diff.removed == 0 and #diff.changed == 0))
end

-- ------- new game

-- boot is Data.field.boot, threaded in by Game: this module must not reach
-- into Data itself.  Every read falls back to the Red literal it replaced,
-- so an absent or partial config still produces the vanilla new game.
function SaveData.newGame(boot)
  boot = type(boot) == "table" and boot or {}
  local map = boot.startMap or "PALLET_TOWN"
  local x, y = boot.startX or 5, boot.startY or 6
  local heal = boot.lastHeal or {}
  local save = {
    meta = { format = Version.saveFormat, mods = {} },
    player = {
      map = map,
      x = x,
      y = y,
      facing = boot.startFacing or "down",
      name = boot.playerName or "RED",
      rival = boot.rivalName or "BLUE",
      -- 16-bit trainer ID rolled at new game (wPlayerID, filled from
      -- hRandomAdd in OakSpeech)
      id = math.random(0, 65535),
    },
    flags = {},
    inventory = {},
    party = {},
    box = {},
    money = boot.startMoney or 3000,
    defeatedTrainers = {},
    pokedex = { seen = {}, owned = {} },
    -- where blackouts and ESCAPE ROPE return to (updated by nurses);
    -- copied, never aliased, so a save never writes back into Data
    lastHeal = { map = heal.map or map, x = heal.x or x, y = heal.y or y },
    repelSteps = 0,
    -- per-mod persistence (mod.save) lives under here, keyed by mod id
    modData = {},
    -- Live options from options.lua (or defaults); New Game keeps the
    -- player's audio/display/battle preferences.
    options = SaveData.loadOptions(),
  }
  -- a total conversion reshapes the skeleton (spawn, party, money)
  -- before anything reads it; unhooked this returns save unchanged
  return Runtime.call("save.new_game", function(s) return s end, save)
end

return SaveData
