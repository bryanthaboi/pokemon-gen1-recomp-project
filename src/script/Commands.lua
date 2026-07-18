-- Script command implementations.  Each receives the script context.
-- Blocking commands yield the script coroutine and resume when the UI or
-- world event completes.
--
-- Conditionals: check_flag stores its result in ctx.lastCheck;
-- jump_if_true/jump_if_false jump to an absolute row index.

local Flags = require("src.script.Flags")
local Logger = require("src.core.Logger")
local TextBox = require("src.render.TextBox")

local Commands = {}

-- show_text <textId or literal> [subs]: textId is looked up in generated
-- text (by label like "_PalletTownGirlText" or via the map's TEXT_*
-- pointers).  subs replaces dynamic tokens, e.g. { RAM = "BULBASAUR" }
-- fills {RAM:wNameBuffer}.
--
-- A preceding play_cry row (static-encounter battle text: PowerPlantZapdos-
-- BattleText and friends -- text_far "Gyaoo!@"/"Mew!@" + text_asm PlayCry +
-- WaitForSoundToFinish) leaves ctx.pendingCry set; that text has no <DONE>/
-- <PROMPT> of its own; the box only closes once WaitForSoundToFinish's poll
-- loop sees the cry channel go quiet, so it's a no-button-wait auto text
-- gated on the cry, not a button-wait one -- see TextBox's opts.auto.
function Commands.show_text(ctx, textId, subs)
  local text = ctx.game.data.text[textId]
  if not text and ctx.overworld then
    text = ctx.game.data:resolveText(ctx.overworld.map.def.label, textId)
  end
  if not text then
    text = textId -- literal string fallback for hand-ported scripts
  end
  if subs then
    for token, value in pairs(subs) do
      -- A mod may transform a gift after the script row was authored.  Keep
      -- that replacement scoped to the immediately following received-mon
      -- message; later script rows (such as the rival's gift) must use their
      -- own explicit RAM value.
      local replacement = value
      if token == "RAM" and ctx.pendingPokemonName then
        replacement = ctx.pendingPokemonName
        ctx.pendingPokemonName = nil
      end
      text = text:gsub("{" .. token .. ":?[%w_]*}", replacement)
    end
  end
  local runner = ctx.runner
  local opts
  if ctx.pendingCry then
    local species = ctx.pendingCry
    ctx.pendingCry = nil
    opts = { auto = { sound = function()
      return require("src.core.Sound").playCry(ctx.game.data, species)
    end, delay = 0 } } -- WaitForSoundToFinish has no trailing Delay3 of its own
  end
  ctx.game.stack:push(TextBox.new(ctx.game, text, function()
    runner:resume()
  end, opts))
  runner:yield()
end

function Commands.jump(ctx, target)
  return target
end

-- ask <textId> [subs]: show text, then a YES/NO box; result lands in
-- ctx.lastCheck.  subs are forwarded to show_text's {token} filling.
function Commands.ask(ctx, textId, subs)
  Commands.show_text(ctx, textId, subs)
  local ChoiceBox = require("src.ui.ChoiceBox")
  local runner = ctx.runner
  ctx.game.stack:push(ChoiceBox.new(ctx.game, function(yes)
    ctx.lastCheck = yes
    runner:resume()
  end))
  runner:yield()
end

function Commands.face_player(ctx)
  if ctx.npc and ctx.overworld then
    ctx.npc:facePlayer(ctx.overworld.player)
  end
end

function Commands.set_flag(ctx, name)
  Flags.set(ctx.save, name)
end

function Commands.clear_flag(ctx, name)
  Flags.clear(ctx.save, name)
end

function Commands.check_flag(ctx, name)
  ctx.lastCheck = Flags.get(ctx.save, name)
end

function Commands.check_item(ctx, itemId)
  ctx.lastCheck = (ctx.save.inventory[itemId] or 0) > 0
end

function Commands.jump_if_true(ctx, target)
  if ctx.lastCheck then return target end
end

function Commands.jump_if_false(ctx, target)
  if not ctx.lastCheck then return target end
end

-- give_item <itemId> [count] [gotText]: adds to the bag, plays the gift
-- jingle and shows the "got item!" box.  pokered's GiveItem (home/
-- give.asm) copies the item name to wStringBuffer and every gift script
-- then prints a text ending "<PLAYER> got\n<item>!" with
-- sound_get_item_1/sound_get_key_item.  gotText picks that per-script
-- text (label or literal; {RAM:wStringBuffer} becomes the item name);
-- pass false when the script shows its own received-text row.
function Commands.give_item(ctx, itemId, count, gotText)
  -- the 20-slot bag can refuse (BAG_ITEM_CAPACITY): say so and halt
  -- the script, so later set_flag rows don't burn the gift -- make
  -- room and talk again, like the original (pokered's `jr nc, .bag_full`
  -- skips the received text entirely when AddItemToInventory refuses)
  if not require("src.inventory.Bag").add(ctx.save, itemId, count or 1) then
    Commands.show_text(ctx, "You can't carry\nany more items!")
    return math.huge
  end
  local def = ctx.game.data.items[itemId]
  -- GiveItem -> GetItemName + CopyToStringBuffer: the received texts
  -- read the name back out of wStringBuffer
  ctx.game.stringBuffer = def and def.name or itemId
  -- the jingle rides the box -- Sound.play routes fanfares through
  -- Music.duckForFanfare, like PlaySoundWaitForCurrent
  require("src.core.Sound").play(ctx.game.data,
    (def and def.keyItem) and "Get_Key_Item" or "Get_Item1")
  if gotText ~= false then
    Commands.show_text(ctx, gotText
      or "{PLAYER} got\n" .. ctx.game.stringBuffer .. "!")
  end
end

function Commands.take_item(ctx, itemId, count)
  local inv = ctx.save.inventory
  inv[itemId] = math.max(0, (inv[itemId] or 0) - (count or 1))
  if inv[itemId] == 0 then inv[itemId] = nil end
end

-- start_battle "wild" species level | start_battle "trainer" OPP_CLASS partyIndex
function Commands.start_battle(ctx, kind, a, b)
  local BattleState = require("src.battle.BattleState")
  local runner = ctx.runner
  local battle
  if kind == "wild" then
    battle = BattleState.newWild(ctx.game, a, b)
  else
    battle = BattleState.newTrainer(ctx.game, a, b)
  end
  battle.onFinish = function(result)
    ctx.lastBattleResult = result
    ctx.lastCheck = result == "win"
    if ctx.overworld then
      ctx.overworld:afterBattle(result)
    end
    runner:resume()
  end
  ctx.game.stack:push(battle)
  runner:yield()
end

function Commands.warp(ctx, mapId, x, y, facing)
  local runner = ctx.runner
  ctx.overworld:startWarpTo(mapId, x, y, facing, function()
    runner:resume()
  end)
  runner:yield()
end

function Commands.wait(ctx, frames)
  ctx.runner.waitingFrames = frames
  ctx.runner:yield()
end

local function walkEntity(ctx, entity, dir, tiles)
  local runner = ctx.runner
  ctx.overworld:scriptMove(entity, dir, tiles or 1, function()
    runner:resume()
  end)
  runner:yield()
end

function Commands.move_player(ctx, dir, tiles)
  walkEntity(ctx, ctx.overworld.player, dir, tiles)
end

function Commands.move_npc(ctx, objIndex, dir, tiles)
  local npc = ctx.overworld:npcByIndex(objIndex)
  if npc then walkEntity(ctx, npc, dir, tiles) end
end

-- Walk an NPC to a target cell along the map's walkable grid (BFS, so
-- scripted walks route around furniture instead of clipping through it).
local DIRS4 = { { 0, -1, "up" }, { 0, 1, "down" },
                { -1, 0, "left" }, { 1, 0, "right" } }

local function bfsPath(map, sx, sy, tx, ty)
  local key = function(x, y) return y * 1000 + x end
  local prev = { [key(sx, sy)] = false }
  local queue = { { sx, sy } }
  local qi = 1
  while queue[qi] do
    local cx, cy = queue[qi][1], queue[qi][2]
    qi = qi + 1
    if cx == tx and cy == ty then
      local path = {}
      local k = key(tx, ty)
      while prev[k] do
        table.insert(path, 1, prev[k][3])
        k = key(prev[k][1], prev[k][2])
      end
      return path
    end
    for _, d in ipairs(DIRS4) do
      local nx, ny = cx + d[1], cy + d[2]
      local nk = key(nx, ny)
      if prev[nk] == nil and map:inBounds(nx, ny)
         and (map:isWalkableCell(nx, ny) or (nx == tx and ny == ty)) then
        prev[nk] = { cx, cy, d[3] }
        table.insert(queue, { nx, ny })
      end
    end
  end
  return nil
end

function Commands.move_npc_to(ctx, objIndex, tx, ty)
  local ow = ctx.overworld
  local npc = ow:npcByIndex(objIndex)
  if not npc then return end
  local path = bfsPath(ow.map, npc.cellX, npc.cellY, tx, ty)
  if not path then
    Logger.warn("move_npc_to: no path to (%d,%d)", tx, ty)
    return
  end
  local runner = ctx.runner
  local i = 0
  local function step()
    i = i + 1
    if not path[i] then
      runner:resume()
      return
    end
    ow:scriptMove(npc, path[i], 1, step)
  end
  step()
  runner:yield()
end

function Commands.face(ctx, dir)
  if ctx.npc then ctx.npc.facing = dir end
end

-- face an arbitrary map object (by object_event index)
function Commands.face_object(ctx, objIndex, dir)
  local npc = ctx.overworld and ctx.overworld:npcByIndex(objIndex)
  if npc then npc.facing = dir end
end

function Commands.face_npc(ctx)
  -- make the player face the talking NPC
  if ctx.npc and ctx.overworld then
    local p = ctx.overworld.player
    local dx, dy = ctx.npc.cellX - p.cellX, ctx.npc.cellY - p.cellY
    if math.abs(dx) > math.abs(dy) then
      p.facing = dx > 0 and "right" or "left"
    else
      p.facing = dy > 0 and "down" or "up"
    end
  end
end

-- Set the player's facing to an explicit direction.  Cutscene runners that
-- have no ctx.npc (e.g. the HALL_OF_FAME room script queued from onEnter)
-- can't use face_player/face_npc to turn the player toward a fixed object,
-- so this mirrors pokered writing wPlayerMovingDirection directly
-- (scripts/HallOfFame.asm HallOfFameOakCongratulationsScript sets
-- PLAYER_DIR_RIGHT before the Oak speech).
function Commands.face_player_dir(ctx, dir)
  if ctx.overworld then ctx.overworld.player.facing = dir end
end

-- Set a plain field on the save table (used for transient one-shot markers
-- consumed by a map's onEnter, e.g. save.pendingHallOfFame handed from the
-- Champions Room warp to the HALL_OF_FAME room cutscene).  Not a flag: it
-- lives outside the event-flag namespace and is cleared on consumption.
function Commands.set_field(ctx, key, value)
  ctx.save[key] = value
end

local function toggleObject(ctx, mapId, objName, visible)
  local save = ctx.save
  save.objectToggles = save.objectToggles or {}
  save.objectToggles[mapId] = save.objectToggles[mapId] or {}
  save.objectToggles[mapId][objName] = visible
  -- add/remove in place (a full map respawn would reset scripted NPC
  -- positions mid-cutscene)
  local ow = ctx.overworld
  if not ow or ow.map.id ~= mapId then return end
  if visible then
    for _, n in ipairs(ow.npcs) do
      if n.def.name == objName then return end
    end
    for _, obj in ipairs(ow.map.def.objects) do
      if obj.name == objName then
        local NPC = require("src.world.NPC")
        local npc = NPC.new(ctx.game.data, mapId, obj)
        table.insert(ow.npcs, npc)
        table.insert(ow.entities, npc)
        return
      end
    end
  else
    for i = #ow.npcs, 1, -1 do
      if ow.npcs[i].def.name == objName then table.remove(ow.npcs, i) end
    end
    for i = #ow.entities, 1, -1 do
      local e = ow.entities[i]
      if e.def and e.def.name == objName then table.remove(ow.entities, i) end
    end
  end
end

function Commands.show_object(ctx, mapId, objName)
  toggleObject(ctx, mapId, objName, true)
end

function Commands.hide_object(ctx, mapId, objName)
  toggleObject(ctx, mapId, objName, false)
end

function Commands.play_sound(ctx, soundId)
  require("src.core.Sound").play(ctx.game.data, soundId)
end

-- play_cry <species>: PlayCry (home/audio.asm).  The text_asm bodies that
-- use it run text_far (a no-button-wait "...@" string) -> PlayCry ->
-- WaitForSoundToFinish, all within the same text ID -- the cry only starts
-- once the box has finished typing, and the box then auto-closes (no A
-- press) the instant the cry finishes, rather than firing immediately
-- alongside the typewriter effect. Script rows run strictly in order, so
-- this stashes the species on ctx for the show_text row that always
-- immediately follows it (Power Plant Zapdos, Seafoam Articuno, Victory
-- Road Moltres, Cerulean Cave Mewtwo battle text) to play once its box is
-- done typing (see show_text's opts.auto).  Headless-safe no-op there.
function Commands.play_cry(ctx, species)
  ctx.pendingCry = species
end

-- check_battle_result <r1> [r2 ...]: lastCheck = the last scripted
-- battle ended with any of the given results
-- ("win"|"lose"|"run"|"caught"), for branches like
-- Route12SnorlaxPostBattleScript's `ld a, [wBattleResult] / cp $2`.
function Commands.check_battle_result(ctx, ...)
  ctx.lastCheck = false
  for _, want in ipairs({ ... }) do
    if ctx.lastBattleResult == want then ctx.lastCheck = true end
  end
end

function Commands.heal_party(ctx)
  local Pokemon = require("src.pokemon.Pokemon")
  for _, mon in ipairs(ctx.save.party) do
    Pokemon.heal(mon)
  end
end

-- give_pokemon <species> <level>: _GivePokemon (engine/events/
-- give_pokemon.asm) -- party first, then the box.  ctx.lastCheck gets
-- the asm's carry: true when the mon was given, false when both the
-- party and every box are full (that .boxFull path leaves the giver's
-- script able to offer again later, e.g. the Celadon Eevee ball).
function Commands.give_pokemon(ctx, species, level)
  -- Native mods can transform a gift before the Pokémon object is created.
  -- This is intentionally an event rather than a special-case starter hook:
  -- mods can use the same seam for story gifts, fossils, or custom scripts.
  local gift = { ctx = ctx, species = species, level = level }
  if ctx.game.mods then
    ctx.game.mods.events:emit("pokemon.before_give", gift)
    species, level = gift.species, gift.level
  end
  local Pokemon = require("src.pokemon.Pokemon")
  local Party = require("src.pokemon.Party")
  local mon = Pokemon.new(ctx.game.data, species, level)
  if gift.nickname then mon.nickname = gift.nickname end
  ctx.game.stringBuffer = ctx.game.data.pokemon[species].name or species
  ctx.pendingPokemonName = species
  require("src.battle.BattleState").stampOT(ctx.save, mon)
  if not Party.add(ctx.save.party, mon) then
    if not require("src.pokemon.Boxes").deposit(ctx.save, mon) then
      ctx.lastCheck = false
      return
    end
  end
  local dex = ctx.save.pokedex
  if dex then
    dex.seen[species] = true
    dex.owned[species] = true
  end
  ctx.lastCheck = true
end

function Commands.give_money(ctx, amount)
  ctx.save.money = math.max(0, ctx.save.money + amount)
end

-- Hall of Fame: snapshot the winning party (SaveHallOfFameTeams inside
-- AnimateHallOfFame), run the induction showcase and the end credits,
-- autosave while THE END is up, then soft-reset to the title -- the whole
-- predef HallOfFamePC + tail of HallOfFameResetEventsAndSaveScript
-- (engine/movie/hall_of_fame.asm, engine/movie/credits.asm,
-- scripts/HallOfFame.asm).
function Commands.record_hall_of_fame(ctx)
  ctx.save.hallOfFame = ctx.save.hallOfFame or {}
  local entry = {}
  for _, mon in ipairs(ctx.save.party) do
    table.insert(entry, { species = mon.species, level = mon.level,
                          nickname = mon.nickname })
  end
  table.insert(ctx.save.hallOfFame, entry)
  local runner = ctx.runner
  local game = ctx.game
  local HallOfFame = require("src.ui.HallOfFame")
  local Credits = require("src.ui.Credits")
  game.stack:push(HallOfFame.new(game, function()
    -- the end credits roll after the induction (engine/movie/credits.asm)
    game.stack:push(Credits.new(game, function()
      runner:resume()
    end, function()
      -- THE END is on screen: HallOfFameResetEventsAndSaveScript sets
      -- wLastBlackoutMap := PALLET_TOWN and runs SaveGameData, so the
      -- save keeps the player standing in the HALL_OF_FAME room.  (The
      -- E4 room-script/event resets that precede the save in pokered are
      -- the Indigo lobby's re-entry reset here, data/scripts/story6.lua.)
      ctx.save.lastHeal = { map = "PALLET_TOWN", x = 5, y = 6 }
      if game.writeSave then game:writeSave() end
    end))
  end))
  runner:yield()
  -- after the A/B press on THE END the script does `jp Init`: a soft
  -- reset through the boot sequence -- copyright card + attract movie,
  -- then the title screen (the same path Game:load boots through)
  require("src.core.Music").stop()
  while game.stack:top() do game.stack:pop() end
  local okIntro, IntroMovie = pcall(require, "src.ui.IntroMovie")
  if okIntro and IntroMovie then
    game.stack:push(IntroMovie.new(game, function()
      if game.makeTitleState then game.stack:push(game:makeTitleState()) end
    end))
  elseif game.returnToTitle then
    game:returnToTitle()
  end
end

-- The Viridian old man's catch tutorial (scripts/ViridianCity.asm
-- BATTLE_TYPE_OLD_MAN): a demo wild battle where the old man throws
-- one POKé BALL; nothing is kept.
function Commands.old_man_demo(ctx)
  local BattleState = require("src.battle.BattleState")
  local runner = ctx.runner
  local om = ctx.game.data.field.oldManBattle or { species = "WEEDLE", level = 5 }
  local battle = BattleState.newWild(ctx.game, om.species, om.level)
  battle:makeOldManDemo()
  battle.onFinish = function() runner:resume() end
  ctx.game.stack:push(battle)
  runner:yield()
end

-- Static overworld encounters (Snorlax, the legendary birds, Mewtwo):
-- a wild battle; the object disappears unless the player loses
-- (blackout).  beatFlag, when given, is the EVENT_BEAT_* event set by
-- EndTrainerBattle (home/trainers.asm) on ANY non-blackout end -- win,
-- catch or flee alike -- which is why a fled legendary never returns.
function Commands.static_battle(ctx, species, level, beatFlag)
  Commands.start_battle(ctx, "wild", species, level)
  local result = ctx.lastBattleResult
  if result ~= "lose" then
    if beatFlag then Flags.set(ctx.save, beatFlag) end
    if ctx.npc and ctx.npc.def.name and ctx.overworld then
      toggleObject(ctx, ctx.overworld.map.id, ctx.npc.def.name, false)
    end
  end
end

-- Open a mart by TEXT constant (used by scripts that mix dialogue with
-- shopping, like the Viridian clerk's parcel handout).
function Commands.open_mart(ctx, textConst)
  local ow = ctx.overworld
  local entry = ctx.game.data:textEntry(ow.map.def.label, textConst)
  if not entry or not entry.mart then
    Logger.warn("open_mart: no mart on %s/%s", ow.map.def.label, tostring(textConst))
    return
  end
  local ShopMenu = require("src.ui.ShopMenu")
  local runner = ctx.runner
  ctx.game.stack:push(ShopMenu.new(ctx.game, entry.mart, function()
    runner:resume()
  end))
  runner:yield()
end

-- Rival battles pick the party from the player's starter choice
-- (parties are ordered by the rival's own starter; see parties.asm):
-- player CHARMANDER -> base+0, SQUIRTLE -> base+1, BULBASAUR -> base+2.
function Commands.rival_battle(ctx, oppClass, baseParty)
  local offset = 0
  if Flags.get(ctx.save, "EVENT_CHOSE_SQUIRTLE") then
    offset = 1
  elseif Flags.get(ctx.save, "EVENT_CHOSE_BULBASAUR") then
    offset = 2
  end
  Commands.start_battle(ctx, "trainer", oppClass, baseParty + offset)
end

-- In-game trades (engine/events/in_game_trades.asm DoInGameTradeDialogue;
-- table from data/events/trades.asm via field.trades).  The NPC wants
-- trades[index].give and hands over trades[index].get.  doneFlag is this
-- trade's wCompletedInGameTradeFlags bit under a port name (FLAG_TEST
-- before the offer -> after-trade text; FLAG_SET on completion), so each
-- trade happens exactly once.  Each trade's dialogset (1..3) picks the
-- _WannaTrade<N>/_NoTrade<N>/_WrongMon<N>/_Thanks<N>/_AfterTrade<N> text
-- family (TradeTextPointers1/2/3).
function Commands.trade(ctx, tradeIndex, doneFlag)
  local trade = ctx.game.data.field.trades[tradeIndex]
  if not trade then
    Logger.warn("trade: no trade %s", tostring(tradeIndex))
    return
  end
  local data = ctx.game.data
  local wantName = data.pokemon[trade.give] and data.pokemon[trade.give].name or trade.give
  local getName = data.pokemon[trade.get] and data.pokemon[trade.get].name or trade.get
  local dialogset = trade.dialogset or 1 -- older generated data: casual
  local subs = {
    ["RAM:wInGameTradeGiveMonName"] = wantName,
    ["RAM:wInGameTradeReceiveMonName"] = getName,
  }
  local function say(label)
    Commands.show_text(ctx, label, subs)
  end
  if doneFlag and Flags.get(ctx.save, doneFlag) then
    say("_AfterTrade" .. dialogset .. "Text")
    return
  end
  Commands.ask(ctx, "_WannaTrade" .. dialogset .. "Text", subs)
  if not ctx.lastCheck then
    say("_NoTrade" .. dialogset .. "Text")
    return
  end
  -- InGameTrade_DoTrade: DisplayPartyMenu -- the player picks which mon
  -- to hand over; backing out reuses the no-trade text, a mon of the
  -- wrong species gets the wrong-mon text
  local party = ctx.save.party
  local runner = ctx.runner
  local picked
  local PartyMenu = require("src.ui.PartyMenu")
  ctx.game.stack:push(PartyMenu.new(ctx.game, {
    pickOnly = true,
    onCancel = function() runner:resume() end,
    onSwitch = function(mon)
      picked = mon
      runner:resume()
    end,
  }))
  runner:yield()
  if not picked then
    say("_NoTrade" .. dialogset .. "Text")
    return
  end
  if picked.species ~= trade.give then
    say("_WrongMon" .. dialogset .. "Text")
    return
  end
  local slot
  for i, mon in ipairs(party) do
    if mon == picked then slot = i break end
  end
  if not slot then return end -- unreachable: picked came from the party
  if doneFlag then Flags.set(ctx.save, doneFlag) end
  say("_ConnectCableText")
  local Pokemon = require("src.pokemon.Pokemon")
  local sent = party[slot]
  -- the received mon keeps the sent mon's level (wCurEnemyLevel) and,
  -- like RemovePokemon + AddPartyMon, joins at the end of the party
  local newMon = Pokemon.new(data, trade.get, sent.level)
  newMon.nickname = trade.nickname
  newMon.traded = true -- boosted exp + Name Rater refusal (different OT)
  table.remove(party, slot)
  table.insert(party, newMon)
  local dex = ctx.save.pokedex
  if dex then
    dex.seen[trade.get] = true
    dex.owned[trade.get] = true
  end
  -- the trade machine animation (engine/movie/trade.asm)
  local TradeAnim = require("src.ui.TradeAnim")
  ctx.game.stack:push(TradeAnim.new(ctx.game, {
    sent = sent, received = newMon,
    onDone = function() runner:resume() end,
  }))
  runner:yield()
  -- TradedForText (sound_get_key_item) then the dialogset's thanks
  require("src.core.Sound").play(data, "Get_Key_Item")
  say("_TradedForText")
  say("_Thanks" .. dialogset .. "Text")
end

return Commands
