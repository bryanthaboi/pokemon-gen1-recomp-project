-- Scripted input driver for visual verification (dev tool).
-- Enable with:  POKEPORT_AUTOPILOT=1 love .
--
-- Steps: waits, key taps, BFS-pathfinding goTo, "mash A until UI closes",
-- callbacks.  Wild battles that interrupt navigation are auto-mashed.
-- Captures screenshots into the LÖVE save directory.

local Autopilot = {}

local RUN = os.getenv("POKEPORT_AUTOPILOT")
local steps = {}
local pc = 1
local timer = 0
local battleTimer = 0
local pending = {}

local function game() return require("src.core.Game") end

-- Anything that makes the overworld ignore normal player input or is
-- waiting on a button: a pushed UI state (text/choice/battle), a
-- script/cutscene in flight (ow.runner, raw scriptMoves, trainer-sight
-- engage), or a timed hold (the "!" emote pause, the heal-machine
-- animation). Mirrors the `scripted` flag OverworldState:update gates
-- real input on, plus the UI-stack and heal-machine cases that flag
-- doesn't cover -- a plain stack-size check reads "idle" the instant a
-- text box closes even mid-cutscene, which let mashUntilIdle() bail out
-- while Oak's escort or the rival's challenge script was still running.
local function busy()
  local ow = game().overworld
  return game().stack:top() ~= ow
         or (ow.runner and ow.runner:isRunning())
         or #(ow.scriptMoves or {}) > 0
         or ow.engaging
         or ow.emote ~= nil
         or ow.healAnim ~= nil
end

local function idle()
  return not busy() and not game().overworld.transitioning
end

local function inBattle()
  local top = game().stack:top()
  return top and top.kind ~= nil -- BattleState has .kind
end

local function press(key)
  game():keypressed(key)
  pending[key] = true
end

-- ---------------------------------------------------------------------
-- BFS pathfinding on the current map (walls + stationary NPCs)
-- ---------------------------------------------------------------------

local DIRS = { { 0, -1, "w" }, { 0, 1, "s" }, { -1, 0, "a" }, { 1, 0, "d" } }

local function bfsSearch(tx, ty)
  local ow = game().overworld
  local map = ow.map
  local p = ow.player
  if p.cellX == tx and p.cellY == ty then return nil, true end
  local w, h = map.widthCells, map.heightCells
  local function id(x, y) return y * w + x end
  local blocked = {}
  for _, npc in ipairs(ow.npcs) do
    blocked[id(npc.cellX, npc.cellY)] = true
    if npc.targetX then blocked[id(npc.targetX, npc.targetY)] = true end
  end
  local prev = {}
  local queue = { id(p.cellX, p.cellY) }
  prev[queue[1]] = -1
  local head = 1
  while head <= #queue do
    local cur = queue[head]
    head = head + 1
    local cx, cy = cur % w, math.floor(cur / w)
    if cx == tx and cy == ty then break end
    for _, d in ipairs(DIRS) do
      local nx, ny = cx + d[1], cy + d[2]
      if nx >= 0 and ny >= 0 and nx < w and ny < h then
        local nid = id(nx, ny)
        if not prev[nid] and not blocked[nid]
           and (map:isWalkableCell(nx, ny) or (nx == tx and ny == ty)) then
          prev[nid] = cur
          table.insert(queue, nid)
        end
      end
    end
  end
  local goal = id(tx, ty)
  if not prev[goal] then return nil, false end
  -- walk back to the first step
  local cur = goal
  while prev[cur] ~= id(p.cellX, p.cellY) do
    cur = prev[cur]
    if cur == -1 or cur == nil then return nil, true end
  end
  local cx, cy = cur % w, math.floor(cur / w)
  for _, d in ipairs(DIRS) do
    if p.cellX + d[1] == cx and p.cellY + d[2] == cy then return d[3], true end
  end
  return nil, true
end

local function bfsNextKey(tx, ty)
  return (bfsSearch(tx, ty))
end

local function reachable(tx, ty)
  local _, ok = bfsSearch(tx, ty)
  return ok
end

-- ---------------------------------------------------------------------
-- schedule DSL
-- ---------------------------------------------------------------------

local function add(step) table.insert(steps, step) end
local function wait(frames) add({ wait = frames }) end
local function shot(name) add({ fn = function()
  love.graphics.captureScreenshot(name .. ".png")
  print("[autopilot] screenshot " .. name)
end }) end
local function tap(key, times)
  for _ = 1, times or 1 do
    add({ key = key })
    wait(20)
  end
end
-- battleShot: optional { at = frame, name = "shot_name" } -- captured
-- once, `at` frames into a battle that interrupts this goTo (see the
-- auto-mash guard in the runner below).
local function goTo(x, y, battleShot) add({ goto_ = { x = x, y = y }, battleShot = battleShot }) end
local function goToFn(fn) add({ goto_ = { fn = fn } }) end
local function mashUntilIdle() add({ mash = true }) end
local function report(extra)
  add({ fn = function()
    local ow = game().overworld
    print(("[autopilot] map %s at (%d,%d)"):format(
      ow.map.id, ow.player.cellX, ow.player.cellY))
    if extra then extra() end
  end })
end

-- find the warp cell on the current map leading to destMap
local function warpTo(destMap)
  return function()
    for _, wp in ipairs(game().overworld.map.def.warps) do
      if wp.destMap == destMap then return wp.x, wp.y end
    end
    return nil
  end
end

-- find a cell adjacent to (and facing) the first NPC matching pred;
-- includes across-the-counter spots (intermediate cell is a counter tile)
local function adjacentToNpc(pred)
  return function()
    local ow = game().overworld
    for _, npc in ipairs(ow.npcs) do
      if pred(npc) then
        local candidates = {
          { npc.cellX, npc.cellY + 1, "w" }, { npc.cellX, npc.cellY - 1, "s" },
          { npc.cellX - 1, npc.cellY, "d" }, { npc.cellX + 1, npc.cellY, "a" },
          { npc.cellX, npc.cellY + 2, "w", npc.cellX, npc.cellY + 1 },
          { npc.cellX, npc.cellY - 2, "s", npc.cellX, npc.cellY - 1 },
          { npc.cellX - 2, npc.cellY, "d", npc.cellX - 1, npc.cellY },
          { npc.cellX + 2, npc.cellY, "a", npc.cellX + 1, npc.cellY },
        }
        for _, c in ipairs(candidates) do
          local counterOk = c[4] == nil or ow.map:isCounterCell(c[4], c[5])
          if counterOk and ow.map:inBounds(c[1], c[2])
             and ow.map:isWalkableCell(c[1], c[2])
             and reachable(c[1], c[2]) then
            return c[1], c[2], c[3]
          end
        end
      end
    end
    return nil
  end
end

local function npcIsMart(npc)
  local ow = game().overworld
  local entry = game().data:textEntry(ow.map.def.label, npc.def.text)
  return entry and entry.mart ~= nil
end

local function npcIsNurse(npc)
  local ow = game().overworld
  local entry = game().data:textEntry(ow.map.def.label, npc.def.text)
  return entry and entry.nurse == true
end

-- ---------------------------------------------------------------------
-- the route
-- ---------------------------------------------------------------------

wait(30)
shot("01_pallet_town")
-- tilt-mode pair: cycle to 15°, let the ~0.25s tween settle, capture,
-- then cycle 35→50→OFF to restore flat
tap("3")
wait(40)
shot("01b_pallet_town_tilt")
for _ = 1, 3 do tap("3") end
wait(40)
goTo(7, 8)
tap("s", 1)
tap("z")
wait(40)
shot("02_sign_text")
mashUntilIdle()
-- Oak's "Hey! Wait!" escort triggers on stepping to Pallet Town row
-- y==1 (PalletTownDefaultScript); from there the walk to the lab, the
-- walk-in, and the choose-a-mon exchange all run as one scripted chain
-- (data/scripts/story2.lua) -- busy()/idle() above track it start to
-- finish, so one mashUntilIdle() rides the whole thing out. Walking
-- straight to the lab door instead (the old route) uses the plain map
-- warp and skips this script entirely -- EVENT_FOLLOWED_OAK_INTO_LAB
-- never gets set, so the starter and rival-battle scripts below stay
-- gated off ("Those are POKé BALLS" / "Gramps isn't around") and the
-- party stays empty for the rest of the run.
goTo(10, 1)
mashUntilIdle()
report()     -- expect OAKS_LAB (5,3), EVENT_FOLLOWED_OAK_INTO_LAB set
shot("03_oaks_lab")
goTo(8, 4)
tap("w", 1)
tap("z")     -- Bulbasaur ball
wait(60)
shot("04_starter_prompt")
mashUntilIdle()
report()
-- the rival's challenge (data/scripts/oaks_lab.lua onStep) fires the
-- instant the player steps away from the table at y >= 6 -- no direct
-- talk needed (the rival has also already relocated to the counter-pick
-- ball, not a fixed cell). Walking to the exit mat below crosses that
-- row; busy()/battleShot above ride out the resulting text + battle.
goTo(5, 11, { at = 30, name = "05_rival_battle" })
tap("s", 2)
mashUntilIdle()
report()     -- expect PALLET_TOWN (12,11)
-- north to Route 1 (connection strip now rendered)
goTo(10, 1)
shot("06_pallet_north_strip")
goTo(10, 0)
tap("w", 2)
report()     -- expect ROUTE_1 (10,35)
shot("07_route1")
-- tilt-mode pair on the route (grass overdraw, water animation, fences).
-- dismiss the entry "tall grass" sign first so the tilt tap isn't gated.
mashUntilIdle()
tap("3")
wait(40)
shot("07c_route1_tilt")
for _ = 1, 3 do tap("3") end
wait(40)
-- guarantee at least one wild battle in the entry grass
add({ grind = { ax = 10, ay = 35, bx = 10, by = 33 },
      shotAt = { [30] = "07b_wild_battle" } })
-- walk the whole route north to Viridian (BFS pathfinds around the
-- fences and one-way ledges); wild battles are auto-mashed
goTo(10, 0)
tap("w", 2)
report()     -- expect VIRIDIAN_CITY
shot("08_viridian")
-- into the mart. By this point in the run EVENT_GOT_STARTER is set but
-- Oak's Parcel hasn't been delivered yet, so talking to the clerk
-- triggers the real Gen 1 quest hand-off (data/scripts/story.lua
-- TEXT_VIRIDIANMART_CLERK: "You came from Pallet Town?" + gives
-- OAKS_PARCEL) instead of opening the shop -- ShopMenu only opens once
-- that quest is resolved (delivered back to Oak), which this short run
-- doesn't do, so there is no purchase to make here.
goToFn(warpTo("VIRIDIAN_MART"))
wait(20)
mashUntilIdle()
report()     -- expect VIRIDIAN_MART
goToFn(adjacentToNpc(npcIsMart))
tap("z")     -- talk to the clerk
wait(40)
shot("09_mart_clerk")
mashUntilIdle()  -- rides out the parcel hand-off text (or the shop, if flags differ)
shot("10_mart_parcel")
report(function()
  local s = game().save
  print(("[autopilot] money %d  got oaks parcel %s"):format(
    s.money, tostring(s.flags.EVENT_GOT_OAKS_PARCEL)))
end)
-- leave the mart, into the center, heal
goToFn(warpTo("LAST_MAP"))
tap("s", 2)
mashUntilIdle()
report()     -- back in VIRIDIAN_CITY
goToFn(warpTo("VIRIDIAN_POKECENTER"))
wait(20)
mashUntilIdle()
report()     -- expect VIRIDIAN_POKECENTER
goToFn(adjacentToNpc(npcIsNurse))
tap("z")
wait(60)
shot("11_nurse")
mashUntilIdle()
report(function()
  local s = game().save
  print(("[autopilot] lastHeal %s (%d,%d)  lead hp %d/%d"):format(
    s.lastHeal.map, s.lastHeal.x, s.lastHeal.y,
    s.party[1].hp, s.party[1].stats.hp))
end)
shot("12_healed")
-- tilt-mode pair inside the Poke Center (interior + heal-machine area)
tap("3")
wait(40)
shot("12b_pokecenter_tilt")
for _ = 1, 3 do tap("3") end
wait(40)
add({ fn = function()
  local s = game().save
  print(("[autopilot] party: %s L%d  money %d  dex seen %d"):format(
    s.party[1] and s.party[1].species or "none",
    s.party[1] and s.party[1].level or 0, s.money,
    (function() local n = 0 for _ in pairs(s.pokedex.seen) do n = n + 1 end return n end)()))
  print("[autopilot] save dir: " .. love.filesystem.getSaveDirectory())
  love.event.quit(0)
end })

-- ---------------------------------------------------------------------
-- runner
-- ---------------------------------------------------------------------

function Autopilot.update()
  if not RUN then return end
  for key in pairs(pending) do
    game():keyreleased(key)
    pending[key] = nil
  end
  local step = steps[pc]
  if not step then return end

  -- auto-mash through anything that interrupts a step: wild/trainer
  -- battles, or a scripted cutscene taking over (busy() -- see above),
  -- EXCEPT for goto_ and key steps. goto_: reaching the target cell
  -- always completes that step first, even if arrival just triggered a
  -- cutscene that will relocate the player (e.g. Oak's escort walking
  -- the player into OAKS_LAB) -- letting busy() intercept before goto_
  -- notices it already arrived would freeze pc on a target cell that no
  -- longer means anything once the cutscene moves the player elsewhere.
  -- key: a scheduled tap() is a deliberate, specific button press for
  -- the menu/dialogue on screen right now (e.g. the mart's greeting ->
  -- BUY -> item -> quantity -> price steps) -- busy() is true for almost
  -- all of those (a UI state is exactly what's on top of the stack), so
  -- letting the generic 25-frame mash intercept scrambles a multi-step
  -- menu sequence instead of advancing it one deliberate press at a
  -- time. mash/grind steps handle their own busy state.
  if busy() and not step.mash and not step.grind and not step.goto_
     and not step.key then
    battleTimer = battleTimer + 1
    if battleTimer % 25 == 0 then press("z") end
    return
  end
  battleTimer = 0

  if step.wait then
    timer = timer + 1
    if timer >= step.wait then timer = 0 pc = pc + 1 end
  elseif step.goto_ then
    timer = timer + 1
    local ow = game().overworld
    local p = ow.player
    local g = step.goto_
    if g.fn and not g.resolved then
      local x, y, face = g.fn()
      if not x then
        print("[autopilot] goto target not found; skipping")
        timer = 0
        pc = pc + 1
        return
      end
      g.x, g.y, g.face = x, y, face
      g.resolved = true
    end
    if p.cellX == g.x and p.cellY == g.y and not p.moving then
      if g.face then
        -- face the target direction with a tap
        if p.facing ~= ({ w = "up", s = "down", a = "left", d = "right" })[g.face] then
          press(g.face)
          return
        end
      end
      timer = 0
      pc = pc + 1
      return
    end
    if timer > 5400 and not g.retried then
      -- a wandering NPC can park on the target (or the only path to it)
      -- for a while; BFS treats it as a wall, so give it one more window
      -- to move along instead of derailing every step after this one
      g.retried = true
      timer = 0
      print("[autopilot] goto slow; retrying once")
      return
    end
    if timer > 5400 then
      print("[autopilot] goto timed out")
      timer = 0
      pc = pc + 1
    elseif busy() then
      -- not there yet and something took over (a trainer/rival's talk +
      -- battle, a wild encounter): mash through it, then resume BFS once
      -- idle again -- unlike arrival above, this never touches g.x/g.y,
      -- so it's safe even though the goto's own target hasn't been hit.
      -- battleShot.frames counts frames since the battle itself started
      -- (not the shared `timer`, which has already been counting since
      -- the walk began) so `at` means "N frames into the battle".
      if step.battleShot and inBattle() then
        local bs = step.battleShot
        bs.frames = (bs.frames or 0) + 1
        if bs.frames == bs.at and not bs.captured then
          bs.captured = true
          love.graphics.captureScreenshot(bs.name .. ".png")
          print("[autopilot] screenshot " .. bs.name)
        end
      end
      if timer % 25 == 0 then press("z") end
    elseif idle() and not p.moving then
      local key = bfsNextKey(g.x, g.y)
      if key and not pending[key] then press(key) end
    end
  elseif step.grind then
    timer = timer + 1
    local g = step.grind
    if inBattle() then
      g.sawBattle = true
      g.battleTimer = (g.battleTimer or 0) + 1
      if step.shotAt and step.shotAt[g.battleTimer] then
        love.graphics.captureScreenshot(step.shotAt[g.battleTimer] .. ".png")
        print("[autopilot] screenshot " .. step.shotAt[g.battleTimer])
      end
      if g.battleTimer % 25 == 0 then press("z") end
    elseif g.sawBattle and idle() then
      timer = 0
      pc = pc + 1
    elseif idle() then
      local p = game().overworld.player
      if p.cellX == g.ax and p.cellY == g.ay then g.toB = true end
      if p.cellX == g.bx and p.cellY == g.by then g.toB = false end
      if not p.moving then
        local key = bfsNextKey(g.toB and g.bx or g.ax, g.toB and g.by or g.ay)
        if key and not pending[key] then press(key) end
      end
    end
    if timer > 7200 then
      print("[autopilot] grind timed out")
      timer = 0
      pc = pc + 1
    end
  elseif step.key then
    press(step.key)
    pc = pc + 1
  elseif step.mash then
    timer = timer + 1
    if step.shotAt and step.shotAt[timer] then
      love.graphics.captureScreenshot(step.shotAt[timer] .. ".png")
      print("[autopilot] screenshot " .. step.shotAt[timer])
    end
    if timer % 25 == 0 then press("z") end
    if idle() and timer % 25 == 24 then
      timer = 0
      pc = pc + 1
    end
    if timer > 5400 then
      print("[autopilot] mash timed out")
      timer = 0
      pc = pc + 1
    end
  elseif step.fn then
    step.fn()
    pc = pc + 1
  end
end

return Autopilot
