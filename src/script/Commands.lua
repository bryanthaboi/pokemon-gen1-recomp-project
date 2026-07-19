-- Script command implementations.  Each receives the script context.
-- Blocking commands yield the script coroutine and resume when the UI or
-- world event completes.
--
-- Conditionals: check_flag stores its result in ctx.lastCheck;
-- jump_if_true/jump_if_false jump to an absolute row index.

local Flags = require("src.script.Flags")
local Logger = require("src.core.Logger")
local Screens = require("src.ui.Screens")
local TextBox = require("src.render.TextBox")

local Commands = {}

-- "mod:" keys route to save.modData[owner], the mod-private namespace
-- (09 §4.8); owner comes from the dispatching contribution's source
-- attribution, so an engine-owned script using one is a script error
local function modFieldOwner(ctx)
  local owner = ctx.source and ctx.source.modId
  if not owner then
    error("'mod:' fields need a mod-owned script", 0)
  end
  return owner
end

local function flagValue(ctx, name)
  local rest = type(name) == "string" and name:match("^mod:(.+)$")
  if rest then
    local modData = ctx.save.modData
    local bucket = modData and modData[modFieldOwner(ctx)]
    return (bucket and bucket[rest]) and true or false
  end
  return Flags.get(ctx.save, name)
end

-- Parallel-runner move locks (09 §4.6): a background script moving an
-- NPC takes a per-NPC lock; a foreground script requesting the same NPC
-- preempts (kills) the background runner.  The player is never movable
-- from a parallel runner.
local function claimMove(ctx, entity)
  local ow = ctx.overworld
  if not ow then return end
  if ctx.runner.parallel then
    if entity == ow.player then
      error("parallel scripts cannot move the player", 0)
    end
    ow.npcMoveLocks = ow.npcMoveLocks or {}
    ow.npcMoveLocks[entity] = ctx.runner
  else
    local holder = ow.npcMoveLocks and ow.npcMoveLocks[entity]
    if holder and holder ~= ctx.runner and ow.killParallel then
      Logger.warn("script: foreground move preempts a parallel runner")
      ow:killParallel(holder)
      -- the dead runner's queued steps go too; the foreground move owns
      -- the entity now
      for i = #ow.scriptMoves, 1, -1 do
        if ow.scriptMoves[i].entity == entity then
          table.remove(ow.scriptMoves, i)
        end
      end
    end
  end
end

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
  -- text_opts armed the next box: auto = true is the plain no-button-wait
  -- form, overlap folds under auto, everything else passes through
  if ctx.textOpts then
    local armed = ctx.textOpts
    ctx.textOpts = nil
    opts = opts or {}
    for k, v in pairs(armed) do
      if k == "auto" then
        opts.auto = opts.auto or (v == true and {} or v)
      elseif k == "overlap" then
        opts.auto = opts.auto or {}
        opts.auto.overlap = v
      else
        opts[k] = v
      end
    end
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
  ctx.lastCheck = flagValue(ctx, name)
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
    Commands.show_text(ctx, ctx.game.data.text
      and ctx.game.data.text._BagFullText or "You can't carry\nany more items!")
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
  claimMove(ctx, entity)
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
-- "mod:key" routes to the owning mod's save.modData namespace instead of
-- the save root, so mod state stays attributable.
function Commands.set_field(ctx, key, value)
  local rest = type(key) == "string" and key:match("^mod:(.+)$")
  if rest then
    local owner = modFieldOwner(ctx)
    local modData = ctx.save.modData
    if not modData then
      modData = {}
      ctx.save.modData = modData
    end
    local bucket = modData[owner]
    if not bucket then
      bucket = {}
      modData[owner] = bucket
    end
    bucket[rest] = value
    return
  end
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
  Screens.push(game, "HallOfFame", function()
    -- the end credits roll after the induction (engine/movie/credits.asm)
    Screens.push(game, "Credits", function()
      runner:resume()
    end, function()
      -- THE END is on screen: HallOfFameResetEventsAndSaveScript sets
      -- wLastBlackoutMap := PALLET_TOWN and runs SaveGameData, so the
      -- save keeps the player standing in the HALL_OF_FAME room.  (The
      -- E4 room-script/event resets that precede the save in pokered are
      -- the Indigo lobby's re-entry reset here, data/scripts/story6.lua.)
      -- The reset heal point is field.boot's spawn, PALLET_TOWN (5,6)
      -- in the vanilla dataset.
      local boot = game.data.field and game.data.field.boot or {}
      ctx.save.lastHeal = { map = boot.startMap or "PALLET_TOWN",
                            x = boot.startX or 5, y = boot.startY or 6 }
      if game.writeSave then game:writeSave() end
    end)
  end)
  runner:yield()
  -- after the A/B press on THE END the script does `jp Init`: a soft
  -- reset through the boot sequence -- copyright card + attract movie,
  -- then the title screen (the same path Game:load boots through)
  require("src.core.Music").stop()
  while game.stack:top() do game.stack:pop() end
  local okIntro = pcall(Screens.push, game, "IntroMovie", function()
    if game.makeTitleState then game.stack:push(game:makeTitleState()) end
  end)
  if not okIntro and game.returnToTitle then
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
  local runner = ctx.runner
  Screens.push(ctx.game, "ShopMenu", entry.mart, function()
    runner:resume()
  end)
  runner:yield()
end

-- Rival battles pick the party from the player's starter choice
-- (parties are ordered by the rival's own starter; see parties.asm):
-- player CHARMANDER -> base+0, SQUIRTLE -> base+1, BULBASAUR -> base+2.
-- offsets (flag -> party offset) lets a modded roster remap the pick;
-- field.starterCounterpicks is the data-side default when stamped.
function Commands.rival_battle(ctx, oppClass, baseParty, offsets)
  offsets = offsets
    or (ctx.game.data.field and ctx.game.data.field.starterCounterpicks)
  local offset = 0
  if offsets then
    for flag, mapped in pairs(offsets) do
      if Flags.get(ctx.save, flag) then offset = mapped break end
    end
  elseif Flags.get(ctx.save, "EVENT_CHOSE_SQUIRTLE") then
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
  -- a trade record may carry explicit text-label overrides (texts.wannaTrade
  -- and friends); the dialogset families stay the defaults
  local texts = trade.texts or {}
  local subs = {
    ["RAM:wInGameTradeGiveMonName"] = wantName,
    ["RAM:wInGameTradeReceiveMonName"] = getName,
  }
  local function say(label)
    Commands.show_text(ctx, label, subs)
  end
  if doneFlag and Flags.get(ctx.save, doneFlag) then
    say(texts.afterTrade or "_AfterTrade" .. dialogset .. "Text")
    return
  end
  Commands.ask(ctx, texts.wannaTrade or "_WannaTrade" .. dialogset .. "Text", subs)
  if not ctx.lastCheck then
    say(texts.noTrade or "_NoTrade" .. dialogset .. "Text")
    return
  end
  -- InGameTrade_DoTrade: DisplayPartyMenu -- the player picks which mon
  -- to hand over; backing out reuses the no-trade text, a mon of the
  -- wrong species gets the wrong-mon text
  local party = ctx.save.party
  local runner = ctx.runner
  local picked
  Screens.push(ctx.game, "PartyMenu", {
    pickOnly = true,
    onCancel = function() runner:resume() end,
    onSwitch = function(mon)
      picked = mon
      runner:resume()
    end,
  })
  runner:yield()
  if not picked then
    say(texts.noTrade or "_NoTrade" .. dialogset .. "Text")
    return
  end
  if picked.species ~= trade.give then
    say(texts.wrongMon or "_WrongMon" .. dialogset .. "Text")
    return
  end
  local slot
  for i, mon in ipairs(party) do
    if mon == picked then slot = i break end
  end
  if not slot then return end -- unreachable: picked came from the party
  if doneFlag then Flags.set(ctx.save, doneFlag) end
  say(texts.connectCable or "_ConnectCableText")
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
  Screens.push(ctx.game, "TradeAnim", {
    sent = sent, received = newMon,
    onDone = function() runner:resume() end,
  })
  runner:yield()
  -- TradedForText (sound_get_key_item) then the dialogset's thanks
  require("src.core.Sound").play(data, "Get_Key_Item")
  say(texts.tradedFor or "_TradedForText")
  say(texts.thanks or "_Thanks" .. dialogset .. "Text")
end

-- ------- script v2 verbs: the promoted raw-Lua cutscene vocabulary

-- label <name>: jump target, pre-scanned by the runner; no-op here
function Commands.label() end

-- emote <target> <bubble> [frames]: the emotion-bubble hold
-- (engine/overworld/emotion_bubbles.asm).  target is "player", an object
-- index, or nil for the talking NPC; bubble names index
-- data.field.emotionBubbles.bubbles; blocks frames (default 60, the
-- trainer-sight hold).
local EMOTE_BUBBLES = { shock = 1, question = 2, happy = 3 }

function Commands.emote(ctx, target, bubble, frames)
  local ow = ctx.overworld
  if not ow then return end
  local entity
  if target == "player" then
    entity = ow.player
  elseif type(target) == "number" then
    entity = ow:npcByIndex(target)
  else
    entity = ctx.npc
  end
  if not entity then return end
  local runner = ctx.runner
  ow.emote = {
    npc = entity, frames = frames or 60,
    bubble = EMOTE_BUBBLES[bubble] or (type(bubble) == "number" and bubble) or 1,
    onDone = function() runner:resume() end,
  }
  runner:yield()
end

-- walk_npc <objIndex|"player"> <dirs> [opts]: chained scriptMove along an
-- explicit direction list; opts.wait = false returns immediately with
-- the movement still running
function Commands.walk_npc(ctx, objIndex, dirs, opts)
  local ow = ctx.overworld
  if not ow then return end
  local entity = objIndex == "player" and ow.player or ow:npcByIndex(objIndex)
  if not entity then return end
  claimMove(ctx, entity)
  local runner = ctx.runner
  local wait = not (opts and opts.wait == false)
  local yielded, finished = false, false
  local i = 0
  local function step()
    i = i + 1
    if not dirs[i] then
      finished = true
      if wait and yielded then runner:resume() end
      return
    end
    ow:scriptMove(entity, dirs[i], 1, step)
  end
  step()
  if wait and not finished then
    yielded = true
    runner:yield()
  end
end

-- march_in_place <objIndex> <on>: toggle the walk-in-place state
-- (NPC_CHANGE_FACING, movement.asm); the overworld re-arms the cycle
-- while the toggle stays set.  Non-blocking, so ambient parallel
-- scripts can leave an NPC fidgeting.
function Commands.march_in_place(ctx, objIndex, on)
  local ow = ctx.overworld
  if not ow then return end
  local npc = ow:npcByIndex(objIndex)
  if not npc then return end
  ow.marchers = ow.marchers or {}
  ow.marchers[npc] = on and true or nil
end

-- play_music <songId> [opts]: switch map music now; opts.keep marks it
-- to survive the next warp (the story files' keepMusic idiom)
function Commands.play_music(ctx, songId, opts)
  require("src.core.Music").play(ctx.game.data, songId)
  if opts and opts.keep and ctx.overworld then
    ctx.overworld.keepMusicOnce = true
  end
end

function Commands.stop_music(ctx)
  require("src.core.Music").stop()
end

-- replace_block <bx> <by> <blockId>: the Cut-tree/card-key-door idiom,
-- on the current map
function Commands.replace_block(ctx, bx, by, blockId)
  if ctx.overworld then ctx.overworld:replaceBlock(bx, by, blockId) end
end

-- set_tile_anim <anim|false>: override the current tileset's animation
-- ("TILEANIM_WATER"; false stops it) until the next map change restores
-- the record (setMap)
function Commands.set_tile_anim(ctx, anim)
  local ow = ctx.overworld
  if not ow then return end
  local tileset = ow.map.tileset
  if not ow.tileAnimOverride then
    ow.tileAnimOverride = { tileset = tileset, animation = tileset.animation }
  end
  tileset.animation = anim or nil
  if ow.map.renderer then ow.map.renderer:rebuild() end
end

-- text_opts <opts>: TextBox options for the NEXT show_text only; auto =
-- true is the plain no-button-wait box, overlap folds under auto
function Commands.text_opts(ctx, opts)
  ctx.textOpts = opts
end

-- push_screen <screenId> [args]: instantiate through the screens
-- registry and block until the screen pops itself
function Commands.push_screen(ctx, screenId, args)
  local screens = ctx.game.data.screens
  if not (screens and screens[screenId]) then
    error(("push_screen: unknown screen '%s'"):format(tostring(screenId)), 0)
  end
  local runner = ctx.runner
  local stack = ctx.game.stack
  local state = Screens.push(ctx.game, screenId, args)
  runner.waitingCheck = function()
    for _, live in ipairs(stack.states) do
      if live == state then return false end
    end
    return true
  end
  runner:yield()
end

-- fade "out"|"in" [frames]: screen fade without warping (the Transition
-- ramp startWarpTo uses, split in two).  "out" pushes a black overlay
-- that stays up; the held state keeps ticking the runner's frame-waits
-- so a script can wait/replace_block under it.  "in" ramps it away.
local FadeOverlay = {}
FadeOverlay.__index = FadeOverlay

function FadeOverlay.new(game, ow)
  return setmetatable({ game = game, ow = ow, alpha = 0 }, FadeOverlay)
end

function FadeOverlay:update()
  local ow = self.ow
  if ow and ow.runner then ow.runner:update() end
  local ramp = self.ramp
  if not ramp then return end
  ramp.t = ramp.t + 1
  local k = math.min(1, ramp.t / ramp.frames)
  self.alpha = ramp.from + (ramp.to - ramp.from) * k
  if ramp.t >= ramp.frames then
    self.ramp = nil
    if ramp.to <= 0 then
      -- a box may sit above the overlay; remove in place, not pop
      local states = self.game.stack.states
      for i = #states, 1, -1 do
        if states[i] == self then table.remove(states, i) break end
      end
      if ow then ow.fadeOverlay = nil end
    end
    if ramp.onDone then ramp.onDone() end
  end
end

function FadeOverlay:draw()
  love.graphics.setColor(0, 0, 0, self.alpha)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  love.graphics.setColor(1, 1, 1, 1)
end

function Commands.fade(ctx, dir, frames)
  local ow = ctx.overworld
  if not ow then return end
  local runner = ctx.runner
  frames = frames or 12 -- Transition's ramp length
  local overlay = ow.fadeOverlay
  if dir == "out" then
    if not overlay then
      overlay = FadeOverlay.new(ctx.game, ow)
      ow.fadeOverlay = overlay
      ctx.game.stack:push(overlay)
    end
    overlay.ramp = { from = overlay.alpha, to = 1, frames = frames, t = 0,
                     onDone = function() runner:resume() end }
    runner:yield()
  elseif dir == "in" then
    if not overlay then return end
    overlay.ramp = { from = overlay.alpha, to = 0, frames = frames, t = 0,
                     onDone = function() runner:resume() end }
    runner:yield()
  end
end

-- pan_camera <dx> <dy> <frames> | "reset": offset the world camera by
-- cells over frames (blocking); "reset" snaps back to player-centered
function Commands.pan_camera(ctx, dx, dy, frames)
  local ow = ctx.overworld
  if not ow then return end
  if dx == "reset" then
    ow.cameraPan = nil
    return
  end
  local runner = ctx.runner
  local pan = ow.cameraPan or { ox = 0, oy = 0 }
  ow.cameraPan = pan
  pan.fromX, pan.fromY = pan.ox, pan.oy
  pan.toX, pan.toY = pan.ox + dx * 16, pan.oy + dy * 16
  pan.frames, pan.t = math.max(1, frames or 30), 0
  pan.onDone = function() runner:resume() end
  runner:yield()
end

-- wait_flag <flagName> [timeoutFrames]: yield until the flag is set,
-- re-checked once per frame; lastCheck = true on the flag, false on
-- timeout.  The synchronization primitive for parallel scripts.
function Commands.wait_flag(ctx, flagName, timeoutFrames)
  local runner = ctx.runner
  local remaining = timeoutFrames
  runner.waitingCheck = function()
    if flagValue(ctx, flagName) then return true, true end
    if remaining then
      remaining = remaining - 1
      if remaining <= 0 then return true, false end
    end
    return false
  end
  ctx.lastCheck = runner:yield()
end

-- run_parallel <rowsOrRef> [opts]: start a background script in one of
-- the bounded slots and continue immediately.  rowsOrRef is a row array
-- or "MAP_ID/name" naming a map_scripts `scripts` entry.
function Commands.run_parallel(ctx, rowsOrRef, opts)
  local ow = ctx.overworld
  if not ow or not ow.startParallel then return end
  ow:startParallel(rowsOrRef, { source = ctx.source })
end

-- choice <labels> [opts]: N-way menu (src/ui/Menu); lastChoice =
-- { index, label }, lastCheck = (index == 1).  opts.default preselects,
-- opts.cancel is the index B maps to (default: last).
function Commands.choice(ctx, labels, opts)
  local Menu = require("src.ui.Menu")
  local runner = ctx.runner
  local function pick(index)
    ctx.lastChoice = { index = index, label = labels[index] }
    ctx.lastCheck = index == 1
    runner:resume()
  end
  local items = {}
  for i, label in ipairs(labels) do
    items[i] = { label = label, onSelect = function() pick(i) end }
  end
  local menu = Menu.new(ctx.game, items, {
    onCancel = function() pick((opts and opts.cancel) or #labels) end,
  })
  if opts and opts.default then menu.index = opts.default end
  ctx.game.stack:push(menu)
  runner:yield()
end

-- ------- registry plumbing

-- foreground commands push UI states or lock input and are illegal in
-- parallel scripts; blocking commands may yield the coroutine
Commands.meta = {}
for _, verb in ipairs({ "show_text", "ask", "choice", "start_battle", "warp",
    "open_mart", "trade", "push_screen", "record_hall_of_fame",
    "old_man_demo", "static_battle", "rival_battle", "give_item",
    "give_pokemon", "fade", "pan_camera" }) do
  Commands.meta[verb] = { foreground = true }
end
for _, verb in ipairs({ "show_text", "ask", "choice", "start_battle", "warp",
    "open_mart", "trade", "push_screen", "record_hall_of_fame",
    "old_man_demo", "static_battle", "rival_battle", "give_item", "wait",
    "wait_flag", "move_player", "move_npc", "move_npc_to", "walk_npc",
    "emote", "fade", "pan_camera" }) do
  local meta = Commands.meta[verb] or {}
  Commands.meta[verb] = meta
  meta.blocking = true
end

-- module functions that are not script verbs
local NOT_VERBS = { registerInto = true, resolve = true }

-- what the engine handed the registry, so resolve can tell a mod's
-- override from the untouched self-registration
local registered = {}

-- Dispatch resolution: a merged record a mod changed or added
-- (Data.commands differing from the engine snapshot) wins; otherwise the
-- live module table stays the dispatch target -- the D6 "merge into the
-- live Commands table" contract, which also keeps test doubles honest.
-- A record is the bare handler (the whole vanilla set) or { fn = ...,
-- foreground = ..., blocking = ... }.
function Commands.resolve(data, name)
  if NOT_VERBS[name] then return nil end
  local record = data and data.commands and data.commands[name]
  if record == nil or record == registered[name] then
    record = Commands[name]
  end
  if type(record) == "table" then return record.fn, record end
  if type(record) ~= "function" then return nil end
  return record, Commands.meta[name]
end

-- every verb in this module is the registry's built-in set; a mod adding a
-- verb registers, a mod replacing one has to say override
function Commands.registerInto(registry, _, owner)
  for verb, fn in pairs(Commands) do
    if type(fn) == "function" and not NOT_VERBS[verb] then
      registry:register(verb, fn, owner)
      registered[verb] = fn
    end
  end
end

return Commands
