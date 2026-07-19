-- Standalone: luajit mods/examples/example_lost_parcel/tests/example_lost_parcel_test.lua
-- Plays the quest end to end headlessly: accept, fetch, hand over.
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Data = require("src.core.Data")
Data:load()

local Font = require("src.render.Font")
local ScriptRunner = require("src.script.ScriptRunner")
local MapScripts = require("src.script.MapScripts")
-- the engine attaches its hand-ported scripts as the base contribution at
-- boot; the quest composes on top of them, so the harness needs them too
require("data.scripts.init")
Font.load(Data)

local run = T.sdk.loadMod("mods/examples/example_lost_parcel", { data = Data })
T.eq(#run.errors, 0, "loads clean (" .. tostring(run.errors[1]) .. ")")
T.check(Data.items.EXAMPLE_LOST_PARCEL_PARCEL ~= nil, "the parcel item merged")
T.check(Data.tokens.EXAMPLE_PARCEL_REWARD ~= nil, "the reward token merged")
T.check(Data.commands["example_lost_parcel:count_ask"] ~= nil,
  "the mod's script verb merged")

-- a stack whose boxes are answered from OUTSIDE the coroutine: a text box
-- pushed by show_text resolves on the next drive tick, never re-entrantly
local choice = 1
local function newGame()
  local game = { data = Data, save = {
    flags = {}, inventory = {}, modData = {},
    player = { name = "RED", rival = "BLUE" },
  } }
  local stack = { states = {} }
  function stack:push(state) self.states[#self.states + 1] = state end
  function stack:pop() return table.remove(self.states) end
  function stack:top() return self.states[#self.states] end
  game.stack = stack
  game.shown = {}    -- first line of every text box, in order
  game.asked = 0     -- YES/NO boxes the conversation put up
  return game
end

-- advance one pending box or emote hold; choice menus pick `choice`
local function settle(game, ow)
  if ow.emote then
    local held = ow.emote
    ow.emote = nil
    held.onDone()
    return true
  end
  local top = table.remove(game.stack.states)
  if not top then return false end
  if top.pages then
    game.lastText = top.pages[1] and top.pages[1][1]
    game.shown[#game.shown + 1] = game.lastText
  end
  if top.items then
    local item = top.items[choice]
    if item and item.onSelect then item.onSelect() end
  elseif top.onChoose then
    -- a bare ChoiceBox: what the engine's own Lua talk handlers ask with
    game.asked = game.asked + 1
    top.onChoose(choice == 1)
  elseif top.onDone then
    top.onDone()
  end
  return true
end

-- the first line of a generated text constant, which is what a TextBox
-- paginates onto its first row
local function firstLine(s) return (tostring(s):match("^[^\n\f\v]*")) end

-- the overworld the talk dispatch would supply; its map label is what
-- show_text resolves a bare TEXT_ constant through
local function overworldFor(mapId)
  return { map = { id = mapId, def = { label = Data.maps[mapId].label } } }
end

local function talk(game, mapId, textConst)
  local rows = MapScripts.talkScript(mapId, textConst)
  T.check(rows ~= nil, mapId .. "." .. textConst .. " has a talk script")
  local ow = overworldFor(mapId)
  local runner = ScriptRunner.new(game, ow)
  runner:run(rows, { source = MapScripts.talkSource(mapId, textConst) })
  for _ = 1, 400 do
    if not runner:isRunning() then break end
    if not settle(game, ow) then runner:update() end
  end
  T.check(not runner:isRunning(), "the " .. textConst .. " script completed")
end

-- ------- branch 1: refuse the quest

do
  choice = 2
  local game = newGame()
  talk(game, "VIRIDIAN_CITY", "TEXT_VIRIDIANCITY_GAMBLER1")
  T.check(not game.save.flags.MOD_EXAMPLE_LOST_PARCEL_STARTED,
    "refusing the choice leaves the quest unstarted")
end

-- ------- branch 2: accept, fetch, deliver

local game = newGame()
choice = 1
talk(game, "VIRIDIAN_CITY", "TEXT_VIRIDIANCITY_GAMBLER1")
T.check(game.save.flags.MOD_EXAMPLE_LOST_PARCEL_STARTED, "accepting sets the started flag")
T.eq(game.save.modData.example_lost_parcel.asked_count, 0,
  "set_field mod: wrote into the mod's own save namespace")

-- The override wins talk dispatch outright, so the branches the quest does
-- not own owe the player the whole base conversation -- which for this NPC
-- is an opening line, a YES/NO prompt and one of two follow-ups, not a
-- single line.  Both answers are driven, before the quest starts and again
-- once the parcel is gone.
local NERD_INTRO = Data.text._PewterCitySuperNerd1DidYouCheckOutMuseumText
local NERD_YES = Data.text._PewterCitySuperNerd1WerentThoseFossilsAmazingText
local NERD_NO = Data.text._PewterCitySuperNerd1YouHaveToGoText
T.check(NERD_INTRO and NERD_YES and NERD_NO,
  "the base super nerd conversation is in the generated text")

local function readsVanillaNerd(when, flags)
  for _, answer in ipairs({ 1, 2 }) do
    local plain = newGame()
    for name, value in pairs(flags or {}) do plain.save.flags[name] = value end
    choice = answer
    talk(plain, "PEWTER_CITY", "TEXT_PEWTERCITY_SUPER_NERD1")
    T.check((plain.save.inventory.EXAMPLE_LOST_PARCEL_PARCEL or 0) == 0,
      when .. ": the base branch never hands out the parcel")
    T.eq(plain.asked, 1, when .. ": the vanilla YES/NO prompt still comes up")
    T.eq(#plain.shown, 2, when .. ": the opening line and a follow-up both play")
    T.eq(plain.shown[1], firstLine(NERD_INTRO), when .. ": the vanilla opening line")
    T.eq(plain.shown[2], firstLine(answer == 1 and NERD_YES or NERD_NO),
      when .. ": the follow-up answers the choice the player made")
  end
end

readsVanillaNerd("before the quest")
readsVanillaNerd("after the parcel is taken", {
  MOD_EXAMPLE_LOST_PARCEL_STARTED = true,
  MOD_EXAMPLE_LOST_PARCEL_TAKEN = true,
})
choice = 1

talk(game, "PEWTER_CITY", "TEXT_PEWTERCITY_SUPER_NERD1")
T.check(game.save.flags.MOD_EXAMPLE_LOST_PARCEL_TAKEN, "the parcel is taken")
T.check((game.save.inventory.EXAMPLE_LOST_PARCEL_PARCEL or 0) > 0,
  "the parcel is in the bag")

talk(game, "VIRIDIAN_CITY", "TEXT_VIRIDIANCITY_GAMBLER1")
T.check(game.save.flags.MOD_EXAMPLE_LOST_PARCEL_DONE, "the quest completes")
T.check((game.save.inventory.EXAMPLE_LOST_PARCEL_PARCEL or 0) == 0,
  "the parcel is consumed")
T.check((game.save.inventory.NUGGET or 0) > 0, "the NUGGET reward is paid")
T.eq(game.save.modData.example_lost_parcel.asked_count, 1,
  "the mod's own verb counted the one pending visit")

-- the ambient script is background-legal: no foreground verb in it
local rows = MapScripts.namedScript("PEWTER_CITY", "example_nerd_pace")
T.check(rows ~= nil, "the parallel ambient script is registered")

run.release()
T.finish("example_lost_parcel")
