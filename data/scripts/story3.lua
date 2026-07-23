-- Third batch of hand-ported events: fishing rod givers, the Marowak
-- ghost, elevators, the Game Corner coins/prizes, the SS Anne departure
-- and the Hall of Fame record.  Each cites its pokered source.

local M = {}

-- -------------------------------------------------------------------
-- Fishing rod givers (scripts/VermilionOldRodHouse.asm,
-- FuchsiaGoodRodHouse.asm, Route12SuperRodHouse.asm)
-- -------------------------------------------------------------------

local function rodGiver(askText, receivedText, afterText, rodItem, flag)
  return {
    { "face_player" },                -- 1
    { "check_flag", flag },           -- 2
    { "jump_if_true", 9 },            -- 3
    { "ask", askText },               -- 4
    { "jump_if_false", 10 },          -- 5
    -- give-then-print like the three rod-house scripts (GiveItem fills
    -- wStringBuffer; the received texts read OLD/GOOD/SUPER ROD from it)
    { "give_item", rodItem, 1, false },  -- 6
    { "show_text", receivedText },       -- 7
    { "set_flag", flag },             -- 8
    { "jump", 10 },                   -- 9 is below
  }
end

M.VERMILION_OLD_ROD_HOUSE = {
  talk = {
    TEXT_VERMILIONOLDRODHOUSE_FISHING_GURU = rodGiver(
      "_VermilionOldRodHouseFishingGuruDoYouLikeToFishText",
      "_VermilionOldRodHouseFishingGuruTakeThisText",
      "_VermilionOldRodHouseFishingGuruHowAreTheFishBitingText",
      "OLD_ROD", "EVENT_GOT_OLD_ROD"),
  },
}
M.VERMILION_OLD_ROD_HOUSE.talk.TEXT_VERMILIONOLDRODHOUSE_FISHING_GURU[9] =
  { "show_text", "_VermilionOldRodHouseFishingGuruHowAreTheFishBitingText" }

M.FUCHSIA_GOOD_ROD_HOUSE = {
  talk = {
    TEXT_FUCHSIAGOODRODHOUSE_FISHING_GURU = rodGiver(
      "_FuchsiaGoodRodHouseFishingGuruText",
      "_FuchsiaGoodRodHouseFishingGuruReceivedGoodRodText",
      "_FuchsiaGoodRodHouseFishingGuruHowAreTheFishText",
      "GOOD_ROD", "EVENT_GOT_GOOD_ROD"),
  },
}
M.FUCHSIA_GOOD_ROD_HOUSE.talk.TEXT_FUCHSIAGOODRODHOUSE_FISHING_GURU[9] =
  { "show_text", "_FuchsiaGoodRodHouseFishingGuruHowAreTheFishText" }

M.ROUTE_12_SUPER_ROD_HOUSE = {
  talk = {
    TEXT_ROUTE12SUPERRODHOUSE_FISHING_GURU = rodGiver(
      "_Route12SuperRodHouseFishingGuruDoYouLikeToFishText",
      "_Route12SuperRodHouseFishingGuruReceivedSuperRodText",
      "_Route12SuperRodHouseFishingGuruTryFishingText",
      "SUPER_ROD", "EVENT_GOT_SUPER_ROD"),
  },
}
M.ROUTE_12_SUPER_ROD_HOUSE.talk.TEXT_ROUTE12SUPERRODHOUSE_FISHING_GURU[9] =
  { "show_text", "_Route12SuperRodHouseFishingGuruTryFishingText" }

-- -------------------------------------------------------------------
-- The ghost Marowak (scripts/PokemonTower6F.asm): blocks the stairs at
-- (10,16) until defeated.
--
-- PokemonTower6FDefaultScript starts the RESTLESS SOUL battle with NO
-- Silph Scope check at the trigger -- the scope only decides whether the
-- battle is disguised (IsGhostBattle -> makeGhost: "too scared to move",
-- balls dodged). An earlier version of this port turned the player back
-- without the scope and never opened the battle, which made 6F
-- impassable on any route that skips Rocket Hideout; vanilla lets the
-- battle open and a POKE_DOLL end it (see wBattleResult below).
-- -------------------------------------------------------------------

M.POKEMON_TOWER_6F = {
  onStep = function(game, ow, x, y)
    if game.save.flags.EVENT_BEAT_GHOST_MAROWAK then return false end
    if x ~= 10 or y ~= 16 then return false end
    local TextBox = require("src.render.TextBox")
    local t = game.data.text
    game.stack:push(TextBox.new(game,
      t._PokemonTower6FBeGoneText or "Be gone...\nIntruders...", function()
      local BattleState = require("src.battle.BattleState")
      local battle = BattleState.newWild(game, "MAROWAK", 30)
      if not game.save.inventory.SILPH_SCOPE then
        battle:makeGhost()
      end
      battle.onFinish = function(result)
        -- wBattleResult parity (PokemonTower6FMarowakBattleScript's
        -- "and a / jr nz"): losing writes $1 and running writes $2, but
        -- ItemUsePokeDoll ends the battle WITHOUT touching it, so the
        -- script reads 0 -- defeated. That is the famous Poke Doll
        -- trick, and the speedrun route this bot follows depends on it.
        if result == "win" or battle.pokeDollEscape then
          game.save.flags.EVENT_BEAT_GHOST_MAROWAK = true
          game.stack:push(TextBox.new(game,
            t._PokemonTower6FSoulWasCalmedText
            or "The mother's soul\nwas calmed.\012It departed to\nthe afterlife!"))
        elseif result ~= "lose" then
          -- .did_not_defeat: one simulated step right, off the trigger,
          -- so fleeing does not leave you standing on a cell that
          -- immediately re-fires.
          ow:scriptMove(ow.player, "right", 1)
        end
        ow:afterBattle(result, battle)
      end
      game.stack:push(battle)
    end))
    return true
  end,
}

-- -------------------------------------------------------------------
-- Elevators (scripts/SilphCoElevator.asm etc.): a floor menu built from
-- the maps whose warps lead to the elevator (fully data-driven).
--
-- engine/events/elevator.asm DisplayElevatorFloorMenu: prints the floor
-- list (SPECIALLISTMENU -- a plain text list, constants/list_constants
-- .asm:7, not a graphical panel) built from each elevator's fixed
-- FLOOR_* table (e.g. scripts/SilphCoElevator.asm SilphCoElevatorFloors,
-- ascending FLOOR_1F..FLOOR_11F); wCurrentMenuItem is explicitly zeroed
-- so the cursor always rests on the topmost floor -- there is no
-- current-floor marker/wWhichFloor symbol anywhere in Gen1.  Floor
-- labels are the short FLOOR_* item-name strings (data/items/names.asm:
-- 87-100 -- '1F'..'11F', 'B1F', 'B2F', 'B4F'), never the room/map name.
-- On B (`ret c`) nothing happens -- no warp, the player just stays put.
-- On A, the map script sees BIT_CUR_MAP_USED_ELEVATOR and runs
-- engine/overworld/elevator.asm ShakeElevator (src/world/ElevatorShake
-- .lua): the music stops, the BG scroll bounces -1/+1px for 100
-- two-frame cycles with SFX_COLLISION each cycle, then
-- SFX_SAFARI_ZONE_PA plays out and the map theme returns, before the
-- player is delivered to the chosen floor.
-- keyGate: the Rocket Hideout panel refuses without the LIFT KEY
-- (scripts/RocketHideoutElevator.asm RocketHideoutElevatorText:
-- "It appears to need a key." and no floor menu)
-- preFrames: the shake's lead-in delays -- ShakeElevator's own Delay3s
-- come to 9 frames; Silph/Rocket's ...ShakeScript prefixes another
-- Delay3 (12) while CeladonMartElevatorShakeScript farjps straight in
-- After the ride the original does NOT jump-cut to the floor: choosing a
-- floor in engine/events/elevator.asm DisplayElevatorFloorMenu rewrites
-- the elevator car's own warp entries (wWarpEntries, via .UpdateWarp) to
-- the chosen floor's exit warp, then the player walks out of the car onto
-- that warp themselves (scripts/SilphCoElevator.asm etc.).  Reproduce
-- that here: rewrite the car's exit warps, then drive a short scripted
-- walk-out onto an exit tile and take the (now rewritten) warp, reusing
-- ow:scriptMove / ow:takeWarp (the Oak-escort primitives).
local WALK_DIRVEC = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }
local WALK_OPP = { up = "down", down = "up", left = "right", right = "left" }
local WALK_ORDER = { "up", "down", "left", "right" }

local function elevatorWalkOut(ow, floor)
  local m, p = ow.map, ow.player
  -- .UpdateWarp is run twice, so BOTH car warp entries get the same
  -- (warp id, map id): point every exit warp at the picked floor's
  -- elevator-door warp (the reciprocal warp found while building the
  -- menu).  The car map's def is shared generated data, but its own
  -- warps are only ever read from inside the car, and this rewrite runs
  -- on every ride before the walk-out fires, so it is self-correcting.
  for _, w in ipairs(m.def.warps) do
    w.destMap = floor.map
    w.destWarp = floor.warpIdx
  end
  -- leave by the exit tile under the player (they warped in onto one),
  -- else the nearest
  local door
  for _, w in ipairs(m.def.warps) do
    if w.x == p.cellX and w.y == p.cellY then door = w break end
  end
  if not door then
    local best
    for _, w in ipairs(m.def.warps) do
      local d = math.abs(w.x - p.cellX) + math.abs(w.y - p.cellY)
      if not best or d < best then best, door = d, w end
    end
  end
  -- the car interior sits on the door's walkable side; "out" is the
  -- doorway direction (the map edge for Silph/Celadon, the top doorway
  -- for the Rocket car).  Fixed direction order keeps the step
  -- deterministic when a door tile has several walkable neighbours
  -- (Silph/Celadon step up into the car, the Rocket car steps down).
  local into
  for _, dir in ipairs(WALK_ORDER) do
    local v = WALK_DIRVEC[dir]
    local nx, ny = door.x + v[1], door.y + v[2]
    if m:inBounds(nx, ny) and m:isWalkableCell(nx, ny) then into = dir break end
  end
  into = into or "up"
  local out = WALK_OPP[into]
  local function leave()
    ow:takeWarp(door) -- door SFX + warp to the rewritten floor target
  end
  -- step one tile into the car, then walk back through the doorway onto
  -- the exit tile and take the warp: a visible walk-out on valid tiles
  -- for either door orientation, instead of a jump cut
  ow:scriptMove(p, into, 1, function()
    ow:scriptMove(p, out, 1, leave)
  end)
end

local function elevator(elevatorMapId, keyGate, preFrames)
  return {
    onEnter = function(game, ow)
      if keyGate and not game.save.inventory[keyGate.item] then
        local TextBox = require("src.render.TextBox")
        game.stack:push(TextBox.new(game,
          game.data.text[keyGate.text] or "It appears to\nneed a key."))
        return
      end
      local floors = {}
      for mapId, def in pairs(game.data.maps) do
        for i, w in ipairs(def.warps) do
          if w.destMap == elevatorMapId then
            -- short floor token pokered actually prints, e.g.
            -- SILPH_CO_10F -> "10F", ROCKET_HIDEOUT_B2F -> "B2F"
            local token = mapId:match("_([^_]+)$") or mapId
            -- warpIdx: this floor's warp back into the elevator IS the
            -- warp the car's rewritten exit lands on (the reciprocal
            -- pair), matching wElevatorWarpMaps' (warp id, map id)
            table.insert(floors,
              { map = mapId, x = w.x, y = w.y, token = token, warpIdx = i })
            break
          end
        end
      end
      -- numeric floor order (SilphCoElevatorFloors' FLOOR_1F..FLOOR_11F),
      -- not lexicographic -- otherwise 10F/11F sort before 2F..9F
      table.sort(floors, function(a, b)
        return (tonumber(a.token:match("%d+")) or 0) <
               (tonumber(b.token:match("%d+")) or 0)
      end)
      local items = {}
      for _, f in ipairs(floors) do
        table.insert(items, { label = f.token, value = f })
      end
      local ListMenu = require("src.ui.ListMenu")
      game.stack:push(ListMenu.new(game, "WHICH FLOOR?", items, {
        onChoose = function(item, list)
          list:close()
          -- the map-entry Transition (startWarpTo) calls onEnter from
          -- its OWN midpoint callback, so this menu was pushed on top
          -- of that still-active Transition; only the top state
          -- updates, so it froze mid-fade instead of finishing.  Left
          -- alone it would resurface after the ride and play a stray
          -- fade at the wrong time -- pop it now, before it can happen.
          local Transition = require("src.render.Transition")
          if getmetatable(game.stack:top()) == Transition then
            game.stack:pop()
          end
          -- the whole ShakeElevator ride runs in place -- music stop,
          -- 100 collision-thud scroll bounces, the PA chime -- and only
          -- then does the player walk out of the car onto the chosen
          -- floor (elevatorWalkOut rewrites the car's exit warps first)
          local ElevatorShake = require("src.world.ElevatorShake")
          game.stack:push(ElevatorShake.new(game, ow, {
            preFrames = preFrames,
            onDone = function()
              elevatorWalkOut(ow, item.value)
            end,
          }))
        end,
        onCancel = function()
          -- DisplayElevatorFloorMenu: `ret c` on B -- no warp, nothing
          -- happens, the player just stays in the car
        end,
      }))
    end,
  }
end

M.SILPH_CO_ELEVATOR = elevator("SILPH_CO_ELEVATOR")
M.CELADON_MART_ELEVATOR = elevator("CELADON_MART_ELEVATOR", nil, 9)
M.ROCKET_HIDEOUT_ELEVATOR = elevator("ROCKET_HIDEOUT_ELEVATOR",
  { item = "LIFT_KEY", text = "_RocketHideoutElevatorAppearsToNeedKeyText" })

-- -------------------------------------------------------------------
-- Game Corner coins, prizes, and the rocket-poster switch that reveals
-- the hideout stairs (scripts/GameCorner.asm, data/events/prizes.asm +
-- prize_mon_levels.asm)
-- -------------------------------------------------------------------

M.GAME_CORNER = {
  -- the hideout stairs hide behind a wall block until the poster
  -- switch is found (the block at (8,2) is $2a while
  -- EVENT_FOUND_ROCKET_HIDEOUT is unset, $43 after)
  onEnter = function(game, ow)
    local poster = game.data.field.gameCornerPoster
    if not poster then return end
    local block = game.save.flags[poster.event] and poster.openBlock
                  or poster.closedBlock
    ow:replaceBlock(poster.x, poster.y, block)
    -- pick this visit's lucky slot machine
    -- (wLuckySlotHiddenEventIndex, engine/slots/game_corner_slots2.asm)
    local seats = game.data.field.slotMachines.GAME_CORNER
    ow.luckySlot = love.math.random(1, #seats)
  end,
  talk = {
    -- the poster bg event: pressing A reveals the hidden switch
    TEXT_GAMECORNER_POSTER = function(game, ow, npc, done)
      local TextBox = require("src.render.TextBox")
      local poster = game.data.field.gameCornerPoster
      local t = game.data.text
      local text = t._GameCornerPosterSwitchBehindPosterText
                   or "Hey!\fA switch behind\nthe poster!?\nLet's push it!"
      if game.save.flags[poster.event] then
        game.stack:push(TextBox.new(game, text, done))
        return
      end
      -- GameCornerPosterText: the SwitchBehindPosterText plays
      -- SFX_SWITCH as it shows, then SFX_GO_INSIDE opens the stairs
      require("src.core.Sound").play(game.data, "Switch")
      game.stack:push(TextBox.new(game, text, function()
        game.save.flags[poster.event] = true
        require("src.core.Sound").play(game.data, "Go_Inside")
        ow:replaceBlock(poster.x, poster.y, poster.openBlock)
        done()
      end))
    end,
    -- the grunt guarding the poster (GameCornerRocketText /
    -- GameCornerRocketBattleScript / GameCornerRocketExitScript): after
    -- losing he warns the BOSS and leaves the floor for good, freeing
    -- the tile in front of the hideout switch
    TEXT_GAMECORNER_ROCKET = function(game, ow, npc, done)
      if ow:trainerDefeated(npc) then
        done()
        return
      end
      ow:engageTrainer(npc, function()
        if not ow:trainerDefeated(npc) then
          done()
          return
        end
        local TextBox = require("src.render.TextBox")
        game.stack:push(TextBox.new(game,
          game.data.text._GameCornerRocketAfterBattleText
          or "Our hideout might\nbe discovered! I\nbetter tell BOSS!",
          function()
            local Commands = require("src.script.Commands")
            Commands.hide_object({ game = game, save = game.save,
                                   overworld = ow },
                                 "GAME_CORNER", "GAMECORNER_ROCKET")
            done()
          end))
      end)
    end,
    TEXT_GAMECORNER_CLERK1 = function(game, ow, npc, done)
      local TextBox = require("src.render.TextBox")
      local ChoiceBox = require("src.ui.ChoiceBox")
      local t = game.data.text
      game.stack:push(TextBox.new(game,
        (t._GameCornerClerk1DoYouNeedSomeGameCoinsText
         or "Do you need some\ngame coins?\f¥1000 for 50."), function()
        game.stack:push(ChoiceBox.new(game, function(yes)
          if not yes then
            game.stack:push(TextBox.new(game,
              t._GameCornerClerk1PleaseComePlaySometimeText
              or "No? Please come\nplay sometime!", done))
            return
          end
          -- scripts/GameCorner.asm GameCornerClerk1Text: coins need
          -- the COIN CASE and room for at least 9 coins (Has9990Coins)
          if not game.save.inventory.COIN_CASE then
            game.stack:push(TextBox.new(game,
              t._GameCornerClerk1DontHaveCoinCaseText
              or "You don't have a\nCOIN CASE!", done))
            return
          end
          if (game.save.coins or 0) >= 9990 then
            game.stack:push(TextBox.new(game,
              t._GameCornerClerk1CoinCaseIsFullText
              or "Oops! Your COIN\nCASE is full.", done))
            return
          end
          if game.save.money < 1000 then
            game.stack:push(TextBox.new(game,
              t._GameCornerClerk1CantAffordTheCoinsText
              or "You can't afford\nthe coins!", done))
            return
          end
          game.save.money = game.save.money - 1000
          game.save.coins = math.min(9999, (game.save.coins or 0) + 50)
          game.stack:push(TextBox.new(game,
            (t._GameCornerClerk1ThanksHereAre50CoinsText
             or "Thanks! Here are\nyour 50 coins!")
            .. ("\fCOINS: %d"):format(game.save.coins), done))
        end))
      end))
    end,
  },
}

-- Game Corner prize lists (data/events/prizes.asm, prize_mon_levels.asm).
-- The six mon prizes differ between Red and Blue; the three TM prizes are
-- identical, so they are shared and appended to each version's mon list.
local PRIZE_TMS = {
  { kind = "item", item = "TM_DRAGON_RAGE", cost = 3300 },
  { kind = "item", item = "TM_HYPER_BEAM", cost = 5500 },
  { kind = "item", item = "TM_SUBSTITUTE", cost = 7700 },
}
local RED_PRIZES = {
  { kind = "mon", species = "ABRA", level = 9, cost = 180 },
  { kind = "mon", species = "CLEFAIRY", level = 8, cost = 500 },
  { kind = "mon", species = "NIDORINA", level = 17, cost = 1200 },
  { kind = "mon", species = "DRATINI", level = 18, cost = 2800 },
  { kind = "mon", species = "SCYTHER", level = 25, cost = 5500 },
  { kind = "mon", species = "PORYGON", level = 26, cost = 9999 },
  PRIZE_TMS[1], PRIZE_TMS[2], PRIZE_TMS[3],
}
local BLUE_PRIZES = {
  { kind = "mon", species = "ABRA", level = 6, cost = 120 },
  { kind = "mon", species = "CLEFAIRY", level = 12, cost = 750 },
  { kind = "mon", species = "NIDORINO", level = 17, cost = 1200 },
  { kind = "mon", species = "PINSIR", level = 20, cost = 2500 },
  { kind = "mon", species = "DRATINI", level = 24, cost = 4600 },
  { kind = "mon", species = "PORYGON", level = 18, cost = 6500 },
  PRIZE_TMS[1], PRIZE_TMS[2], PRIZE_TMS[3],
}

local function activePrizes()
  return require("src.core.GameVersion").isBlue() and BLUE_PRIZES or RED_PRIZES
end

local function prizeCounter(game, ow, npc, done)
  local ListMenu = require("src.ui.ListMenu")
  local Commands = require("src.script.Commands")
  local items = {}
  for _, p in ipairs(activePrizes()) do
    local label
    if p.kind == "mon" then
      label = ("%s L%d"):format(game.data.pokemon[p.species].name, p.level)
    else
      label = game.data.items[p.item].name
    end
    table.insert(items, { label = label, right = tostring(p.cost), value = p })
  end
  local list
  list = ListMenu.new(game, "PRIZES (COINS)", items, {
    footer = ("COINS %d"):format(game.save.coins or 0),
    onChoose = function(item)
      local p = item.value
      if (game.save.coins or 0) < p.cost then
        list.footer = "Not enough coins!"
        return
      end
      game.save.coins = game.save.coins - p.cost
      if p.kind == "mon" then
        Commands.give_pokemon({ save = game.save, game = game },
                              p.species, p.level)
      else
        game.save.inventory[p.item] = (game.save.inventory[p.item] or 0) + 1
      end
      list.footer = ("Got it! COINS %d"):format(game.save.coins)
    end,
    onCancel = done,
  })
  game.stack:push(list)
end

M.GAME_CORNER_PRIZE_ROOM = {
  talk = { -- the three prize counters are bg events
    TEXT_GAMECORNERPRIZEROOM_PRIZE_VENDOR_1 = prizeCounter,
    TEXT_GAMECORNERPRIZEROOM_PRIZE_VENDOR_2 = prizeCounter,
    TEXT_GAMECORNERPRIZEROOM_PRIZE_VENDOR_3 = prizeCounter,
  },
}

-- -------------------------------------------------------------------
-- SS Anne departure (scripts/VermilionDock.asm): once HM01 is in hand
-- and the player steps off the dock, the ship sets sail.
-- -------------------------------------------------------------------

-- the ship's hull/deck blocks (block cols 5-8, rows 1-2) and the water
-- that replaces them once she sails (the surrounding blocks of each row)
local DOCK_SHIP_BLOCKS = {
  { bx = 5, by = 1, water = 1 }, { bx = 6, by = 1, water = 1 },
  { bx = 7, by = 1, water = 1 }, { bx = 8, by = 1, water = 1 },
  { bx = 5, by = 2, water = 13 }, { bx = 6, by = 2, water = 13 },
  { bx = 7, by = 2, water = 13 }, { bx = 8, by = 2, water = 13 },
}

M.VERMILION_DOCK = {
  onEnter = function(game, ow)
    local f = game.save.flags
    if f.EVENT_SS_ANNE_LEFT then
      -- the ship is long gone: erase her right away, and anyone who
      -- still lands here is sent back out past the guard
      for _, b in ipairs(DOCK_SHIP_BLOCKS) do
        ow.map:setBlock(b.bx, b.by, b.water)
      end
      ow.map.renderer:rebuild()
      local TextBox = require("src.render.TextBox")
      game.stack:push(TextBox.new(game,
        game.data.text._VermilionCitySailor1ShipSetSailText
        or "The ship set sail.", function()
        ow:startWarpTo("VERMILION_CITY", 18, 29, "up")
      end))
    elseif f.EVENT_GOT_HM01 and ow.player.cellY == 2 then
      -- VermilionDockSSAnneLeavesScript: only stepping OFF the ship
      -- triggers the departure (wDestinationWarpID == 1 in pokered) --
      -- the horn blows, smoke puffs drift off the funnel, the ship is
      -- erased to open water, and the player is walked off the dock
      -- into the city past the guard (VermilionCity's
      -- SCRIPT_VERMILIONCITY_PLAYER_EXIT_SHIP walk)
      f.EVENT_SS_ANNE_LEFT = true
      require("src.core.Music").stop()
      require("src.core.Sound").play(game.data, "SS_Anne_Horn")
      local function puff(n, cx)
        if n <= 0 then return end
        ow:startDustAnim(cx, 1, function() puff(n - 1, cx + 2) end)
      end
      puff(3, 15)
      local rows = {}
      rows[#rows + 1] = { "wait", 100 }
      for _, b in ipairs(DOCK_SHIP_BLOCKS) do
        rows[#rows + 1] = { "replace_block", b.bx, b.by, b.water }
      end
      rows[#rows + 1] = { "wait", 30 }
      rows[#rows + 1] = { "move_player", "up", 2 }
      rows[#rows + 1] = { "warp", "VERMILION_CITY", 18, 31, "up" }
      rows[#rows + 1] = { "move_player", "up", 2 }
      ow:queueScript(rows)
    end
  end,
}

return M
