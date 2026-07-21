-- More hand-ported events: the Pallet Town intro, the thirsty Saffron
-- gate guards, the Bike Voucher chain, fossils and the day-care.
-- Registered via data/scripts/init.lua; each cites its pokered source.

local M = {}

-- -------------------------------------------------------------------
-- Pallet Town intro (scripts/PalletTown.asm PalletTownOakHeyWaitScript):
-- stepping toward the grass without a starter makes Oak stop you and
-- take you to his lab (the walk cutscene is compressed into the warp).
-- -------------------------------------------------------------------

-- Pure escort data, exposed on the map entry as `escort` for
-- tests/parity_intro.lua.
local escort = {}

-- FindPathToPlayer (engine/overworld/pathfinding.asm): each step
-- reduces whichever axis has more distance left; ties step X first
-- (`ld a, e / cp d / jr c, .yDistanceGreater`, e = X left, d = Y left).
function escort.findPath(fromX, fromY, toX, toY)
  local xdist, ydist = math.abs(toX - fromX), math.abs(toY - fromY)
  local xdir = toX > fromX and "right" or "left"
  local ydir = toY > fromY and "down" or "up"
  local xprog, yprog = 0, 0
  local path = {}
  while xprog < xdist or yprog < ydist do
    if xdist - xprog >= ydist - yprog and xprog < xdist then
      xprog = xprog + 1
      path[#path + 1] = xdir
    else
      yprog = yprog + 1
      path[#path + 1] = ydir
    end
  end
  return path
end

-- PalletTownOakWalksToPlayerScript: Oak appears at his object spot
-- (8,5) and zigzags to one tile below the player (hNPCPlayerYDistance
-- is pre-decremented before predef FindPathToPlayer).
function escort.oakApproach(playerX)
  return escort.findPath(8, 5, playerX, 2)
end

-- RLEList_ProfOakWalkToLab (engine/overworld/auto_movement.asm):
-- DOWN x5, LEFT, DOWN x5, RIGHT x3, UP -- Oak's last step lands on the
-- lab door (12,11).  (The trailing NPC_CHANGE_FACING is a march-in-
-- place beat on the mat; here Oak just stands his final beat.)
escort.oakSteps = {
  "down", "down", "down", "down", "down",
  "left",
  "down", "down", "down", "down", "down",
  "right", "right", "right",
  "up",
}

-- RLEList_PlayerWalkToLab decodes to UP x2, RIGHT x3, DOWN x5, LEFT,
-- DOWN x6 and plays in REVERSE buffer order (wSimulatedJoypadStatesEnd
-- grows downward): DOWN x6, LEFT, DOWN x5, RIGHT x3, UP x2 -- Oak's
-- exact path one step behind.  The 17th press (the second UP) is eaten
-- by the door-warp frame (WarpFound clears hJoyHeld via EnterMap), so
-- only 16 real steps happen; the walk ends on the door at (12,11).
escort.playerSteps = { "down" }
for _, d in ipairs(escort.oakSteps) do
  escort.playerSteps[#escort.playerSteps + 1] = d
end

M.PALLET_TOWN = {
  talk = require("data.scripts.pallet_town").talk,
  escort = escort,
  -- Oak stops you at the north row (PalletTownDefaultScript's
  -- `wYCoord == 1` check), walks up from (8,5), and leads you to his
  -- lab with the player one step behind (scripts/PalletTown.asm +
  -- PalletMovementScriptPointerTable in
  -- engine/overworld/auto_movement.asm), then the lab walk-in and the
  -- choose-mon exchange (scripts/OaksLab.asm OaksLabDefaultScript ..
  -- OaksLabOakChooseMonSpeechScript).
  onStep = function(game, ow, x, y)
    if y ~= 1 or game.save.flags.EVENT_FOLLOWED_OAK_INTO_LAB
       or game.save.flags.EVENT_GOT_STARTER then
      return false
    end
    local TextBox = require("src.render.TextBox")
    local Commands = require("src.script.Commands")
    local Music = require("src.core.Music")
    local t = game.data.text
    local ctx = { save = game.save, game = game, overworld = ow }

    -- PalletTownDefaultScript: stop the player, turn them around
    -- (wPlayerMovingDirection = PLAYER_DIR_DOWN applies on the very
    -- next frame, before the text box opens) and strike up the "oak
    -- appears" theme (MUSIC_MEET_PROF_OAK)
    ow.player.facing = "down"
    Music.play(game.data, "Music_MeetProfOak")

    -- DelayFrames-style hold: the world pauses (input stays locked)
    -- for `frames` frames, then cb runs.  Reuses the emote pause slot;
    -- with an `npc` the "!" bubble draws above it (EmotionBubble).
    local function hold(frames, npc, cb)
      ow.emote = { frames = frames, npc = npc, onDone = cb }
    end

    -- chain single-tile scriptMoves through a direction list
    local function walkList(entity, steps, done)
      local i = 0
      local function nextStep()
        i = i + 1
        if not entity or not steps[i] then
          if done then done() end
          return
        end
        ow:scriptMove(entity, steps[i], 1, nextStep)
      end
      nextStep()
    end

    -- ---- Oak's Lab side (scripts/OaksLab.asm) ----------------------

    -- OaksLabOakChooseMonSpeechScript: the fed-up / choose-mon /
    -- what-about-me / be-patient exchange, Delay3 between boxes
    local function chooseMonSpeech()
      local function say(key, fb, next)
        game.stack:push(TextBox.new(game, t[key] or fb, next))
      end
      say("_OaksLabRivalFedUpWithWaitingText",
          "{RIVAL}: Gramps!\nI'm fed up with\nwaiting!", function()
        hold(3, nil, function()
          say("_OaksLabOakChooseMonText",
              "OAK: Here, {PLAYER}!\fThere are 3\nPOKéMON here!\fYou can have one!\nChoose!", function()
            hold(3, nil, function()
              say("_OaksLabRivalWhatAboutMeText",
                  "{RIVAL}: Hey!\nGramps! What\nabout me?", function()
                hold(3, nil, function()
                  say("_OaksLabOakBePatientText",
                      "OAK: Be patient!\n{RIVAL}, you can\nhave one too!", function()
                    game.save.flags.EVENT_OAK_ASKED_TO_CHOOSE_MON = true
                  end)
                end)
              end)
            end)
          end)
        end)
      end)
    end

    -- entering the lab: the door Oak (OAKSLAB_OAK2, (5,10)) walks up 3
    -- ahead of the player (OaksLabOakEntersLabScript OakEntryMovement),
    -- swaps for the desk Oak (OAKSLAB_OAK1, (5,2)), then the player
    -- walks up 8 from the mat (PlayerEntryMovementRLE) while the rival
    -- and Oak turn with them (OaksLabPlayerEntersLabScript /
    -- OaksLabFollowedOakScript)
    local function labWalkIn()
      local oak2 = ow:npcByIndex(8)
      local function swapOaks()
        Commands.hide_object(ctx, "OAKS_LAB", "OAKSLAB_OAK2")
        Commands.show_object(ctx, "OAKS_LAB", "OAKSLAB_OAK1")
        hold(3, nil, function() -- Delay3
          Commands.face_object(ctx, 1, "down") -- rival watches you pass
          ow:scriptMove(ow.player, "up", 8, function()
            -- OaksLabFollowedOakScript: flags only after the walk-in, so a
            -- stray step on the door mat can't fire the "don't go away"
            -- push-up (oaks_lab.lua onStep) mid-cutscene.  Outdoor escort
            -- still re-arms on F1 mid-escort -- these flags stay clear
            -- until the lab walk finishes.
            game.save.flags.EVENT_FOLLOWED_OAK_INTO_LAB = true
            game.save.flags.EVENT_FOLLOWED_OAK_INTO_LAB_2 = true
            Commands.face_object(ctx, 1, "up")
            -- res BIT_NO_MAP_MUSIC + PlayDefaultMusic: the lab theme
            -- only starts once the walk-in is done
            Music.playMap(game.data, "OAKS_LAB")
            chooseMonSpeech()
          end)
        end)
      end
      if oak2 then
        ow:scriptMove(oak2, "up", 3, swapOaks)
      else
        swapOaks()
      end
    end

    -- PalletMovementScript_Done + the door warp: Oak is hidden as the
    -- player steps into the doorway; PALLET_TOWN warp 3 -> OAKS_LAB
    -- warp 2 = (5,11), with the door SFX (WarpFound -> SFX_GO_INSIDE)
    local function enterLab()
      Commands.hide_object(ctx, "PALLET_TOWN", "PALLETTOWN_OAK")
      Commands.show_object(ctx, "OAKS_LAB", "OAKSLAB_OAK2")
      ow.doorWarp = true
      ow:startWarpTo("OAKS_LAB", 5, 11, "up", labWalkIn,
                     { keepMusic = true })
    end

    -- PalletMovementScript_WalkToLab: Oak's NPC movement and the
    -- player's simulated joypad run simultaneously, in lockstep; the
    -- player retraces Oak's path one step behind and follows him into
    -- the doorway on the final beat
    local function walkToLab(oak)
      local i = 0
      local function tick()
        i = i + 1
        local playerStep = escort.playerSteps[i]
        if not playerStep then
          enterLab()
          return
        end
        if oak and escort.oakSteps[i] then
          ow:scriptMove(oak, escort.oakSteps[i], 1)
        elseif oak then
          -- RLEList_ProfOakWalkToLab's trailing NPC_CHANGE_FACING beat:
          -- Oak marches in place on the door mat while the player takes
          -- the final step up behind him (movement.asm ChangeFacingDirection)
          ow:marchInPlace(oak)
        end
        ow:scriptMove(ow.player, playerStep, 1, tick)
      end
      tick()
    end

    -- PalletMovementScript_OakMoveLeft/_PlayerMoveLeft: from the right
    -- tile (x == 11) Oak sidesteps left first, then the player follows
    -- left (wNumStepsToTake = wXCoord - 10), and only then both walk
    local function escortToLab(oak)
      local numSteps = x - 10
      if oak and numSteps > 0 then
        ow:scriptMove(oak, "left", numSteps, function()
          ow:scriptMove(ow.player, "left", numSteps, function()
            walkToLab(oak)
          end)
        end)
      else
        walkToLab(oak)
      end
    end

    -- ---- Pallet Town side (scripts/PalletTown.asm) -----------------

    -- PalletTownOakWalksToPlayerScript: Oak appears at (8,5), faces up
    -- (SetSpriteFacingDirectionAndDelay + Delay3), then zigzags to the
    -- player; the "It's unsafe!" text follows and the escort begins
    local function oakAppearsAndWalks()
      Commands.show_object(ctx, "PALLET_TOWN", "PALLETTOWN_OAK")
      local oak = ow:npcByIndex(1)
      if oak then oak.facing = "up" end
      hold(6, nil, function()
        walkList(oak, escort.oakApproach(x), function()
          -- PalletTownOakNotSafeComeWithMeScript: the second text waits
          -- for a button, then the escort starts
          game.stack:push(TextBox.new(game,
            t._PalletTownOakItsUnsafeText
            or "OAK: It's unsafe!\nWild POKéMON\nlive in tall grass!",
            function() escortToLab(oak) end))
        end)
      end)
    end

    -- The "Hey! Wait!" box ends without a button wait (auto), then the
    -- "!" bubble shows over the player WHILE the box is still on screen
    -- (PalletTownOakText: DelayFrames 10 then EmotionBubble, box not yet
    -- cleared).  onOverlap sets the bubble during the box's last frames;
    -- the box pops after `overlap`, and the bubble's 60-frame hold then
    -- runs to Oak's appearance (the bubble is static while the box is up,
    -- since the overworld pauses under it, so 10 overlap + 50 = 60).
    game.stack:push(TextBox.new(game,
      t._PalletTownOakHeyWaitDontGoOutText or "OAK: Hey! Wait!\nDon't go out!",
      nil, { auto = { delay = 10, overlap = 10, onOverlap = function()
        ow.emote = { npc = ow.player, frames = 50, onDone = oakAppearsAndWalks }
      end } }))
    return true
  end,
}

-- -------------------------------------------------------------------
-- Saffron gate guards (scripts/Route5Gate.asm etc.): crossing the gate
-- without having given them a drink gets you turned back; a drink from
-- the bag (bought at Celadon's vending machines... or any mart that
-- stocks them) opens all four gates.
-- -------------------------------------------------------------------

local DRINKS = { "FRESH_WATER", "SODA_POP", "LEMONADE" }

-- Hand over the first drink in the bag, if any. Mirrors RemoveGuardDrink
-- (engine/items/inventory.asm), which walks the same three item ids and
-- removes ONE, and the caller's BIT_GAVE_SAFFRON_GUARDS_DRINK.
local function takeGuardDrink(game)
  for _, drink in ipairs(DRINKS) do
    if (game.save.inventory[drink] or 0) > 0 then
      game.save.inventory[drink] = game.save.inventory[drink] - 1
      if game.save.inventory[drink] == 0 then
        game.save.inventory[drink] = nil
      end
      game.save.flags.EVENT_GAVE_GUARDS_DRINK = true
      return true
    end
  end
  return false
end

local function saffronGate(guardText, triggers, horizontal)
  return {
    talk = {
      [guardText] = function(game, ow, npc, done)
        local TextBox = require("src.render.TextBox")
        local t = game.data.text
        if game.save.flags.EVENT_GAVE_GUARDS_DRINK then
          game.stack:push(TextBox.new(game,
            t._SaffronGateGuardThanksForTheDrinkText or "Gee, that was\ntasty!", done))
          return
        end
        if takeGuardDrink(game) then
          game.stack:push(TextBox.new(game,
            (t._SaffronGateGuardYouCanGoOnThroughText or
             "Thanks! You can\ngo on through!"), done))
          return
        end
        game.stack:push(TextBox.new(game,
          t._SaffronGateGuardGeeImThirstyText or "Gee, I'm thirsty\nthough!", done))
      end,
    },
    -- the gate's trigger cells (each gate's PlayerInCoordsArray):
    -- without the drink flag you get walked back the way you came
    onStep = function(game, ow, x, y)
      local hit = false
      for _, c in ipairs(triggers) do
        if x == c[1] and y == c[2] then hit = true break end
      end
      if not hit then return false end
      if game.save.flags.EVENT_GAVE_GUARDS_DRINK then return false end
      local TextBox = require("src.render.TextBox")
      local t = game.data.text
      -- Stepping on the trigger WITH a drink hands it over right here.
      --
      -- Route5GateDefaultScript (scripts/Route5Gate.asm) runs
      -- `farcall RemoveGuardDrink` before it decides anything: the coord
      -- trigger itself takes the drink and sets
      -- BIT_GAVE_SAFFRON_GUARDS_DRINK, and only a player carrying nothing
      -- gets the thirsty line and the walk-back. We had the removal on the
      -- guard's TALK handler only, so walking up with a FRESH_WATER in the
      -- bag was turned away and the four gates stayed shut unless you
      -- happened to talk to him -- which vanilla never requires.
      --
      -- Saffron is the middle of the map, so this sealed it: every route
      -- through the city (Celadon <-> Lavender, Vermilion <-> Cerulean the
      -- short way) was unreachable, and the bot could not get to Lavender
      -- for the POKE_FLUTE at all.
      if takeGuardDrink(game) then
        game.stack:push(TextBox.new(game,
          (t._SaffronGateGuardYouCanGoOnThroughText or
           "Thanks! You can\ngo on through!")))
        return true
      end
      local back
      if horizontal then
        back = ow.player.facing == "left" and "right" or "left"
      else
        back = ow.player.facing == "up" and "down" or "up"
      end
      game.stack:push(TextBox.new(game,
        t._SaffronGateGuardImParchedText or "I'm parched...\nNo entry until\nI get a drink!",
        function()
          ow:scriptMove(ow.player, back, 1)
        end))
      return true
    end,
  }
end

M.ROUTE_5_GATE = saffronGate("TEXT_ROUTE5GATE_GUARD", { { 3, 3 }, { 4, 3 } })
M.ROUTE_6_GATE = saffronGate("TEXT_ROUTE6GATE_GUARD", { { 3, 2 }, { 4, 2 } })
M.ROUTE_7_GATE = saffronGate("TEXT_ROUTE7GATE_GUARD", { { 3, 3 }, { 3, 4 } }, true)
M.ROUTE_8_GATE = saffronGate("TEXT_ROUTE8GATE_GUARD", { { 2, 3 }, { 2, 4 } }, true)

-- -------------------------------------------------------------------
-- Bike Voucher chain (scripts/PokemonFanClub.asm, BikeShop.asm)
-- -------------------------------------------------------------------

M.POKEMON_FAN_CLUB = {
  talk = {
    TEXT_POKEMONFANCLUB_CHAIRMAN = {
      { "face_player" },                                          -- 1
      { "check_flag", "EVENT_RECEIVED_BIKE_VOUCHER" },            -- 2
      { "jump_if_true", 9 },                                      -- 3
      { "show_text", "_PokemonFanClubChairmanIntroText" },        -- 4
      { "show_text", "_PokemonFanClubChairmanStoryText" },        -- 5
      -- give-then-print like scripts/PokemonFanClub.asm (GiveItem
      -- fills wStringBuffer; the received text reads it)
      { "give_item", "BIKE_VOUCHER", 1, false },                  -- 6
      { "show_text", "_PokemonFanClubReceivedBikeVoucherText" },  -- 7
      { "set_flag", "EVENT_RECEIVED_BIKE_VOUCHER" },              -- 8
      { "show_text", "_PokemonFanClubExplainBikeVoucherText" },   -- 9
    },
  },
}

M.BIKE_SHOP = {
  talk = {
    TEXT_BIKESHOP_CLERK = function(game, ow, npc, done)
      local TextBox = require("src.render.TextBox")
      if (game.save.inventory.BICYCLE or 0) > 0 then
        game.stack:push(TextBox.new(game, "How's the\nBICYCLE treating\nyou?", done))
      elseif (game.save.inventory.BIKE_VOUCHER or 0) > 0 then
        game.save.inventory.BIKE_VOUCHER = nil
        game.save.inventory.BICYCLE = 1
        game.stack:push(TextBox.new(game,
          ("Oh, that's a\nBIKE VOUCHER!\f%s exchanged\nit for a BICYCLE!")
          :format(game.save.player.name), done))
      else
        game.stack:push(TextBox.new(game,
          "A BICYCLE costs\n¥1000000. Sorry,\nno instalments!", done))
      end
    end,
  },
}

-- -------------------------------------------------------------------
-- Fossils (scripts/MtMoonB2F.asm, Museum1F.asm,
-- CinnabarLabFossilRoom.asm): pick one Mt Moon fossil, revive them at
-- the Cinnabar lab (the wait is skipped).
-- -------------------------------------------------------------------

local function mtMoonFossil(itemId, otherName)
  return function(game, ow, npc, done)
    local TextBox = require("src.render.TextBox")
    local ChoiceBox = require("src.ui.ChoiceBox")
    if game.save.flags.EVENT_GOT_A_FOSSIL then
      game.stack:push(TextBox.new(game, "You already took\na fossil.", done))
      return
    end
    game.stack:push(TextBox.new(game, "You found a\nfossil! Take it?", function()
      game.stack:push(ChoiceBox.new(game, function(yes)
        if not yes then done() return end
        game.save.inventory[itemId] = 1
        game.save.flags.EVENT_GOT_A_FOSSIL = true
        local Commands = require("src.script.Commands")
        local ctx = { save = game.save, overworld = ow, game = game }
        Commands.hide_object(ctx, "MT_MOON_B2F", npc.def.name)
        Commands.hide_object(ctx, "MT_MOON_B2F", otherName)
        local name = game.data.items[itemId].name
        game.stack:push(TextBox.new(game,
          ("%s got the\n%s!"):format(game.save.player.name, name), done))
      end))
    end))
  end
end

M.MT_MOON_B2F = {
  talk = {
    TEXT_MTMOONB2F_DOME_FOSSIL = mtMoonFossil("DOME_FOSSIL", "MTMOONB2F_HELIX_FOSSIL"),
    TEXT_MTMOONB2F_HELIX_FOSSIL = mtMoonFossil("HELIX_FOSSIL", "MTMOONB2F_DOME_FOSSIL"),
  },
}

-- The ticket clerk (scripts/Museum1F.asm Museum1FScientist1Text):
-- Y50, once; declining at the rope walks you back out.
local function museumClerk(game, ow, done, onDecline)
  local TextBox = require("src.render.TextBox")
  local ChoiceBox = require("src.ui.ChoiceBox")
  if game.save.flags.EVENT_BOUGHT_MUSEUM_TICKET then
    game.stack:push(TextBox.new(game,
      "Take your time,\nand enjoy it all!", done))
    return
  end
  game.stack:push(TextBox.new(game,
    "It's ¥50 for a\nchild's ticket.\fWould you like to\ncome in?", function()
    game.stack:push(ChoiceBox.new(game, function(yes)
      if yes and game.save.money >= 50 then
        game.save.money = game.save.money - 50
        game.save.flags.EVENT_BOUGHT_MUSEUM_TICKET = true
        game.stack:push(TextBox.new(game,
          "Right, ¥50!\nThank you!", done))
      elseif yes then
        game.stack:push(TextBox.new(game,
          "You don't have\nenough money.", onDecline or done))
      else
        game.stack:push(TextBox.new(game,
          "Come again!", onDecline or done))
      end
    end))
  end))
end

M.MUSEUM_1F = {
  -- crossing the rope at (9,4)/(10,4) without a ticket calls the clerk
  -- over (Museum1FDefaultScript's coordinate check)
  onStep = function(game, ow, x, y)
    if y == 4 and (x == 9 or x == 10)
       and not game.save.flags.EVENT_BOUGHT_MUSEUM_TICKET then
      museumClerk(game, ow, nil, function()
        ow:scriptMove(ow.player, "right", 1)
      end)
      return true
    end
    return false
  end,
  talk = {
    TEXT_MUSEUM1F_SCIENTIST1 = function(game, ow, npc, done)
      museumClerk(game, ow, done)
    end,
    -- The OLD AMBER display object is plain flavor; the scientist
    -- (TEXT_MUSEUM1F_SCIENTIST2, data/scripts/flavor/museum_1f.lua) is who
    -- hands it over and hides this object, per scripts/Museum1F.asm.
    TEXT_MUSEUM1F_OLD_AMBER = function(game, ow, npc, done)
      local TextBox = require("src.render.TextBox")
      game.stack:push(TextBox.new(game,
        game.data.text._Museum1FOldAmberText or "The OLD AMBER.", done))
    end,
  },
}

local FOSSIL_MONS = {
  HELIX_FOSSIL = "OMANYTE", DOME_FOSSIL = "KABUTO", OLD_AMBER = "AERODACTYL",
}

-- Deterministic scan order mirrors FossilsList (scripts/
-- CinnabarLabFossilRoom.asm lines 43-47): DOME_FOSSIL, HELIX_FOSSIL,
-- OLD_AMBER (the old pairs()-order loop this replaced was undefined).
local FOSSIL_ORDER = { "DOME_FOSSIL", "HELIX_FOSSIL", "OLD_AMBER" }

-- fills the {PLAYER}/{RAM:...} placeholders in the extracted text
-- verbatim (text/CinnabarLabFossilRoom.asm); TextBox itself only knows
-- how to substitute {RAM:wStringBuffer}, so this has to happen first.
-- RAM placeholders resolve by buffer name from subs (SeesFossilText
-- reads both wNameBuffer and wStringBuffer), falling back to subs.ram.
local function fillFossilText(s, subs)
  s = s:gsub("{PLAYER}", subs.player or "")
  s = s:gsub("{RAM:([^}]*)}", function(name) return subs[name] or subs.ram or "" end)
  return s
end

M.CINNABAR_LAB_FOSSIL_ROOM = {
  talk = {
    -- Fossil revival quest (scripts/CinnabarLabFossilRoom.asm
    -- CinnabarLabFossilRoomScientist1Text lines 49-99, deposit flow in
    -- engine/events/cinnabar_lab.asm GiveFossilToCinnabarLab): deposit
    -- a fossil -> pending for the rest of this visit -> ready once the
    -- player leaves and re-enters the CINNABAR_ISLAND overworld map
    -- (M.CINNABAR_ISLAND.onEnter in data/scripts/story5.lua clears
    -- EVENT_LAB_STILL_REVIVING_FOSSIL there, mirroring CinnabarIsland.
    -- asm line 6) -> hand over the mon and reset the whole quest so a
    -- second fossil can be deposited later.
    --
    -- The deposit itself follows GiveFossilToCinnabarLab: a bordered
    -- top-left menu of every carried fossil (A/B watched; B backs out),
    -- then SeesFossilText with a Yes/No confirm; both cancel paths
    -- (B on the menu, NO on the confirm) share ComeAgainText.
    TEXT_CINNABARLABFOSSILROOM_SCIENTIST1 = function(game, ow, npc, done)
      local TextBox = require("src.render.TextBox")
      local t = game.data.text
      local f = game.save.flags
      local subs = { player = game.save.player.name }

      if f.EVENT_GAVE_FOSSIL_TO_LAB then
        if f.EVENT_LAB_STILL_REVIVING_FOSSIL then
          -- .check_done_reviving -> still pending this visit
          game.stack:push(TextBox.new(game,
            t._CinnabarLabFossilRoomScientist1GoForAWalkText or
            "I take a little\ntime!\fYou go for walk a\nlittle while!", done))
          return
        end
        -- STILL_REVIVING was cleared (CINNABAR_ISLAND was reloaded
        -- since the deposit): .done_reviving, lines 72-83
        local species = game.save.labFossilMon
        subs.ram = species and game.data.pokemon[species]
                   and game.data.pokemon[species].name or ""
        f.EVENT_LAB_HANDING_OVER_FOSSIL_MON = true
        game.stack:push(TextBox.new(game,
          fillFossilText(
            t._CinnabarLabFossilRoomScientist1FossilIsBackToLifeText or
            "Where were you?\fYour fossil is\nback to life!\fIt was {RAM:x}\nlike I think!",
            subs),
          function()
            if species then
              local Commands = require("src.script.Commands")
              local ctx = { save = game.save, game = game, overworld = ow }
              Commands.give_pokemon(ctx, species, 30)
              if not ctx.lastCheck then
                -- GivePokemon failed (party+box full): pokered's
                -- `jr nc, .done` leaves the quest pending so the
                -- scientist re-offers the mon next visit instead of
                -- destroying it.
                game.stack:push(TextBox.new(game,
                  t._BoxIsFullText or "Box is full!", done))
                return
              end
            end
            game.save.labFossilMon = nil
            f.EVENT_GAVE_FOSSIL_TO_LAB = nil
            f.EVENT_LAB_STILL_REVIVING_FOSSIL = nil
            f.EVENT_LAB_HANDING_OVER_FOSSIL_MON = nil
            done()
          end))
        return
      end

      -- No fossil deposited yet: the intro always plays first (.Text),
      -- then either the fossil-select menu (GiveFossilToCinnabarLab)
      -- or NoFossilsText.
      game.stack:push(TextBox.new(game,
        t._CinnabarLabFossilRoomScientist1Text or
        "Hiya!\fI am important\ndoctor!\fI study here rare\nPOKéMON fossils!\fYou! Have you a\nfossil for me?",
        function()
          -- Lab4Script_GetFossilsInBag: every carried fossil, in
          -- FossilsList order
          local carried = {}
          for _, fossil in ipairs(FOSSIL_ORDER) do
            if (game.save.inventory[fossil] or 0) > 0 then
              carried[#carried + 1] = fossil
            end
          end
          if #carried == 0 then
            game.stack:push(TextBox.new(game,
              t._CinnabarLabFossilRoomScientist1NoFossilsText or
              "No! Is too bad!", done))
            return
          end
          -- .cancelledGivingFossil: B on the menu and NO on the
          -- confirm both land here
          local function comeAgain()
            game.stack:push(TextBox.new(game,
              t._CinnabarLabFossilRoomScientist1ComeAgainText or
              "Aiyah! You come\nagain!", done))
          end
          local items = {}
          for _, fossil in ipairs(carried) do
            items[#items + 1] = {
              label = game.data.items[fossil].name,
              onSelect = function()
                -- LoadFossilItemAndMonName: wNameBuffer = item name,
                -- wStringBuffer = mon name; then .ScientistSeesFossilText
                -- with YesNoChoice (cursor starts on YES)
                local species = FOSSIL_MONS[fossil]
                local def = game.data.pokemon[species]
                subs.wNameBuffer = game.data.items[fossil].name
                subs.wStringBuffer = def and def.name or species
                game.stack:push(TextBox.new(game,
                  fillFossilText(
                    t._CinnabarLabFossilRoomScientist1SeesFossilText or
                    "Oh! That is\n{RAM:wNameBuffer}!\fIt is fossil of\n{RAM:wStringBuffer}, a\nPOKéMON that is\nalready extinct!\fMy Resurrection\nMachine will make\nthat POKéMON live\nagain!",
                    subs),
                  nil, { choice = function(yes)
                    if not yes then comeAgain() return end
                    -- YES: TakesFossilText, RemoveItemByID, GoForAWalk2,
                    -- SetEvents GAVE_FOSSIL_TO_LAB + STILL_REVIVING
                    require("src.inventory.Bag").remove(game.save, fossil, 1)
                    game.save.labFossilMon = species
                    f.EVENT_GAVE_FOSSIL_TO_LAB = true
                    f.EVENT_LAB_STILL_REVIVING_FOSSIL = true
                    game.stack:push(TextBox.new(game,
                      fillFossilText(
                        t._CinnabarLabFossilRoomScientist1TakesFossilText or
                        "So! You hurry and\ngive me that!\f{PLAYER} handed\nover {RAM:wNameBuffer}!",
                        subs),
                      function()
                        game.stack:push(TextBox.new(game,
                          t._CinnabarLabFossilRoomScientist1GoForAWalkText2 or
                          "I take a little\ntime!\fYou go for walk a\nlittle while!", done))
                      end))
                  end }))
              end,
            }
          end
          -- GiveFossilToCinnabarLab's menu: TextBoxBorder at 0,0
          -- (interior width $d, height 2 per fossil), A|B watched
          local Menu = require("src.ui.Menu")
          game.stack:push(Menu.new(game, items,
            { tx = 0, ty = 0, tw = 15, onCancel = comeAgain }))
        end))
    end,
    -- the other scientist trades SAILOR: Ponyta -> Seel
    -- (scripts/CinnabarLabFossilRoom.asm TRADE_FOR_SAILOR)
    TEXT_CINNABARLABFOSSILROOM_SCIENTIST2 = {
      { "face_player" },
      { "trade", 4, "EVENT_TRADED_PONYTA_FOR_SEEL" },
    },
  },
}

-- -------------------------------------------------------------------
-- Day-care (scripts/Daycare.asm): the boarded Pokémon earns 1 exp per
-- step; the fee is ¥100 plus ¥100 per level gained.
-- -------------------------------------------------------------------

M.DAYCARE = {
  talk = {
    TEXT_DAYCARE_GENTLEMAN = function(game, ow, npc, done)
      local TextBox = require("src.render.TextBox")
      local ChoiceBox = require("src.ui.ChoiceBox")
      local t = game.data.text
      local dc = game.save.daycare

      if dc and dc.mon then
        local Growth = require("src.pokemon.Growth")
        local Stats = require("src.pokemon.Stats")
        local mon = dc.mon
        local def = game.data.pokemon[mon.species]
        mon.exp = mon.exp + (dc.steps or 0)
        local newLevel = math.min(100, Growth.levelForExp(def.growthRate, mon.exp))
        local fee = 100 + (newLevel - mon.level) * 100
        local grew = newLevel > mon.level
        mon.level = newLevel
        mon.stats = Stats.calc(def, mon.level, mon.dvs, mon.statExp)
        mon.hp = mon.stats.hp
        local msg = grew and (t._DaycareGentlemanMonHasGrownText or "It's grown a lot!")
                    or "Back already?"
        game.stack:push(TextBox.new(game,
          msg .. ("\fThe fee is ¥%d.\nGet it back?"):format(fee), function()
          game.stack:push(ChoiceBox.new(game, function(yes)
            if yes and game.save.money >= fee then
              game.save.money = game.save.money - fee
              table.insert(game.save.party, mon)
              game.save.daycare = nil
              game.stack:push(TextBox.new(game,
                t._DaycareGentlemanGotMonBackText or "Here you go!", done))
            else
              game.stack:push(TextBox.new(game,
                yes and (t._DaycareGentlemanOweMoneyText or "You owe me money!")
                    or "Come again!", done))
            end
          end))
        end))
        return
      end

      if #game.save.party < 2 then
        game.stack:push(TextBox.new(game,
          "You only have one\nPOKéMON with you!", done))
        return
      end
      game.stack:push(TextBox.new(game,
        t._DaycareGentlemanIntroText or "I can raise a\nPOKéMON for you.", function()
        game.stack:push(ChoiceBox.new(game, function(yes)
          if not yes then done() return end
          local PartyMenu = require("src.ui.PartyMenu")
          game.stack:push(PartyMenu.new(game, {
            pickOnly = true,
            onSwitch = function(mon)
              for i, m in ipairs(game.save.party) do
                if m == mon then table.remove(game.save.party, i) break end
              end
              game.save.daycare = { mon = mon, steps = 0 }
              game.stack:push(TextBox.new(game,
                t._DaycareGentlemanWillLookAfterMonText or
                "Fine, I'll look\nafter it a while!", done))
            end,
          }))
        end))
      end))
    end,
  },
}

return M
