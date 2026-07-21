-- UI extensibility (M8): the Screens factory and its cache invalidation,
-- StateStack screen events, the three menu-injection hooks with non-table
-- degrade, the mod.ui helper surface, theme defaults, branding reads from
-- field.*, and ManagerState v2 -- error surfacing, toggle resolution with
-- dependency dialogs, staged apply/discard, options auto-UI, profiles and
-- the safe-mode banner.
package.path = "./?.lua;./?/init.lua;" .. package.path

local S = require("tests.harness").suite("mod ui")
local check = S.check

local love = _G.love or require("tests.love_stub")
_G.love = love

local Events = require("src.mods.Events")
local Hooks = require("src.mods.Hooks")
local Runtime = require("src.mods.Runtime")
local Logger = require("src.core.Logger")
local Assets = require("src.render.Assets")
local Screens = require("src.ui.Screens")
local StateStack = require("src.core.StateStack")
local ManagerState = require("src.mods.ManagerState")
local ModUI = require("src.ui.ModUI")
local Theme = require("src.ui.Theme")

local savedEvents, savedHooks, savedErrors =
  Runtime.events, Runtime.hooks, Runtime.errors
local savedSafeMode = Runtime.safeMode

local function logged(fragment)
  for _, line in ipairs(Logger.history) do
    if line:find(fragment, 1, true) then return true end
  end
  return false
end

-- minimal stack/input doubles matching the StateStack and Input surfaces
local function newStack()
  local stack = { states = {} }
  function stack:push(state, ...)
    table.insert(self.states, state)
    if state.enter then state:enter(...) end
  end
  function stack:pop()
    local state = table.remove(self.states)
    if state and state.exit then state:exit() end
    return state
  end
  function stack:top() return self.states[#self.states] end
  return stack
end

local function newInput()
  local input = { queue = {} }
  function input:wasPressed(btn) return self.queue[btn] or false end
  return input
end

local function press(state, btn)
  state.game.input.queue = { [btn] = true }
  state:update(1 / 60)
  state.game.input.queue = {}
end

-- ------- Screens: resolution identity (parity)
Screens.invalidate()
local sgame = { data = {}, stack = newStack() }
for _, id in ipairs({ "TitleState", "IntroMovie", "OakSpeech", "NamingScreen",
    "StartMenu", "PokedexMenu", "DexEntryMenu", "TownMap", "PartyMenu",
    "BagMenu", "SummaryMenu", "TrainerCard", "OptionsMenu", "ShopMenu",
    "BoxMenu", "PlayerPC", "MoveLearnMenu", "EvolutionState", "HallOfFame",
    "Credits", "SlotMachine", "TradeAnim", "FlyMenu", "BindingsMenu" }) do
  check(Screens.get(sgame, id) == require("src.ui." .. id),
    "empty registry resolves the require module: " .. id)
end
check(Screens.get(sgame, "ManagerState") == ManagerState,
  "ManagerState resolves from src.mods")

-- ------- Screens: override, screenId stamp, broken-factory fallback
Screens.invalidate()
sgame.data.screens = {
  TitleState = { new = function(game) return { marker = true } end },
}
local inst = Screens.push(sgame, "TitleState")
check(inst.marker == true, "registry record wins over the builtin")
check(inst.screenId == "TitleState", "push stamps screenId")
check(sgame.stack:top() == inst, "push lands the instance on the stack")

Screens.invalidate()
sgame.data.screens = { TitleState = { new = function() error("boom") end } }
local fallback = Screens.push(sgame, "TitleState")
check(getmetatable(fallback) == require("src.ui.TitleState"),
  "a throwing mod factory degrades to the builtin")
check(logged("mod screen 'TitleState' failed"),
  "the failed factory is logged")

-- ------- Screens: cache flush rides the Assets invalidation fan-out
Screens.invalidate()
sgame.data.screens = nil
local cached = Screens.get(sgame, "TitleState")
sgame.data.screens = {
  TitleState = { new = function() return { modded = true } end },
}
check(Screens.get(sgame, "TitleState") == cached,
  "the factory cache holds between resolutions")
Assets.invalidate()
check(Screens.get(sgame, "TitleState") ~= cached,
  "Assets.invalidate flushes the screens cache")
sgame.data.screens = nil
Screens.invalidate()

-- ------- StateStack events
local events, hooks = Events.new(), Hooks.new()
local errors = {}
Runtime.install(events, hooks, errors)
StateStack:init()
local order = {}
events:on("screen.pushed", function(e)
  order[#order + 1] = "pushed:" .. tostring(e.state.entered)
end, 0, "t")
events:on("screen.popped", function(e)
  order[#order + 1] = "popped:" .. tostring(e.state.exited)
end, 0, "t")
local probe = {}
function probe:enter() self.entered = true end
function probe:exit() self.exited = true end
StateStack:push(probe)
StateStack:pop()
check(order[1] == "pushed:true", "screen.pushed fires after enter")
check(order[2] == "popped:true", "screen.popped fires after exit")

local seenId
events:on("screen.pushed", function(e) seenId = e.state.screenId end, 0, "t")
Screens.push({ data = {}, stack = StateStack }, "TrainerCard")
check(seenId == "TrainerCard", "listeners match by screenId via Screens.push")
StateStack:pop()
events:removeOwner("t")
check(not Runtime.wants("screen.pushed"),
  "no listeners left: the emit guard skips payload construction")
StateStack:push({}) -- no listener, no payload, no error
StateStack:pop()

-- ------- ui.start_menu.items
local StartMenu = require("src.ui.StartMenu")
local function startGame()
  return {
    data = {},
    stack = newStack(),
    input = newInput(),
    save = { flags = { EVENT_GOT_POKEDEX = true }, party = { {} },
             player = { name = "RED" }, options = {},
             pokedex = { owned = {} } },
  }
end
local VANILLA_START = { "POKéDEX", "POKéMON", "ITEM", "RED", "SAVE",
                        "OPTION", "LINK", "QUIT" }
local menu = StartMenu.new(startGame())
check(#menu.items == #VANILLA_START, "vanilla start menu row count")
for i, label in ipairs(VANILLA_START) do
  check(menu.items[i].label == label, "vanilla start menu row " .. i)
end
check(menu.th == #menu.items * 2 + 2, "menu height derives from the item count")

local gated = startGame()
gated.modStatus = { available = { { id = "m" } } }
menu = StartMenu.new(gated)
check(menu.items[#menu.items - 1].label == "MODS",
  "pause-menu MODS entry appears once a mod is discovered")

hooks:wrap("ui.start_menu.items", function(nextFn, game, items)
  ModUI.insertBefore(items, "ITEM", { label = "QUESTS",
    onSelect = function() end })
  return nextFn(game, items)
end, 0, "fixture")
menu = StartMenu.new(startGame())
check(menu.items[3].label == "QUESTS" and menu.items[4].label == "ITEM",
  "hook inserts a start-menu entry before its anchor")
hooks:removeOwner("fixture")

hooks:wrap("ui.start_menu.items", function() return 42 end, 0, "bad")
menu = StartMenu.new(startGame())
check(#menu.items == #VANILLA_START and menu.items[3].label == "ITEM",
  "a non-table hook result degrades to the vanilla items")
check(logged("ui.start_menu.items returned"), "the degrade is logged")
hooks:removeOwner("bad")

-- ------- ui.options.rows and the descriptor refactor
local OptionsMenu = require("src.ui.OptionsMenu")
local function optGame()
  return {
    data = {
      rulesets = {
        gen1_faithful = { name = "GEN 1" },
        modern_clean = { name = "MODERN" },
        secret = { name = "SECRET", hidden = true },
      },
      constants = {},
    },
    save = { options = {} },
    stack = newStack(),
    input = newInput(),
    modStatus = { available = {} },
  }
end
local om = OptionsMenu.new(optGame())
local WANT_IDS = { "textSpeed", "animations", "battleStyle", "ruleset",
                   "musicVol", "sfxVol", "musicFilter", "colors", "tilt",
                   "gbcfx", "videoMode", "speed", "mods", "controls" }
check(#om.rows == #WANT_IDS, "vanilla options row count (plus MODS/CONTROLS)")
for i, id in ipairs(WANT_IDS) do
  check(om.rows[i].id == id, "options row order: " .. id)
end

-- ruleset row cycles the sorted non-hidden registry ids showing name
om.game.save.options.ruleset = "gen1_faithful"
check(om.rows[4].value(om.game) == "GEN 1", "ruleset row shows record.name")
om.rows[4].step(om.game, 1)
check(om.game.save.options.ruleset == "modern_clean",
  "ruleset row cycles sorted registry ids")
om.rows[4].step(om.game, 1)
check(om.game.save.options.ruleset == "gen1_faithful",
  "hidden rulesets are excluded from the cycle")

-- stepping parity with the old per-index ladder
om.rows[1].step(om.game, 1)
check(om.game.save.options.textSpeed == 5, "text speed MEDIUM steps to SLOW")
om.rows[1].step(om.game, 1)
check(om.game.save.options.textSpeed == 1, "then wraps to FAST")
om.rows[2].step(om.game, 1)
check(om.game.save.options.animations == false, "animations toggles off")
om.rows[3].step(om.game, 1)
check(om.game.save.options.battleStyle == "set", "battle style flips to SET")
om.rows[5].step(om.game, -1)
check(om.game.save.options.musicVol == 6, "music volume steps down")
for _ = 1, 10 do om.rows[5].step(om.game, -1) end
check(om.game.save.options.musicVol == 0, "music volume clamps at 0")

-- the MODS row is the manager's discoverable home
local mgGame = optGame()
om = OptionsMenu.new(mgGame)
om.rows[13].activate(mgGame)
check(getmetatable(mgGame.stack:top()) == ManagerState,
  "the MODS row opens the manager")
check(mgGame.stack:top().screenId == "ManagerState",
  "the pushed manager carries its screen id")

-- ------- the CONTROLS row and BindingsMenu (gap C2's file-12 half)
local BindingsMenu = require("src.ui.BindingsMenu")
local cbGame = optGame()
om = OptionsMenu.new(cbGame)
om.rows[14].activate(cbGame)
local bm = cbGame.stack:top()
check(getmetatable(bm) == BindingsMenu,
  "the CONTROLS row opens the rebind list")
check(bm.screenId == "BindingsMenu",
  "the pushed rebind screen carries its screen id")
check(#bm.items == 8, "one row per logical button")
check(bm.items[1].label == "UP" and bm.items[1].right == "UP"
  and bm.items[5].label == "A" and bm.items[5].right == "Z"
  and bm.items[7].label == "START" and bm.items[7].right == "ESCAPE",
  "with no rebind the rows mirror the fixed map")
check(cbGame.save.options.bindings == nil,
  "opening the screen alone writes nothing")
check(bm.onKeyPressed == nil and bm.onGamepadPressed == nil,
  "no raw-input claim until a capture is armed")
press(bm, "a")
check(bm.capture == bm.items[1] and bm.onKeyPressed ~= nil,
  "A on a row arms the capture")
local wroteOptions = false
function cbGame:writeOptions() wroteOptions = true end
bm:onKeyPressed("j")
check(cbGame.save.options.bindings.up.key == "j",
  "a captured key lands in options.bindings")
check(bm.items[1].right == "J", "the row shows the new key")
check(wroteOptions, "a rebind persists through writeOptions")
check(bm.capture == nil and bm.onKeyPressed == nil
  and bm.onGamepadPressed == nil, "the capture disarms after one input")
bm.index = 5
press(bm, "a")
bm:onGamepadPressed("y")
check(cbGame.save.options.bindings.a.pad == "y",
  "a captured pad button lands beside the key slot")
check(bm.items[5].right == "Z", "a pad rebind keeps the key column")
press(bm, "b")
check(#cbGame.stack.states == 0, "B closes the rebind screen")

-- Game routes pad buttons to a capturing top state and nowhere else
local Game = require("src.core.Game")
local Input = require("src.core.Input")
local gpGame = { stack = newStack() }
local sawPad
gpGame.stack:push({ onGamepadPressed = function(_, b) sawPad = b end })
Game.gamepadpressed(gpGame, nil, "y")
check(sawPad == "y", "pad buttons reach a capturing top state")
Input:init()
gpGame.stack:pop()
Game.gamepadpressed(gpGame, nil, "a")
Input:step()
check(Input:wasPressed("a"),
  "without a capturing state pad input still feeds the mapped path")

local hookSawCancel = false
hooks:wrap("ui.options.rows", function(nextFn, game, rows)
  for _, row in ipairs(rows) do
    if row.label == "CANCEL" then hookSawCancel = true end
  end
  rows[#rows + 1] = { id = "quest_pace", label = "QUEST PACE",
    value = function() return "OFF" end,
    step = function() return true end }
  return nextFn(game, rows)
end, 0, "fixture")
om = OptionsMenu.new(optGame())
check(om.rows[#om.rows].id == "quest_pace", "hook appends an options row")
check(not hookSawCancel, "CANCEL is appended after the hook, unreachable")
hooks:removeOwner("fixture")

hooks:wrap("ui.options.rows", function() return "nope" end, 0, "bad")
om = OptionsMenu.new(optGame())
check(#om.rows == #WANT_IDS, "a non-table rows result keeps the vanilla rows")
hooks:removeOwner("bad")

-- ------- ui.party.submenu
local PartyMenu = require("src.ui.PartyMenu")
local function partyGame()
  return {
    data = { pokemon = { PIKACHU = { name = "PIKACHU" } } },
    save = {
      party = { { species = "PIKACHU", hp = 10, stats = { hp = 10 },
                  level = 5, moves = { { id = "TACKLE" } } } },
      inventory = {}, options = {},
    },
    stack = newStack(),
    input = newInput(),
  }
end
local pgame = partyGame()
local pm = PartyMenu.new(pgame)
pm.game = pgame
pgame.stack:push(pm)
press(pm, "a")
check(pm.submenu and #pm.subItems == 2
  and pm.subItems[1].label == "STATS" and pm.subItems[2].label == "SWITCH",
  "vanilla party submenu unchanged with no hooks")
pm.submenu = nil

local ranWith
hooks:wrap("ui.party.submenu", function(nextFn, game, items, mon, ctx)
  table.insert(items, { label = "QUESTS",
    onSelect = function(m) ranWith = m end })
  return nextFn(game, items, mon, ctx)
end, 0, "fixture")
press(pm, "a")
check(#pm.subItems == 3 and pm.subItems[3].label == "QUESTS",
  "hook appends a party submenu entry")
pm.subIndex = 3
press(pm, "a")
check(ranWith == pgame.save.party[1],
  "an injected entry's onSelect runs with the focused mon")
check(not pm.submenu, "the submenu closes after an injected entry runs")
hooks:removeOwner("fixture")

hooks:wrap("ui.party.submenu", function() return nil end, 0, "bad")
press(pm, "a")
check(#pm.subItems == 2, "a non-table submenu result keeps the vanilla list")
hooks:removeOwner("bad")
pm.submenu = nil

-- ------- mod.ui helpers and theme defaults
local items = { { label = "A" }, { label = "B" } }
ModUI.insertAfter(items, "A", { label = "X" })
check(items[2].label == "X", "insertAfter lands behind its anchor")
ModUI.insertBefore(items, "A", { label = "Y" })
check(items[1].label == "Y", "insertBefore lands ahead of its anchor")
ModUI.removeLabel(items, "X")
check(#items == 3 and items[3].label == "B", "removeLabel drops the entry")
ModUI.insertBefore(items, "MISSING", { label = "Z" })
check(items[#items].label == "Z", "a missing anchor appends")
check(ModUI.Menu == require("src.ui.Menu"), "mod.ui exposes the widgets")
check(ModUI.TextBox == require("src.render.TextBox"),
  "mod.ui exposes TextBox")
check(type(ModUI.push) == "function", "mod.ui.push opens screens")

check(Theme.cursor == 0xED and Theme.cursorHollow == 0xEC
  and Theme.moreArrow == 0xEE, "theme defaults are the old literals")
check(Theme.choiceBox.tx == 0 and Theme.choiceBox.ty == 7
  and Theme.choiceBox.tw == 6 and Theme.choiceBox.th == 5,
  "choice box geometry keeps its vanilla tiles")
Theme.load({ field = { theme = { cursor = 0xAA } } })
check(Theme.cursor == 0xAA, "field.theme restyles the cursor glyph")
Theme.cursor = 0xED

-- ------- branding reads from field.*
local TitleState = require("src.ui.TitleState")
local tgame = { data = { field = { title = {
  cycleSpecies = { "MEW" }, music = "My_Song", copyrightText = "HELLO",
} }, pokemon = { MEW = {} } } }
local title = TitleState.new(tgame, {})
check(#title.cycleSpecies == 1 and title.cycleSpecies[1] == "MEW",
  "field.title.cycleSpecies replaces the literal list")
check(title.title.music == "My_Song", "field.title.music is read")
title = TitleState.new({ data = {} }, {})
check(#title.cycleSpecies == 16 and title.cycleSpecies[1] == "CHARMANDER",
  "no data keeps the vanilla cycle list")
check(title.logo and title.logo.path == "assets/logo/pokemon_logo.png",
  "no data keeps the shipped logo")

-- the importer seeds field.title with {path,width,height} descriptors
-- (data/generated/field.lua); they must load via their path, and the
-- file-12 plain-string shape must keep working
title = TitleState.new({ data = { field = { title = {
  logo = { path = "assets/generated/title/pokemon_logo.png",
           width = 128, height = 56 },
  version = { path = "assets/generated/title/red_version.png",
              width = 80, height = 8 },
} } } }, {})
check(title.logo and title.logo.path
  == "assets/generated/title/pokemon_logo.png",
  "a {path} logo descriptor loads its image")
check(title.version and title.version.path
  == "assets/generated/title/red_version.png",
  "the importer's version descriptor feeds the ribbon")
title = TitleState.new({ data = { field = { title = {
  logo = "mods/x/logo.png", versionRibbon = "mods/x/ribbon.png",
} } } }, {})
check(title.logo and title.logo.path == "mods/x/logo.png",
  "a plain-string logo path loads directly")
check(title.version and title.version.path == "mods/x/ribbon.png",
  "versionRibbon wins as the file-12 patch key")
-- pin against the shipped data itself: a real boot must load the logo
-- art, never fall back to the ASCII placeholder
title = TitleState.new({ data = { field = dofile("data/generated/field.lua") } },
                       {})
check(title.logo and title.logo.path
  == "assets/generated/title/pokemon_logo.png",
  "the shipped field.title.logo loads its art")
check(title.version and title.version.path
  == "assets/generated/title/red_version.png",
  "the shipped version ribbon loads")

local OakSpeech = require("src.ui.OakSpeech")
local ogame = { data = {
  field = { oakSpeech = { music = "X_Song", demoSpecies = "PIKACHU" } },
  pokemon = { PIKACHU = {} }, trainers = {},
  constants = { playerNameLength = 10 },
} }
local oak = OakSpeech.new(ogame, nil)
check(oak.demoSpecies == "PIKACHU", "field.oakSpeech.demoSpecies is read")
check(oak.nameLen == 10, "constants.playerNameLength caps the naming screen")
check(oak.cfg.music == "X_Song", "field.oakSpeech.music is read")
oak = OakSpeech.new({ data = {} }, nil)
check(oak.demoSpecies == "NIDORINO" and oak.nameLen == 7,
  "no data keeps the vanilla speech values")

local IntroMovie = require("src.ui.IntroMovie")
local introDone = false
local igame = { data = { field = { intro = {
  studio = { card = "MY STUDIO", credit = "ME" }, skip = true,
  music = "Alt_Battle",
} } }, stack = newStack(), input = newInput() }
local movie = IntroMovie.new(igame, function() introDone = true end)
check(movie.studio.card == "MY STUDIO" and movie.studio.credit == "ME",
  "field.intro.studio strings are read")
check(movie.introCfg.music == "Alt_Battle", "field.intro.music is read")
igame.stack:push(movie)
movie:update(1 / 60)
check(introDone and #igame.stack.states == 0,
  "field.intro.skip jumps straight past the movie")

local Credits = require("src.ui.Credits")
local credits = Credits.new({ data = { field = {
  credits = { music = "My_Credits" } } } }, nil, nil)
check(credits.music == "My_Credits", "field.credits.music is read")
credits = Credits.new({ data = {} }, nil, nil)
check(credits.music == "Music_Credits", "no data keeps the vanilla song")

-- ------- ManagerState v2
check(ManagerState.onKeyPressed == nil,
  "the manager reads mapped input, not raw keys")
check(ManagerState.screenId == "ManagerState",
  "the manager carries its screen id for the F10 toggle")

local function manifest(id, over)
  local m = { id = id, name = id:upper(), version = "1.0.0",
    category = "OTHER", state = "loaded", enabled = true,
    dependencySpecs = {}, conflictSpecs = {}, permissions = {},
    description = "a mod" }
  for k, v in pairs(over or {}) do m[k] = v end
  return m
end

local function fakeLoader(available, loadErrors)
  local loader = { optionSchemas = {}, modOptions = {},
    events = Events.new(), errors = loadErrors or {} }
  function loader:status()
    return { available = available, loaded = {}, errors = self.errors,
      order = {} }
  end
  function loader:setEnabled(id, enabled)
    for _, m in ipairs(available) do
      if m.id == id then m.enabled = enabled end
    end
    return true
  end
  return loader
end

local function managerGame(loader)
  return { data = {}, stack = newStack(), input = newInput(),
    save = { options = { mods = {} } }, mods = loader,
    modStatus = loader:status() }
end

-- resolveToggle: the table-driven dependency cases
local RT = ManagerState.resolveToggle
local rtMods = {
  base = manifest("base"),
  addon = manifest("addon", { dependencySpecs = { { id = "base" } } }),
  rival = manifest("rival", { conflictSpecs = { { id = "base" } } }),
  old = manifest("old", { game_version = ">=99.0.0" }),
  strict = manifest("strict",
    { dependencySpecs = { { id = "base", range = ">=2.0.0" } } }),
  ghostly = manifest("ghostly", { dependencySpecs = { { id = "ghost" } } }),
}
local r = RT(rtMods, "base", false, { base = true })
check(r.apply.base == false and #r.alsoDisable == 0 and #r.missing == 0,
  "clean flip: no cascade")
r = RT(rtMods, "base", false, { base = true, addon = true })
check(r.apply.base == false and r.apply.addon == false
  and r.alsoDisable[1] == "addon", "disabling a dep cascades to dependents")
r = RT(rtMods, "addon", true, {})
check(r.apply.addon == true and r.apply.base == true
  and r.alsoEnable[1] == "base", "enabling pulls hard deps in")
r = RT(rtMods, "ghostly", true, {})
check(r.missing[1] == "ghost", "a missing dep blocks")
r = RT(rtMods, "rival", true, { base = true })
check(r.conflicts[1] == "base", "a co-enabled conflict blocks")
r = RT(rtMods, "old", true, {})
check(#r.badVersion == 1 and r.badVersion[1].engine,
  "an engine version mismatch blocks")
r = RT(rtMods, "strict", true, { base = true })
check(#r.badVersion == 1 and r.badVersion[1].id == "base",
  "a dep range mismatch blocks")

-- errors are visible: glyph on the roster, message on the errors screen
local avail = {
  manifest("badmod", { state = "failed", error = "boom" }),
  manifest("okmod"),
}
local loader = fakeLoader(avail, { "badmod: boom" })
local mgame = managerGame(loader)
-- production wiring: the runtime error feed is the loader's error list
Runtime.errors = loader.errors
local ms = ManagerState.new(mgame)
mgame.stack:push(ms)
local rows = ms:modRows()
check(rows[1].header and rows[1].label == "OTHER",
  "categories are section headers")
check(rows[2].mod.id == "badmod" and rows[2].glyph == "!",
  "an errored mod carries the ! glyph")
check(rows[3].mod.id == "okmod" and rows[3].glyph == " ",
  "a healthy mod has a clear gutter")
local lines = ms:errorLines(nil)
check(lines[1]:find("badmod: boom", 1, true) ~= nil,
  "loader errors finally render in the manager")
check(ms:errorLines(avail[1])[1]:find("FAILED: boom", 1, true) ~= nil,
  "the per-mod error leads its own view")

-- select stages a clean toggle; discard reverts it
check(ms.cursor == 2, "the cursor skips the category header")
press(ms, "select")
check(avail[1].enabled == false, "SELECT quick-toggles the focused mod")
check(ms:isStaged(avail[1]), "a flip against boot state is staged")
check(ms:glyphFor(avail[1]) == ".", "staged mods show the staged glyph")
check(mgame.save.options.mods.badmod == false,
  "the live options table mirrors the flip")
check(ms.restartPending, "staged changes arm the apply screen")
ms:discardChanges()
check(avail[1].enabled == true and not ms.restartPending,
  "discard restores the boot enable set")

-- cascade dialog: disabling a dep asks before flipping both
local avail2 = {
  manifest("base"),
  manifest("addon", { dependencySpecs = { { id = "base" } } }),
}
local mgame2 = managerGame(fakeLoader(avail2))
local ms2 = ManagerState.new(mgame2)
mgame2.stack:push(ms2)
ms2:beginToggle(ms2.byId.base)
check(ms2.overlay and ms2.overlay.kind == "confirm",
  "a cascading toggle opens the consent dialog")
check(avail2[1].enabled and avail2[2].enabled,
  "nothing flips before consent")
press(ms2, "a") -- YES
check(avail2[1].enabled == false and avail2[2].enabled == false,
  "consent flips the whole closure")

-- blocked dialog: a missing dep explains and refuses
local avail3 = { manifest("lonely", { enabled = false, state = "disabled",
  dependencySpecs = { { id = "ghost" } } }) }
local mgame3 = managerGame(fakeLoader(avail3))
local ms3 = ManagerState.new(mgame3)
mgame3.stack:push(ms3)
ms3:beginToggle(ms3.byId.lonely)
check(ms3.overlay and ms3.overlay.kind == "ok", "a blocked toggle explains")
check(ms3.overlay.lines[1] == "NEEDS ghost", "the dialog names the dep")
check(avail3[1].enabled == false, "a blocked toggle never flips")
press(ms3, "a")
check(ms3.overlay == nil, "the blocked dialog dismisses")

-- options auto-UI: schema rows edit, persist, emit, reset
local schema = {
  { key = "hardcore", label = "NUZLOCKE", type = "toggle", default = false },
  { key = "odds", label = "ODDS", type = "choice",
    choices = { { "STD", "std" }, { "BOOST", "boosted" } }, default = "std" },
  { key = "startMoney", label = "START", type = "number",
    min = 0, max = 9000, step = 1000, default = 3000 },
  { key = "tag", label = "RIVAL", type = "text", maxLen = 7,
    default = "BLUE" },
  { bad = "row" },
}
loader.optionSchemas.okmod = schema
local heardOpt
loader.events:on("mod.options_changed", function(e) heardOpt = e end, 0, "t")
ms.currentMod = ms.byId.okmod
ms:openOptions(ms.byId.okmod)
check(ms.screen == "options", "OPTIONS.. routes to the options screen")
check(#ms.optionRows == 5, "four typed rows plus RESET; malformed skipped")
check(loader.errors[#loader.errors]:find("options row skipped", 1, true),
  "the malformed row lands in the error feed")
ms.optionRows[1].step(mgame, 1)
check(mgame.save.options.modOptions.okmod.hardcore == true,
  "a toggle edit persists to options.modOptions")
check(loader.modOptions.okmod.hardcore == true,
  "the live value is visible to mod.options:get")
check(heardOpt and heardOpt.mod == "okmod" and heardOpt.key == "hardcore"
  and heardOpt.value == true, "mod.options_changed fires on edit")
check(ms.optionRows[1].value(mgame) == "ON", "the toggle renders its state")
ms.optionRows[2].step(mgame, 1)
check(loader.modOptions.okmod.odds == "boosted"
  and ms.optionRows[2].value(mgame) == "BOOST",
  "a choice edit cycles and renders its label")
ms.optionRows[3].step(mgame, -1)
check(loader.modOptions.okmod.startMoney == 2000, "a number edit steps")
for _ = 1, 5 do ms.optionRows[3].step(mgame, -1) end
check(loader.modOptions.okmod.startMoney == 0, "number edits clamp at min")
ms.optionRows[4].activate()
check(getmetatable(mgame.stack:top()) == require("src.ui.NamingScreen"),
  "a text row opens the naming screen")
mgame.stack:top().onDone("REDD")
mgame.stack:pop()
check(loader.modOptions.okmod.tag == "REDD", "the typed text persists")
ms.optionRows[5].activate()
check(loader.modOptions.okmod.hardcore == false
  and loader.modOptions.okmod.odds == "std"
  and loader.modOptions.okmod.startMoney == 3000
  and loader.modOptions.okmod.tag == "BLUE",
  "RESET DEFAULTS restores every schema default")
press(ms, "b")
check(ms.screen == "list", "B leaves the options screen")

-- profiles: save, drift to ad-hoc, apply, rename, delete
ms.tab = 2
ms:saveCurrentAs()
mgame.stack:top().onDone("EASY")
mgame.stack:pop()
local easy = ms:findProfile("EASY")
check(easy ~= nil and easy.enabled.badmod == true,
  "SAVE CURRENT AS snapshots the enable set")
check(ms:optionsTable().activeProfile == "EASY", "the new profile is active")
ms:commitToggle({ okmod = false })
check(ms:optionsTable().activeProfile == nil,
  "an off-profile toggle reverts to the ad-hoc set")
ms:applyProfile(easy)
check(ms.byId.okmod.enabled == true
  and ms:optionsTable().activeProfile == "EASY",
  "applying a profile stages the flips back")
ms:renameProfile(easy)
mgame.stack:top().onDone("HARD")
mgame.stack:pop()
check(easy.name == "HARD" and ms:optionsTable().activeProfile == "HARD",
  "rename keeps the active pointer")
ms:deleteProfile(easy)
check(ms:findProfile("HARD") == nil
  and ms:optionsTable().activeProfile == nil, "delete clears the profile")

-- permissions rows
local permy = manifest("permy", { permissions = { "network" } })
local msP = ManagerState.new(managerGame(fakeLoader({ permy })))
msP.game.stack:push(msP)
local prows = msP:permissionRows(permy)
check(prows[1].glyph == "!" and prows[1].label == "USES THE NETWORK",
  "declared permissions render with risk glyphs")
check(msP:permissionRows(manifest("pure"))[1].label == "DATA & API ONLY",
  "no permissions shows the synthetic clean row")

-- safe mode: the banner rides Runtime.safeMode, never an option
Runtime.safeMode = true
local msS = ManagerState.new(mgame)
msS:enter()
check(msS.banner == "SAFE MODE - ALL MODS OFF",
  "safe mode shows the recovery banner")
Runtime.safeMode = nil
local msN = ManagerState.new(mgame)
msN:enter()
check(msN.banner == nil, "no safe mode, no banner")

-- empty roster shows the empty state and B closes the manager
local msE = ManagerState.new(managerGame(fakeLoader({})))
msE.game.stack:push(msE)
check(msE:modRows()[1].label == "NO MODS INSTALLED", "empty-state row")
press(msE, "b")
check(#msE.game.stack.states == 0, "B on the roster closes the manager")

-- ------- mod.ui through a loader-built api
-- the worked example in 12 6 does mod.ui.insertBefore / mod.ui.push /
-- mod.ui.Theme on the api the loader hands the entry chunk, so the facade
-- has to arrive wired there, not just exist as a module
local Loader = require("src.mods.Loader")
local uiFiles = {
  ["mods/uikit/manifest.json"] =
    '{"id":"uikit","name":"uikit","version":"1.0.0","entry":"main.lua","api":2}',
  ["mods/uikit/main.lua"] = "return function(mod) _G.MOD_UI_API = mod end",
}
local uiFs = {
  read = function(path) return uiFiles[path] end,
  getInfo = function(path)
    if uiFiles[path] then return { type = "file" } end
    local prefix = path .. "/"
    for key in pairs(uiFiles) do
      if key:sub(1, #prefix) == prefix then return { type = "directory" } end
    end
    return nil
  end,
  load = function(path)
    if not uiFiles[path] then return nil, "no file: " .. path end
    return load(uiFiles[path], path)
  end,
  getDirectoryItems = function(path)
    local seen, names = {}, {}
    local prefix = path .. "/"
    for key in pairs(uiFiles) do
      if key:sub(1, #prefix) == prefix then
        local child = key:sub(#prefix + 1):match("^[^/]+")
        if child and not seen[child] then
          seen[child] = true
          names[#names + 1] = child
        end
      end
    end
    table.sort(names)
    return names
  end,
}
local uiLoader = Loader.new({ fs = uiFs })
check(uiLoader:load({}) == true, "the uikit fixture loads clean")
local uiApi = _G.MOD_UI_API
_G.MOD_UI_API = nil
check(uiApi ~= nil, "the entry chunk received its api")
check(uiApi.ui == ModUI, "mod.ui is the toolkit facade")
check(uiApi.ui.Theme == Theme, "mod.ui.Theme reaches the theme module")
check(uiApi.ui.Menu == require("src.ui.Menu"),
  "mod.ui widgets resolve through the loader-built api")
local uiItems = { { label = "ITEM" } }
uiApi.ui.insertBefore(uiItems, "ITEM", { label = "QUESTS" })
check(uiItems[1].label == "QUESTS" and uiItems[2].label == "ITEM",
  "mod.ui.insertBefore works as documented")
local uiGame = { data = {}, stack = newStack() }
local uiPushed = uiApi.ui.push(uiGame, "TrainerCard")
check(uiGame.stack:top() == uiPushed and uiPushed.screenId == "TrainerCard",
  "mod.ui.push opens a screen from a loader-built api")

Runtime.safeMode = savedSafeMode
Runtime.install(savedEvents, savedHooks, savedErrors)

S.finish()
