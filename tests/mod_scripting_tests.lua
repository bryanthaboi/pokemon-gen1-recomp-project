-- Scripting v2 (M5): label resolution, the commands registry consumed by
-- dispatch, map_scripts compose semantics, the queueScript FIFO, bounded
-- parallel runners, the tokens registry, mod-field routing, load-time
-- validation and the script events/hook.
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local Commands = require("src.script.Commands")
local Data = require("src.core.Data")
local Events = require("src.mods.Events")
local Flags = require("src.script.Flags")
local Hooks = require("src.mods.Hooks")
local Loader = require("src.mods.Loader")
local Logger = require("src.core.Logger")
local MapScripts = require("src.script.MapScripts")
local OW = require("src.world.OverworldController")
local Runtime = require("src.mods.Runtime")
local ScriptRunner = require("src.script.ScriptRunner")
local TextBox = require("src.render.TextBox")
local Tokens = require("src.script.Tokens")

local S = require("tests.harness").suite("scripting v2 (M5)")
local check = S.check

if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end

local function memfs(files)
  return {
    read = function(path) return files[path] end,
    getInfo = function(path)
      if files[path] then return { type = "file" } end
      local prefix = path .. "/"
      for key in pairs(files) do
        if key:sub(1, #prefix) == prefix then return { type = "directory" } end
      end
      return nil
    end,
    load = function(path)
      if not files[path] then return nil, "no file: " .. path end
      return load(files[path], path)
    end,
    getDirectoryItems = function(path)
      local seen, items = {}, {}
      local prefix = path .. "/"
      for key in pairs(files) do
        if key:sub(1, #prefix) == prefix then
          local child = key:sub(#prefix + 1):match("^[^/]+")
          if child and not seen[child] then
            seen[child] = true
            items[#items + 1] = child
          end
        end
      end
      table.sort(items)
      return items
    end,
  }
end

local function newGame()
  return { data = Data, save = { flags = {}, inventory = {} } }
end

local function drive(runner, frames)
  for _ = 1, frames or 200 do
    if not runner:isRunning() then return true end
    runner:update()
  end
  return not runner:isRunning()
end

-- ------- labels

do
  local labeled = {
    { "check_flag", "MOD_SCRIPT_L" },
    { "jump_if_true", "yes" },
    { "set_field", "labelPath", "no" },
    { "jump", "end" },
    { "label", "yes" },
    { "set_field", "labelPath", "yes" },
  }
  local numbered = {
    { "check_flag", "MOD_SCRIPT_L" },
    { "jump_if_true", 5 },
    { "set_field", "labelPath", "no" },
    { "jump", math.huge },
    { "set_field", "labelPath", "yes" },
  }
  for _, flagged in ipairs({ false, true }) do
    local results = {}
    for kind, script in pairs({ labeled = labeled, numbered = numbered }) do
      local game = newGame()
      if flagged then Flags.set(game.save, "MOD_SCRIPT_L") end
      local runner = ScriptRunner.new(game, nil)
      runner:run(script, {})
      check(not runner:isRunning(), kind .. " script completes")
      results[kind] = game.save.labelPath
    end
    check(results.labeled == results.numbered,
      "label jumps match the hand-numbered equivalent")
    check(results.labeled == (flagged and "yes" or "no"),
      "label branch picks the right path")
  end

  local labels = ScriptRunner.scanLabels(labeled)
  check(labels.yes == 5, "scanLabels finds the label row")

  -- a jump to a missing label kills the script instead of skipping
  local game = newGame()
  local runner = ScriptRunner.new(game, nil)
  runner:run({ { "jump", "nowhere" }, { "set_field", "after", 1 } }, {})
  check(not runner:isRunning() and game.save.after == nil,
    "missing label kills the script")
end

-- ------- unknown verbs: v1 skip vs api-2 strict kill

do
  local game = newGame()
  local runner = ScriptRunner.new(game, nil)
  runner:run({ { "totally_bogus_verb" }, { "set_field", "after", 1 } }, {})
  check(game.save.after == 1, "unknown verb skips for compat scripts")

  game = newGame()
  runner = ScriptRunner.new(game, nil)
  runner:run({ { "totally_bogus_verb" }, { "set_field", "after", 1 } },
    { source = { modId = "tmod", strict = true } })
  check(not runner:isRunning() and game.save.after == nil,
    "unknown verb kills a strict (api 2) script")
end

-- ------- load-time validation

do
  local problems = ScriptRunner.validate({
    { "label", "a" },
    { "label", "a" },
    { "jump", "missing" },
    { "bogus_verb" },
    { "jump", 99 },
    "not a row",
  })
  local text = table.concat(problems, "\n")
  check(text:find("duplicate label 'a'", 1, true), "duplicate label reported")
  check(text:find("row 2", 1, true), "duplicate names its row")
  check(text:find("missing label 'missing'", 1, true), "missing label reported")
  check(text:find("unknown command 'bogus_verb'", 1, true), "unknown verb reported")
  check(text:find("out of range", 1, true), "numeric jump bounds checked")
  check(text:find("row 6 is not", 1, true), "malformed row reported")

  check(#ScriptRunner.validate({ { "set_flag", "X" }, { "jump", "end" } }) == 0,
    "a clean script validates clean")

  local findings = MapScripts.validateContribution({
    talk = { TEXT_V = { { "typod_verb" } } },
    scripts = { amb = { { "jump", "gone" } } },
  })
  local joined = table.concat(findings, "\n")
  check(joined:find("talk.TEXT_V", 1, true), "contribution findings name the talk key")
  check(joined:find("scripts.amb", 1, true), "contribution findings name the script key")
end

-- ------- commands registry: mod verbs, override wins, collision fails

do
  local fs = memfs({
    ["mods/tmod/manifest.json"] =
      '{"id":"tmod","name":"T","version":"1.0.0","entry":"main.lua","api":2}',
    ["mods/tmod/main.lua"] = [[
return function(mod)
  mod.commands:register("tmod:mark", function(ctx, value)
    ctx.save.marked = value
  end)
  mod.content.commands:override("give_money", function(ctx, amount)
    ctx.save.money = 777
  end)
  mod.content.tokens:register("TMOD_X", function() return "42" end)
  mod.content.map_scripts:register("MOD_LOADER_MAP", {
    talk = { TEXT_T = { { "tmod:mark", 5 } } },
  })
end
]],
  })
  local loader = Loader.new({ fs = fs })
  local data = { pokemon = {}, moves = {}, items = {} }
  check(loader:load(data) == true, "scripting fixture mod loads")
  check(type(data.commands["tmod:mark"]) == "function", "mod verb merges")

  local game = { data = data, save = { flags = {}, inventory = {}, money = 0 } }
  local runner = ScriptRunner.new(game, nil)
  runner:run({ { "tmod:mark", 5 }, { "give_money", 10 } }, {})
  check(game.save.marked == 5, "a mod-registered verb dispatches")
  check(game.save.money == 777, "a mod override of an engine verb wins dispatch")

  -- the merged chain drives MapScripts through the same store the loader wrote
  local savedChains = Data.map_scripts
  Data.map_scripts = data.map_scripts
  MapScripts.invalidate()
  local rows = MapScripts.talkScript("MOD_LOADER_MAP", "TEXT_T")
  check(type(rows) == "table" and rows[1][1] == "tmod:mark",
    "a registered map_scripts talk entry resolves")
  Data.map_scripts = savedChains
  MapScripts.invalidate()

  -- tokens registry drives substitution
  local tokenGame = { data = data, save = { player = { name = "ASH" } } }
  check(TextBox.substitute(tokenGame, "{TMOD_X}/{PLAYER}") == "42/ASH",
    "a mod token expands beside the engine set")

  -- register over an engine verb is a collision, not a silent replace
  local clash = Loader.new({ fs = memfs({
    ["mods/clash/manifest.json"] =
      '{"id":"clash","name":"C","version":"1.0.0","entry":"main.lua","api":2}',
    ["mods/clash/main.lua"] = [[
return function(mod)
  mod.commands:register("show_text", function() end)
end
]],
  }) })
  check(clash:load({ pokemon = {} }) == false,
    "registering over an engine verb fails the mod")
end

-- ------- foreground metadata and parallel rejection

do
  check(Commands.meta.show_text.foreground and Commands.meta.show_text.blocking,
    "show_text carries foreground+blocking metadata")
  check(Commands.meta.wait_flag.blocking and not Commands.meta.wait_flag.foreground,
    "wait_flag is background-legal")

  local game = newGame()
  local runner = ScriptRunner.new(game, nil)
  runner.parallel = true
  runner:run({ { "show_text", "HI" }, { "set_field", "after", 1 } }, {})
  check(not runner:isRunning() and game.save.after == nil,
    "a foreground verb kills a parallel script")

  game = newGame()
  runner = ScriptRunner.new(game, nil)
  runner.parallel = true
  runner:run({ { "set_flag", "MOD_BG_OK" } }, {})
  check(Flags.get(game.save, "MOD_BG_OK"), "background-legal verbs run in parallel")
end

-- ------- tokens: engine parity and the unknown-token fallback

do
  local game = { save = { player = { name = "ASH" } }, stringBuffer = "POTION" }
  check(TextBox.substitute(game, "{PLAYER} got\n{RAM:wStringBuffer}!")
    == "ASH got\nPOTION!", "PLAYER and RAM expand as before")
  check(TextBox.substitute(game, "{RIVAL}") == "BLUE", "RIVAL keeps its default")
  check(TextBox.substitute(game, "A{RAM:wOtherBuffer}B") == "AB",
    "an unhandled RAM buffer still drops silently")

  local before = #Logger.history
  check(Tokens.expand(game, "A{MOD_NOPE_TOKEN}B{MOD_NOPE_TOKEN}C",
    TextBox.TOKENS) == "ABC", "an unknown token is dropped, not rendered")
  local warns = 0
  for i = before + 1, #Logger.history do
    if Logger.history[i]:find("MOD_NOPE_TOKEN", 1, true) then warns = warns + 1 end
  end
  check(warns == 1, "the unknown token warns once, not per occurrence")
end

-- ------- tokens: golden parity sweep over the vanilla text corpus

do
  -- the pre-registry substitute, reproduced verbatim as the oracle: the
  -- registry path must render every vanilla string byte-identically,
  -- including the {NUM:...} extractor spans the old catch-all left alone
  local function oracle(game, text)
    local save = game.save
    text = text:gsub("{PLAYER}", save.player.name or "RED")
    text = text:gsub("{RIVAL}", save.player.rival or "BLUE")
    if game.stringBuffer then
      text = text:gsub("{RAM:wStringBuffer}", game.stringBuffer)
    end
    text = text:gsub("{[%w_:]+}", "")
    return text
  end
  local game = { save = { player = { name = "ASH", rival = "GARY" } },
                 stringBuffer = "POTION" }
  check(type(Data.text) == "table" and next(Data.text) ~= nil,
    "the text corpus is loaded")
  local swept = 0
  for id, text in pairs(Data.text) do
    if type(text) == "string" then
      check(TextBox.substitute(game, text) == oracle(game, text),
        "token expansion diverges from the oracle on " .. tostring(id))
      swept = swept + 1
    end
  end
  check(swept > 2000, "the sweep covered the generated corpus")
end

-- ------- map_scripts compose semantics

do
  local calls = {}
  local baseTalk = { { "set_flag", "BASE_TALK" } }
  MapScripts.attachBase("MOD_COMPOSE_MAP", {
    talk = { TEXT_A = baseTalk, TEXT_B = { { "set_flag", "BASE_B" } } },
    onEnter = function() calls[#calls + 1] = "base" end,
    onStep = function() calls[#calls + 1] = "base_step" return false end,
  })
  local fastPath = MapScripts.get("MOD_COMPOSE_MAP")
  check(fastPath.talk.TEXT_A == baseTalk,
    "no chain returns the base table untouched")

  -- the loader writes Registry:chain output: priority descending, then
  -- registration order; the view re-ranks equal-priority ties so the
  -- later registration wins, and slots base at priority 0 behind mods
  local modTalkA = { { "set_flag", "MOD_TALK" } }
  local chain = {
    { priority = 5, onEnter = function() calls[#calls + 1] = "D" end,
      talk = { TEXT_B = false } },
    { onEnter = function() calls[#calls + 1] = "A" end,
      talk = { TEXT_A = modTalkA },
      scripts = { amb = { { "set_flag", "AMB" } } } },
    { onEnter = function() calls[#calls + 1] = "B" error("boom") end,
      onStep = function() calls[#calls + 1] = "B_step" return true end },
    { priority = -1, onEnter = function() calls[#calls + 1] = "C" end },
  }
  local savedChains = Data.map_scripts
  Data.map_scripts = { MOD_COMPOSE_MAP = chain }
  MapScripts.invalidate()

  local view = MapScripts.get("MOD_COMPOSE_MAP")
  check(MapScripts.get("MOD_COMPOSE_MAP") == view, "merged views are cached")

  check(view.talk.TEXT_A == modTalkA, "talk is single-winner: the mod outranks base")
  check(view.talk.TEXT_B == nil, "talk false suppresses the base entry")
  check(MapScripts.baseTalk("MOD_COMPOSE_MAP", "TEXT_A") == baseTalk,
    "baseTalk still reaches the engine handler behind the override")
  check(MapScripts.namedScript("MOD_COMPOSE_MAP", "amb") ~= nil,
    "scripts entries resolve by MAP/name")

  calls = {}
  view.onEnter({}, {})
  check(table.concat(calls, ",") == "D,B,A,base,C",
    "onEnter all-run order: priority desc, later-first ties, base behind, "
    .. "negative after base, throwing sibling isolated (got "
    .. table.concat(calls, ",") .. ")")

  calls = {}
  local consumed = view.onStep({}, {}, 0, 0)
  check(consumed == true and #calls == 1 and calls[1] == "B_step",
    "onStep first truthy return consumes the step")

  Data.map_scripts = savedChains
  MapScripts.invalidate()
  check(MapScripts.get("MOD_COMPOSE_MAP").talk.TEXT_A == baseTalk,
    "dropping the chain restores the base fast path")

  -- a mod talk script on a real map merges beside the vanilla NPCs
  local init = require("data.scripts.init")
  local clerk = init.talkScript("VIRIDIAN_MART", "TEXT_VIRIDIANMART_CLERK")
  check(clerk ~= nil, "the vanilla clerk script is registered")
  Data.map_scripts = { VIRIDIAN_MART = {
    { talk = { TEXT_VIRIDIANMART_MODNPC = { { "set_flag", "MOD_HELLO" } } } },
  } }
  MapScripts.invalidate()
  check(init.talkScript("VIRIDIAN_MART", "TEXT_VIRIDIANMART_MODNPC") ~= nil,
    "the mod talk entry resolves on an existing map")
  check(init.talkScript("VIRIDIAN_MART", "TEXT_VIRIDIANMART_CLERK") == clerk,
    "the vanilla clerk script is not displaced")
  Data.map_scripts = savedChains
  MapScripts.invalidate()
end

-- ------- map_scripts:override, the total-conversion escape hatch (09 4.4)

do
  local baseRan = false
  local baseTalk = { { "set_flag", "TC_BASE_TALK" } }
  MapScripts.attachBase("MOD_TC_MAP", {
    talk = { TEXT_TC_BASE = baseTalk, TEXT_TC_KEPT = { { "set_flag", "KEPT" } } },
    onEnter = function() baseRan = true end,
    onStep = function() return true end,
    snorlaxWake = { script = { { "set_flag", "WAKE" } } },
  })

  local fs = memfs({
    ["mods/tc/manifest.json"] =
      '{"id":"tc","name":"TC","version":"1.0.0","entry":"main.lua","api":2}',
    ["mods/tc/main.lua"] = [[
return function(mod)
  -- a plain contribution first: override must clear this one too, not just
  -- fold on top of it
  mod.content.map_scripts:register("MOD_TC_MAP", {
    talk = { TEXT_TC_EARLY = { { "set_flag", "EARLY" } } },
  })
  mod.content.map_scripts:override("MOD_TC_MAP", {
    talk = { TEXT_TC_NEW = { { "set_flag", "TC_NEW" } } },
    onEnter = function(game) game.tcRan = true end,
  })
  mod.content.map_scripts:register("MOD_TC_ADD_MAP", {
    talk = { TEXT_TC_ADD = { { "set_flag", "ADD" } } },
  })
end
]],
  })
  local loader = Loader.new({ fs = fs })
  local data = { pokemon = {}, moves = {}, items = {} }
  check(loader:load(data) == true, "total-conversion fixture mod loads")

  local chain = data.map_scripts.MOD_TC_MAP
  check(chain.replacesBase == true, "an override stamps replacesBase on the chain")
  check(#chain == 1, "override collapses the chain to a single contribution")

  local savedChains = Data.map_scripts
  Data.map_scripts = data.map_scripts
  MapScripts.invalidate()

  local view = MapScripts.get("MOD_TC_MAP")
  check(view.talk.TEXT_TC_NEW ~= nil, "the override's own talk entry resolves")
  check(view.talk.TEXT_TC_BASE == nil,
    "base talk entries are absent from an overridden map")
  check(view.talk.TEXT_TC_KEPT == nil,
    "a base TEXT constant the override never redefined does not bleed through")
  check(view.talk.TEXT_TC_EARLY == nil,
    "override clears lower-precedence mod contributions too")
  check(view.snorlaxWake == nil, "legacy base keys are cleared by an override")
  check(view.onStep == nil, "base hooks are absent from an overridden map")

  baseRan = false
  local probe = {}
  view.onEnter(probe, {})
  check(probe.tcRan == true, "the override's onEnter runs")
  check(baseRan == false, "base onEnter does not run on an overridden map")

  -- the control: a plain register still composes on top of base
  check(MapScripts.get("MOD_TC_ADD_MAP") ~= nil, "a register-only map still merges")
  check(data.map_scripts.MOD_TC_ADD_MAP.replacesBase == nil,
    "a register-only chain is not flagged as replacing base")

  Data.map_scripts = savedChains
  MapScripts.invalidate()
  check(MapScripts.get("MOD_TC_MAP").talk.TEXT_TC_BASE == baseTalk,
    "dropping the chain restores the untouched base contribution")
end

-- ------- map_scripts:remove, the whole-map tombstone (09 4.4)

do
  MapScripts.attachBase("MOD_RM_MAP", {
    talk = { TEXT_RM_BASE = { { "set_flag", "RM_BASE" } } },
    onEnter = function() error("base onEnter ran on a removed map") end,
    snorlaxWake = { script = { { "set_flag", "RM_WAKE" } } },
  })
  local keptTalk = { { "set_flag", "RM_KEPT" } }
  MapScripts.attachBase("MOD_RM_KEPT_MAP", { talk = { TEXT_RM_KEPT = keptTalk } })
  MapScripts.attachBase("MOD_RM_BACK_MAP", {
    talk = { TEXT_RM_BACK_BASE = { { "set_flag", "RM_BACK_BASE" } } },
  })

  local fs = memfs({
    ["mods/rmadd/manifest.json"] =
      '{"id":"rmadd","name":"Add","version":"1.0.0","entry":"main.lua","api":2}',
    ["mods/rmadd/main.lua"] = [[
return function(mod)
  mod.content.map_scripts:register("MOD_RM_MAP", {
    talk = { TEXT_RM_ADDED = { { "set_flag", "RM_ADDED" } } },
    onEnter = function(game) game.addedRan = true end,
  })
end
]],
    -- depends on rmadd so the remove is guaranteed to land after it
    ["mods/rmcut/manifest.json"] =
      '{"id":"rmcut","name":"Cut","version":"1.0.0","entry":"main.lua","api":2,'
      .. '"dependencies":["rmadd"]}',
    ["mods/rmcut/main.lua"] = [[
return function(mod)
  mod.content.map_scripts:remove("MOD_RM_MAP")
  mod.content.map_scripts:remove("MOD_RM_BACK_MAP")
  mod.content.map_scripts:register("MOD_RM_BACK_MAP", {
    talk = { TEXT_RM_BACK_NEW = { { "set_flag", "RM_BACK_NEW" } } },
  })
end
]],
  })
  local loader = Loader.new({ fs = fs })
  local data = { pokemon = {}, moves = {}, items = {} }
  check(loader:load(data) == true, "map_scripts remove fixture loads")

  local chain = data.map_scripts.MOD_RM_MAP
  check(type(chain) == "table" and #chain == 0,
    "a removed map merges as an empty chain, not as a missing key")
  check(chain.replacesBase == true,
    "the tombstone is stamped so the consumer drops its base contribution")

  local savedChains = Data.map_scripts
  Data.map_scripts = data.map_scripts
  MapScripts.invalidate()

  local init = require("data.scripts.init")
  check(MapScripts.get("MOD_RM_MAP") == nil,
    "a removed map has no view: no base talk, no base onEnter, no snorlaxWake")
  check(init.get("MOD_RM_MAP") == nil, "the dispatcher sees the map as gone")
  check(MapScripts.talkScript("MOD_RM_MAP", "TEXT_RM_BASE") == nil,
    "base talk does not survive the removal")
  check(MapScripts.baseTalk("MOD_RM_MAP", "TEXT_RM_BASE") ~= nil,
    "the base contribution itself is untouched, only excluded")
  check(MapScripts.talkScript("MOD_RM_MAP", "TEXT_RM_ADDED") == nil,
    "remove clears another owner's contribution too")

  -- registering after the tombstone rebuilds the map from nothing
  local backView = MapScripts.get("MOD_RM_BACK_MAP")
  check(backView and backView.talk.TEXT_RM_BACK_NEW ~= nil,
    "a register after remove resurrects the map id")
  check(backView.talk.TEXT_RM_BACK_BASE == nil,
    "and base stays out of the resurrected chain")

  check(MapScripts.get("MOD_RM_KEPT_MAP").talk.TEXT_RM_KEPT == keptTalk,
    "an untouched map still takes the base fast path")

  Data.map_scripts = savedChains
  MapScripts.invalidate()
  check(MapScripts.talkScript("MOD_RM_MAP", "TEXT_RM_BASE") ~= nil,
    "dropping the chain restores the base contribution")
end

-- ------- owner attribution through the real dispatch path

do
  local fs = memfs({
    ["mods/srcmod/manifest.json"] =
      '{"id":"srcmod","name":"S","version":"1.0.0","entry":"main.lua","api":2}',
    ["mods/srcmod/main.lua"] = [[
return function(mod)
  mod.content.map_scripts:register("MOD_SOURCE_MAP", {
    talk = { TEXT_S = { { "set_field", "mod:asked_count", 0 } } },
    scripts = { amb = { { "set_flag", "MOD_SRC_AMB" } } },
  })
end
]],
  })
  local loader = Loader.new({ fs = fs })
  local data = { pokemon = {}, moves = {}, items = {} }
  check(loader:load(data) == true, "source fixture mod loads")
  local chain = data.map_scripts.MOD_SOURCE_MAP
  check(chain.owners and chain.owners[1]
    and chain.owners[1].modId == "srcmod" and chain.owners[1].strict == true,
    "the merged chain carries owner records")

  local savedChains = Data.map_scripts
  Data.map_scripts = data.map_scripts
  MapScripts.invalidate()

  local source = MapScripts.talkSource("MOD_SOURCE_MAP", "TEXT_S")
  check(source and source.modId == "srcmod" and source.strict == true
    and source.mapId == "MOD_SOURCE_MAP" and source.hook == "talk",
    "talkSource names the owning contribution")
  local named = MapScripts.namedSource("MOD_SOURCE_MAP", "amb")
  check(named and named.modId == "srcmod" and named.hook == "scripts.amb",
    "namedSource names the scripts entry owner")

  -- the real showMapText dispatch: the source rides into the runner, so a
  -- mod: field lands in the owner's save.modData bucket instead of killing
  -- the script
  local fakeGame = { data = Data, save = { flags = {}, inventory = {} } }
  local gameIdx, scriptsIdx
  local i = 1
  while true do
    local name = debug.getupvalue(OW.showMapText, i)
    if not name then break end
    if name == "Game" then
      gameIdx = i
      debug.setupvalue(OW.showMapText, i, fakeGame)
    elseif name == "mapScripts" then
      scriptsIdx = i
      debug.setupvalue(OW.showMapText, i, require("data.scripts.init"))
    end
    i = i + 1
  end
  check(gameIdx and scriptsIdx, "showMapText binds Game and mapScripts")
  local ow = setmetatable({
    map = { id = "MOD_SOURCE_MAP", def = { label = "ModSourceMap" } },
  }, { __index = OW })
  ow.runner = ScriptRunner.new(fakeGame, ow)
  ow:showMapText("TEXT_S", nil, nil)
  check(not ow.runner:isRunning(), "the talk rows complete")
  check(fakeGame.save.modData and fakeGame.save.modData.srcmod
    and fakeGame.save.modData.srcmod.asked_count == 0,
    "a mod: field write lands under the owner on the real dispatch path")

  -- a startParallel named ref runs as the owning contribution
  ow:startParallel("MOD_SOURCE_MAP/amb")
  local queued = ow.parallelQueue and ow.parallelQueue[1]
  check(queued and queued.extra and queued.extra.source
    and queued.extra.source.modId == "srcmod",
    "a named parallel ref carries its owner's source")

  debug.setupvalue(OW.showMapText, gameIdx, require("src.core.Game"))
  Data.map_scripts = savedChains
  MapScripts.invalidate()
end

-- ------- hook chains attribute a throwing handler to its owner

do
  local savedEvents, savedHooks, savedErrors =
    Runtime.events, Runtime.hooks, Runtime.errors
  local errs = {}
  Runtime.install(Events.new(), Hooks.new(), errs)
  local savedChains = Data.map_scripts
  Data.map_scripts = { MOD_ATTR_MAP = {
    { onEnter = function() error("attr boom") end },
    owners = { { modId = "attrmod", strict = true } },
  } }
  MapScripts.invalidate()
  local view = MapScripts.get("MOD_ATTR_MAP")
  local before = #Logger.history
  view.onEnter({}, {}) -- must be swallowed, not propagate
  local named = false
  for i = before + 1, #Logger.history do
    if Logger.history[i]:find("attrmod", 1, true) then named = true end
  end
  check(named, "a throwing mod hook logs its owner")
  check(#errs == 1 and errs[1]:find("attrmod", 1, true) ~= nil
    and errs[1]:find("attr boom", 1, true) ~= nil,
    "the failure lands in the runtime error feed")
  Data.map_scripts = savedChains
  MapScripts.invalidate()
  Runtime.install(savedEvents, savedHooks, savedErrors)
end

-- ------- §4.9 through the real loader: bad rows fail an api 2 mod

do
  local badMain = [[
return function(mod)
  mod.commands:register("badmod:mark", function() end)
  mod.content.map_scripts:register("VIRIDIAN_CITY", {
    talk = { TEXT_VIRIDIANCITY_GAMBLER1 = { { "totally_bogus_verb_xyz" } } },
  })
end
]]
  local badFiles = {
    ["mods/badmod/manifest.json"] =
      '{"id":"badmod","name":"B","version":"1.0.0","entry":"main.lua","api":2}',
    ["mods/badmod/main.lua"] = badMain,
  }
  local loader = Loader.new({ fs = memfs(badFiles) })
  local data = { pokemon = {}, moves = {}, items = {} }
  check(loader:load(data) == false, "a typo'd verb fails an api 2 mod at load")
  local seen
  for _, entry in ipairs(loader:status().available) do
    if entry.id == "badmod" then seen = entry end
  end
  check(seen and seen.state == "failed"
    and seen.error:find("unknown command 'totally_bogus_verb_xyz'", 1, true) ~= nil
    and seen.error:find("VIRIDIAN_CITY", 1, true) ~= nil,
    "the manager sees a named load error")
  check(data.map_scripts == nil, "the bad contribution never merges")
  check(data.commands["badmod:mark"] == nil and data.commands.show_text ~= nil,
    "the failed mod's other content rolls back")

  -- the same rows in an api 1 mod keep the v1 runtime skip: warn and load
  local softLoader = Loader.new({ fs = memfs({
    ["mods/softmod/manifest.json"] =
      '{"id":"softmod","name":"S","version":"1.0.0","entry":"main.lua"}',
    ["mods/softmod/main.lua"] = badMain,
  }) })
  local softData = { pokemon = {}, moves = {}, items = {} }
  local before = #Logger.history
  check(softLoader:load(softData) == true, "api 1 findings do not fail the load")
  check(softData.map_scripts and softData.map_scripts.VIRIDIAN_CITY ~= nil,
    "the api 1 contribution still merges")
  local warned = false
  for i = before + 1, #Logger.history do
    if Logger.history[i]:find("totally_bogus_verb_xyz", 1, true) then warned = true end
  end
  check(warned, "api 1 findings surface as warnings")

  -- a dependent of the failed mod is unloaded and purged with it
  local casFiles = {
    ["mods/leech/manifest.json"] = '{"id":"leech","name":"L","version":"1.0.0",'
      .. '"entry":"main.lua","api":2,"dependencies":["badmod"]}',
    ["mods/leech/main.lua"] = [[
return function(mod)
  mod.commands:register("leech:mark", function() end)
end
]],
  }
  for path, content in pairs(badFiles) do casFiles[path] = content end
  local casLoader = Loader.new({ fs = memfs(casFiles) })
  local casData = { pokemon = {}, moves = {}, items = {} }
  check(casLoader:load(casData) == false, "the cascade load fails")
  local states = {}
  for _, entry in ipairs(casLoader:status().available) do
    states[entry.id] = entry.state
  end
  check(states.badmod == "failed" and states.leech == "blocked_dependency",
    "the dependent is taken down with the bad mod")
  check(casData.commands["leech:mark"] == nil,
    "the dependent's content rolls back too")
  check(#casLoader:status().order == 0, "neither mod stays in the load order")
end

-- ------- queueScript FIFO

do
  local ran = {}
  local fakeRunner = { running = false }
  function fakeRunner:isRunning() return self.running end
  function fakeRunner:run(script) ran[#ran + 1] = script end
  function fakeRunner:update() end
  local ow = setmetatable({
    scriptMoves = {}, transitioning = false, runner = fakeRunner,
    map = { id = "MOD_FIFO_MAP" },
  }, { __index = OW })
  local s1, s2, s3 = { "s1" }, { "s2" }, { "s3" }
  ow:queueScript(s1)
  ow:queueScript(s2)
  ow:queueScript(s3)
  check(#ow.pendingScripts == 3, "three scripts queue without clobbering")
  ow:drainPendingScripts()
  check(#ran == 1 and ran[1] == s1, "one script starts per idle frame, in order")
  fakeRunner.running = true
  ow:drainPendingScripts()
  check(#ran == 1, "a busy runner defers the queue")
  fakeRunner.running = false
  ow:drainPendingScripts()
  ow:drainPendingScripts()
  check(ran[2] == s2 and ran[3] == s3, "the FIFO drains head-first")
end

-- ------- parallel runners: slots, drain, kill, move locks

do
  -- OverworldState's methods close over a module-local Game
  local fakeGame = newGame()
  local bound = false
  local i = 1
  while true do
    local name = debug.getupvalue(OW.updateParallel, i)
    if not name then break end
    if name == "Game" then
      debug.setupvalue(OW.updateParallel, i, fakeGame)
      bound = true
      break
    end
    i = i + 1
  end
  check(bound, "updateParallel binds Game")

  local ow = setmetatable({
    scriptMoves = {}, transitioning = false, npcs = {}, entities = {},
    map = { id = "MOD_PARA_MAP" },
    parallelRunners = {}, parallelQueue = {}, marchers = {},
    pendingScripts = {}, npcMoveLocks = {},
  }, { __index = OW })
  ow.runner = ScriptRunner.new(fakeGame, ow)

  for _ = 1, 5 do
    ow:startParallel({ { "wait_flag", "MOD_PARA_GO" } })
  end
  ow:updateParallel()
  check(#ow.parallelRunners == 4 and #ow.parallelQueue == 1,
    "four bounded slots; overflow waits FIFO-style")

  Flags.set(fakeGame.save, "MOD_PARA_GO")
  ow:updateParallel()
  ow:updateParallel()
  ow:updateParallel()
  check(#ow.parallelRunners == 0 and #ow.parallelQueue == 0,
    "parallel runners drain once the flag lands")

  -- a parallel NPC walk takes the move lock; a foreground move preempts
  Flags.clear(fakeGame.save, "MOD_PARA_GO")
  local npc = { def = { index = 2 }, cellX = 0, cellY = 0, moving = false }
  ow.npcs = { npc }
  ow:startParallel({ { "walk_npc", 2, { "down", "down" } } })
  ow:updateParallel()
  local holder = ow.npcMoveLocks[npc]
  check(holder ~= nil and holder.parallel, "a parallel walk takes the NPC move lock")

  ow.runner:run({ { "move_npc", 2, "up", 1 } }, {})
  check(ow.npcMoveLocks[npc] == nil, "a foreground move releases the lock")
  check(not holder:isRunning(), "the parallel runner was preempted")
  -- finish the foreground move so the runner ends clean
  ow:updateScriptMoves()
  npc.moving = false
  ow:updateScriptMoves()
  check(not ow.runner:isRunning(), "the foreground move completes")

  -- the player is never movable from a parallel runner
  ow.player = { cellX = 0, cellY = 0, moving = false }
  ow:startParallel({ { "walk_npc", "player", { "down" } } })
  ow:updateParallel()
  ow:updateParallel()
  check(#ow.parallelRunners == 0, "a parallel player move dies on the spot")

  -- march_in_place toggles ride ow.marchers, not scriptMoves
  local marchRunner = ScriptRunner.new(fakeGame, ow)
  marchRunner:run({ { "march_in_place", 2, true } }, {})
  check(ow.marchers[npc] == true and #ow.scriptMoves == 0,
    "march_in_place arms the marcher table without a scriptMove")
  ow:updateScriptMoves()
  check(npc.marching == true, "the marcher cycle re-arms")
  npc.moving, npc.marching = false, false
  marchRunner:run({ { "march_in_place", 2, false } }, {})
  ow:updateScriptMoves()
  check(ow.marchers[npc] == nil and npc.marching == false,
    "march_in_place off stops the cycle")

  -- restore the module-local Game for later chained suites
  debug.setupvalue(OW.updateParallel, i, require("src.core.Game"))
end

-- ------- emote and choice

do
  local fakeGame = newGame()
  local ow = { player = { px = 0, py = 0 }, npcs = {} }
  local runner = ScriptRunner.new(fakeGame, ow)
  runner:run({ { "emote", "player", "question", 5 },
               { "set_field", "after", 1 } }, {})
  check(ow.emote and ow.emote.npc == ow.player and ow.emote.bubble == 2
    and ow.emote.frames == 5, "emote arms the bubble hold")
  check(fakeGame.save.after == nil, "emote blocks until the hold ends")
  ow.emote.onDone()
  check(fakeGame.save.after == 1, "the hold resumes the script")

  local stack = { states = {} }
  function stack:push(state) self.states[#self.states + 1] = state end
  function stack:pop() return table.remove(self.states) end
  fakeGame.stack = stack
  runner = ScriptRunner.new(fakeGame, ow)
  runner:run({ { "choice", { "YES", "NO", "MAYBE" }, { cancel = 3 } },
               { "jump_if_true", "first" },
               { "set_field", "picked", "other" },
               { "jump", "end" },
               { "label", "first" },
               { "set_field", "picked", "first" } }, {})
  local menu = stack.states[#stack.states]
  check(menu and #menu.items == 3, "choice pushes a three-way menu")
  menu.items[2].onSelect()
  check(fakeGame.save.picked == "other", "a non-first choice clears lastCheck")

  runner = ScriptRunner.new(fakeGame, ow)
  runner:run({ { "choice", { "YES", "NO" } },
               { "jump_if_true", "first" },
               { "jump", "end" },
               { "label", "first" },
               { "set_field", "picked", "first" } }, {})
  stack.states[#stack.states].items[1].onSelect()
  check(fakeGame.save.picked == "first", "the first choice sets lastCheck")
end

-- ------- mod-field routing and wait_flag

do
  local game = newGame()
  local runner = ScriptRunner.new(game, nil)
  runner:run({ { "set_field", "mod:stage", 3 },
               { "check_flag", "mod:stage" },
               { "jump_if_true", "yes" },
               { "set_field", "sawStage", false },
               { "jump", "end" },
               { "label", "yes" },
               { "set_field", "sawStage", true } },
    { source = { modId = "tmod" } })
  check(game.save.modData and game.save.modData.tmod
    and game.save.modData.tmod.stage == 3,
    "mod: fields land in save.modData under the owner")
  check(game.save.sawStage == true, "check_flag reads mod: fields symmetrically")

  game = newGame()
  runner = ScriptRunner.new(game, nil)
  runner:run({ { "set_field", "mod:x", 1 }, { "set_field", "after", 1 } }, {})
  check(game.save.after == nil and game.save.modData == nil,
    "mod: fields are a script error in engine-owned scripts")

  -- wait_flag: timeout path then flag path
  game = newGame()
  runner = ScriptRunner.new(game, nil)
  local script = { { "wait_flag", "MOD_WF", 3 },
                   { "jump_if_true", "hit" },
                   { "set_field", "wf", "timeout" },
                   { "jump", "end" },
                   { "label", "hit" },
                   { "set_field", "wf", "flag" } }
  runner:run(script, {})
  check(runner:isRunning(), "wait_flag blocks")
  drive(runner, 10)
  check(game.save.wf == "timeout", "wait_flag times out with lastCheck false")

  game = newGame()
  runner = ScriptRunner.new(game, nil)
  runner:run(script, {})
  Flags.set(game.save, "MOD_WF")
  drive(runner, 10)
  check(game.save.wf == "flag", "wait_flag resumes true when the flag lands")
end

-- ------- script events and the script.command hook

do
  local savedEvents, savedHooks, savedErrors =
    Runtime.events, Runtime.hooks, Runtime.errors
  local events, hooks = Events.new(), Hooks.new()
  Runtime.install(events, hooks, {})

  local flagSeen = {}
  events:on("flag.changed", function(ev)
    flagSeen[#flagSeen + 1] = ev.name .. "=" .. tostring(ev.value)
  end, 0, "t")
  local save = { flags = {} }
  Flags.set(save, "MOD_EV")
  Flags.set(save, "MOD_EV")
  Flags.clear(save, "MOD_EV")
  Flags.clear(save, "MOD_EV")
  check(table.concat(flagSeen, ",") == "MOD_EV=true,MOD_EV=false",
    "flag.changed fires only on actual transitions")

  local lifecycle = {}
  events:on("script.started", function() lifecycle[#lifecycle + 1] = "start" end,
    0, "t")
  events:on("script.ended", function(ev)
    lifecycle[#lifecycle + 1] = "end:" .. tostring(ev.completed)
  end, 0, "t")
  local game = newGame()
  local runner = ScriptRunner.new(game, nil)
  runner:run({ { "set_flag", "X" } }, {})
  check(table.concat(lifecycle, ",") == "start,end:true",
    "script.started/ended bracket a clean run")
  lifecycle = {}
  runner = ScriptRunner.new(game, nil)
  runner:run({ { "jump", "nowhere" } }, {})
  check(lifecycle[2] == "end:false", "an error-kill emits completed = false")

  local commandsSeen = {}
  hooks:wrap("script.command", function(nextFn, ctx, name, args)
    commandsSeen[#commandsSeen + 1] = name
    if name == "set_field" and args[1] == "skipme" then
      return 4 -- force the jump past the marker row
    end
    return nextFn()
  end, 0, "t")
  game = newGame()
  runner = ScriptRunner.new(game, nil)
  runner:run({ { "set_flag", "A" },
               { "set_field", "skipme", 1 },
               { "set_field", "skipped", 1 },
               { "set_flag", "B" } }, {})
  check(table.concat(commandsSeen, ",") == "set_flag,set_field,set_flag",
    "the script.command hook wraps every dispatch")
  check(game.save.skipme == nil and game.save.skipped == nil
    and Flags.get(game.save, "B"),
    "a hook-returned pc rewrites the jump")

  Runtime.install(savedEvents, savedHooks, savedErrors)
end

S.finish()
