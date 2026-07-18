-- Parity test,  Workstream I+M.
-- I: Surf/Cut are chosen from the party menu's per-mon field-move submenu
--    (start_sub_menus.asm .outOfBattleMovePointers), never from an
--    overworld A-press.  M: Strength gates boulder pushing on a session
--    "activated" flag (push_boulder.asm TryPushingBoulder reads
--    BIT_STRENGTH_ACTIVE) set only by the party-menu STRENGTH action and
--    cleared on every real map load (home/overworld.asm EnterMap ->
--    ResetUsingStrengthOutOfBattleBit).
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end
local fails, total = 0, 0
local function check(c, m) total = total + 1; if c then print("ok   " .. m) else fails = fails + 1; print("FAIL " .. m) end end
local function eq(g, w, m) check(g == w, ("%s (got %s, want %s)"):format(m, tostring(g), tostring(w))) end

-- === harness ===
require("src.render.Font").load(Data)
local Game       = require("src.core.Game")
local Input      = require("src.core.Input")
local StateStack = require("src.core.StateStack")
local Renderer   = require("src.render.Renderer")
local SaveData   = require("src.core.SaveData")
local Pokemon    = require("src.pokemon.Pokemon")
local PartyMenu  = require("src.ui.PartyMenu")
local TextBox    = require("src.render.TextBox")
local OW         = require("src.world.OverworldController")

Game.data = Data
Game.input = Input; Input:init()
Game.renderer = Renderer; Renderer:init()
Game.stack = StateStack; StateStack:init()
Game.save = SaveData.newGame()

-- Spy on the TextBox constructor so we can assert which message a field
-- move surfaced (the raw text passed in, before {PLAYER}/token expansion).
local realTextBoxNew = TextBox.new
local captured = {}
TextBox.new = function(game, text, onDone, opts)
  captured[#captured + 1] = text or ""
  return realTextBoxNew(game, text, onDone, opts)
end
local function clearCaptured() captured = {} end
local function sawText(sub)
  for _, t in ipairs(captured) do if t:find(sub, 1, true) then return true end end
  return false
end

-- one input frame: btns is a list of GB button names held this frame.
-- Sets both the edge (wasPressed) and held (isDown) states so TextBoxes
-- type at the held-button fast speed while menus still see the edge.
local function frame(btns)
  Input.pressed = {}
  for _, b in ipairs(btns or {}) do Input.pressed[b] = true; Input.state[b] = true end
  StateStack:update(1 / 60)
  for _, b in ipairs(btns or {}) do Input.state[b] = false end
end
local function popAll() while Game.stack:top() do Game.stack:pop() end end
local function popToOW() while Game.stack:top() and Game.stack:top() ~= OW do Game.stack:pop() end end
local function pushOW(mapId, x, y, facing)
  popAll()
  Game.stack:push(OW, mapId, x, y, facing)
  return Game.stack:top()
end
-- drain any TextBox(es) sitting on top of the overworld (OW has no .pages)
local function drainText()
  local guard = 0
  while guard < 400 do
    guard = guard + 1
    local top = Game.stack:top()
    if not top or top.pages == nil then break end
    frame({ "a" })
  end
end
local function onStack(s)
  for _, st in ipairs(Game.stack.states) do if st == s then return true end end
  return false
end
local function submenuActions(pm)
  local s = {}
  for _, it in ipairs(pm.subItems or {}) do s[it.action] = true end
  return s
end
-- a party mon that knows exactly the given field move(s)
local function mkMon(species, ...)
  local m = Pokemon.new(Data, species, 20)
  m.moves = {}
  for _, id in ipairs({ ... }) do m.moves[#m.moves + 1] = { id = id, pp = 15 } end
  return m
end
-- open the field-move submenu and select the entry at row `idx`
local function selectSubItem(pm, idx)
  Game.stack:push(pm)
  frame({ "a" })                       -- A on the mon builds the submenu
  for _ = 2, idx do frame({ "down" }) end
  frame({ "a" })                       -- A on the target row dispatches
end

-- ===========================================================================
-- M: STRENGTH activation + boulder gate (SEAFOAM_ISLANDS_1F boulder @18,10)
-- ===========================================================================
Game.save.party = { mkMon("MACHOP", "STRENGTH") }
Game.save.inventory = { RAINBOWBADGE = true }
local ow = pushOW("SEAFOAM_ISLANDS_1F", 17, 10, "right")

eq(ow.strengthActive, false, "setMap default: strengthActive is false")
local boulder = ow:npcAtCell(18, 10)
check(boulder ~= nil and boulder.def.sprite == "SPRITE_BOULDER",
      "boulder NPC present at (18,10)")
check(ow:partyKnows("STRENGTH") ~= nil, "party knows STRENGTH + holds RAINBOWBADGE")

-- Gap under test: knowing STRENGTH + badge is NOT enough; without an
-- activation the push routine bails at the BIT_STRENGTH_ACTIVE gate.
eq(ow:checkBoulderPush("right"), false, "no push before activation (bump 1)")
eq(ow:checkBoulderPush("right"), false, "no push before activation (bump 2)")
eq(boulder.cellX, 18, "boulder unmoved while STRENGTH is inactive")

-- activate via the party menu STRENGTH action (submenu {STATS,SWITCH,STRENGTH})
clearCaptured()
local pmStr = PartyMenu.new(Game)
selectSubItem(pmStr, 3)
eq(Game.overworld.strengthActive, true, "party-menu STRENGTH sets strengthActive")
check(not onStack(pmStr), "party menu closes after STRENGTH")
check(sawText("used") and sawText("STRENGTH"), "_UsedStrengthText shown")
drainText()
check(sawText("move boulders"), "_CanMoveBouldersText shown after it")

-- now the same two bumps push the boulder (gate passes -> arm -> move)
eq(ow:checkBoulderPush("right"), false, "first bump arms the push after activation")
eq(ow:checkBoulderPush("right"), true, "boulder pushes after activation")

-- every real map load clears the flag (ResetUsingStrengthOutOfBattleBit)
ow:setMap("SEAFOAM_ISLANDS_1F", 17, 10, "right")
eq(ow.strengthActive, false, "setMap re-entry resets strengthActive")
eq(ow:checkBoulderPush("right"), false,
   "no push after map reload until STRENGTH is reselected")

-- ===========================================================================
-- I: SURF from the party menu (PALLET_TOWN water @4,14, stand @4,13)
-- ===========================================================================
Game.save.party = { mkMon("SQUIRTLE", "SURF") }
Game.save.inventory = { SOULBADGE = true }
ow = pushOW("PALLET_TOWN", 4, 13, "down")
ow.player.surfing = false

eq(ow:useSurfFieldMove(), "ok", "useSurfFieldMove ok when facing water")
ow.player.facing = "up"
eq(ow:useSurfFieldMove(), "no_water", "useSurfFieldMove no_water when facing land")
ow.player.facing = "down"
Game.save.inventory.SOULBADGE = nil
eq(ow:useSurfFieldMove(), "no_badge", "useSurfFieldMove no_badge without SOULBADGE")
Game.save.inventory.SOULBADGE = true

-- failure path: selecting SURF while not facing water shows
-- _NoSurfingHereText and loops back (submenu stays open, no mount)
ow.player.facing = "up"; ow.player.surfing = false
clearCaptured()
local pmSurfFail = PartyMenu.new(Game)
selectSubItem(pmSurfFail, 3)
check(sawText("No SURFing"), "_NoSurfingHereText when not facing water")
check(pmSurfFail.submenu == true, "party menu stays open after a failed SURF")
eq(ow.player.surfing, false, "no mount when SURF fails")
popToOW()

-- success path: facing water -> mount + _SurfingGotOnText, menu closes
ow.player.facing = "down"; ow.player.surfing = false
clearCaptured()
local pmSurf = PartyMenu.new(Game)
selectSubItem(pmSurf, 3)
eq(ow.player.surfing, true, "SURF from the party menu sets player.surfing")
check(not onStack(pmSurf), "party menu closes after a successful SURF")
check(sawText("got on"), "_SurfingGotOnText shown on a successful SURF")

-- ===========================================================================
-- I: list-time badge filter,  CUT/SURF/STRENGTH absent without the badge
-- ===========================================================================
Game.save.party = { mkMon("SQUIRTLE", "CUT", "SURF", "STRENGTH") }
Game.save.inventory = {}
ow = pushOW("PALLET_TOWN", 4, 13, "down")
local pmNoBadge = PartyMenu.new(Game)
Game.stack:push(pmNoBadge)
frame({ "a" })
local actsOff = submenuActions(pmNoBadge)
check(not actsOff.cut and not actsOff.surf and not actsOff.strength,
      "no CUT/SURF/STRENGTH submenu entries without the required badges")
popToOW()
Game.save.inventory = { CASCADEBADGE = true, SOULBADGE = true, RAINBOWBADGE = true }
local pmBadge = PartyMenu.new(Game)
Game.stack:push(pmBadge)
frame({ "a" })
local actsOn = submenuActions(pmBadge)
check(actsOn.cut and actsOn.surf and actsOn.strength,
      "CUT/SURF/STRENGTH submenu entries appear once the badges are held")

-- ===========================================================================
-- I: CUT from the party menu (CERULEAN_CITY cut tree @18,28, stand @17,28)
-- ===========================================================================
Game.save.party = { mkMon("BULBASAUR", "CUT") }
Game.save.inventory = { CASCADEBADGE = true }
ow = pushOW("CERULEAN_CITY", 17, 28, "right")
check(ow.map:blockAt(9, 14) == 50, "cut tree block (50) present before CUT")

eq(ow:useCutFieldMove(), "ok", "useCutFieldMove ok when facing a cut tree")
ow.player.facing = "up"
eq(ow:useCutFieldMove(), "nothing", "useCutFieldMove nothing when not facing a tree")
ow.player.facing = "right"
Game.save.inventory.CASCADEBADGE = nil
eq(ow:useCutFieldMove(), "no_badge", "useCutFieldMove no_badge without CASCADEBADGE")
Game.save.inventory.CASCADEBADGE = true

-- success path: facing the tree -> _UsedCutText, menu closes, tree replaced
clearCaptured()
local pmCut = PartyMenu.new(Game)
selectSubItem(pmCut, 3)
check(not onStack(pmCut), "party menu closes after a successful CUT")
check(sawText("CUT"), "_UsedCutText shown on a successful CUT")
drainText() -- the tree swap is deferred until the message is dismissed
eq(ow.map:blockAt(9, 14), 109, "CUT replaces the tree block (50 -> 109)")

-- failure path: not facing a tree -> _NothingToCutText, submenu stays open
popToOW()
ow.player.facing = "up"
clearCaptured()
local pmCutFail = PartyMenu.new(Game)
selectSubItem(pmCutFail, 3)
check(sawText("anything to CUT"), "_NothingToCutText when not facing a tree")
check(pmCutFail.submenu == true, "party menu stays open after a failed CUT")
ow.player.facing = "right"

-- ===========================================================================
-- I: the overworld A-press shortcut for Surf/Cut is gone (interact())
-- ===========================================================================
Game.save.party = { mkMon("SQUIRTLE", "SURF") }
Game.save.inventory = { SOULBADGE = true }
ow = pushOW("PALLET_TOWN", 4, 13, "down")
ow.player.surfing = false
ow:interact()
eq(ow.player.surfing, false, "interact() facing water no longer starts Surf")

Game.save.party = { mkMon("BULBASAUR", "CUT") }
Game.save.inventory = { CASCADEBADGE = true }
ow = pushOW("CERULEAN_CITY", 17, 28, "right")
local cutBlk0 = ow.map:blockAt(9, 14)
ow:interact()
eq(cutBlk0, 50, "cut tree still present before interact()")
eq(ow.map:blockAt(9, 14), 50, "interact() facing a cut tree no longer starts Cut")

-- ===========================================================================
-- I: IsSurfingAllowed (engine/overworld/field_move_messages.asm) -- the
-- Cycling Road and Seafoam B4F current refusals
-- ===========================================================================
Game.save.party = { mkMon("SQUIRTLE", "SURF") }
Game.save.inventory = { SOULBADGE = true }
ow = pushOW("PALLET_TOWN", 4, 13, "down")
ow.player.surfing = false

-- BIT_ALWAYS_ON_BIKE set -> refuse with _CyclingIsFunText, submenu stays
Game.save.forcedBike = true
eq(ow:useSurfFieldMove(), "forced_bike", "forced bike refuses SURF (even facing water)")
clearCaptured()
local pmBike = PartyMenu.new(Game)
selectSubItem(pmBike, 3)
check(sawText("Cycling is fun!\nForget SURFing!"), "_CyclingIsFunText verbatim")
check(pmBike.submenu == true, "party menu stays open (.loop) after the bike refusal")
eq(ow.player.surfing, false, "no mount on the Cycling Road")
Game.save.forcedBike = nil
popToOW()

-- the flag's lifecycle: armed by the forced-bike tiles
-- (CheckForceBikeOrSurf), cleared by the Route 16/18 gate scripts and the
-- fly/dungeon/blackout warps (HandleFlyWarpOrDungeonWarp)
Game.save.inventory.BICYCLE = 1
Game.save.onBike = false
ow = pushOW("ROUTE_16", 17, 10, "down")
ow:checkForcedMovement()
eq(Game.save.onBike, true, "forced-bike tile mounts the BICYCLE")
eq(Game.save.forcedBike, true, "forced-bike tile arms BIT_ALWAYS_ON_BIKE")
drainText()
ow:setMap("ROUTE_16_GATE_1F", 4, 8, "down")
eq(Game.save.forcedBike, nil, "Route 16 gate clears BIT_ALWAYS_ON_BIKE")
Game.save.forcedBike = true
ow:setMap("ROUTE_18_GATE_1F", 4, 8, "down")
eq(Game.save.forcedBike, nil, "Route 18 gate clears BIT_ALWAYS_ON_BIKE")
Game.save.forcedBike = true
ow = pushOW("ROUTE_17", 4, 10, "down")
ow:flyTo("PALLET_TOWN")
eq(Game.save.forcedBike, nil, "Fly clears BIT_ALWAYS_ON_BIKE")
ow.flyAnim, ow.flyDest, ow.player.inputLocked = nil, nil, false -- undo flyTo
Game.save.forcedBike = true
ow:warpToHealPoint()
eq(Game.save.forcedBike, nil, "blackout/escape warps clear BIT_ALWAYS_ON_BIKE")
ow.transitioning = false -- undo the queued warp transition
Game.save.onBike = false
Game.save.inventory.BICYCLE = nil

-- Seafoam B4F: only the stairs square (dbmapcoord 7,11) refuses, and only
-- until BOTH boulders are down (CheckBothEventsSet)
Game.save.flags["EVENT_SEAFOAM4_BOULDER1_DOWN_HOLE"] = nil
Game.save.flags["EVENT_SEAFOAM4_BOULDER2_DOWN_HOLE"] = nil
ow = pushOW("SEAFOAM_ISLANDS_B4F", 7, 11, "down")
ow.player.surfing = false
check(ow.map:isWaterCell(7, 12), "water south of the B4F stairs square")
eq(ow:useSurfFieldMove(), "current", "B4F stairs square refuses SURF pre-boulders")
clearCaptured()
local pmCur = PartyMenu.new(Game)
selectSubItem(pmCur, 3)
check(sawText("The current is\nmuch too fast!"), "_CurrentTooFastText verbatim")
check(pmCur.submenu == true, "party menu stays open (.loop) after the current refusal")
eq(ow.player.surfing, false, "no mount against the current")
popToOW()
ow.player.cellX, ow.player.cellY = 7, 10
eq(ow:useSurfFieldMove(), "no_water", "one square north the gate doesn't fire")
ow.player.cellX, ow.player.cellY = 7, 11
Game.save.flags["EVENT_SEAFOAM4_BOULDER1_DOWN_HOLE"] = true
eq(ow:useSurfFieldMove(), "current", "one boulder down still refuses (both required)")
Game.save.flags["EVENT_SEAFOAM4_BOULDER2_DOWN_HOLE"] = true
eq(ow:useSurfFieldMove(), "ok", "both boulders down: SURF allowed from the stairs")
Game.save.flags["EVENT_SEAFOAM4_BOULDER1_DOWN_HOLE"] = nil
Game.save.flags["EVENT_SEAFOAM4_BOULDER2_DOWN_HOLE"] = nil

-- ===========================================================================
-- I: SURF re-selected while surfing (ItemUseSurfboard .tryToStopSurfing)
-- ===========================================================================
Game.save.party = { mkMon("SQUIRTLE", "SURF") }
Game.save.inventory = { SOULBADGE = true }
ow = pushOW("PALLET_TOWN", 4, 14, "up")
ow.player.surfing = true
eq(ow:useSurfFieldMove(), "dismount", "surfing + facing land tries to get off")
ow.player.facing = "down"
eq(ow:useSurfFieldMove(), "no_place", "surfing + facing open water: no place")
ow.player.facing = "up"
table.insert(ow.entities, { cellX = 4, cellY = 13 })
eq(ow:useSurfFieldMove(), "no_place",
   "a sprite on the landing square blocks it (IsSpriteInFrontOfPlayer2)")
table.remove(ow.entities)

-- menu-driven dismount: NO text, the menu closes behind the white blink
-- (.stopSurfing never prints; wActionResult stays 1 -> whiteout +
-- .goBackToMap) and the simulated pad press steps the player ashore
clearCaptured()
local pmOff = PartyMenu.new(Game)
selectSubItem(pmOff, 3)
check(not onStack(pmOff), "party menu closes on dismount")
eq(ow.player.surfing, false, ".stopSurfing returns to walking before the step")
eq(#captured, 0, "no message on a successful dismount")
local offFlash = Game.stack:top()
check(offFlash ~= nil and offFlash ~= ow and offFlash.pages == nil,
      "the GBPalWhiteOut blink covers the menu close")
for _ = 1, 60 do frame({}) end -- blink pops, the queued step walks out
eq(Game.stack:top(), ow, "back on the map after the blink")
eq(ow.player.cellY, 13, "the player stepped forward onto land")

-- "no place to get off": the text shows, and the menu STILL closes
-- (.cannotStopSurfing leaves wActionResultOrTookBattleTurn at 1)
ow.player.surfing = true
ow.player.cellX, ow.player.cellY = 4, 15
ow.player.px, ow.player.py = 4 * 16, 15 * 16
ow.player.facing = "down"
clearCaptured()
local pmNoOff = PartyMenu.new(Game)
selectSubItem(pmNoOff, 3)
check(sawText("There's no place\nto get off!"), "_SurfingNoPlaceToGetOffText verbatim")
check(not onStack(pmNoOff), "the menu closes after the message (result stays 1)")
eq(ow.player.surfing, true, "still surfing after a blocked dismount")
drainText()
ow.player.surfing = false
popToOW()

-- ===========================================================================
-- M: STRENGTH pages -- no prompt on _UsedStrengthText (text_asm cry +
-- Delay3 auto-advance), `prompt` on _CanMoveBouldersText, then the
-- GBPalWhiteOutWithDelay3 blink (start_sub_menus.asm .strength)
-- ===========================================================================
Game.save.party = { mkMon("MACHOP", "STRENGTH") }
Game.save.inventory = { RAINBOWBADGE = true }
ow = pushOW("SEAFOAM_ISLANDS_1F", 17, 10, "right")
clearCaptured()
local pmStr2 = PartyMenu.new(Game)
selectSubItem(pmStr2, 3)
local page1 = Game.stack:top()
check(page1 ~= nil and page1.pages ~= nil and page1.auto ~= nil,
      "_UsedStrengthText box is a no-prompt (auto) page")
local guard = 0
while Game.stack:top() == page1 and guard < 240 do guard = guard + 1; frame({}) end
check(Game.stack:top() ~= page1, "page 1 advanced without an A press")
check(sawText("can\nmove boulders."), "_CanMoveBouldersText follows")
local page2 = Game.stack:top()
check(page2 ~= nil and page2.pages ~= nil and page2.auto == nil,
      "_CanMoveBouldersText is a normal `prompt` page")
for _ = 1, 150 do frame({}) end -- types out, then waits
check(Game.stack:top() == page2, "page 2 waits for A/B")
frame({ "a" })
local strFlash = Game.stack:top()
check(strFlash ~= page2 and strFlash ~= ow and strFlash.pages == nil,
      "the white blink follows the A press (GBPalWhiteOutWithDelay3)")
for _ = 1, 10 do frame({}) end
eq(Game.stack:top(), ow, "back on the map after the blink")

-- restore the spied constructor so later dofile'd suites are unaffected
TextBox.new = realTextBoxNew
popAll()

print(("parity I_M: %d/%d passed"):format(total - fails, total))
if fails > 0 then error(fails .. " parity-I_M assertion(s) failed") end
