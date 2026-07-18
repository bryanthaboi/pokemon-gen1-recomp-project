-- Headless tests for tools/save-editor pure logic.
-- Run from repo root: lua5.4 tests/run_save_editor_tests.lua
-- (If lua5.4 is missing, use the same interpreter as tests/run_tests.lua.)
--
-- Panel suites (Boxes/Items, Events/Dex, Map) live in separate files so each
-- can define its own harness without colliding with this runner:
--   tests/save_editor_task6_tests.lua
--   tests/save_editor_task7_tests.lua
--   tests/save_editor_task8_tests.lua
-- See tools/save-editor/README.md for the full list.

package.path = package.path .. ";./?.lua;./?/init.lua;./tools/save-editor/?.lua"
  .. ";./tools/save-editor/panels/?.lua"

local love_stub = require("tests.love_stub")
love = love_stub

local passed, failed = 0, 0

local function check(cond, msg)
  if cond then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL: " .. msg)
  end
end

local function eq(a, b, msg)
  check(a == b, msg .. string.format(" (got %s, want %s)", tostring(a), tostring(b)))
end

print("== save editor tests ==")

local SaveData = require("src.core.SaveData")

do
  local data = SaveData.newGame()
  data.player.map = "VIRIDIAN_CITY"
  data.money = 1234
  data.flags.EVENT_GOT_POKEDEX = true
  local encoded = SaveData.encode(data)
  check(type(encoded) == "string", "encode returns string")
  check(encoded:match("^return "), "encode starts with return")
  local back, err = SaveData.decode(encoded)
  check(back ~= nil, "decode ok: " .. tostring(err))
  eq(back.player.map, "VIRIDIAN_CITY", "decode map")
  eq(back.money, 1234, "decode money")
  check(back.flags.EVENT_GOT_POKEDEX == true, "decode flag")
end

do
  local bad, err = SaveData.decode("not lua {{{")
  check(bad == nil, "decode rejects garbage")
  check(type(err) == "string", "decode returns err string")
end

local SaveIO = require("SaveIO")

do
  local path = SaveIO.defaultPath()
  check(type(path) == "string" and #path > 0, "defaultPath nonempty")
  check(path:match("save%.lua$"), "defaultPath ends with save.lua")
  check(path:match("pokemon%-love2d"), "defaultPath uses game identity folder")
  local uname = io.popen and io.popen("uname -s 2>/dev/null")
  local sys = uname and uname:read("*l") or ""
  if uname then uname:close() end
  if sys == "Darwin" then
    check(path:match("/LOVE/"), "defaultPath on macOS includes LOVE folder")
  end
  check(type(SaveIO.choosePath) == "function", "choosePath exists")
end

do
  local path = os.tmpname() .. "-gamesave.lua"

  local data = SaveData.newGame()
  data.money = 42
  local ok, err = SaveIO.save(path, data)
  check(ok, "SaveIO.save ok: " .. tostring(err))
  local f = io.open(path, "r")
  check(f ~= nil, "save file exists")
  if f then f:close() end

  local loaded, lerr = SaveIO.load(path)
  check(loaded ~= nil, "SaveIO.load ok: " .. tostring(lerr))
  eq(loaded.money, 42, "SaveIO round trip money")

  data.money = 99
  ok, err = SaveIO.save(path, data)
  check(ok, "second save ok: " .. tostring(err))
  loaded = assert(SaveIO.load(path))
  eq(loaded.money, 99, "second save money")

  local bakFiles = {}
  local bakGlob = io.popen('ls -1 "' .. path .. '.bak-"* 2>/dev/null')
  if bakGlob then
    for line in bakGlob:lines() do
      bakFiles[#bakFiles + 1] = line
    end
    bakGlob:close()
  end
  check(#bakFiles >= 1, "second save creates .bak-* sibling")
  if #bakFiles >= 1 then
    local bakData, berr = SaveIO.load(bakFiles[1])
    check(bakData ~= nil, "backup load ok: " .. tostring(berr))
    if bakData then eq(bakData.money, 42, "backup preserves previous money") end
  end

  os.remove(path)
  for _, bak in ipairs(bakFiles) do
    os.remove(bak)
  end
end

local Catalog = require("Catalog")
local MonOps = require("MonOps")
local Data = require("src.core.Data")
Data:load()

do
  local cat = Catalog.build(Data)
  check(#cat.species > 140, "species catalog size")
  check(#cat.items > 100, "items catalog size")
  check(#cat.moves > 150, "moves catalog size")
  check(cat.species[1] < cat.species[2], "species sorted")
end

do
  local events = Catalog.scrapeEvents("data/scripts", "data/generated/trainer_headers.lua")
  check(#events > 50, "scraped events")
  check(events[1]:match("^EVENT_"), "event prefix")
end

do
  local mon = MonOps.create(Data, "PIDGEY", 10)
  eq(mon.species, "PIDGEY", "create species")
  eq(mon.level, 10, "create level")
  local hpBefore = mon.stats.hp
  MonOps.setLevel(Data, mon, 20)
  eq(mon.level, 20, "setLevel")
  check(mon.stats.hp > hpBefore, "stats grew on level")
  check(mon.hp <= mon.stats.hp, "hp clamped")
  MonOps.setMove(Data, mon, 1, "GUST")
  eq(mon.moves[1].id, "GUST", "setMove id")
  check(mon.moves[1].pp > 0, "setMove pp")
end

do
  -- Magikarp is SLOW, Butterfree is MEDIUM_FAST,  same level, different exp
  local mon = MonOps.create(Data, "MAGIKARP", 20)
  local expSlow = mon.exp
  MonOps.setSpecies(Data, mon, "BUTTERFREE")
  eq(mon.species, "BUTTERFREE", "setSpecies id")
  eq(mon.level, 20, "setSpecies keeps level")
  check(mon.exp ~= expSlow, "setSpecies resyncs exp for new growth curve")
  eq(mon.exp, require("src.pokemon.Growth").expForLevel(
    Data.pokemon.BUTTERFREE.growthRate, 20), "setSpecies exp matches curve")
  MonOps.setDv(Data, mon, "attack", 15)
  eq(mon.dvs.attack, 15, "setDv attack")
  check(mon.dvs.hp >= 8, "syncHpDv sets high bit from odd attack")
end

local State = require("State")

do
  local s = State.new()
  eq(s.tab, "party", "State.new default tab")
  eq(s.dirty, false, "State.new default dirty")
  eq(s.selectedParty, 1, "State.new default selectedParty")
  eq(s.selectedBox, 1, "State.new default selectedBox")
  check(s.editingMon == nil, "State.new default editingMon nil")
  State.markDirty(s)
  check(s.dirty == true, "State.markDirty sets dirty")
end

-- Party/MonEditor panels: drive Kit's immediate-mode hit-testing by placing
-- the "mouse" at the exact coordinates each panel draws its widgets at
-- (mirroring the layout constants in panels/{Party,MonEditor}.lua), so the
-- click handlers run for real without a live window.
local Kit = require("Kit")
local Party = require("Party")
local MonEditor = require("MonEditor")
local Pokemon = require("src.pokemon.Pokemon")

do
  local S = State.new()
  S.data = Data
  S.cat = Catalog.build(Data)
  S.save = SaveData.newGame()
  local wartortle = MonOps.create(Data, "WARTORTLE", 20)
  local pidgey = MonOps.create(Data, "PIDGEY", 5)
  S.save.party = { wartortle, pidgey }
  S.selectedParty = 1

  local px, py = 12, 80

  Kit.beginFrame(px + 10, py + 24 + 22 + 5, true) -- row 2 of the list
  Party.draw(S, Kit, px, py)
  eq(S.selectedParty, 2, "Party list click selects row")
  check(S.editingMon == pidgey, "Party list click sets editingMon")

  Kit.beginFrame(px + 10, py + 200 + 10, true) -- Add button
  Party.draw(S, Kit, px, py)
  eq(#S.save.party, 3, "Party Add appends a mon")
  check(S.dirty == true, "Party Add marks dirty")
  S.dirty = false

  S.selectedParty = 3
  Kit.beginFrame(px + 110 + 10, py + 200 + 10, true) -- Remove button
  Party.draw(S, Kit, px, py)
  eq(#S.save.party, 2, "Party Remove drops selected mon")

  S.selectedParty = 2
  Kit.beginFrame(px + 220 + 10, py + 200 + 10, true) -- Move Up button
  Party.draw(S, Kit, px, py)
  eq(S.selectedParty, 1, "Party Move Up updates selection")
  check(S.save.party[1] == pidgey, "Party Move Up swaps order")
end

do
  local S = State.new()
  S.data = Data
  S.cat = Catalog.build(Data)
  local mon = MonOps.create(Data, "WARTORTLE", 20)
  S.editingMon = mon

  local mx, my = 640, 80
  local levelBefore = mon.level
  local hpStatBefore = mon.stats.hp

  Kit.beginFrame(mx + 148 + 10, my + 84 + 10, true) -- "+1" level button
  MonEditor.draw(S, Kit, mx, my)
  eq(mon.level, levelBefore + 1, "MonEditor +1 level button")
  check(mon.stats.hp >= hpStatBefore, "MonEditor level up recalcs stats")
  check(S.dirty == true, "MonEditor level change marks dirty")
  S.dirty = false

  local dvY = my + 154
  local attackBefore = mon.dvs.attack
  Kit.beginFrame(mx + 160 + 5, dvY + 5, true) -- attack DV "+" button
  MonEditor.draw(S, Kit, mx, my)
  eq(mon.dvs.attack, math.min(15, attackBefore + 1), "MonEditor DV attack + button")

  local hpDvY = dvY + 4 * 30 + 6
  local movesY = hpDvY + 34
  local slot1Y = movesY + 24
  local moveBefore = mon.moves[1] and mon.moves[1].id
  Kit.beginFrame(mx + 10, slot1Y + 10, true) -- move slot 1
  MonEditor.draw(S, Kit, mx, my)
  check(mon.moves[1] ~= nil, "MonEditor move slot has a move after cycle")
  check(mon.moves[1].id ~= moveBefore, "MonEditor move slot cycles to a different move")

  local actionsY = movesY + 24 + 4 * 30 + 10
  Kit.beginFrame(mx + 10, actionsY + 10, true) -- Reset moves to learnset
  MonEditor.draw(S, Kit, mx, my)
  local def = Data.pokemon[mon.species]
  local learned = Pokemon.movesAtLevel(def, mon.level)
  eq(#mon.moves, #learned, "MonEditor reset moves matches learnset size")

  Kit.beginFrame(mx + 10, actionsY + 38 + 10, true) -- Close
  MonEditor.draw(S, Kit, mx, my)
  check(S.editingMon == nil, "MonEditor Close clears editingMon")
end

-- App.load corrupt-save vs missing-save (Important fix #2): App.load takes
-- an optional path override precisely so tests can drive this without
-- touching the real default save file.
local App = require("App")

-- App.draw() sources its click state from App.mousepressed() + the mouse
-- position at draw time (not from a Kit.beginFrame call made by the test),
-- so simulating a click means moving the mouse and pressing before drawing.
local appMouseX, appMouseY = 0, 0
love.mouse = { getPosition = function() return appMouseX, appMouseY end }

local function clickApp(x, y)
  appMouseX, appMouseY = x, y
  App.mousepressed(x, y, 1)
  App.draw()
end

do
  local tmpPath = os.tmpname() .. "-missing-save.lua"
  os.remove(tmpPath)

  App.load(tmpPath)
  local s = App.getState()
  eq(s.loadError, false, "App.load missing-file: loadError stays false")
  eq(s.allowSave, true, "App.load missing-file: allowSave stays true")
  check(s.status:match("No save at") ~= nil, "App.load missing-file status mentions no save")
end

do
  local tmpPath = os.tmpname() .. "-corrupt-save.lua"
  local f = io.open(tmpPath, "wb")
  f:write("not valid lua {{{")
  f:close()

  App.load(tmpPath)
  local s = App.getState()
  eq(s.loadError, true, "App.load corrupt-file: loadError set true")
  eq(s.allowSave, false, "App.load corrupt-file: allowSave set false")
  check(s.status:match("Corrupt save") ~= nil, "App.load corrupt-file status mentions corrupt save")

  -- Clicking Save while loadError is set must be a no-op: file on disk
  -- (the corrupt real save) must not be overwritten by the stub.
  clickApp(110 + 10, 6 + 10) -- Save button
  local unchanged = io.open(tmpPath, "rb")
  local contents = unchanged:read("*a")
  unchanged:close()
  eq(contents, "not valid lua {{{", "Save no-op leaves the corrupt file on disk untouched")
  check(App.getState().status:match("disabled") ~= nil, "Save no-op reports a disabled status")

  -- Fixing the file and Reloading must re-enable Save.
  local fixed = io.open(tmpPath, "wb")
  fixed:write(SaveData.encode(SaveData.newGame()))
  fixed:close()
  clickApp(200 + 10, 6 + 10) -- Reload button
  eq(App.getState().loadError, false, "Reload after fixing the file clears loadError")
  eq(App.getState().allowSave, true, "Reload after fixing the file re-enables allowSave")

  os.remove(tmpPath)
end

do
  -- Optional fix: quit-confirmation re-arms once new edits land, so a
  -- prior "press quit again" arming doesn't leak across separate edits.
  local tmpPath = os.tmpname() .. "-quitarmed-save.lua"
  os.remove(tmpPath)
  App.load(tmpPath)
  local s = App.getState()
  s._quitArmed = true
  s.tab = "items"

  clickApp(12 + 132 + 10, 80 + 22 + 10) -- Items panel "+10" money button
  eq(App.getState()._quitArmed, false, "A fresh dirty edit resets _quitArmed")

  os.remove(tmpPath)
end

do
  -- Open... / App.openPath: switch to another save; dirty needs a second open.
  local a = os.tmpname() .. "-open-a.lua"
  local b = os.tmpname() .. "-open-b.lua"
  local dataA = SaveData.newGame(); dataA.money = 111
  local dataB = SaveData.newGame(); dataB.money = 222
  assert(SaveIO.save(a, dataA))
  assert(SaveIO.save(b, dataB))

  App.load(a)
  eq(App.getState().save.money, 111, "openPath setup: loaded A")
  eq(App.getState().path, a, "openPath setup: path is A")

  check(App.openPath(b) == true, "openPath clean switch succeeds")
  eq(App.getState().path, b, "openPath updates path to B")
  eq(App.getState().save.money, 222, "openPath loads B money")
  eq(App.getState().dirty, false, "openPath clears dirty")

  App.getState().dirty = true
  check(App.openPath(a) == false, "openPath dirty first call arms confirm")
  eq(App.getState().path, b, "openPath dirty first call keeps current path")
  check(App.getState().status:match("Unsaved changes") ~= nil,
        "openPath dirty first call status warns")
  check(App.openPath(a) == true, "openPath dirty second call proceeds")
  eq(App.getState().path, a, "openPath dirty second call switches path")
  eq(App.getState().save.money, 111, "openPath dirty second call loads A")

  check(App.openPath(b, true) == true, "openPath force=true skips arming")
  eq(App.getState().path, b, "openPath force switches immediately")

  -- Drag-drop uses the File:getFilename() API.
  local dropped = { getFilename = function() return a end }
  App.filedropped(dropped)
  eq(App.getState().path, a, "filedropped opens the dropped path")

  os.remove(a); os.remove(b)
  for _, path in ipairs({ a, b }) do
    local bak = io.popen('ls -1 "' .. path .. '.bak-"* 2>/dev/null')
    if bak then
      for line in bak:lines() do os.remove(line) end
      bak:close()
    end
  end
end

print(string.format("save editor tests: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
