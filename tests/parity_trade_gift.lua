-- Parity test,  custom-flag equivalence audit: in-game trades
-- (EVENT_TRADED_*) and the Celadon Eevee gift (EVENT_GOT_EEVEE).
--
-- asm sources:
--   engine/events/in_game_trades.asm (DoInGameTradeDialogue /
--     InGameTrade_DoTrade: wCompletedInGameTradeFlags FLAG_TEST before
--     the offer, FLAG_SET on completion; party-menu pick; NoTrade on
--     decline/cancel, WrongMon on species mismatch; ConnectCable ->
--     anim -> TradedFor -> Thanks; received mon keeps the sent level
--     and joins at the party's end)
--   data/events/trades.asm (TradeMons: give/get/dialogset/nickname)
--   scripts/CeladonMansionRoofHouse.asm (Eevee ball: GivePokemon with
--     no confirm prompt; HideObject on success; ball stays if
--     GivePokemon fails with party+box full)
--   scripts/SSAnne2F.asm (rival ambush gated by wSSAnne2FCurScript ->
--     port flag EVENT_BEAT_SS_ANNE_RIVAL)
--
-- Self-contained: run via `luajit tests/parity_trade_gift.lua`; also
-- dofile'd by tests/run_tests.lua's aggregator.
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end

local fails, total = 0, 0
local function check(c, m) total = total + 1; if c then print("ok   " .. m) else fails = fails + 1; print("FAIL " .. m) end end
local function eq(g, w, m) check(g == w, ("%s (got %s, want %s)"):format(m, tostring(g), tostring(w))) end

local Game = require("src.core.Game")
local Input = require("src.core.Input")
local StateStack = require("src.core.StateStack")
local SaveData = require("src.core.SaveData")
local ScriptRunner = require("src.script.ScriptRunner")
local Commands = require("src.script.Commands")
local Flags = require("src.script.Flags")
local Pokemon = require("src.pokemon.Pokemon")
local PartyMenu = require("src.ui.PartyMenu")
local ChoiceBox = require("src.ui.ChoiceBox")
local mapScripts = require("data.scripts.init")

Game.data = Data
Game.input = Input; Input:init()
Game.stack = StateStack; StateStack:init()
Game.save = SaveData.newGame()
require("src.render.Font").load(Data)

-- === 1) TradeMons table parity (data/events/trades.asm order,
--        1-based; dialogset 1/2/3 = CASUAL/EVOLUTION/HAPPY) ===
local TRADEMONS = {
  { "NIDORINO", "NIDORINA", 1, "TERRY" },
  { "ABRA", "MR_MIME", 1, "MARCEL" },
  { "BUTTERFREE", "BEEDRILL", 3, "CHIKUCHIKU" }, -- unused in pokered
  { "PONYTA", "SEEL", 1, "SAILOR" },
  { "SPEAROW", "FARFETCHD", 3, "DUX" },
  { "SLOWBRO", "LICKITUNG", 1, "MARC" },
  { "POLIWHIRL", "JYNX", 2, "LOLA" },
  { "RAICHU", "ELECTRODE", 2, "DORIS" },
  { "VENONAT", "TANGELA", 3, "CRINKLES" },
  { "NIDORAN_M", "NIDORAN_F", 3, "SPOT" },
}
eq(#Data.field.trades, 10, "field.trades has all 10 TradeMons rows")
for i, want in ipairs(TRADEMONS) do
  local t = Data.field.trades[i] or {}
  check(t.give == want[1] and t.get == want[2]
        and (t.dialogset or 1) == want[3] and t.nickname == want[4],
        ("trades[%d] = %s->%s set %d %q"):format(i, want[1], want[2], want[3], want[4]))
end

-- === 2) every wired trade row uses the right index and a unique
--        EVENT_TRADED_* flag (wCompletedInGameTradeFlags bit per
--        TRADE_FOR_* constant); index 3 (CHIKUCHIKU) stays unused ===
local WIRED = { -- 1-based trade index -> port flag
  [1] = "EVENT_TRADED_NIDORINO_FOR_NIDORINA",
  [2] = "EVENT_TRADED_ABRA_FOR_MR_MIME",
  [4] = "EVENT_TRADED_PONYTA_FOR_SEEL",
  [5] = "EVENT_TRADED_SPEAROW_FOR_FARFETCHD",
  [6] = "EVENT_TRADED_SLOWBRO_FOR_LICKITUNG",
  [7] = "EVENT_TRADED_POLIWHIRL_FOR_JYNX",
  [8] = "EVENT_TRADED_RAICHU_FOR_ELECTRODE",
  [9] = "EVENT_TRADED_VENONAT_FOR_TANGELA",
  [10] = "EVENT_TRADED_NIDORAN_M_FOR_NIDORAN_F",
}
-- (init.lua's registry MERGES talk tables in place, so the same script
-- rows are reachable through several story/flavor modules -- dedupe by
-- map + text constant, which is what the player can actually reach)
local seen, sites = {}, {}
for _, modname in ipairs({ "data.scripts.story", "data.scripts.story2",
                           "data.scripts.story3", "data.scripts.story4",
                           "data.scripts.story5", "data.scripts.story6",
                           "data.scripts.story7", "data.scripts.flavor_all" }) do
  for mapId, m in pairs(require(modname)) do
    if type(m) == "table" and m.talk then
      for const, s in pairs(m.talk) do
        if type(s) == "table" and not sites[mapId .. "/" .. const] then
          for _, row in ipairs(s) do
            if type(row) == "table" and row[1] == "trade" then
              local idx, flag = row[2], row[3]
              sites[mapId .. "/" .. const] = true
              check(WIRED[idx] == flag,
                    ("%s/%s: trade %s pairs with %s"):format(
                      mapId, const, tostring(idx), tostring(flag)))
              check(not seen[idx],
                    ("trade index %s wired by only one NPC"):format(tostring(idx)))
              seen[idx] = true
            end
          end
        end
      end
    end
  end
end
for idx in pairs(WIRED) do
  check(seen[idx], ("trade index %d is wired somewhere"):format(idx))
end
check(not seen[3], "unused CHIKUCHIKU trade (index 3) stays unwired")

-- === harness: run a talk script headless, recording show_text ids ===
local shown = {}
local origShow = Commands.show_text
Commands.show_text = function(ctx, textId, subs)
  table.insert(shown, textId)
  return origShow(ctx, textId, subs)
end

-- pressFn returns the Input.pressed table for this frame (default: A)
local function runScript(mapId, textConst, pressFn)
  shown = {}
  local script = mapScripts.talkScript(mapId, textConst)
  local ow = { map = { id = mapId, def = { label = mapId } },
               npcs = {}, entities = {} }
  local r = ScriptRunner.new(Game, ow)
  r:run(script, { npc = { def = {}, facePlayer = function() end },
                  overworld = ow })
  local guard = 0
  while r:isRunning() and guard < 3000 do
    guard = guard + 1
    Input.pressed = pressFn and pressFn() or { a = true }
    StateStack:update(1 / 60)
    r:update()
  end
  Input.pressed = {}
  return not r:isRunning()
end

local function shownIs(want, msg)
  local got = table.concat(shown, ",")
  eq(got, table.concat(want, ","), msg)
end

local function toggleOf(mapId, objName)
  local t = Game.save.objectToggles
  return t and t[mapId] and t[mapId][objName]
end

-- press B when `class` is on top of the stack, A otherwise
local function bOn(class)
  return function()
    if getmetatable(StateStack:top()) == class then return { b = true } end
    return { a = true }
  end
end

local MARCEL = { "ROUTE_2_TRADE_HOUSE", "TEXT_ROUTE2TRADEHOUSE_GAMEBOY_KID" }

-- === 3) trade success: WannaTrade -> yes -> pick ABRA -> ConnectCable
--        -> anim -> TradedFor -> Thanks; MR_MIME joins at the party's
--        end with the sent level + nickname; flag set ===
Game.save = SaveData.newGame()
Game.save.party = { Pokemon.new(Data, "ABRA", 10), Pokemon.new(Data, "PIDGEY", 7) }
check(runScript(MARCEL[1], MARCEL[2]), "MARCEL trade script completes")
shownIs({ "_WannaTrade1Text", "_ConnectCableText", "_TradedForText", "_Thanks1Text" },
        "trade success text sequence (casual dialogset)")
eq(#Game.save.party, 2, "party size unchanged by trade")
eq(Game.save.party[1].species, "PIDGEY", "remaining mon shifts up")
eq(Game.save.party[2].species, "MR_MIME", "received mon joins at the end")
eq(Game.save.party[2].level, 10, "received mon keeps the sent mon's level")
eq(Game.save.party[2].nickname, "MARCEL", "received mon keeps its TradeMons nickname")
check(Game.save.party[2].traded, "received mon is foreign (boosted exp)")
check(Flags.get(Game.save, "EVENT_TRADED_ABRA_FOR_MR_MIME"),
      "trade sets its wCompletedInGameTradeFlags bit")
check(Game.save.pokedex.owned.MR_MIME, "received species registered owned")

-- === 4) after the trade the same NPC only shows AfterTrade text and
--        the trade cannot repeat (FLAG_TEST short-circuit) ===
Game.save.party = { Pokemon.new(Data, "ABRA", 10) } -- bait: another ABRA
check(runScript(MARCEL[1], MARCEL[2]), "post-trade script completes")
shownIs({ "_AfterTrade1Text" }, "completed trade shows only AfterTrade text")
eq(Game.save.party[1].species, "ABRA", "no second trade happens")

-- === 5) decline at the yes/no: NoTrade text, nothing else ===
Game.save = SaveData.newGame()
Game.save.party = { Pokemon.new(Data, "ABRA", 10) }
check(runScript(MARCEL[1], MARCEL[2], bOn(ChoiceBox)), "declined trade completes")
shownIs({ "_WannaTrade1Text", "_NoTrade1Text" }, "decline shows NoTrade text")
check(not Flags.get(Game.save, "EVENT_TRADED_ABRA_FOR_MR_MIME"),
      "declined trade leaves the flag unset")
eq(Game.save.party[1].species, "ABRA", "declined trade keeps the party")

-- === 6) backing out of the party menu also lands on NoTrade ===
check(runScript(MARCEL[1], MARCEL[2], bOn(PartyMenu)), "cancelled pick completes")
shownIs({ "_WannaTrade1Text", "_NoTrade1Text" }, "party-menu cancel shows NoTrade text")
check(not Flags.get(Game.save, "EVENT_TRADED_ABRA_FOR_MR_MIME"),
      "cancelled pick leaves the flag unset")

-- === 7) offering the wrong species: WrongMon text, trade still open ===
Game.save = SaveData.newGame()
Game.save.party = { Pokemon.new(Data, "PIDGEY", 7) }
check(runScript(MARCEL[1], MARCEL[2]), "wrong-mon offer completes")
shownIs({ "_WannaTrade1Text", "_WrongMon1Text" }, "wrong species shows WrongMon text")
check(not Flags.get(Game.save, "EVENT_TRADED_ABRA_FOR_MR_MIME"),
      "wrong species leaves the flag unset")
eq(Game.save.party[1].species, "PIDGEY", "wrong species keeps the party")

-- === 8) dialogsets: LOLA (EVOLUTION -> set 2), DUX (HAPPY -> set 3)
--        pick the matching AfterTrade text family ===
Game.save = SaveData.newGame()
Flags.set(Game.save, "EVENT_TRADED_POLIWHIRL_FOR_JYNX")
check(runScript("CERULEAN_TRADE_HOUSE", "TEXT_CERULEANTRADEHOUSE_GAMBLER"),
      "LOLA post-trade script completes")
shownIs({ "_AfterTrade2Text" }, "LOLA uses the evolution dialogset")
Flags.set(Game.save, "EVENT_TRADED_SPEAROW_FOR_FARFETCHD")
check(runScript("VERMILION_TRADE_HOUSE", "TEXT_VERMILIONTRADEHOUSE_LITTLE_GIRL"),
      "DUX post-trade script completes")
shownIs({ "_AfterTrade3Text" }, "DUX uses the happy dialogset")

-- === 9) Celadon Eevee: no confirm prompt, GotMonText, ball hidden ===
local EEVEE_MAP, EEVEE_BALL =
  "CELADON_MANSION_ROOF_HOUSE", "CELADONMANSION_ROOF_HOUSE_EEVEE_POKEBALL"
local EEVEE_TEXT = "TEXT_CELADONMANSION_ROOF_HOUSE_EEVEE_POKEBALL"
Game.save = SaveData.newGame()
check(runScript(EEVEE_MAP, EEVEE_TEXT), "Eevee ball script completes")
shownIs({ "_GotMonText" }, "Eevee gives immediately (no ask prompt)")
eq(#Game.save.party, 1, "Eevee joins the party")
eq(Game.save.party[1].species, "EEVEE", "gift species is EEVEE")
eq(Game.save.party[1].level, 25, "Eevee is level 25")
check(Flags.get(Game.save, "EVENT_GOT_EEVEE"), "EVENT_GOT_EEVEE bookkeeping set")
eq(toggleOf(EEVEE_MAP, EEVEE_BALL), false, "the poke ball object is hidden")
check(Game.save.pokedex.owned.EEVEE, "Eevee registered owned")

-- re-interaction (only possible on old saves): silent, no second Eevee
check(runScript(EEVEE_MAP, EEVEE_TEXT), "post-gift script completes")
shownIs({}, "taken ball gives nothing and says nothing")
eq(#Game.save.party, 1, "no second Eevee")

-- === 10) old-save self-heal: flag set but ball never hidden ===
Game.save = SaveData.newGame()
Flags.set(Game.save, "EVENT_GOT_EEVEE")
check(runScript(EEVEE_MAP, EEVEE_TEXT), "old-save script completes")
shownIs({}, "old save: silent")
eq(#Game.save.party, 0, "old save: no Eevee re-gift")
eq(toggleOf(EEVEE_MAP, EEVEE_BALL), false, "old save: leftover ball hidden")

-- === 11) GivePokemon failure (party + every box full): BoxIsFullText,
--         ball stays, flag unset -- the gift stays claimable ===
Game.save = SaveData.newGame()
for i = 1, 6 do Game.save.party[i] = Pokemon.new(Data, "PIDGEY", 5) end
local Boxes = require("src.pokemon.Boxes")
Boxes.ensure(Game.save)
for b = 1, Boxes.COUNT do
  for s = 1, Boxes.CAPACITY do Game.save.boxes[b][s] = { species = "PIDGEY" } end
end
check(runScript(EEVEE_MAP, EEVEE_TEXT), "full-everything script completes")
shownIs({ "_BoxIsFullText" }, "full party+box shows BoxIsFullText")
check(not Flags.get(Game.save, "EVENT_GOT_EEVEE"), "full party+box leaves flag unset")
eq(toggleOf(EEVEE_MAP, EEVEE_BALL), nil, "full party+box leaves the ball visible")

-- === 12) SS Anne rival ambush guard (scripts/SSAnne2F.asm: the
--         wSSAnne2FCurScript NOOP progression <-> the port's
--         EVENT_BEAT_SS_ANNE_RIVAL flag) ===
local ss = require("data.scripts.story5").SS_ANNE_2F
Game.save = SaveData.newGame()
Flags.set(Game.save, "EVENT_BEAT_SS_ANNE_RIVAL")
eq(ss.onStep(Game, nil, 36, 8), false, "beaten rival: no ambush on (36,8)")
eq(ss.onStep(Game, nil, 37, 8), false, "beaten rival: no ambush on (37,8)")
Game.save = SaveData.newGame()
eq(ss.onStep(Game, nil, 30, 8), false, "unbeaten rival: no ambush off the trigger tiles")

Commands.show_text = origShow

print(("parity trade/gift: %d/%d passed"):format(total - fails, total))
if fails > 0 then error(fails .. " parity trade/gift assertion(s) failed") end
