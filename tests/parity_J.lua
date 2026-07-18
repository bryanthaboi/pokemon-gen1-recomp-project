-- Parity test,  Workstream J.
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end
local fails, total = 0, 0
local function check(c, m) total = total + 1; if c then print("ok   " .. m) else fails = fails + 1; print("FAIL " .. m) end end
local function eq(g, w, m) check(g == w, ("%s (got %s, want %s)"):format(m, tostring(g), tostring(w))) end

-- === assertions per your spec test plan ===

local Game = require("src.core.Game")
Game.data = Data
Game.save = require("src.core.SaveData").newGame()
local Font = require("src.render.Font")
if not pcall(Font.encode, "A") then Font.load(Data) end
local Pokemon = require("src.pokemon.Pokemon")
local BattleState = require("src.battle.BattleState")
local MoveEffects = require("src.battle.MoveEffects")

local function freshBattle()
  Game.save.party = { Pokemon.new(Data, "BULBASAUR", 20) }
  local tb = BattleState.newWild(Game, "PIDGEY", 10)
  return tb
end

-- scripted rng: pops the given values, then always returns the max roll
local function mkseq(vals)
  local i = 0
  return function(a, b)
    i = i + 1
    return vals[i] ~= nil and vals[i] or b
  end
end

-- (1) TRANSFORM: user.sprite morphs into the target species pic AND the
-- target's stat stages are copied (not cleared).  transform.asm:31-53
-- (AnimationTransformMon) + :57-132 (copies wEnemyMonStatMods).
do
  local tb = freshBattle()
  local preSprite = tb.player.sprite
  tb.enemy.stages.attack = 2
  tb.enemy.stages.speed = -1
  MoveEffects.primary.TRANSFORM_EFFECT(tb, tb.player, tb.enemy)
  check(tb.player.sprite ~= preSprite, "transform swaps the user's sprite")
  eq(tb.player.sprite.path, Data.pokemon.PIDGEY.spriteBack,
     "player-side transform uses the target species BACK pic")
  eq(tb.player.stages.attack, 2, "transform copies target's +attack stage")
  eq(tb.player.stages.speed, -1, "transform copies target's -speed stage")
  -- deep copy: later changes to the target must not bleed into the user
  tb.enemy.stages.attack = 5
  eq(tb.player.stages.attack, 2, "transform stages are a deep copy")
  -- enemy-side transform uses the FRONT pic
  local tb2 = freshBattle()
  MoveEffects.primary.TRANSFORM_EFFECT(tb2, tb2.enemy, tb2.player)
  eq(tb2.enemy.sprite.path, Data.pokemon.BULBASAUR.spriteFront,
     "enemy-side transform uses the target species FRONT pic")
end

-- (2) TRAPPING: continueTrapping replays the trapping move's per-turn
-- animation (core.asm:3554-3566 -> GetPlayerAnimationType).
do
  local tb = freshBattle()
  -- performMove WRAP rng: accuracy, crit, damage-random, trapping counter
  tb.rng = mkseq({ 0, 255, 255, 0 })
  tb:performMove(tb.player, tb.enemy, { id = "WRAP", pp = 10 })
  eq(tb.player.trapMove, "WRAP", "the trapping move id is stored on the user")
  -- keep the victim alive so the continuation stays clean
  tb.enemy.mon.stats.hp = 999
  tb.enemy.mon.hp = 999
  tb.queue = {}
  tb.nextInsert = 0
  tb:continueTrapping(tb.player, tb.enemy)
  local animRow
  for _, row in ipairs(tb.queue) do
    if row.anim == "WRAP" then animRow = row end
  end
  check(animRow ~= nil, "continueTrapping queues an anim row for the trap move")
  check(animRow and animRow.attackerIsPlayer == true,
        "the queued trap anim row is attributed to the attacker")
end

-- (3) MIMIC runs MID-move (MimicEffect, effects.asm:1203-1273): the
-- move executes, MoveHitTest runs, and only on a hit does the player's
-- copy menu open (.letPlayerChooseMove) -- the enemy's Mimic and link
-- battles roll a random slot (.getRandomMove).  The copied move
-- overwrites the used slot's ID in place (the PP byte is untouched,
-- :1261-1266) and the id snaps back when the battler leaves play.
local function queueScan(tb)
  local found = { texts = {} }
  for _, row in ipairs(tb.queue) do
    if row.mimicSelect then found.chooser = row.mimicSelect end
    if row.anim == "MIMIC" then found.anim = true end
    if row.text then table.insert(found.texts, row.text) end
  end
  return found
end
local function hasText(found, pat)
  for _, t in ipairs(found.texts) do if t:find(pat) then return true end end
  return false
end
do
  -- player Mimic HIT: the chooser row is queued only after the hit test
  local tb = freshBattle()
  tb.kind = "wild"
  tb.player.curMoves[1] = { id = "MIMIC", pp = 10 } -- aliases mon.moves
  tb.enemy.curMoves = { { id = "GUST", pp = 35 }, { id = "SAND_ATTACK", pp = 15 } }
  tb.rng = function(a, b) return a end -- accuracy roll 0: hit
  tb.queue, tb.nextInsert = {}, 0
  tb:performMove(tb.player, tb.enemy, tb.player.curMoves[1])
  local found = queueScan(tb)
  check(found.chooser ~= nil, "player Mimic hit queues the mid-move chooser row")
  check(not found.anim, "no Mimic animation before the copy is picked")
  eq(tb.player.curMoves[1].id, "MIMIC", "the slot is untouched until the pick")
  -- apply the pick like the mimicSelect A-handler does
  tb.nextInsert = 0
  tb:applyMimic(found.chooser.user, found.chooser.target, found.chooser.moveInst, 2)
  eq(tb.player.curMoves[1].id, "SAND_ATTACK",
     "the pick overwrites Mimic's slot id (slot 2 copied)")
  eq(tb.player.curMoves[1].pp, 9,
     "the copy inherits Mimic's remaining PP (only the move id byte is written)")
  eq(tb.player.mon.moves[1].id, "SAND_ATTACK",
     "the battle slot aliases the party slot (DecrementPP hits both)")
  check(tb.player.curMoves[1].mimic == true, "the copied slot is flagged mimic")
  found = queueScan(tb)
  check(found.anim, "the Mimic animation plays after the copy")
  check(hasText(found, "learned"), "the 'learned MOVE!' text follows")
  -- the id snaps back when the battler leaves play; spent PP stays spent
  tb:restoreMimicked(tb.player)
  eq(tb.player.mon.moves[1].id, "MIMIC", "leaving play restores the party move id")
  eq(tb.player.mon.moves[1].pp, 9, "spent PP stays spent after the restore")

  -- player Mimic MISS: "But, it failed!", no chooser, no animation
  local tbm = freshBattle()
  tbm.kind = "wild"
  tbm.player.curMoves[1] = { id = "MIMIC", pp = 10 }
  tbm.enemy.curMoves = { { id = "GUST", pp = 35 } }
  tbm.rng = function(a, b) return b end -- accuracy roll 255: miss
  tbm.queue, tbm.nextInsert = {}, 0
  tbm:performMove(tbm.player, tbm.enemy, tbm.player.curMoves[1])
  local fm = queueScan(tbm)
  check(fm.chooser == nil, "a missed Mimic never opens the chooser")
  check(not fm.anim, "a missed Mimic plays no animation")
  check(hasText(fm, "But, it failed!"),
        "a missed Mimic prints PrintButItFailedText_")
  eq(tbm.player.curMoves[1].id, "MIMIC", "a missed Mimic copies nothing")

  -- a mid-Fly/Dig target also fails (.mimicMissed via INVULNERABLE)
  local tbi = freshBattle()
  tbi.kind = "wild"
  tbi.player.curMoves[1] = { id = "MIMIC", pp = 10 }
  tbi.enemy.curMoves = { { id = "GUST", pp = 35 } }
  tbi.enemy.invulnerable = true
  tbi.rng = function(a, b) return a end
  tbi.queue, tbi.nextInsert = {}, 0
  tbi:performMove(tbi.player, tbi.enemy, tbi.player.curMoves[1])
  local fi = queueScan(tbi)
  check(fi.chooser == nil and hasText(fi, "But, it failed!"),
        "Mimic fails outright against a mid-Fly/Dig target")

  -- enemy Mimic: random slot of the player, no menu (.getRandomMove)
  local tbe = freshBattle()
  tbe.kind = "wild"
  tbe.player.curMoves = { { id = "GUST", pp = 35 }, { id = "SAND_ATTACK", pp = 15 } }
  tbe.enemy.curMoves[1] = { id = "MIMIC", pp = 10 }
  tbe.rng = mkseq({ 0, 2 }) -- accuracy hit, then random slot 2
  tbe.queue, tbe.nextInsert = {}, 0
  tbe:performMove(tbe.enemy, tbe.player, tbe.enemy.curMoves[1])
  local fe = queueScan(tbe)
  check(fe.chooser == nil, "enemy Mimic never opens a chooser")
  eq(tbe.enemy.curMoves[1].id, "SAND_ATTACK",
     "enemy Mimic copies a random player move immediately")
  eq(tbe.enemy.curMoves[1].pp, 9, "enemy Mimic also keeps the slot's PP")
  check(fe.anim and hasText(fe, "learned"),
        "enemy Mimic still plays the animation and learned text")

  -- link battle: the player's Mimic rolls random too (no chooser)
  local tbl = freshBattle()
  tbl.kind = "link"
  tbl.player.curMoves[1] = { id = "MIMIC", pp = 10 }
  tbl.enemy.curMoves = { { id = "GUST", pp = 35 }, { id = "SAND_ATTACK", pp = 15 } }
  tbl.rng = mkseq({ 0, 1 }) -- accuracy hit, random slot 1
  tbl.queue, tbl.nextInsert = {}, 0
  tbl:performMove(tbl.player, tbl.enemy, tbl.player.curMoves[1])
  local fl = queueScan(tbl)
  check(fl.chooser == nil, "link Mimic skips the interactive chooser")
  eq(tbl.player.curMoves[1].id, "GUST", "link Mimic rolls random (slot 1)")
  tbl:restoreMimicked(tbl.player)

  -- the test-injection hook still short-circuits the player's menu
  local tbh = freshBattle()
  tbh.kind = "wild"
  tbh.player.curMoves[1] = { id = "MIMIC", pp = 10 }
  tbh.enemy.curMoves = { { id = "GUST", pp = 35 }, { id = "SAND_ATTACK", pp = 15 } }
  tbh.mimicChoice = function(self, target) return 2 end
  tbh.rng = function(a, b) return a end
  tbh.queue, tbh.nextInsert = {}, 0
  tbh:performMove(tbh.player, tbh.enemy, tbh.player.curMoves[1])
  eq(tbh.player.curMoves[1].id, "SAND_ATTACK",
     "the mimicChoice hook applies the pick without a chooser row")
end

-- (3b) MIMIC chooser wiring through the queue: the mimicSelect row
-- flips the phase when it reaches the queue head, and the A-press
-- applies the highlighted slot (B never cancels: MoveSelectionMenu's
-- mimic menu watches only UP/DOWN/A, core.asm:2553-2557).
do
  local pressed = {}
  local tb = freshBattle()
  tb.game = { input = { wasPressed = function(_, k) return pressed[k] or false end },
              stack = { top = function() return tb end },
              save = Game.save }
  tb.kind = "wild"
  tb.player.curMoves[1] = { id = "MIMIC", pp = 10 }
  tb.enemy.curMoves = { { id = "GUST", pp = 35 }, { id = "SAND_ATTACK", pp = 15 } }
  tb.rng = function(a, b) return a end
  tb.queue, tb.nextInsert = {}, 0
  tb.phase = "messages"
  tb.afterQueue = "menu"
  tb:performMove(tb.player, tb.enemy, tb.player.curMoves[1])
  -- drain the queue past the announcement + 50-frame beat
  for _ = 1, 400 do
    if tb.phase ~= "messages" then break end
    pressed.a = true
    tb:updateQueue()
    if tb.current then tb.current = nil end -- fast-forward text rows
  end
  pressed.a = false
  eq(tb.phase, "mimicSelect", "the queued chooser row enters the mimicSelect phase")
  eq(#tb.mimicMoves, 2, "the chooser lists the enemy's moves")
  eq(tb.mimicIndex, 1, "the cursor starts on the first move")
  -- B does nothing (no cancel path in the mimic menu)
  pressed.b = true
  tb:update(1 / 60)
  pressed.b = false
  eq(tb.phase, "mimicSelect", "B does not leave the mimic menu")
  -- DOWN then A copies slot 2
  pressed.down = true
  tb:update(1 / 60)
  pressed.down = false
  eq(tb.mimicIndex, 2, "DOWN moves the chooser cursor")
  pressed.a = true
  tb:update(1 / 60)
  pressed.a = false
  eq(tb.phase, "messages", "A returns to the message queue")
  eq(tb.player.curMoves[1].id, "SAND_ATTACK", "A applies the highlighted slot")
  tb:restoreMimicked(tb.player)
end

-- (4) BIDE (regression): Gen 1 never rolls accuracy on release, so the
-- stored energy unleashes as bideDamage*2 even when an accuracy roll
-- would have missed (effects.asm:764-789 + core.asm:3481-3529).
do
  local tb = freshBattle()
  tb.enemy.mon.stats.hp = 200
  tb.enemy.mon.hp = 200
  local rngCalls = 0
  tb.rng = function(a, b) rngCalls = rngCalls + 1; return b end -- 255 -> would miss
  tb.player.bideTurns = 1
  tb.player.bideDamage = 50
  tb:continueBide(tb.player, tb.enemy)
  eq(tb.player.bideTurns, nil, "Bide releases on schedule")
  eq(tb.enemy.mon.hp, 100, "Bide release deals bideDamage*2 (2*50)")
  eq(rngCalls, 0, "Bide release consumes no rng for an accuracy check")
end

-- (5) OLD MAN catch tutorial (DisplayBattleMenu's old-man branch,
-- core.asm:2018-2050 + BagWasSelected:2193-2210 + ItemUseBall's
-- BATTLE_TYPE_OLD_MAN forks): no input is read at the battle menu --
-- the cursor hovers FIGHT for 80 frames, hops to ITEM for 50, and the
-- item menu (one POKé BALL x50) is forced.  The item list is scripted
-- too (DisplayListMenuID's old-man branch, home/list_menu.asm:65-80):
-- input is never read, the '▶' hovers POKé BALL for 80 frames, then the
-- auto A-press leaves the hollow '▷' on the row and the ball is used.
-- The old man NEVER attacks; the throw skips the catch calc entirely
-- ($43 = always caught) and the Weedle is not kept.
do
  local pressed = {}
  local stack = { states = {} }
  function stack:push(s) table.insert(self.states, s) end
  function stack:pop() return table.remove(self.states) end
  function stack:top() return self.states[#self.states] end
  local fg = {
    data = Data,
    save = require("src.core.SaveData").newGame(),
    input = { wasPressed = function(_, k) return pressed[k] or false end },
    stack = stack,
  }
  fg.save.party = { Pokemon.new(Data, "BULBASAUR", 20) }
  local seen = {}
  local demo = BattleState.newWild(fg, "WEEDLE", 5)
  demo:makeOldManDemo()
  local finished = false
  demo.onFinish = function() finished = true end
  local origStart = demo.startMessage
  demo.startMessage = function(self, item)
    table.insert(seen, item.text)
    origStart(self, item)
  end
  stack:push(demo)
  demo:enter()
  check(demo.playerBackPic == nil or tostring(demo.playerBackPic.path or ""):find("oldman") ~= nil
        or demo.demo, "the demo uses the old man back pic slot") -- headless: pic may be nil
  -- intro text auto-advances on A
  for _ = 1, 300 do
    if demo.phase == "menu" then break end
    pressed.a = true
    demo:update(1 / 60)
  end
  pressed.a = false
  eq(demo.phase, "menu", "the demo reaches the battle menu")
  -- the scripted cursor ignores input and holds the menu for 130 frames
  local frames = 0
  for _ = 1, 200 do
    if stack:top() ~= demo then break end
    pressed.a = true -- must be ignored: the old man script reads no input
    if demo.phase == "menu" then frames = frames + 1 end
    demo:update(1 / 60)
  end
  pressed.a = false
  check(stack:top() ~= demo, "the ITEM menu is forced without input")
  eq(frames, 131, "FIGHT hover (80) + ITEM hover (50) frames before the bag")
  local bag = stack:top()
  eq(bag.items and #bag.items, 1, "the old man's bag lists exactly one item")
  eq(bag.items[1].label, "POKé BALL", "the item is a POKé BALL")
  eq(bag.items[1].right, "x50", "with quantity x50 (OldManItemList)")
  -- the list script (home/list_menu.asm:65-80): input is never read --
  -- B can't back out -- and the '▶' hovers POKé BALL for 80 frames
  local enemyHP = demo.enemy.mon.hp
  pressed.b = true
  local hover = 0
  for _ = 1, 80 do
    if stack:top() ~= bag then break end
    hover = hover + 1
    bag:update(1 / 60)
  end
  pressed.b = false
  check(stack:top() == bag, "the old man's bag reads no input (B can't back out)")
  eq(hover, 80, "the '▶' hovers POKé BALL for 80 frames")
  check(not bag.hollowIndex, "the cursor stays the filled '▶' through the hover")
  -- frame 81: the auto A-press leaves the hollow '▷' on the chosen row
  -- (PlaceUnfilledArrowMenuCursor) while ItemUseBall spins up
  bag:update(1 / 60)
  eq(bag.hollowIndex, 1, "the auto-A leaves the hollow '▷' on the POKé BALL row")
  check(stack:top() == bag, "the hollow '▷' is visible while the list is open")
  -- the throw follows without any input: OLD MAN throws, it ALWAYS
  -- catches, nothing is kept
  for _ = 1, 20 do
    if stack:top() ~= bag then break end
    bag:update(1 / 60)
  end
  check(stack:top() ~= bag, "the ball is thrown without input")
  for _ = 1, 2000 do
    if finished then break end
    pressed.a = true
    demo:update(1 / 60)
  end
  pressed.a = false
  check(finished, "the throw ends the demo battle")
  local function sawText(pat)
    for _, t in ipairs(seen) do if t and t:find(pat, 1, true) then return true end end
    return false
  end
  check(sawText("OLD MAN used\nPOKé BALL!"), "the throw is credited to OLD MAN")
  check(sawText("All right!\nWEEDLE was\ncaught!"), "the ball always catches (_ItemUseBallText05)")
  eq(demo.enemy.mon.hp, enemyHP, "the old man never attacks (Weedle at full HP)")
  eq(#fg.save.party, 1, "the caught Weedle is NOT added to the party")
  check(not (fg.save.pokedex and fg.save.pokedex.owned and fg.save.pokedex.owned.WEEDLE),
        "the caught Weedle is NOT added to the dex")
end

print(("parity J: %d/%d passed"):format(total - fails, total))
if fails > 0 then error(fails .. " parity-J assertion(s) failed") end
