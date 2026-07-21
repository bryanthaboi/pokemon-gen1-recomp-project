-- Full-route bot driver.
--
--   POKEPORT_DRIVER=tests/drivers/route.lua love .
--   xvfb-run -a env POKEPORT_DRIVER=tests/drivers/route.lua love .   (headless)
--
-- Interprets tests/drivers/bot_route.lua -- the converted PokeBotBad any%
-- route, see tools/botconv/ -- against the live Game object. The route is
-- geography only: we walk where the speedrun walks but fight everything
-- the slow reliable way, so none of its frame-perfect tactics carry over.
--
-- Unimplemented ops do not abort the run. They log and continue, and the
-- summary at the end lists every op that was skipped and where. A run that
-- stalls tells you which handler to write next; a run that finishes is an
-- end-to-end assertion that warps, scripts, battles and menus all work.

local U = require("tests.drivers.util")
local ROUTE = require("tests.drivers.bot_route")

local G          -- the Game object, set on entry
local skipped = {}
local log = {}
-- Set when the party blacks out. Polling HP for this is unreliable: the
-- revive can land in the same frame the battle screen pops, so a run can
-- black out without the driver ever observing a zeroed party -- which is
-- exactly how one attempt sailed on to skip 145 segments and then ran the
-- ENDGAME Viridian Gym visit at level 12, because it happened to be
-- standing in Viridian City and the map matched.
--
-- OverworldController announces it instead, immediately before reviving
-- (`Runtime.emit("world.blacked_out", ...)`), so hook the announcement.
-- Wrapping emit rather than subscribing keeps this working headlessly:
-- the mod event bus is a null object until a loader installs one.
local blackedOut = false
do
  local Runtime = require("src.mods.Runtime")
  local baseEmit = Runtime.emit
  Runtime.emit = function(name, payload)
    if name == "world.blacked_out" then blackedOut = true end
    return baseEmit(name, payload)
  end
end

local function note(op, where)
  local key = op .. " @ " .. where
  skipped[key] = (skipped[key] or 0) + 1
end

-- A long run is normally stopped by killing the process, and block-buffered
-- stdout discards everything since the last 4K flush -- which is most of
-- what we want to read. Go unbuffered, and additionally mirror to a file
-- flushed per line (POKEPORT_ROUTE_LOG) so output survives a hard kill.
pcall(function() io.stdout:setvbuf("no") end)
local logFile
do
  local path = os.getenv("POKEPORT_ROUTE_LOG")
  if path then logFile = io.open(path, "w") end
end

-- ---------------------------------------------------------------------
-- danger memory
-- ---------------------------------------------------------------------
-- Where the party has died before, counted per map and persisted, so the
-- bot gets more careful about a place every time it loses there instead of
-- walking into the same fight at the same HP forever. It survives the
-- process, so each run starts knowing what killed the last one.
--
-- Keyed by map rather than by segment index: segment numbers shift
-- whenever the route is regenerated, but "Viridian Forest keeps killing
-- us" stays true across conversions.
local MEMORY_PATH = os.getenv("POKEPORT_ROUTE_MEMORY")
                    or "/tmp/pokeport_route_memory.lua"
local deaths, walls, seams = {}, {}, {}

local function loadMemory()
  local chunk = loadfile(MEMORY_PATH)
  if not chunk then return end
  local ok, t = pcall(chunk)
  if not (ok and type(t) == "table") then return end
  -- earlier files were a flat map -> death-count table
  deaths = type(t.deaths) == "table" and t.deaths or t
  walls = type(t.walls) == "table" and t.walls or {}
  seams = type(t.seams) == "table" and t.seams or {}
end

local function writeCounts(fh, tbl)
  local keys = {}
  for k in pairs(tbl) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do fh:write(("    [%q] = %d,\n"):format(k, tbl[k])) end
end

local function saveMemory()
  local fh = io.open(MEMORY_PATH, "w")
  if not fh then return end
  fh:write("-- written by tests/drivers/route.lua; safe to delete to forget\n")
  fh:write("return {\n  deaths = {\n")
  writeCounts(fh, deaths)
  fh:write("  },\n  walls = {\n")
  writeCounts(fh, walls)
  fh:write("  },\n  seams = {\n")
  writeCounts(fh, seams)
  fh:write("  },\n}\n")
  fh:close()
end

local function dangerAt(mapId) return deaths[mapId or ""] or 0 end

local function recordDeath(mapId)
  if not mapId then return end
  deaths[mapId] = (deaths[mapId] or 0) + 1
  saveMemory()
end

-- Cells the engine refused to walk into, keyed "<map>#<cellId>".
--
-- BFS plans over map:isWalkableCell, a static tile test that does not know
-- about ledges (one-way), directional blocks, counters or the goal-cell
-- exemption below -- so it can hand back a step tryMove rejects. Because
-- BFS is deterministic, re-planning then returns the SAME step and the
-- player bumps the identical wall until the retry counter gives up. This
-- is that missing feedback: a refusal is remembered and planned around.
local WALL_CONFIRM = 2 -- refusals before future runs plan around it

local function wallKey(mapId, cell) return tostring(mapId) .. "#" .. cell end

local function noteWall(mapId, cell)
  local k = wallKey(mapId, cell)
  walls[k] = (walls[k] or 0) + 1
  saveMemory()
  return walls[k]
end

-- Walking onto a cell proves it passable after all, so forget it. Keeps a
-- temporary blocker (an NPC mid-stroll, a tree before we have Cut) from
-- being blacklisted for good.
local function clearWall(mapId, cell)
  local k = wallKey(mapId, cell)
  if walls[k] then walls[k] = nil; saveMemory() end
end

-- Map-graph hops that did not work, keyed "<from>><to>".
--
-- The same feedback idea as `walls`, one level up. travelTo plans over map
-- adjacency, which is geography and says nothing about whether the seam is
-- actually passable YET: Route 6's north connection to Saffron is real map
-- data, but the city is walled and gated until the guards are dealt with.
--
-- A PRICE, never a ban, and that distinction is the whole lesson here. This
-- started out as a hard block after two failures, which quietly severed the
-- map graph: crossing a seam is flaky (an NPC parked on the border cell is
-- enough), so VERMILION_CITY>ROUTE_6 -- the only way north out of Vermilion,
-- and one that had already worked earlier in the same session -- reached two
-- failures and became impossible. The run degenerated to skipping from
-- segment 1. A seam that is merely expensive gets tried again when it is the
-- only way through; a banned one strands the run for good.
--
-- Cleared outright on a crossing that works, so a seam that opens later (a
-- gate script, a Cut tree) costs nothing thereafter.
local SEAM_PENALTY = 4   -- added to the hop cost per recorded failure
local SEAM_PENALTY_MAX = 24

local function seamKey(from, to) return tostring(from) .. ">" .. tostring(to) end

-- A travel edge's identity for the per-trip ban set.
--
-- Per WARP, not per seam. A gate exposes many physical warps for the SAME
-- (from, to) pair -- ROUTE_16_GATE_1F has eight LAST_MAP warps all leading
-- back to ROUTE_16, four to each half -- so banning by seamKey when one of
-- them fails kills all eight, including the east door that is the only way
-- across. Keying the ban by the warp's own cell keeps the others live.
-- Connections have a single seam, so they fall back to seamKey.
local function edgeId(from, e)
  if e.warp then
    return ("%s>%s@%d,%d"):format(tostring(from), tostring(e.to),
                                  e.warp.x, e.warp.y)
  end
  return seamKey(from, e.to)
end

local function noteSeam(from, to)
  local k = seamKey(from, to)
  seams[k] = (seams[k] or 0) + 1
  saveMemory()
  return seams[k]
end

local function clearSeam(from, to)
  local k = seamKey(from, to)
  if seams[k] then seams[k] = nil; saveMemory() end
end

local function seamCost(from, to)
  return math.min((seams[seamKey(from, to)] or 0) * SEAM_PENALTY, SEAM_PENALTY_MAX)
end

-- cells this map has refused often enough to route around from the start
local function knownWalls(mapId)
  local prefix = tostring(mapId) .. "#"
  local set
  for k, n in pairs(walls) do
    if n >= WALL_CONFIRM and k:sub(1, #prefix) == prefix then
      set = set or {}
      set[tonumber(k:sub(#prefix + 1))] = true
    end
  end
  return set
end

local function say(...)
  local parts = { ... }
  for i = 1, #parts do parts[i] = tostring(parts[i]) end
  local line = "[route] " .. table.concat(parts, " ")
  print(line)
  if logFile then logFile:write(line, "\n"); logFile:flush() end
end

-- ---------------------------------------------------------------------
-- state predicates (mirrors tests/autopilot.lua's busy()/idle())
-- ---------------------------------------------------------------------

local function ow() return G.overworld end

-- Anything that makes the overworld ignore normal player input: a pushed
-- UI state, a script/cutscene in flight, or a timed hold. A plain
-- stack-size check reads "idle" the instant a text box closes even mid
-- cutscene, which would let us resume walking during Oak's escort.
local function busy()
  local o = ow()
  return G.stack:top() ~= o
         or (o.runner and o.runner:isRunning())
         or #(o.scriptMoves or {}) > 0
         or o.engaging
         or o.emote ~= nil
         or o.healAnim ~= nil
end

local function idle() return not busy() and not ow().transitioning end

local function inBattle()
  local top = G.stack:top()
  return top ~= nil and top.kind ~= nil
end

local function press(btn) U.tap(G, btn) end

-- Movement needs the direction HELD, not tapped: OverworldController's
-- handleInput walks on input:isDown(dir) (OverworldController.lua:734) and
-- calls tryMove every frame the key is down. A one-frame tap only turns
-- the player in place, which reads as walking on the spot into a wall.
-- Edge exits, ledge hops and boulder pushes additionally require that we
-- already face the direction before the step (lines 735-739), so holding
-- through the turn is what makes those fire at all.
--
-- Returns true if we changed cell (or map), false if we were blocked.
local function walk(dir, maxFrames)
  local o = ow()
  local sx, sy, smap = o.player.cellX, o.player.cellY, o.map.id
  local moved = false
  -- Frames spent already facing `dir` without the step starting. The engine
  -- refuses a blocked move every frame the key is held, so without this the
  -- loop replays the bump animation for the whole of maxFrames -- and the
  -- caller then retries up to 8 times. That is what "Red walking into the
  -- same wall ten times and then recovering" looks like on screen; it is a
  -- held-input problem, not a pathfinding one. Bail as soon as the engine
  -- has clearly said no and let the caller re-plan.
  local refusedFrames = 0
  for _ = 1, maxFrames or 40 do
    table.insert(G.input.pressQueue, dir)
    G.input.state[dir] = true
    coroutine.yield()
    local p = ow().player
    if ow().map.id ~= smap then moved = true break end
    if (p.cellX ~= sx or p.cellY ~= sy) and not p.moving then moved = true break end
    if busy() then
      -- A LEDGE HOP is performed with scriptMove, so it reads as "busy"
      -- exactly like a cutscene does -- and breaking here reported the hop
      -- as "did not move", which made goto_ blacklist the ledge as a wall.
      -- Wait out our own hop and judge by the cell we land on. Anything else
      -- busy (a battle, a real script) still belongs to the caller.
      local hopping = (ow().player.hopFrames or 0) > 0
      if hopping and not inBattle() then
        for _ = 1, 90 do
          if not busy() then break end
          coroutine.yield()
        end
        local q = ow().player
        if ow().map.id ~= smap or q.cellX ~= sx or q.cellY ~= sy then
          moved = true
        end
      end
      break
    end
    -- the first frames legitimately go on turning to face `dir`
    if p.facing == dir and not p.moving then
      refusedFrames = refusedFrames + 1
      if refusedFrames >= 6 then break end
    else
      refusedFrames = 0
    end
  end
  G.input.state[dir] = false
  coroutine.yield()
  return moved
end

-- ---------------------------------------------------------------------
-- BFS over the current map (walls + stationary NPCs), from autopilot.lua
-- ---------------------------------------------------------------------

local DIRS = { { 0, -1, "up" }, { 0, 1, "down" }, { -1, 0, "left" }, { 1, 0, "right" } }

-- direction key -> step delta, for turning a refused step back into a cell
local DELTA = {}
for _, d in ipairs(DIRS) do DELTA[d[3]] = { d[1], d[2] } end

-- `extra` is a set of cell ids to treat as walls (see knownWalls / the
-- refusal feedback in ops.goto_).
-- Where a ledge hop from (x, y) in `dir` would land, or nil if there is no
-- hop to be had.
--
-- Mirrors OverworldState:checkLedgeHop (OverworldController.lua:845): the
-- standing tile, the ledge tile in front and the input direction all have to
-- match a row of field.ledges, and the landing cell two along must be free.
--
-- BFS needs this because it plans over `isWalkableCell`, and a ledge tile is
-- deliberately NOT walkable -- you may only cross it by hopping. Without it
-- Route 4 is impassable: the route steps from (79,8) to (79,10), which is a
-- hop over the ledge at (79,9), and the bot reported "goto (79,10)
-- unreachable" and then failed the edge exit into Cerulean, losing the run to
-- nine skipped segments every single time. Every later route with a ledge
-- would have gone the same way.
local function ledgeLanding(map, x, y, dir, dx, dy)
  local ledges = G.data.field and G.data.field.ledges
  if not ledges then return nil end
  local fx, fy = x + dx, y + dy
  if not map:inBounds(fx, fy) then return nil end
  local tileset = map.def.tileset
  local standing, front = map:cellTile(x, y), map:cellTile(fx, fy)
  for _, ledge in ipairs(ledges) do
    if (ledge.tileset or "OVERWORLD") == tileset
       and ledge.facing == dir and ledge.input == dir
       and ledge.standingTile == standing and ledge.ledgeTile == front then
      local lx, ly = fx + dx, fy + dy
      if map:inBounds(lx, ly) and map:isWalkableCell(lx, ly) then
        return lx, ly
      end
    end
  end
  return nil
end

-- Walkable for the player AS THEY CURRENTLY ARE. isWalkableCell is a
-- land-only test, so once SURF is up every remaining over-water waypoint
-- would read unreachable -- and ROUTE_21 is a ninety-row water corridor,
-- so the trip to Cinnabar dies on the first plan without this. While
-- surfing, water counts too; land stays passable because walking onto the
-- shore is exactly how you dismount.
local function passableCell(map, x, y)
  if map:isWalkableCell(x, y) then return true end
  local p = ow().player
  return p.surfing == true and map:isWaterCell(x, y)
end

local function bfsNextKey(tx, ty, extra)
  local o = ow()
  local map, p = o.map, o.player
  if p.cellX == tx and p.cellY == ty then return nil end
  local w = map.widthCells
  local function id(x, y) return y * w + x end
  local blocked = {}
  if extra then
    for cell in pairs(extra) do blocked[cell] = true end
  end
  -- NPCs are walls -- but only the ones that belong to THIS map.
  --
  -- A warp swaps map.id before the entity list is rebuilt, so a plan made
  -- in that window blocks cells using the PREVIOUS map's NPCs. Their
  -- coordinates are usually nonsense here, and `id(x, y)` folds x and y
  -- together, so an NPC at forest (16,43) lands on some innocent cell of an
  -- 8-wide gate and walls it off. That is exactly what stranded a run in
  -- VIRIDIAN_FOREST_NORTH_GATE: "goto (4,1) unreachable ... npcs:
  -- SPRITE_YOUNGSTER@(16,43) SPRITE_YOUNGSTER@(30,33)" -- forest
  -- coordinates listed against a gate the size of a room, every following
  -- segment skipping, and the attempt lost.
  local h = map.heightCells
  for _, npc in ipairs(o.npcs) do
    local inMap = npc.cellX >= 0 and npc.cellY >= 0
                  and npc.cellX < w and npc.cellY < h
    if inMap then
      blocked[id(npc.cellX, npc.cellY)] = true
      if npc.targetX and npc.targetX >= 0 and npc.targetY >= 0
         and npc.targetX < w and npc.targetY < h then
        blocked[id(npc.targetX, npc.targetY)] = true
      end
    end
  end
  local prev = { [id(p.cellX, p.cellY)] = -1 }
  local queue, head = { id(p.cellX, p.cellY) }, 1
  while head <= #queue do
    local cur = queue[head]; head = head + 1
    local cx, cy = cur % w, math.floor(cur / w)
    if cx == tx and cy == ty then break end
    for _, d in ipairs(DIRS) do
      local nx, ny = cx + d[1], cy + d[2]
      local nid = id(nx, ny)
      -- Never path onto the Celadon Mart elevator entrance. There the
      -- elevator is optional (stairs reach every floor) and its mat is a
      -- bounce-trap the driver keeps stepping onto during floor navigation.
      -- Scoped to CELADON_MART so Silph's elevator -- a different map the
      -- route genuinely rides -- is untouched, and to elevator-destination
      -- warps so ordinary doors and stairs are untouched. The target cell
      -- is always allowed (never block where we are trying to go).
      local elevTrap = false
      if tostring(map.id):find("CELADON_MART") and not (nx == tx and ny == ty) then
        local wc = map.warpAtCell and map:warpAtCell(nx, ny)
        local dm = wc and wc.def and wc.def.destMap
        elevTrap = type(dm) == "string" and dm:find("ELEVATOR") ~= nil
      end
      if nx >= 0 and ny >= 0 and nx < w and ny < map.heightCells
         and not prev[nid] and not blocked[nid] and not elevTrap
         and (passableCell(map, nx, ny) or (nx == tx and ny == ty)) then
        prev[nid] = cur
        queue[#queue + 1] = nid
      else
        -- Not walkable -- but it may be a ledge we can hop, which lands two
        -- cells along and is one-way. Treated as an ordinary edge from the
        -- cell we are standing on; walk() already holds the direction, which
        -- is what makes the engine's hop fire.
        local lx, ly = ledgeLanding(map, cx, cy, d[3], d[1], d[2])
        if lx then
          local lid = id(lx, ly)
          if not prev[lid] and not blocked[lid] then
            prev[lid] = cur
            queue[#queue + 1] = lid
          end
        end
      end
    end
  end
  local goal = id(tx, ty)
  if not prev[goal] then return nil end
  local cur = goal
  while prev[cur] ~= id(p.cellX, p.cellY) do
    cur = prev[cur]
    if cur == nil or cur == -1 then return nil end
  end
  local cx, cy = cur % w, math.floor(cur / w)
  for _, d in ipairs(DIRS) do
    if p.cellX + d[1] == cx and p.cellY + d[2] == cy then return d[3] end
  end
  -- The first move may be a ledge hop, which lands TWO cells along rather
  -- than one, so the adjacency test above finds nothing. Same direction, and
  -- walk() holds it exactly the same way -- the engine does the jumping.
  for _, d in ipairs(DIRS) do
    local lx, ly = ledgeLanding(map, p.cellX, p.cellY, d[3], d[1], d[2])
    if lx == cx and ly == cy then return d[3] end
  end
end

-- ---------------------------------------------------------------------
-- battle
-- ---------------------------------------------------------------------

-- A deterministic mid-roll stand-in for love.math.random. Damage.lua only
-- ever calls rng(min, max) (Damage.lua:83,105,253), so probing a move with
-- this consumes no game RNG and cannot desync the battle -- which calling
-- battle.rng directly would.
-- Wait for a screen to appear WITHOUT pressing anything.
--
-- pressUntil mashes A, which is safe on a text box and disastrous on a
-- bag or a party list: A there means "use this item" / "send out this mon",
-- so mashing to wait for the screen acts on whatever the cursor happens to
-- be sitting on.
local function waitFor(pred, tries)
  for _ = 1, tries or 40 do
    if pred() then return true end
    U.wait(3)
  end
  return pred()
end

-- Set while we are driving a *voluntary* switch (training, below), so
-- sendOutHealthy -- which owns the forced post-faint menu -- does not grab
-- the same PartyMenu and send out slot 1 instead.
local switchingForTraining = false

-- The battle's replacement PartyMenu, if it is what we are looking at.
--
-- It is pushed on top of the BattleState (BattleState:openReplacementMenu),
-- and it carries no `.kind`, so inBattle() reads false while it is up and
-- fightBattle's loop exits underneath it. `.onSwitch` is what makes it this
-- menu rather than the overworld party screen.
local function replacementMenu()
  local t = G.stack:top()
  if t and t.onSwitch ~= nil and t.index ~= nil and t.items == nil then
    return t
  end
end

-- Send out the first healthy mon.
--
-- Pressing A blind does NOT work: the cursor starts on slot 1, which is the
-- mon that just fainted, and PartyMenu answers "There's no will to fight!"
-- and reopens (BattleState.lua:2606-2609). The first run that ever had a
-- second Pokémon to switch to spent the rest of its life in that menu,
-- logging "mashUntilIdle timed out" on repeat.
local function sendOutHealthy()
  if switchingForTraining then return false end
  if not replacementMenu() then return false end
  local slot
  for i, mon in ipairs(G.save.party or {}) do
    if (mon.hp or 0) > 0 then slot = i break end
  end
  if not slot then return false end -- nothing left; the blackout owns this
  for _ = 1, 12 do
    local t = replacementMenu()
    if not t or t.index == slot then break end
    press(t.index > slot and "up" or "down")
    U.wait(3)
  end
  if replacementMenu() then
    press("a")
    U.wait(8)
  end
  return true
end

-- ---------------------------------------------------------------------
-- training the second Pokémon
-- ---------------------------------------------------------------------
--
-- Gen 1 gives exp only to mons that were actually SENT OUT
-- (BattleState:markParticipant / the participant split in enemyMonFainted),
-- so the Nidoran we go out of our way to catch on Route 22 earns nothing at
-- all while it sits in slot 2. The route would then reach Mt. Moon and put a
-- Moon Stone into a level 4 Nidoking, wasting every TM aimed at it later
-- (thrash, thunderbolt, horn drill, rock slide, ice beam).
--
-- Sending it out and switching straight back earns it a full share without it
-- ever having to survive a fight. The cost is the enemy's free move on each
-- switch, so it only runs while the trainee is healthy enough to take one and
-- only on the first menu of a battle, never mid-fight.
local TRAINEE_MIN_HP = 0.6

-- How far above the trainee a wild foe may be before switching the
-- trainee in is a faint rather than a share of the exp. The switch costs
-- it one free enemy attack, so the gap is a survivability bound, not a
-- preference: past it the trainee dies, leaves the rotation (traineeSlot
-- wants hp > 0) and never trains again. Eight covers the levels the route
-- actually intends -- a NIDORAN caught at 3-4 on ROUTE_22 training through
-- Mt. Moon's level 8-12 wilds -- without feeding it to Route 9.
local TRAINEE_MAX_GAP = 8

-- The party slot we are levelling: the healthy member furthest behind the
-- lead. nil when there is nobody worth training.
local function traineeSlot()
  local roster = G.save.party or {}
  local lead = roster[1]
  if not lead or #roster < 2 then return nil end
  local best, bestLevel
  for i = 2, #roster do
    local mon = roster[i]
    local max = mon.stats and mon.stats.hp or 0
    if (mon.hp or 0) > 0 and max > 0
       and (mon.hp / max) >= TRAINEE_MIN_HP
       and (mon.level or 0) < (lead.level or 0)
       and (not bestLevel or (mon.level or 0) < bestLevel) then
      best, bestLevel = i, mon.level or 0
    end
  end
  return best
end

local function midRng(a, b) return math.floor((a + b) / 2) end

-- Rank the active mon's moves by expected damage against the current
-- opponent using the engine's own damage math, so type effectiveness,
-- STAB and the ruleset all come from the game rather than a ported table.
-- The move that takes the enemy DOWN without killing it, for catching.
--
-- Gen 1's catch formula scales with missing HP, so throwing at full health
-- is close to the worst odds available. It is fine for the route's NIDORAN
-- (catch rate 235), which is why the original threw immediately, but ODDISH
-- is catch rate 45 -- six balls went into one at full HP and it still broke
-- out every time.
--
-- Returns the move doing the most damage that still leaves the target
-- alive, with a margin, or nil when every move would KO (a level-20 lead
-- against a level-13 wild mon frequently has no safe option at all) -- in
-- which case the caller throws at whatever HP it has rather than killing
-- the thing it came for.
local CATCH_HP_MARGIN = 0.10 -- of max HP, kept in reserve under any hit

local function weakenMoveIndex(battle)
  local enemy = battle.enemy and battle.enemy.mon
  if not enemy then return nil end
  local maxHP = math.max(1, enemy.stats and enemy.stats.hp or 1)
  local floorHP = math.max(1, math.floor(maxHP * CATCH_HP_MARGIN))
  local headroom = (enemy.hp or 0) - floorHP
  if headroom <= 0 then return nil end -- already as low as we dare
  local bestIdx, bestDmg = nil, -1
  for i, mv in ipairs(battle.player.curMoves) do
    if mv.pp > 0 and battle.player.disabledSlot ~= i then
      local def = battle:moveDef(mv)
      if def then
        local probe = setmetatable({ id = mv.id }, { __index = def })
        local ok, dmg, info = pcall(function()
          return battle:computeDamage(battle.player, battle.enemy, probe,
                                      { rng = midRng })
        end)
        -- Only moves that compute a real number are candidates: a status
        -- move does no damage and would spin the turn without progress.
        if ok and type(dmg) == "number" and dmg > 0
           and not (info and info.typeMult == 0) then
          -- midRng is the MID roll; the real hit can roll higher and crit,
          -- so leave the margin rather than aiming at exactly 1 HP.
          if dmg <= headroom and dmg > bestDmg then bestIdx, bestDmg = i, dmg end
        end
      end
    end
  end
  return bestIdx
end

local function bestMoveIndex(battle)
  local moves = battle.player.curMoves
  local bestIdx, bestDmg = nil, -1
  for i, mv in ipairs(moves) do
    if mv.pp > 0 and battle.player.disabledSlot ~= i then
      local def = battle:moveDef(mv)
      if def then
        -- guarantee .id/.highCrit reach Damage.critRoll even if the merged
        -- record does not carry them
        local probe = setmetatable({ id = mv.id }, { __index = def })
        local ok, dmg, info = pcall(function()
          return battle:computeDamage(battle.player, battle.enemy, probe,
                                      { rng = midRng })
        end)
        if ok and type(dmg) == "number" then
          if info and info.typeMult == 0 then dmg = -1 end -- immune
          if dmg > bestDmg then bestIdx, bestDmg = i, dmg end
        elseif bestIdx == nil then
          bestIdx, bestDmg = i, 0 -- status move / uncomputable: still usable
        end
      end
    end
  end
  return bestIdx or 1
end

-- Move the 2x2 action cursor to `want` (1=fight 2=pkmn 3=item 4=run).
-- Layout is index = row*2 + col + 1 (BattleState.lua:1040-1047); left and
-- right both toggle the column, up and down both toggle the row.
local function battleMenuTo(battle, want)
  for _ = 1, 4 do
    if battle.menuIndex == want then return true end
    local col = (battle.menuIndex - 1) % 2
    local wantCol = (want - 1) % 2
    if col ~= wantCol then press("left") else press("up") end
    U.wait(2)
  end
  return battle.menuIndex == want
end

-- Switch to party `slot` from the battle action menu (PKMN is index 2).
--
-- Flags the PartyMenu it opens as ours, so sendOutHealthy leaves it alone --
-- otherwise the forced-replacement handler would see a party menu and send
-- out slot 1, which is the mon we are trying to switch away from.
local function switchTo(battle, slot)
  switchingForTraining = true
  local ok = false
  repeat
    if not battleMenuTo(battle, 2) then break end
    press("a")
    if not waitFor(replacementMenu, 30) then break end
    for _ = 1, 12 do
      local t = replacementMenu()
      if not t or t.index == slot then break end
      press(t.index > slot and "up" or "down")
      U.wait(3)
    end
    local t = replacementMenu()
    if not t or t.index ~= slot then break end
    press("a")
    U.wait(10)
    ok = true
  until true
  switchingForTraining = false
  if not ok then -- back out of whatever we left open
    for _ = 1, 6 do
      if not replacementMenu() then break end
      press("b")
      U.wait(4)
    end
  end
  return ok
end

-- Below this fraction of max HP we would rather leave than trade turns.
--
-- Two thresholds, because a flat one is wrong in both directions. Fleeing
-- forfeits the XP, so a cautious bot arrives everywhere underlevelled,
-- takes proportionally more damage and flees even more -- but dropping the
-- threshold outright is worse: a lone level-5 starter on Route 1 has no
-- centre and no items, and fighting on simply kills it (tried it, the run
-- died at segment 6 instead of 22).
--
-- So: fight further down only when something can actually put the HP back.
local LOW_HP_EXPOSED = 0.35 -- nothing can restore HP; protect the run
local LOW_HP_COVERED = 0.2  -- a nurse or a potion is within reach

-- assigned below, once the healing helpers it needs exist
local canRestoreHP = function() return false end

-- true while deliberately farming encounters: fleeing earns no XP, which is
-- the whole point of grinding, so the flee guard stands down
local grinding = false

-- Drink a potion during a battle. Defined further down, once the bag
-- helpers (HP_ITEMS, heldCount, party) it needs exist; fightBattle
-- calls it and comes first.
local IN_BATTLE_HEAL_AT = 0.35
local healInBattle

-- Throw the POKE_DOLL from the battle ITEM menu. Defined near
-- healInBattle (same forward-declaration dance); fightBattle needs it for
-- the static ghost MAROWAK, where fleeing leaves the blocker standing.
local throwPokeDoll

local function lowOnHP(battle)
  if grinding then return false end -- training: take the XP, not the exit
  local mon = battle.player and battle.player.mon
  local max = mon and mon.stats and mon.stats.hp
  if not max or max <= 0 then return false end
  -- Stay in the fight only where we can both afford to and have not been
  -- killed before: a map with a death on record gets the cautious bar even
  -- when the bag is full, because the record says our estimate was wrong
  -- here at least once.
  local covered = canRestoreHP() and dangerAt(ow().map.id) == 0
  return mon.hp / max < (covered and LOW_HP_COVERED or LOW_HP_EXPOSED)
end

local function fightBattle(limit)
  limit = limit or 20000
  local frames = 0
  -- TryRunningFromBattle can fail on a speed check, and each failure costs
  -- the turn, so cap the attempts and fight on rather than be cornered
  -- burning turns we cannot afford.
  local runAttempts = 0
  -- Potions drunk this battle. Bounded so a fight we are losing anyway
  -- cannot drain the bag one turn at a time.
  local healsLeft = 3
  -- Switch the trainee in for its exp share, then straight back out. Only
  -- while grinding is off (grindALevel wants the trainee to actually fight)
  -- and only when there is somebody behind the lead worth levelling.
  --
  -- WILD battles only. Sharing splits the exp, so training through the
  -- trainer fights left the lead three levels down by Pewter and it died to
  -- Brock seven times in one run. Wild encounters are frequent and cheap;
  -- the fights that decide the run are not the place to hand away half the
  -- exp and two free enemy moves.
  local trainingPhase = "done"
  if not grinding and G.stack:top() and G.stack:top().kind == "wild"
     and not G.stack:top().ghost and not G.stack:top().safari
     and traineeSlot() then
    trainingPhase = "in"
  end
  -- The replacement menu sits ON TOP of the battle and has no `.kind`, so
  -- inBattle() alone would end the loop the moment our lead faints and hand
  -- a party menu to mashUntilIdle, which only knows how to press A.
  while (inBattle() or replacementMenu()) and frames < limit do
    if sendOutHealthy() then
      frames = frames + 10
      goto continue
    end
    local battle = G.stack:top()
    local phase = battle.phase
    -- Watch for the wipe here rather than after the battle: blacking out
    -- revives the party at the heal point, so a check made once the screen
    -- has popped always sees a healthy party and misses it entirely.
    if not blackedOut then
      local roster = G.save.party or {}
      local alive = false
      for _, mon in ipairs(roster) do
        if (mon.hp or 0) > 0 then alive = true break end
      end
      if #roster > 0 and not alive then blackedOut = true end
    end
    if phase == "menu" then
      if battle.safari then
        -- Safari battles have no FIGHT: the grid is BALL/BAIT/ROCK/RUN
        -- and the route catches nothing in the zone -- it is a corridor
        -- to the GOLD TEETH and HM03. RUN always succeeds in the Safari
        -- Zone, and every other choice spends a ball or a turn.
        if battleMenuTo(battle, 4) then press("a") end
      elseif battle.player.mon.hp <= 0 then
        -- our lead is down but the replacement menu has not opened yet;
        -- A brings it up, and sendOutHealthy above drives it once it does
        press("a")
      elseif battle.ghost then
        -- Pokémon Tower without the SILPH_SCOPE: FIGHT answers "too
        -- scared to move!", balls are dodged, and the ghost never goes
        -- down -- the battle cannot be won, only left. tryRun's
        -- IsGhostBattle branch always escapes, so RUN is guaranteed.
        --
        -- Except the static MAROWAK at (10,16): fleeing that one leaves
        -- it blocking the stairs and the trigger re-fires forever. The
        -- POKE_DOLL ends it for good (the wBattleResult trick, see
        -- data/scripts/story3.lua) -- and no WILD tower encounter is a
        -- MAROWAK, so the species is a safe discriminator.
        local foe = battle.enemy and battle.enemy.mon
        if foe and tostring(foe.species) == "MAROWAK"
           and ((G.save.inventory or {}).POKE_DOLL or 0) > 0
           and throwPokeDoll and throwPokeDoll(battle) then
          frames = frames + 10
        elseif battleMenuTo(battle, 4) then
          press("a")
        end
        -- First menu of the battle: send the trainee out purely to be
        -- marked a participant, then hand the fight straight back.
        --
        -- Only when it can survive being there. Switching in costs the
        -- trainee one free enemy attack, and against a foe far above it
        -- that is simply a faint -- after which traineeSlot's `hp > 0`
        -- drops it from the rotation for good, until some nurse happens to
        -- revive it. That is how NIDORAN_M sat at level 4 for an entire
        -- run while the lead reached 33: it was fed to the first big wild
        -- mon it met and never trained again. Being a level behind is the
        -- point of a trainee; being thirty behind means the exp share is
        -- worth less than the body.
        local slot = traineeSlot()
        local foe = battle.enemy and battle.enemy.mon
        local mon = slot and (G.save.party or {})[slot]
        local gap = (foe and mon) and ((foe.level or 0) - (mon.level or 0)) or 0
        if slot and gap > TRAINEE_MAX_GAP then
          slot = nil -- too dangerous to be worth the share
        end
        trainingPhase = (slot and switchTo(battle, slot)) and "out" or "done"
      elseif trainingPhase == "out" then
        -- Leave the trainee IN to actually fight when the encounter is weak
        -- enough to be safe. A share of the exp levels it far too slowly --
        -- Nidoran was still trailing badly by Cerulean -- and the route
        -- needs a real Nidoking, not a passenger. Taking the kill is worth
        -- several shares, so the rule is "fight anything at or below your
        -- own level while healthy, hand back anything above it".
        local me = battle.player and battle.player.mon
        local foe = battle.enemy and battle.enemy.mon
        local maxHP = me and me.stats and me.stats.hp or 0
        local safe = me and foe and maxHP > 0
                     and (foe.level or 99) <= (me.level or 0) + 1
                     and (me.hp or 0) / maxHP >= 0.5
        local lead = (G.save.party or {})[1]
        if not safe and lead and (lead.hp or 0) > 0 then
          switchTo(battle, 1)
        end
        trainingPhase = "done"
      elseif battle.kind ~= "wild" and healsLeft > 0
             and (battle.player.mon.hp or 0)
                 / math.max(1, battle.player.mon.stats.hp or 1) < IN_BATTLE_HEAL_AT
             and healInBattle(battle, "battle") then
        -- A trainer cannot be fled (tryRun refuses), so the only way to
        -- survive a gauntlet is to drink. Capped per battle so a losing
        -- fight empties the turn counter rather than the whole bag.
        healsLeft = healsLeft - 1
      elseif battle.kind == "wild" and runAttempts < 4 and lowOnHP(battle) then
        -- RUN is index 4 of the 2x2 grid; trainers refuse (tryRun), so
        -- this only ever fires on wild encounters
        runAttempts = runAttempts + 1
        if battleMenuTo(battle, 4) then press("a") end
      elseif battleMenuTo(battle, 1) then
        press("a")
      end
    elseif phase == "moveSelect" then
      local want = bestMoveIndex(battle)
      for _ = 1, 8 do
        if battle.moveIndex == want then break end
        press(battle.moveIndex > want and "up" or "down")
        U.wait(2)
        frames = frames + 2
      end
      press("a")
    else
      press("a") -- intro / messages / anything else: advance
    end
    U.wait(3)
    frames = frames + 4
    ::continue::
  end
  if frames >= limit then say("battle timed out") end
end

-- ---------------------------------------------------------------------
-- shared waits
-- ---------------------------------------------------------------------

-- Mash A until the overworld is idle again, fighting any battle that opens.
local function mashUntilIdle(limit)
  limit = limit or 6000
  local frames = 0
  while frames < limit do
    -- Never press A blind at a replacement menu: the cursor is on the mon
    -- that just fainted, so A re-picks it and the menu reopens forever.
    if replacementMenu() then sendOutHealthy() end
    if inBattle() then fightBattle() end
    if idle() then return true end
    press("a")
    U.wait(6)
    frames = frames + 7
  end
  say("mashUntilIdle timed out")
  return false
end

-- Turn without stepping: hold just long enough for the turn to register,
-- then release before tryMove commits to a move.
local function faceDir(dir)
  if not dir then return end
  for _ = 1, 4 do
    if ow().player.facing == dir then return end
    table.insert(G.input.pressQueue, dir)
    G.input.state[dir] = true
    coroutine.yield()
    G.input.state[dir] = false
    U.wait(3)
  end
end

-- Map lookups. Defined up here because both the shop and the Poké Center
-- helpers need them, and the shop comes first.
local function findWarpTo(pattern)
  for _, w in ipairs(ow().map.def.warps or {}) do
    if type(w.destMap) == "string" and w.destMap:find(pattern) then return w end
  end
end

local function findObject(pattern)
  for _, o in ipairs(ow().map.def.objects or {}) do
    if type(o.name) == "string" and o.name:find(pattern) then return o end
  end
end

-- ---------------------------------------------------------------------
-- ops
-- ---------------------------------------------------------------------

local ops = {}

-- Assigned further down, once the bag/nurse helpers they need exist.
-- Declared here so ops.battle can top up BEFORE picking a fight.
local autoHeal, riskThreshold

-- The map the NEXT segment expects, set by the segment loop. DIG and FLY
-- land wherever the save's heal point says rather than where the route
-- assumed, so the ops that use them need to know what they were aiming at.
local nextMapWanted
local travelDumped = false

-- Cut a tree that is walling us off from (tx, ty). Assigned below, once
-- ops.fieldMove exists to do the cutting; declared here because ops.goto_
-- calls it and comes first.
local cutToward

-- Reach a warp cell by ARRIVING through it. Assigned below (it needs
-- travelTo); declared here for the same reason as cutToward.
local arriveByWarp

-- Cross to another region of the same map through a gate. Assigned below
-- (needs walkOntoWarp); declared here because ops.goto_ calls it.
local reEnterThroughGate

-- Walk to (x, y). Coordinates outside the map are the route's idiom for
-- "leave through this edge into the connecting map", so we walk into the
-- edge and let the connection carry us rather than pathfinding to a cell
-- that does not exist.
function ops.goto_(s, _where, isLast)
  local o = ow()
  local map = o.map
  local outside = s.x < 0 or s.y < 0
                  or s.x >= map.widthCells or s.y >= map.heightCells
  if outside then
    local dir = (s.y < 0 and "up") or (s.y >= map.heightCells and "down")
                or (s.x < 0 and "left") or "right"
    local startMap = map.id

    -- Get to the border cell the route is pointing through FIRST.
    --
    -- Holding the direction from wherever we happen to be standing only
    -- works if the way out is already in front of us. With a wall in
    -- between it walks into that wall once per iteration -- 200 identical
    -- bumps before giving up, which is exactly what "Red walking into the
    -- same wall over and over and then recovering" looks like on screen.
    local tx = math.max(0, math.min(s.x, map.widthCells - 1))
    local ty = math.max(0, math.min(s.y, map.heightCells - 1))
    local refusedEdge = knownWalls(map.id) or {}
    for _ = 1, 300 do
      if ow().map.id ~= startMap then return true end
      local p = ow().player
      if p.cellX == tx and p.cellY == ty and not p.moving then break end
      if inBattle() then fightBattle()
      elseif busy() then mashUntilIdle()
      else
        local key = bfsNextKey(tx, ty, refusedEdge)
        if not key then
          -- No path to the border cell -- and on the way OUT of a map that
          -- is very often a Cut tree that has grown back. Gen 1 restores
          -- them on every map re-entry, so a tree the route cut on the way
          -- in is solid again on the way back: ROUTE_16 cuts one at segment
          -- 101, and returning east to CELADON_CITY then reported
          -- "ROUTE_16 -> CELADON_CITY did not cross" four times over, with
          -- the bot trapped in the western pocket and travelTo concluding
          -- "no way there from ROUTE_16".
          --
          -- cutToward already handles this for ordinary waypoints; the
          -- edge-exit branch is a separate path and never called it.
          local p2 = ow().player
          if p2.cellX ~= tx or p2.cellY ~= ty then
            if cutToward(tx, ty) then
              goto edgeStep -- re-plan now that the way is open
            end
            -- The border can also be walled off by a gate rather than a
            -- tree: ROUTE_16's east seam sits beyond the gate building, so
            -- leaving toward CELADON_CITY means going through it first.
            if reEnterThroughGate(tx, ty) then
              goto edgeStep
            end
          end
          break -- already there, or genuinely no path
        end
        if not walk(key) then
          local dv = DELTA[key]
          if dv then
            local cell = (p.cellY + dv[2]) * map.widthCells + (p.cellX + dv[1])
            refusedEdge[cell] = true
            noteWall(map.id, cell)
          end
        end
      end
      ::edgeStep::
    end

    -- Now push across the seam, but stop as soon as it is clearly not
    -- happening rather than hammering the border for a fixed 200 frames.
    local stalls = 0
    for _ = 1, 80 do
      if ow().map.id ~= startMap then return true end
      if inBattle() then fightBattle()
      elseif busy() then mashUntilIdle()
      else
        local p = ow().player
        local bx, by = p.cellX, p.cellY
        faceDir(dir)
        walk(dir)
        local q = ow().player
        if q.cellX == bx and q.cellY == by then
          stalls = stalls + 1
          if stalls >= 6 then break end
        else
          stalls = 0
        end
      end
    end
    say(("edge exit failed on %s: %s from (%d,%d) toward (%d,%d)")
        :format(tostring(startMap), dir,
                ow().player.cellX, ow().player.cellY, s.x, s.y))
    return false
  end

  local blocked = 0
  -- Cells the engine has refused this trip, seeded with the ones earlier
  -- runs already learned about on this map, so we plan around a known bad
  -- tile instead of rediscovering it by walking into it.
  local refused = knownWalls(map.id) or {}
  -- How often we have stood on each cell while pathing. A gate script that
  -- shoves the player back (the locked Viridian Gym at (32,8), Pewter's
  -- youngster, the Route 22 sign) defeats the `blocked` counter below: the
  -- step genuinely succeeds, so walk() returns true and blocked resets --
  -- then the script walks us straight back and we oscillate for the full
  -- 600 iterations. Bail once a cell has come round too many times.
  local visits, oscillating = {}, 12
  for _ = 1, 600 do
    -- Stop the instant a warp changed the map under us.
    --
    -- A waypoint can sit past a warp the route walks THROUGH rather than
    -- onto: VERMILION_DOCK's boarding warp is at (14,2) and segment 62 is
    -- `goto (14,0)` then `goto (14,3)`, so walking down to (14,3) steps onto
    -- (14,2) and boards the S.S. Anne mid-walk. Without this guard the goto
    -- kept chasing (14,3) -- now a cell ON THE SHIP -- and pathed from the
    -- arrival tile (27,0) straight into (26,0), the ship's OWN warp back to
    -- the dock, bouncing off. Every following segment then ran on the wrong
    -- map: the whole ship skipped, HM01 CUT was never collected, and the
    -- run died 15 segments later at the uncuttable Route 9 tree. The
    -- edge-exit branch already returns on a map change; the in-bounds loop
    -- must too, and the segment loop re-syncs to wherever the warp left us.
    if ow().map.id ~= map.id then return true end
    local p = ow().player
    if p.cellX == s.x and p.cellY == s.y then
      -- Arrived. If the tween into the cell is still running, wait it out
      -- rather than falling through to BFS -- bfsNextKey returns nil when
      -- start == goal, which the branch below would misread as "no path"
      -- and report as unreachable while we are standing on the target.
      if not p.moving then
        -- Landing on a warp cell that does not take us anywhere.
        --
        -- Warp.onArrive only fires for a tile in the tileset's warpTiles;
        -- everything else needs the direction still HELD while facing the
        -- map edge (Warp.onCollision + extraCheck), and walk() releases the
        -- key the moment the cell changes. Either way the segment then ends
        -- on the right tile, on the wrong map, and every following segment
        -- skips -- Mt. Moon B1F's exit at (27,3) is exactly this.
        --
        -- ONLY on a segment's last step. A segment's FIRST waypoint is
        -- routinely the warp we just arrived through -- Red's house
        -- segment 2 opens on (7,1), the stairs it just came down -- and
        -- shoving there rides them straight back up. That cost a whole
        -- attempt at segment 2 the first time this went in.
        local warped = isLast and map:warpAtCell(s.x, s.y)
        if warped then
          local from = ow().map.id
          local pushed = false
          for _ = 1, 8 do
            if ow().map.id ~= from then return true end
            local m = ow().map
            -- only a warp ON the map border needs the held direction; an
            -- interior door fires on its own and has no "outward" to push
            local outward = (s.x >= m.widthCells - 1 and "right")
                            or (s.x <= 0 and "left")
                            or (s.y >= m.heightCells - 1 and "down")
                            or (s.y <= 0 and "up")
            if not outward then break end
            pushed = true
            faceDir(outward)
            walk(outward, 8)
          end
          -- Only worth saying when we actually tried and it still refused.
          -- Interior doors reach here every time (they fire a moment later,
          -- during the next segment's map-wait), and warning about those
          -- just cries wolf -- two showed up in the first ten segments.
          if pushed and ow().map.id == from then
            local dest = (warped.def and warped.def.destMap) or warped.destMap
            say(("goto (%d,%d): stood on a border warp to %s on %s and it "
                 .. "did not fire"):format(s.x, s.y, tostring(dest), from))
          end
        end
        return true
      end
      U.wait(2)
    elseif inBattle() then
      fightBattle()
    elseif busy() then
      mashUntilIdle()
    else
      -- Count only the iterations where we actually choose a step from this
      -- cell -- not frames spent in a battle or waiting out a tween, which
      -- legitimately sit on one cell for a long time.
      local cell = p.cellY * ow().map.widthCells + p.cellX
      visits[cell] = (visits[cell] or 0) + 1
      if visits[cell] > oscillating then
        say(("goto (%d,%d) gave up on %s: pathed away from (%d,%d) %d times "
             .. "-- a gate script keeps pushing us back")
            :format(s.x, s.y, ow().map.id, p.cellX, p.cellY, visits[cell]))
        return false
      end
      local key = bfsNextKey(s.x, s.y, refused)
      if not key then
        -- an NPC can park on the target or the only path to it; give it a
        -- moment to wander off before giving up on this waypoint
        U.wait(30)
        -- That wait yields, so a script move or a tween can land us on the
        -- target meanwhile -- and bfsNextKey returns nil for "already
        -- there" just as it does for "no path". Re-check arrival first or
        -- we report the waypoint unreachable while standing on it (and
        -- `p` is live, so the message would print from == target).
        local arrived = p.cellX == s.x and p.cellY == s.y
        if not arrived and not bfsNextKey(s.x, s.y, refused) then
          -- BFS treats NPCs as walls, so an unreachable waypoint almost
          -- always means somebody is standing where the route expects
          -- empty floor -- usually an event NPC that should have been
          -- hidden by a script. Name them, so the log says who.
          local who = {}
          for _, npc in ipairs(ow().npcs) do
            who[#who + 1] = ("%s@(%d,%d)"):format(
              tostring(npc.def and npc.def.id or npc.def and npc.def.sprite or "?"),
              npc.cellX, npc.cellY)
          end
          -- ...or a Cut tree has grown back across the way.
          --
          -- Gen 1 restores cut trees whenever the map is re-entered, and we
          -- re-enter constantly: every Poké Center visit is a warp out and
          -- back. Vermilion is the case that forced this. Its gym sits in a
          -- pocket (x 6-15, y 20-23) whose ONLY opening is the tree at
          -- (15,18) -- verified against the block data, block 53, which is
          -- a cutTreeSwaps entry. So beating Surge, healing at the centre
          -- and then running segment 71 found `goto (12,20)` unreachable,
          -- every following segment skipped, and a won gym was thrown away.
          if cutToward(s.x, s.y) then
            blocked = 0
            goto keepGoing
          end
          -- ...or the target is in a part of this map no walk connects.
          --
          -- Cave floors are not one connected room. MT_MOON_B1F is four
          -- separate pockets stitched together through B2F and 1F, so
          -- standing on warp 5 at (21,17) there is genuinely NO path to
          -- warp 7 at (23,3) -- the log said so with "npcs: none". travelTo
          -- cannot help either: both cells are the same MAP, so it thinks
          -- we have already arrived. The way to such a cell is to come out
          -- of it, which is what this does.
          if arriveByWarp(s.x, s.y) then return true end
          -- ...or the way across is a gate whose warps all say LAST_MAP,
          -- which no plan can see through (ROUTE_16's two halves).
          if reEnterThroughGate(s.x, s.y) then
            blocked = 0
            goto keepGoing
          end
          -- ...or the waypoint IS an NPC's own cell. PokeBotBad's
          -- collision model does not wall off NPCs, so its waypoints
          -- sometimes name the tile a clerk is standing on -- Celadon
          -- Mart 2F's goto (6,3) is CELADONMART2F_CLERK2's cell, and the
          -- failed step cost the run its POKE_DOLL. Our BFS is right to
          -- refuse; "beside them, facing them" serves every use the
          -- route makes of such a waypoint (a talk/shop step follows).
          for _, npc in ipairs(ow().npcs) do
            if npc.cellX == s.x and npc.cellY == s.y then
              for _, d in ipairs({ { 0, 1, "up" }, { 0, -1, "down" },
                                   { -1, 0, "right" }, { 1, 0, "left" } }) do
                local ax, ay = s.x + d[1], s.y + d[2]
                if map:inBounds(ax, ay) and map:isWalkableCell(ax, ay)
                   and not ow():npcAtCell(ax, ay)
                   and ops.goto_({ x = ax, y = ay }) then
                  local p2 = ow().player
                  if p2.cellX == ax and p2.cellY == ay then
                    faceDir(d[3])
                    say(("goto (%d,%d) is %s's own cell; standing beside "
                         .. "at (%d,%d)"):format(s.x, s.y,
                        tostring(npc.def and (npc.def.id or npc.def.sprite)
                                 or "npc"), ax, ay))
                    return true
                  end
                end
              end
              break
            end
          end
          say(("goto (%d,%d) unreachable on %s; from (%d,%d); npcs: %s")
              :format(s.x, s.y, ow().map.id, p.cellX, p.cellY,
                      #who > 0 and table.concat(who, " ") or "none"))
          return false
        end
      elseif walk(key) then
        blocked = 0
        -- proved passable: forget any refusal an earlier run recorded here
        local now = ow()
        if now.map.id == map.id then
          clearWall(map.id, now.player.cellY * now.map.widthCells + now.player.cellX)
        end
      else
        -- BFS said this was walkable but the step did not land: a warp
        -- fired, an entity moved in, or the collision data disagrees
        -- (ledges are one-way, counters and doors are not plain floor).
        --
        -- Retrying alone is useless -- BFS is deterministic, so it hands
        -- back this exact step again and we bump the same wall until the
        -- counter runs out. Remember the cell it refused and re-plan; the
        -- next bfsNextKey call treats it as a wall and routes around.
        blocked = blocked + 1
        local dv = DELTA[key]
        if dv then
          local bx, by = p.cellX + dv[1], p.cellY + dv[2]
          local cell = by * map.widthCells + bx
          refused[cell] = true
          local seen = noteWall(map.id, cell)
          if blocked == 1 then
            say(("goto (%d,%d): %s refused the step into (%d,%d); routing "
                 .. "around it (refused %dx across runs)")
                :format(s.x, s.y, ow().map.id, bx, by, seen))
          end
        end
        if blocked >= 8 then
          say(("goto (%d,%d) stuck at (%d,%d) on %s")
              :format(s.x, s.y, p.cellX, p.cellY, ow().map.id))
          return false
        end
        U.wait(4)
      end
    end
    ::keepGoing::
  end
  say(("goto (%d,%d) timed out"):format(s.x, s.y))
  return false
end

-- Interact with whatever is adjacent, and report whether anything opened.
--
-- Most converted steps carry no direction: PokeBotBad's strategy functions
-- knew the geometry, so the route only records a dir for its generic
-- {s="talk",dir=...} verb. Walking a waypoint leaves us facing the way we
-- travelled, which is rarely the way the target sits -- arriving at Oak's
-- ball row from the west leaves us facing right while the ball is north.
-- So when no direction is given, try each facing until the press takes.
local function interact(face)
  local dirs = face and { face }
                or { ow().player.facing, "up", "down", "left", "right" }
  for _, d in ipairs(dirs) do
    faceDir(d)
    press("a")
    U.wait(10)
    if busy() or inBattle() then return true end
  end
  return false
end

function ops.battle(s, where)
  -- Top up BEFORE picking the fight rather than after losing it. This is
  -- the whole difference between a trainer costing us a potion and a
  -- trainer costing us the run, and it is where the danger memory pays
  -- off: on a map that has killed us the bar is much higher.
  autoHeal(where, riskThreshold(where))
  local opened = interact(s.face)
  if inBattle() then fightBattle() end
  mashUntilIdle()
  return opened
end

function ops.talk(s)
  local opened = interact(s.face)
  -- a talk can start a fight (a trainer, or the ball that triggers the
  -- rival), so never assume the overworld is what we come back to
  if inBattle() then fightBattle() end
  mashUntilIdle()
  return opened
end

ops.pickup = ops.talk

function ops.bike()
  -- toggling the bike needs the bag; without a handler we simply walk,
  -- which costs time but never blocks progress
  return true
end

-- The route names its catch targets in its own vocabulary; these are the
-- species the encounter tables actually use. `flier` is PokeBotBad's word
-- for "whatever around here can be taught FLY".
local CATCH_SPECIES = {
  nidoran = { "NIDORAN_M", "NIDORAN_F" },
  oddish  = { "ODDISH" },
  paras   = { "PARAS" },
  flier   = { "SPEAROW", "PIDGEY" },
}

-- Set by allowCatch, read by the catch handlers that follow it. The route
-- always pairs the two (`allowCatch nidoran` then `manual catchNidoran`),
-- so this is only a fallback for the handler's own species list.
local catchTarget

function ops.allowCatch(s)
  catchTarget = s.mon and CATCH_SPECIES[s.mon] or nil
  return true
end

-- ---------------------------------------------------------------------
-- shops
-- ---------------------------------------------------------------------
-- Which screen is on top. ShopMenu is a Menu of BUY/SELL/QUIT whose rows
-- carry .onSelect; the buy list is a ListMenu whose rows carry .value (the
-- item id); QuantityBox owns .qty; ChoiceBox owns .index with no rows.
local function top() return G.stack:top() end
local function rows() local t = top() return t and t.items end
local function isMenu()
  local r = rows() return r ~= nil and r[1] ~= nil and r[1].onSelect ~= nil
end
local function isList()
  local r = rows() return r ~= nil and r[1] ~= nil and r[1].value ~= nil
end
local function isQty() local t = top() return t ~= nil and t.qty ~= nil end
local function isChoice()
  local t = top() return t ~= nil and t.index ~= nil and t.items == nil
end

-- press `btn` until pred() holds
local function pressUntil(pred, btn, tries)
  for _ = 1, tries or 60 do
    if pred() then return true end
    press(btn)
    U.wait(4)
  end
  return pred()
end

-- move a vertical cursor to `want`, reading `field` off the top screen
local function cursorTo(field, want, tries)
  for _ = 1, tries or 40 do
    local t = top()
    if not t or t[field] == want then return t ~= nil end
    press(t[field] > want and "up" or "down")
    U.wait(3)
  end
  local t = top()
  return t ~= nil and t[field] == want
end

-- PokeBotBad's shop lists are exact counts tuned to a speedrun's money and
-- damage breakpoints. We only need to stay alive and be able to catch
-- things, so each stop buys a plain stock instead.
local SHOP_STOCK = {
  -- Viridian Mart stocks POKE_BALL, ANTIDOTE, PARLYZ_HEAL, BURN_HEAL and
  -- no POTION at all (vanilla) -- so there is no HP healing for sale until
  -- Pewter, and the only HP items before Viridian Forest are the two
  -- hidden POTIONs at VIRIDIAN_CITY (14,4) and VIRIDIAN_FOREST (1,18).
  -- The status heals are worth the money: ops.heal(status) can spend them,
  -- and a slept lead loses more turns than a dented one.
  viridianBalls = { { "POKE_BALL", 10 }, { "ANTIDOTE", 2 }, { "PARLYZ_HEAL", 2 } },
  -- ESCAPE_ROPE first, and it is not optional: segment 48 leaves Bill's
  -- house with `useItem escape_rope` and has no walk to the door, so
  -- without one in the bag the bot takes the S.S. ANNE TICKET and then
  -- stands in Bill's living room until the skip guard kills the attempt.
  -- Pewter is the only stop before Bill that sells them (Cerulean Mart
  -- stocks REPEL in that slot), so it gets first call on the money.
  pewter        = { { "ESCAPE_ROPE", 1 }, { "POTION", 8 } },
  -- SUPER_POTION, not POTION: VermilionMartClerkText stocks
  -- POKE_BALL, SUPER_POTION, ICE_HEAL, AWAKENING, PARLYZ_HEAL, REPEL
  -- (data/items/marts.asm:17) and carries no plain POTION at all. Asking
  -- for one bought nothing -- "shop: no POTION @ VERMILION_MART" -- so the
  -- bot left Vermilion with zero healing and spent the next stretch of the
  -- route dying: nine wipes in Surge's gym, five more around Cerulean, all
  -- of them fought at whatever HP the last nurse left. Healing comes first
  -- here; the balls are for later catches and can wait.
  vermilion     = { { "SUPER_POTION", 8 }, { "POKE_BALL", 5 } },
  -- Celadon Mart 2F (segment 92) is the best-stocked shop the route visits
  -- and the last one before the long Rocket Hideout / Pokémon Tower / Silph
  -- stretch, so it is where the run buys its staying power.
  --
  -- SUPER_REPEL is dropped on purpose: fewer wild encounters means less
  -- exp, and being underlevelled is what actually kills this bot. REVIVE is
  -- worth the 1500 -- a faint mid-dungeon otherwise means a walk back from
  -- the heal point through everything we just cleared.
  -- `reserve` keeps ¥800 back for the roof's vending machines four segments
  -- later (a FRESH_WATER is ¥200, and one drink opens every Saffron gate).
  -- REVIVE is dropped: at ¥1500 it alone emptied the wallet, and a revive
  -- is worth far less to this run than reaching Lavender at all.
  repels        = { reserve = 800, { "SUPER_POTION", 4 } },
  -- Celadon Mart 5F stocks X_ACCURACY / GUARD_SPEC / DIRE_HIT / the X
  -- stat items and the five vitamins -- no healing at all. It previously
  -- asked for FULL_RESTORE here, which 5F has never sold (that is the
  -- Indigo Plateau lobby), so the step bought nothing every run. The X
  -- items are exactly the speedrun tech we drop, so there is nothing here
  -- worth stopping for; kept as an empty list so the step is a no-op
  -- rather than a logged failure.
  buffs         = {},
  pokeDoll      = { { "POKE_DOLL", 1 } },
  -- TM07 and the vending machine are speedrun tech (Horn Drill, drinks for
  -- the Saffron guards); the guards are handled by the giveWater handler
  tm07 = {}, vending = {}, water = {},
  -- The Indigo lobby mart (ULTRA_BALL, GREAT_BALL, FULL_RESTORE,
  -- MAX_POTION, FULL_HEAL, REVIVE, MAX_REPEL). Not a route stop -- the
  -- speedrun arrives provisioned -- but our bot arrives with whatever
  -- survived Victory Road, and the Elite Four is five fights with no
  -- nurse between them. The segment loop shops here on its own when the
  -- lobby segment runs (see the INDIGO_PLATEAU_LOBBY anchor). No REVIVE:
  -- nothing in the driver knows how to use one.
  indigo = { { "FULL_RESTORE", 6 }, { "FULL_HEAL", 3 } },
}
local DEFAULT_STOCK = { { "POTION", 10 } }

-- Drive a QuantityBox to `want`.
--
-- It does NOT follow the list convention cursorTo implements. On a list,
-- up moves toward index 1; on a QuantityBox, up *increases* the count and
-- down decreases it, both wrapping around 1..max (QuantityBox.lua:29-33).
-- Handing it cursorTo therefore walked the wrong way and then oscillated
-- between 1 and max forever, so buyItem gave up and bought nothing -- the
-- exception being a target exactly one wrap below max, which is why the
-- occasional stop appeared to work and the failure looked intermittent.
local function qtyTo(want, tries)
  for _ = 1, tries or 120 do
    local t = top()
    if not t or not t.qty then return false end
    if t.qty == want then return true end
    press(t.qty < want and "up" or "down")
    U.wait(3)
  end
  local t = top()
  return t ~= nil and t.qty == want
end

-- Buy `qty` of `id` from an open buy list. Leaves the list open.
local function buyItem(id, qty, where)
  if not isList() then return false end
  local idx
  for i, row in ipairs(rows()) do
    if row.value == id then idx = i break end
  end
  if not idx then
    note("shop: no " .. id, where)
    return false
  end
  if not cursorTo("index", idx) then return false end
  press("a")
  U.wait(6)
  if not isQty() then
    note("shop: no quantity box for " .. id, where)
    return false
  end
  -- QuantityBox caps at .max (what we can afford), so never ask for more
  local want = math.min(qty, top().max or qty)
  if not qtyTo(want) then
    note("shop: could not set the quantity for " .. id, where)
    say(("shop: stuck setting %s quantity to %d on %s"):format(id, want,
        tostring(where)))
    return false
  end
  press("a")
  U.wait(6)
  if isChoice() then
    if not cursorTo("index", 1) then return false end -- YES
    press("a")
    U.wait(10)
  end
  -- back to the list (the purchase text may need clearing first)
  pressUntil(isList, "a", 20)
  return true
end

-- Back all the way out of the shop with B.
--
-- Never mash A to close one: on the buy list A IS a purchase, so the
-- generic mashUntilIdle() turns any wrong turn in here into an endless
-- shopping spree that empties the wallet and then sits on the "not enough
-- money" footer forever. B is the only safe key once a shop screen is up.
local function closeShop()
  for _ = 1, 40 do
    if not (isList() or isQty() or isChoice() or isMenu()) then return true end
    press("b")
    U.wait(6)
  end
  return false
end

-- Walk to a cell beside (ox, oy) and turn to face it.
--
-- The route's own waypoint is wherever PokeBotBad happened to stand, which
-- is not always next to the thing it then talks to. Viridian Mart is the
-- case that matters: the shop step walks to (2,5), but VIRIDIANMART_CLERK
-- is at (0,5) -- two tiles west, so interact() probed four empty cells and
-- the shop never opened. That failed quietly into `note`, so every stop on
-- the route had been buying nothing at all: no POKE_BALLs for the Nidoran
-- catch, and none of Pewter's eight POTIONs either, which is a large part
-- of why the party kept arriving at Brock with nothing to heal with.
local function stepUpTo(ox, oy)
  local m = ow().map
  for _, d in ipairs({ { 1, 0, "left" }, { -1, 0, "right" },
                       { 0, 1, "up" }, { 0, -1, "down" } }) do
    local cx, cy = ox + d[1], oy + d[2]
    if m:inBounds(cx, cy) and m:isWalkableCell(cx, cy)
       and not ow():npcAtCell(cx, cy) then
      local p = ow().player
      if not (p.cellX == cx and p.cellY == cy) then
        ops.goto_({ x = cx, y = cy })
        p = ow().player
      end
      if p.cellX == cx and p.cellY == cy then
        faceDir(d[3])
        return true
      end
    end
  end
  -- No walkable cell touches the object: it stands BEHIND A COUNTER, the
  -- normal case for every mart clerk (Celadon 2F/4F is where this bit --
  -- "FAILED at reaching the clerk" cost the run its SUPER_POTIONs and the
  -- POKE_DOLL the MAROWAK strategy depends on). Counter tiles are talked
  -- across (Map's counterTiles, same as the nurse's desk), so stand TWO
  -- cells away with the counter between us and face the object.
  for _, d in ipairs({ { 0, 2, "up" }, { 0, -2, "down" },
                       { 2, 0, "left" }, { -2, 0, "right" } }) do
    local cx, cy = ox + d[1], oy + d[2]
    if m:inBounds(cx, cy) and m:isWalkableCell(cx, cy) then
      local p = ow().player
      if not (p.cellX == cx and p.cellY == cy) then
        ops.goto_({ x = cx, y = cy })
        p = ow().player
      end
      if p.cellX == cx and p.cellY == cy then
        faceDir(d[3])
        return true
      end
    end
  end
  return false
end

function ops.shop(s, where)
  local stock = SHOP_STOCK[s.list] or DEFAULT_STOCK
  if #stock == 0 then return true end
  -- Stand next to the clerk first; the route's waypoint may not be
  -- adjacent to them (see stepUpTo).
  local clerk = findObject("CLERK") or findObject("CASHIER")
  if clerk then stepUpTo(clerk.x, clerk.y) end
  -- Shops failed silently into `note` for a long time, and a note only
  -- surfaces in the end-of-run summary -- long after the empty bag has
  -- already cost a catch or a gym. Name the stage that failed, live.
  local function stageFailed(stage)
    local t = top()
    local kind = (isList() and "list") or (isMenu() and "menu")
                 or (isQty() and "qty") or (isChoice() and "choice")
                 or (t and "other") or "nothing"
    say(("shop %s on %s: FAILED at %s (top=%s, rows=%d)"):format(
        tostring(s.list), tostring(where), stage, kind,
        rows() and #rows() or 0))
  end

  if not interact() then
    note("shop: no clerk", where)
    stageFailed("reaching the clerk")
    return false
  end
  if not pressUntil(isMenu, "a", 60) then
    note("shop: menu never opened", where)
    stageFailed("BUY/SELL/QUIT menu")
    closeShop()
    mashUntilIdle()
    return false
  end
  if not cursorTo("index", 1) then
    stageFailed("cursor to BUY")
    closeShop()
    return false
  end
  press("a")
  U.wait(10)
  if not pressUntil(isList, "a", 30) then
    note("shop: buy list never opened", where)
    stageFailed("buy list")
    closeShop()
    mashUntilIdle()
    return false
  end
  -- Stop buying once the reserve is reached.
  --
  -- Some later step needs money more than this shop does, and a shop with
  -- no brake spends it all. Celadon Mart 2F is exactly that: it comes at
  -- segment 92 and the roof's vending machines at 96, so stocking up on
  -- SUPER_POTIONs left ¥68 and the vending machine could not sell a
  -- ¥200 FRESH_WATER -- "3 vending purchases, 0 drink(s) in the bag". That
  -- drink is not a comfort item: it opens all four Saffron gates, and with
  -- Saffron shut the run cannot reach Lavender for the POKE_FLUTE, so the
  -- potions bought instead cost the back half of the game.
  for _, want in ipairs(stock) do
    if (G.save.money or 0) <= (stock.reserve or 0) then
      say(("shop %s on %s: stopping at ¥%d to keep the ¥%d reserve")
          :format(tostring(s.list), tostring(where), G.save.money or 0,
                  stock.reserve or 0))
      break
    end
    buyItem(want[1], want[2], where)
  end
  local closed = closeShop()
  if not closed then note("shop: would not close", where) end
  mashUntilIdle() -- safe now: every shop screen is off the stack
  -- Report what we actually walked out with. A shop that silently buys
  -- nothing is the failure mode this op has already had once, and it only
  -- shows up much later as an empty bag at the point of need.
  local got = {}
  for _, want in ipairs(stock) do
    got[#got + 1] = ("%s x%d"):format(want[1], (G.save.inventory or {})[want[1]] or 0)
  end
  say(("shop %s on %s: %s (¥%d left)"):format(
      tostring(s.list), tostring(where), table.concat(got, ", "),
      G.save.money or 0))
  return closed
end

-- ---------------------------------------------------------------------
-- healing
-- ---------------------------------------------------------------------
-- The route's `heal` steps are bag heals, not Poké Center visits: only 3
-- of the 197 segments are centers, and PokeBotBad tops up from items as it
-- walks. A step can carry `status` (cure a status), `full` (spend a
-- FULL_RESTORE) or `hp = N` (only bother once N HP is missing).
--
-- We drive the real menus instead of calling ItemEffects.use directly.
-- Calling the API would heal just as well and be far less fiddly, but the
-- whole point of the run is to assert that warps, scripts, battles AND
-- menus work end to end -- a bag that stopped opening would go unnoticed.

-- weakest first, so a heal spends the cheapest thing that will do
local HP_ITEMS = { "POTION", "SUPER_POTION", "HYPER_POTION", "MAX_POTION",
                   "FULL_RESTORE" }
local STATUS_ITEMS = { "ANTIDOTE", "PARLYZ_HEAL", "AWAKENING", "BURN_HEAL",
                       "ICE_HEAL", "FULL_HEAL" }

local function party() return G.save.party or {} end
local function heldCount(id) return (G.save.inventory or {})[id] end

-- the living mon that has lost the most HP, and how much it is missing
local function mostHurt()
  local slot, worst
  for i, mon in ipairs(party()) do
    local max = mon.stats and mon.stats.hp
    if max and mon.hp and mon.hp > 0 then
      local missing = max - mon.hp
      if missing > 0 and (not worst or missing > worst) then slot, worst = i, missing end
    end
  end
  return slot, worst or 0
end

local function firstStatused()
  for i, mon in ipairs(party()) do
    if mon.hp and mon.hp > 0 and mon.status and mon.status ~= "" then return i end
  end
end

-- B out of whatever menus are open, back to the plain overworld
local function backOut()
  for _ = 1, 25 do
    if top() == ow() then return true end
    press("b")
    U.wait(5)
  end
  return top() == ow()
end

-- The USE/TOSS submenu is pushed with a raw stack:push, so unlike every
-- other screen here it carries no .screenId -- identify it by its rows.
local function isUseToss()
  local r = rows()
  return r ~= nil and r[1] ~= nil and r[1].label == "USE"
end

-- START -> ITEM -> <item> -> USE -> <party slot>. Returns true if used.
local function useItemOn(itemId, slot, where)
  press("start")
  U.wait(8)
  local menu = top()
  if not (menu and menu.screenId == "StartMenu") then
    note("heal: start menu never opened", where)
    backOut()
    return false
  end
  -- the ITEM row shifts with the POKéDEX/LINK/MODS rows (and the list runs
  -- through the ui.start_menu.items mod hook), so never hardcode its index
  local itemRow
  for i, it in ipairs(menu.items or {}) do
    if it.label == "ITEM" then itemRow = i break end
  end
  if not itemRow or not cursorTo("index", itemRow) then
    note("heal: no ITEM row", where)
    backOut()
    return false
  end
  press("a")
  U.wait(10)

  local bag = top()
  if not (bag and bag.screenId == "BagMenu") then
    note("heal: bag never opened", where)
    backOut()
    return false
  end
  local bagRow
  for i, r in ipairs(bag.items or {}) do
    if r.value == itemId then bagRow = i break end
  end
  if not bagRow or not cursorTo("index", bagRow) then
    note("heal: " .. itemId .. " not in bag", where)
    backOut()
    return false
  end
  press("a")
  U.wait(8)

  -- outside battle a healing item always offers USE/TOSS first; USE is row 1
  if isUseToss() then
    if not cursorTo("index", 1) then backOut() return false end
    press("a")
    U.wait(8)
  end

  local pm = top()
  if not (pm and pm.screenId == "PartyMenu") then
    note("heal: party menu never opened", where)
    backOut()
    return false
  end
  if not cursorTo("index", slot) then backOut() return false end
  press("a")
  U.wait(10)
  -- clear the "HP was restored!" box, then unwind the bag + start menu
  pressUntil(function() return not (top() and top().screenId == "PartyMenu") end, "a", 15)
  backOut()
  return true
end

-- Drink a potion DURING a battle.
--
-- fightBattle only ever had one answer to a hurt lead: flee. That works on
-- a wild encounter and is impossible against a trainer, so a gauntlet map
-- simply ground the lead down and killed it -- ROUTE_9 is one long chain of
-- trainers and it wiped the run fifteen times in a single attempt while
-- eight SUPER_POTIONs sat unused in the bag. The lead was level 33 against
-- level-20 trainers; it was not outmatched, it was just never healed.
--
-- Losing the turn is the right trade here. A faint costs the whole battle,
-- and behind our lead sits a level-4 NIDORAN -- when the lead goes down the
-- run is over, so the turn is cheap by comparison.
--
-- The bag in battle is the ITEM slot of the action grid (index 3), the same
-- door throwBall uses; the potion then asks for a target through a
-- pickOnly PartyMenu (BagMenu:useItem -> Screens.push "PartyMenu").
function healInBattle(battle, where)
  local mon = battle.player and battle.player.mon
  if not mon or not mon.stats then return false end
  local gap = (mon.stats.hp or 0) - (mon.hp or 0)
  if gap <= 0 then return false end
  -- smallest item that covers the gap, so a MAX_POTION is not spent on a
  -- scratch (same order ops.heal uses)
  local pick
  for _, id in ipairs(HP_ITEMS) do
    if (heldCount(id) or 0) > 0 then
      local amount = (id == "POTION" and 20) or (id == "SUPER_POTION" and 50)
                     or (id == "HYPER_POTION" and 200) or 999
      if not pick then pick = id end
      if amount >= gap then pick = id break end
    end
  end
  if not pick then return false end
  local beforeHP = mon.hp or 0
  local beforeCount = heldCount(pick) or 0
  if not battleMenuTo(battle, 3) then return false end
  press("a")
  if not waitFor(isList, 40) then backOut() return false end
  local idx
  for i, row in ipairs(rows() or {}) do
    if row.value == pick then idx = i break end
  end
  if not idx or not cursorTo("index", idx) then backOut() return false end
  press("a")
  U.wait(10)
  -- the party picker: heal the mon that is actually out, which is slot 1's
  -- position in the list only when nothing has been switched, so find it
  local pm = top()
  if pm and pm.onSwitch ~= nil and pm.index ~= nil then
    local slot = 1
    for i, m in ipairs(party()) do
      if m == mon then slot = i break end
    end
    if not cursorTo("index", slot) then backOut() return false end
    press("a")
    U.wait(12)
  end
  -- Sample the result BEFORE handing the turn back.
  --
  -- The first version logged HP after mashUntilIdle, which runs the rest of
  -- the turn including the enemy's attack -- so every heal printed "(0/79)"
  -- and there was no way to tell a potion that never applied from one that
  -- worked before we were killed anyway. Watch for the HP to actually rise,
  -- and check the bag, so the log says which it was.
  local rose = waitFor(function() return (mon.hp or 0) > beforeHP end, 30)
  local healedTo = mon.hp or 0
  local spent = (heldCount(pick) or 0) < beforeCount
  mashUntilIdle(400)
  if rose then
    say(("healed %s with %s mid-battle: %d -> %d/%d"):format(
        tostring(mon.species), pick, beforeHP, healedTo, mon.stats.hp or 0))
  else
    say(("mid-battle %s did NOT heal %s (%d/%d, item %s) -- now %d/%d"):format(
        pick, tostring(mon.species), beforeHP, mon.stats.hp or 0,
        spent and "was consumed" or "still in the bag",
        mon.hp or 0, mon.stats.hp or 0))
  end
  return rose
end

-- Battle menu -> ITEM -> POKE_DOLL. Used by fightBattle against the
-- static ghost MAROWAK; ItemEffects ends the battle as an escape and
-- BagMenu marks battle.pokeDollEscape for the 6F script's win check.
function throwPokeDoll(battle)
  if not battleMenuTo(battle, 3) then return false end
  press("a")
  if not waitFor(isList, 40) then backOut() return false end
  local idx
  for i, row in ipairs(rows() or {}) do
    if row.value == "POKE_DOLL" then idx = i break end
  end
  if not idx or not cursorTo("index", idx) then backOut() return false end
  press("a")
  U.wait(12)
  say("threw the POKE DOLL")
  mashUntilIdle(400)
  return true
end

function ops.heal(s, where)
  -- status cures first: a slept/paralysed lead loses more turns than a
  -- dented one, and the route only asks for them when it matters
  if s.status then
    local slot = firstStatused()
    if not slot then return true end -- nothing to cure; not a failure
    for _, id in ipairs(STATUS_ITEMS) do
      if heldCount(id) then return useItemOn(id, slot, where) end
    end
    note("heal: no status item", where)
    return true
  end

  local slot, missing = mostHurt()
  if not slot then return true end -- party is topped up already
  -- `hp = N` is the route's "only bother once N HP is down" threshold
  if s.hp and missing < s.hp then return true end

  local order = HP_ITEMS
  if s.full then order = { "FULL_RESTORE", "MAX_POTION", "HYPER_POTION" } end
  -- prefer the smallest item that covers the gap, so early POTIONs are not
  -- wasted on 2 HP and a FULL_RESTORE is not wasted on a scratch
  local pick
  for _, id in ipairs(order) do
    if heldCount(id) then
      pick = pick or id -- fallback: the weakest thing we actually own
      local amount = (id == "POTION" and 20) or (id == "SUPER_POTION" and 50)
                     or (id == "HYPER_POTION" and 200) or 999
      if amount >= missing then pick = id break end
    end
  end
  if not pick then
    note("heal: no HP item", where)
    return true
  end
  return useItemOn(pick, slot, where)
end

-- ---------------------------------------------------------------------
-- Poké Centers
-- ---------------------------------------------------------------------
-- Viridian Mart sells POKE_BALL/ANTIDOTE/PARLYZ_HEAL/BURN_HEAL and no
-- POTION (vanilla), and the first POTION on sale is in Pewter -- on the
-- far side of Viridian Forest. For the whole first act the nurse is the
-- only way to restore HP, so healing cannot be just another route verb:
-- it has to be able to leave the route, walk to a counter, and come back
-- to the tile it left from.

-- Walk onto a warp tile, stopping the instant the map changes.
--
-- ops.goto_ must NOT be used for this: it re-reads ow() every iteration,
-- so once the warp fires it carries on pathfinding toward the *old* map's
-- coordinates on the new map -- which for a door at (23,25) landing in a
-- 12x8 Poké Center is off the edge, and the out-of-bounds branch then
-- spends 200 frames trying to leave by the nearest border.
local function walkOntoWarp(wx, wy)
  local from = ow().map.id
  local stuckOnWarp = 0
  for _ = 1, 300 do
    if ow().map.id ~= from then return true end
    if inBattle() then fightBattle()
    elseif busy() then mashUntilIdle()
    else
      local p = ow().player
      if p.cellX == wx and p.cellY == wy then
        -- Standing on the mat is not enough for a building exit: it fires
        -- on the step that LEAVES the doorway, so push toward the nearest
        -- edge (down for a door on the bottom row) instead of waiting.
        --
        -- Without this we sit on the mat until the loop expires and the
        -- rest of the route then runs indoors, where the city's waypoints
        -- are out of bounds on a 12x8 Poké Center and read as the route's
        -- "leave by this edge" idiom -- which is Red shoving downward into
        -- the wall below the door instead of walking out of it.
        local m = ow().map
        local outward = (wy >= m.heightCells - 1 and "down")
                        or (wy <= 0 and "up")
                        or (wx <= 0 and "left")
                        or (wx >= m.widthCells - 1 and "right")
                        or "down"
        faceDir(outward)
        walk(outward)
        -- If pushing outward does nothing, the warp we are standing on is
        -- INERT -- we arrived onto it, and the engine keeps a warp inert
        -- until you step off (OverworldController warpEntryCell). That is
        -- correct for not bouncing, but here we WANT to leave the same way,
        -- which is exactly the Route 16 gate: the plan routes back out the
        -- door we came in, and walkOntoWarp shoved a dead warp forever
        -- ("warp@0,8 did not move" x90). Step off to an adjacent cell and
        -- back on to re-arm it, then the next loop takes it normally.
        if ow().map.id == from and (p.cellX == wx and p.cellY == wy) then
          stuckOnWarp = (stuckOnWarp or 0) + 1
          if stuckOnWarp >= 3 then
            for _, d in ipairs(DIRS) do
              local ax, ay = wx + d[1], wy + d[2]
              if m:inBounds(ax, ay) and m:isWalkableCell(ax, ay)
                 and not m:warpAtCell(ax, ay) then
                walk(d[3])        -- step OFF the warp (re-arms it)
                if ow().player.cellX == ax and ow().player.cellY == ay then
                  stuckOnWarp = 0
                  break
                end
              end
            end
          end
        else
          stuckOnWarp = 0
        end
      else
        local key = bfsNextKey(wx, wy)
        if not key then
          -- The warp may be walled off by a Cut tree -- the Vermilion Gym
          -- door at (12,19) sits behind one -- so walkOntoWarp could never
          -- reach it and travelTo(VERMILION_GYM) spun "did not move"
          -- forever. Cut a blocking tree and retry; only give up if there
          -- is none (a genuinely unreachable warp).
          if cutToward and cutToward(wx, wy) then
            -- way opened; loop re-paths
          else
            return false
          end
        elseif not walk(key) then
          U.wait(4)
        end
      end
    end
  end
  return ow().map.id ~= from
end

-- ---------------------------------------------------------------------
-- cross-map travel
-- ---------------------------------------------------------------------
--
-- The route travels by HEAL POINT: segment 72 leaves the Pokémon Fan Club
-- with `fieldMove dig`, and DIG warps to wLastBlackoutMap. A speedrun never
-- heals at Vermilion, so the route can assume that lands in Cerulean; our
-- survival systems visit any nurse the party is hurt in front of, so it
-- does not. Those two facts cannot both stand, and suppressing the nurse
-- is the wrong half to give up -- so travel to a named map instead of
-- trusting where a warp happened to drop us.
--
-- Plans over map ADJACENCY -- connections and warps together -- because
-- Vermilion -> Cerulean is ROUTE_6 -> UNDERGROUND_PATH_ROUTE_6 ->
-- UNDERGROUND_PATH_NORTH_SOUTH -> UNDERGROUND_PATH_ROUTE_5 -> ROUTE_5 ->
-- CERULEAN_CITY, whose middle is warps and whose ends are connections. A
-- connection-only search cannot find it at all.

local COMPASS_DIR = { north = "up", south = "down", west = "left", east = "right" }

-- Walkability of an arbitrary map's cell, without loading it.
--
-- Mirrors Map:cellTile + Map:isWalkableCell (src/world/Map.lua) -- the
-- bottom-left 8x8 tile of the cell, against the tileset's walkable list.
-- We need this for maps we are NOT standing on, and MapLoader builds only
-- the current one, so the lookup is reproduced here rather than shared.
local function defWalkable(def, cx, cy)
  local ts = G.data.tilesets and G.data.tilesets[def.tileset]
  if not ts or not ts.blocks or not ts.walkable then return false end
  local tx, ty = cx * 2, cy * 2 + 1
  local bx, by = math.floor(tx / 4), math.floor(ty / 4)
  local id
  if bx < 0 or by < 0 or bx >= def.width or by >= def.height then
    id = def.borderBlock
  else
    id = def.blocks[by * def.width + bx + 1]
  end
  local block = ts.blocks[(id or 0) + 1]
  if not block then return false end
  local tile = block[(ty % 4) * 4 + (tx % 4) + 1]
  for _, w in ipairs(ts.walkable) do
    if w == tile then return true end
  end
  return false
end

-- The border cells of `def` on `dir` whose opposite number across the seam
-- is walkable too, nearest first once the caller sorts them.
--
-- crossConnection places you at destX = curX - offset*2 (clamped), so the
-- pairing is exact and a seam with no walkable pair can never be crossed
-- however hard we push at it. This is what keeps the search from planning
-- Vermilion -> Saffron -> Cerulean through a walled city.
local function seamCells(def, dir, conn)
  local dest = G.data.maps and G.data.maps[conn.map]
  if not dest then return {} end
  local aW, aH = def.width * 2, def.height * 2
  local bW, bH = dest.width * 2, dest.height * 2
  local out = {}
  if dir == "north" or dir == "south" then
    local ay = (dir == "north") and 0 or aH - 1
    local by = (dir == "north") and bH - 1 or 0
    for x = 0, aW - 1 do
      local dx = x - conn.offset * 2
      if dx >= 0 and dx < bW
         and defWalkable(def, x, ay) and defWalkable(dest, dx, by) then
        out[#out + 1] = { x, ay }
      end
    end
  else
    local ax = (dir == "west") and 0 or aW - 1
    local bx = (dir == "west") and bW - 1 or 0
    for y = 0, aH - 1 do
      local dy = y - conn.offset * 2
      if dy >= 0 and dy < bH
         and defWalkable(def, ax, y) and defWalkable(dest, bx, dy) then
        out[#out + 1] = { ax, y }
      end
    end
  end
  return out
end

-- The collision tile of an arbitrary map's cell (for ledge matching),
-- mirroring Map:cellTile without loading the map.
local function defCellTile(def, cx, cy)
  local ts = G.data.tilesets and G.data.tilesets[def.tileset]
  if not ts or not ts.blocks then return nil end
  local tx, ty = cx * 2, cy * 2 + 1
  local bx, by = math.floor(tx / 4), math.floor(ty / 4)
  local id
  if bx < 0 or by < 0 or bx >= def.width or by >= def.height then
    id = def.borderBlock
  else
    id = def.blocks[by * def.width + bx + 1]
  end
  local block = ts.blocks[(id or 0) + 1]
  return block and block[(ty % 4) * 4 + (tx % 4) + 1]
end

-- ---------------------------------------------------------------------
-- region-aware map graph
-- ---------------------------------------------------------------------
--
-- A plain map graph treats each map as ONE node, which is wrong for maps a
-- gate building or a ledge splits into parts no single walk connects.
-- ROUTE_16 is three such regions, SAFFRON's four routes each cross through
-- a gate, ROUTE_8/11/12 are each cut in two. Planning over map nodes there
-- makes travelTo try a connection it cannot reach from its current side,
-- fail, and re-plan the long way -- which walked a Saffron trip back to
-- ROUTE_9, half the map away.
--
-- So nodes are (map, REGION): a connected component of the map's walkable
-- cells. Warps, connections and ledges connect specific regions, so a plan
-- can only cross where the current side actually reaches.

-- mapId -> { reg = {cellId -> regionIndex}, wc, n }. Flood-filled once.
local REGION_CACHE = {}
local function mapRegions(mapId)
  if REGION_CACHE[mapId] then return REGION_CACHE[mapId] end
  local def = G.data.maps[mapId]
  local wc, hc = def.width * 2, def.height * 2
  local reg, n = {}, 0
  for y = 0, hc - 1 do
    for x = 0, wc - 1 do
      local id = y * wc + x
      if defWalkable(def, x, y) and not reg[id] then
        n = n + 1
        reg[id] = n
        local stack = { { x, y } }
        while #stack > 0 do
          local c = stack[#stack]; stack[#stack] = nil
          for _, d in ipairs(DIRS) do
            local nx, ny = c[1] + d[1], c[2] + d[2]
            local nid = ny * wc + nx
            if nx >= 0 and ny >= 0 and nx < wc and ny < hc
               and defWalkable(def, nx, ny) and not reg[nid] then
              reg[nid] = n
              stack[#stack + 1] = { nx, ny }
            end
          end
        end
      end
    end
  end
  local r = { reg = reg, wc = wc, n = n }
  REGION_CACHE[mapId] = r
  return r
end

local function cellRegionOf(mapId, x, y)
  local r = mapRegions(mapId)
  return r.reg[y * r.wc + x]
end

local function regionNode(mapId, reg) return mapId .. "#" .. tostring(reg) end

-- The region graph: node -> list of edges, each carrying how to EXECUTE the
-- crossing (a warp cell, a connection dir+seam, or a ledge hop).
local REGION_GRAPH
local function regionGraph()
  if REGION_GRAPH then return REGION_GRAPH end
  local maps = G.data.maps
  local g, into = {}, {}
  local function add(a, b, e) e.to = b; g[a] = g[a] or {}; g[a][#g[a] + 1] = e end
  -- who warps into each map, for LAST_MAP resolution
  for id, def in pairs(maps) do
    for _, w in ipairs(def.warps or {}) do
      if type(w.destMap) == "string" and w.destMap ~= "LAST_MAP" and maps[w.destMap] then
        into[w.destMap] = into[w.destMap] or {}
        into[w.destMap][id] = true
      end
    end
  end
  for id, def in pairs(maps) do
    -- warps (concrete destination)
    for _, w in ipairs(def.warps or {}) do
      local d = w.destMap
      local sr = cellRegionOf(id, w.x, w.y)
      if d == "LAST_MAP" then
        -- resolve against each map that feeds this one, at destWarp's cell
        for src in pairs(into[id] or {}) do
          local dw = maps[src].warps and maps[src].warps[w.destWarp]
          local dr = dw and cellRegionOf(src, dw.x, dw.y)
          if sr and dr then
            add(regionNode(id, sr), regionNode(src, dr),
                { warp = { x = w.x, y = w.y }, cost = 3, dynamic = true })
          end
        end
      elseif type(d) == "string" and maps[d] then
        local dw = maps[d].warps and maps[d].warps[w.destWarp]
        local dr = dw and cellRegionOf(d, dw.x, dw.y)
        if sr and dr then
          local c = (id:find("ELEVATOR") or d:find("ELEVATOR")) and 50 or 1
          add(regionNode(id, sr), regionNode(d, dr),
              { warp = { x = w.x, y = w.y }, cost = c })
        end
      end
    end
    -- connections (seam pairs, grouped by region pair)
    for dir, conn in pairs(def.connections or {}) do
      if maps[conn.map] and COMPASS_DIR[dir] then
        local cells = seamCells(def, dir, conn)
        local dest = maps[conn.map]
        local seen = {}
        for _, c in ipairs(cells) do
          local sr = cellRegionOf(id, c[1], c[2])
          -- the paired cell on the far side
          local bx, by
          if dir == "north" then bx, by = c[1] - conn.offset * 2, dest.height * 2 - 1
          elseif dir == "south" then bx, by = c[1] - conn.offset * 2, 0
          elseif dir == "west" then bx, by = dest.width * 2 - 1, c[2] - conn.offset * 2
          else bx, by = 0, c[2] - conn.offset * 2 end
          local dr = cellRegionOf(conn.map, bx, by)
          local k = tostring(sr) .. ">" .. tostring(dr)
          if sr and dr and not seen[k] then
            seen[k] = true
            add(regionNode(id, sr), regionNode(conn.map, dr),
                { dir = COMPASS_DIR[dir], cells = cells, cost = 1 })
          end
        end
      end
    end
    -- ledge hops (one-way region connectors)
    local wc, hc = def.width * 2, def.height * 2
    for y = 0, hc - 1 do
      for x = 0, wc - 1 do
        if defWalkable(def, x, y) then
          for _, d in ipairs(DIRS) do
            local fx, fy = x + d[1], y + d[2]
            if fx >= 0 and fy >= 0 and fx < wc and fy < hc then
              local st, ft = defCellTile(def, x, y), defCellTile(def, fx, fy)
              for _, ledge in ipairs(G.data.field.ledges or {}) do
                if (ledge.tileset or "OVERWORLD") == def.tileset
                   and ledge.facing == d[3] and ledge.input == d[3]
                   and ledge.standingTile == st and ledge.ledgeTile == ft then
                  local lx, ly = fx + d[1], fy + d[2]
                  if lx >= 0 and ly >= 0 and lx < wc and ly < hc
                     and defWalkable(def, lx, ly) then
                    local sr, dr = cellRegionOf(id, x, y), cellRegionOf(id, lx, ly)
                    if sr and dr and sr ~= dr then
                      add(regionNode(id, sr), regionNode(id, dr),
                          { ledge = { x = x, y = y, dir = d[3] }, cost = 1 })
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
    -- Cut trees bridge regions. A cuttable tree is a wall in the static
    -- tiles, so the flood fill splits the map at it -- but CUT opens it,
    -- and the route relies on that: ROUTE_16 cuts a tree at ~(34,8) that
    -- joins the Celadon-side strip to the east-top, the only walking link
    -- between Route 16's two halves. Without this the fly-house pocket is a
    -- dead end and the run dies there. Connect the regions on either side
    -- of each cut tree, both ways, executed by walking onto the far cell
    -- (ops.goto_ cuts the tree in the way).
    local swaps = G.data.field.cutTreeSwaps or {}
    local isCut = {}
    for _, sw in ipairs(swaps) do isCut[sw.before] = true end
    for y = 0, hc - 1 do
      for x = 0, wc - 1 do
        local block = defWalkable(def, x, y) and nil
                      or (function()
                            local bx, by = math.floor(x / 2), math.floor(y / 2)
                            if bx < 0 or by < 0 or bx >= def.width or by >= def.height then
                              return def.borderBlock
                            end
                            return def.blocks[by * def.width + bx + 1]
                          end)()
        if block and isCut[block] then
          -- walkable orthogonal neighbours of the tree cell
          local nbr = {}
          for _, d in ipairs(DIRS) do
            local nx, ny = x + d[1], y + d[2]
            if nx >= 0 and ny >= 0 and nx < wc and ny < hc
               and defWalkable(def, nx, ny) then
              local r = cellRegionOf(id, nx, ny)
              if r then nbr[#nbr + 1] = { x = nx, y = ny, r = r } end
            end
          end
          for a = 1, #nbr do
            for b = 1, #nbr do
              if a ~= b and nbr[a].r ~= nbr[b].r then
                add(regionNode(id, nbr[a].r), regionNode(id, nbr[b].r),
                    { cut = { x = nbr[b].x, y = nbr[b].y }, cost = 2 })
              end
            end
          end
        end
      end
    end
  end
  REGION_GRAPH = g
  return g
end

-- Cheapest region-path from the current position to any region of `dest`.
-- Returns a list of edges (each with warp/dir/ledge execution info).
local function planRegionRoute(fromNode, dest, banned)
  local g = regionGraph()
  local dist, prev = { [fromNode] = 0 }, {}
  local settled = {}
  local goal
  while true do
    local cur, best
    for k, dv in pairs(dist) do
      if not settled[k] and (best == nil or dv < best) then cur, best = k, dv end
    end
    if not cur then break end
    if cur:match("^(.-)#") == dest then goal = cur; break end
    settled[cur] = true
    for _, e in ipairs(g[cur] or {}) do
      local bk = cur .. "|" .. (e.warp and (e.warp.x .. "," .. e.warp.y)
                 or e.ledge and ("L" .. e.ledge.x .. "," .. e.ledge.y)
                 or e.cut and ("T" .. e.cut.x .. "," .. e.cut.y)
                 or ("C" .. tostring(e.dir))) .. "|" .. e.to
      if not (banned and banned[bk]) then
        local nd = best + e.cost + seamCost(cur:match("^(.-)#"), e.to:match("^(.-)#"))
        if dist[e.to] == nil or nd < dist[e.to] then
          dist[e.to] = nd
          prev[e.to] = { node = cur, edge = e, bk = bk }
        end
      end
    end
  end
  if not goal then return nil end
  local path, cur = {}, goal
  while prev[cur] do
    local p = prev[cur]
    table.insert(path, 1, { edge = p.edge, bk = p.bk })
    cur = p.node
  end
  return path
end

-- map id -> list of outgoing edges. Built once; the map data never changes.
local MAP_GRAPH

local function mapGraph()
  if MAP_GRAPH then return MAP_GRAPH end
  local maps = G.data.maps or {}
  local g, into = {}, {}
  for id, def in pairs(maps) do
    g[id] = g[id] or {}
    for _, w in ipairs(def.warps or {}) do
      local d = w.destMap
      if type(d) == "string" and d ~= "LAST_MAP" and maps[d] then
        -- Elevators are costly, so travelTo prefers stairs. Walking into an
        -- elevator is a bounce-trap for a plain warp cross: the car opens a
        -- floor MENU and its default exit dumps you on the reciprocal warp,
        -- oscillating ELEVATOR <-> floor. rideElevator drives the menu when
        -- we are actually in the car, but travelTo must route AROUND the
        -- elevator wherever stairs exist (all of Celadon Mart). Priced high
        -- rather than deleted so a floor only the elevator can reach (Silph's
        -- top) is still on the graph.
        local elev = (id:find("ELEVATOR") or d:find("ELEVATOR")) and 50 or 1
        g[id][#g[id] + 1] = { to = d, warp = w, cost = elev }
        into[d] = into[d] or {}
        into[d][id] = true
      end
    end
    for dir, c in pairs(def.connections or {}) do
      if maps[c.map] and COMPASS_DIR[dir] then
        -- A seam with no walkable pair is map data that describes two
        -- adjacent maps you cannot actually walk between. Keep the edge
        -- but make it expensive rather than deleting it: a Cut tree or a
        -- gate script can open one later, and a wrongly deleted edge is
        -- an unreachable map, while a wrongly costly one is a detour.
        local cells = seamCells(def, dir, c)
        g[id][#g[id] + 1] = { to = c.map, dir = COMPASS_DIR[dir],
                              cells = cells, cost = #cells > 0 and 1 or 8 }
      end
    end
  end
  -- A LAST_MAP warp goes back wherever we came IN from, which is not known
  -- until we are standing there. For planning, the candidates are every map
  -- that warps into this one; we re-plan after each hop, so guessing wrong
  -- costs one replan rather than a wrong route. Priced above a concrete
  -- edge so a known-destination hop always wins a tie.
  for id, def in pairs(maps) do
    for _, w in ipairs(def.warps or {}) do
      if w.destMap == "LAST_MAP" then
        for src in pairs(into[id] or {}) do
          g[id][#g[id] + 1] = { to = src, warp = w, dynamic = true, cost = 3 }
        end
      end
    end
  end
  MAP_GRAPH = g
  return g
end

-- Cheapest hop list from `from` to `to`, or nil. `banned` is a set of
-- seamKeys this trip has already proved useless.
local function planMapRoute(from, to, banned)
  local g = mapGraph()
  if from == to then return {} end
  local dist, prev = { [from] = 0 }, {}
  -- Dijkstra over a handful of hundreds of nodes: a linear scan for the
  -- nearest unsettled node is far cheaper than the heap it would replace.
  local settled = {}
  while true do
    local cur, best
    for id, d in pairs(dist) do
      if not settled[id] and (best == nil or d < best) then cur, best = id, d end
    end
    if not cur or cur == to then break end
    settled[cur] = true
    for _, e in ipairs(g[cur] or {}) do
      local k = edgeId(cur, e)
      -- `banned` is per-TRIP and per-WARP (see edgeId): within one travelTo
      -- a specific warp that just looped us back must not be re-planned, but
      -- its siblings across the same seam stay available. Across trips the
      -- memory only makes a seam dearer -- see seamCost.
      if not (banned and banned[k]) then
        local nd = best + e.cost + seamCost(cur, e.to)
        if dist[e.to] == nil or nd < dist[e.to] then
          dist[e.to] = nd
          prev[e.to] = { map = cur, edge = e }
        end
      end
    end
  end
  if not prev[to] then return nil end
  local path, cur = {}, to
  while prev[cur] do
    table.insert(path, 1, prev[cur].edge)
    cur = prev[cur].map
  end
  return path
end

-- Walk off the map edge in `dir`, taking the connection. Returns true if
-- the map changed.
local function crossSeam(edge)
  local m = ow().map
  local p = ow().player
  local from = m.id
  local W, H = m.widthCells, m.heightCells
  -- Prefer a border cell whose far side is walkable; fall back to any
  -- walkable border cell when the seam data gave us none, so a connection
  -- we mispriced can still be tried.
  local cands = {}
  for _, c in ipairs(edge.cells or {}) do cands[#cands + 1] = { c[1], c[2] } end
  if #cands == 0 then
    if edge.dir == "up" or edge.dir == "down" then
      local by = (edge.dir == "up") and 0 or H - 1
      for x = 0, W - 1 do
        if m:isWalkableCell(x, by) then cands[#cands + 1] = { x, by } end
      end
    else
      local bx = (edge.dir == "left") and 0 or W - 1
      for y = 0, H - 1 do
        if m:isWalkableCell(bx, y) then cands[#cands + 1] = { bx, y } end
      end
    end
  end
  table.sort(cands, function(a, b)
    return math.abs(a[1] - p.cellX) + math.abs(a[2] - p.cellY)
         < math.abs(b[1] - p.cellX) + math.abs(b[2] - p.cellY)
  end)
  -- Out-of-bounds coordinates are ops.goto_'s "leave through this edge"
  -- idiom: it clamps back to the border cell, paths there, then holds the
  -- direction across the seam.
  --
  -- Several candidates, because a single one makes crossing flaky: BFS
  -- treats an NPC as a wall, and Vermilion's seam cells sit among six
  -- wandering sprites, so the same crossing succeeded and failed within one
  -- session depending on where they had drifted. Trying more of the seam
  -- costs a little walking and removes most of that.
  for k = 1, math.min(#cands, 8) do
    local cx, cy = cands[k][1], cands[k][2]
    local ox = (edge.dir == "left" and -1) or (edge.dir == "right" and W) or cx
    local oy = (edge.dir == "up" and -1) or (edge.dir == "down" and H) or cy
    ops.goto_({ x = ox, y = oy })
    if ow().map.id ~= from then return true end
  end
  return false
end

-- How many hops a trip may take. The longest legitimate one in the route
-- (Vermilion -> Cerulean underground) is six; the cap only exists so a
-- pair of seams that each bounce us back cannot loop forever.
-- Generous: a gate can cost several wrong-door tries before the right one
-- (Route 16 has eight warps to sift), and each is one hop. The cap only
-- exists so a genuinely impossible trip cannot spin forever.
local MAX_TRAVEL_HOPS = 90
-- Distinct maps a single travelTo may touch before it is declared lost.
-- The fly-replacement town-to-town trips are long -- ROUTE_16 -> LAVENDER
-- runs Celadon, Route 7, Saffron, Route 8, and the two gates that split
-- Route 16 and Route 11 each add a couple of sub-maps to sift. The old cap
-- of 12 cut those off and stranded the fly, then it wandered. It can be
-- this loose safely now that GRINDING no longer travels (grindALevel does a
-- single crossSeam), which was the only case that wandered map-wide.
local MAX_TRAVEL_MAPS = 30
-- Times one cell may be looped back onto before travelTo gives up entirely.
local MAX_TRAVEL_REVISITS = 8
-- Times a connection may fail to cross before travelTo bans it for the trip.
-- One miss is common (an NPC on the seam, an odd DIG landing); a persistent
-- miss means it is genuinely shut from here.
local CONNECTION_CROSS_TRIES = 3

-- Execute one graph hop -- a warp, a connection cross, or a ledge hop --
-- the same way for a region edge or a map edge.
local function doHop(edge)
  if edge.warp then
    walkOntoWarp(edge.warp.x, edge.warp.y)
  elseif edge.ledge then
    -- one-way ledge: stand on the cell and hold the direction; the engine
    -- does the two-cell jump (walk() waits out its hop frames)
    ops.goto_({ x = edge.ledge.x, y = edge.ledge.y })
    faceDir(edge.ledge.dir)
    walk(edge.ledge.dir)
  elseif edge.cut then
    -- cross a cut tree: walk onto the far-side cell. ops.goto_ cuts a tree
    -- walling off the target on its own (cutToward), then walks through.
    ops.goto_({ x = edge.cut.x, y = edge.cut.y })
  else
    crossSeam({ dir = edge.dir, cells = edge.cells })
  end
end

-- Walk the map graph to `dest`, independent of the heal point.
--
-- Plans over the REGION graph (a gate-split map is several nodes), so it can
-- only propose a crossing the current side actually reaches -- no more
-- trying a Saffron exit from the wrong region and wandering off. Falls back
-- to the plain map graph when the player's cell has no region (an odd warp
-- tile), so the older behaviour is still there as a net.
local function travelTo(dest, where)
  if not (G.data.maps and G.data.maps[dest]) then
    say(("travelTo: no such map %s"):format(tostring(dest)))
    return false
  end
  local banned = {}
  local start = ow().map.id
  local function posKey()
    local p = ow().player
    return ("%s:%d:%d"):format(ow().map.id, p.cellX, p.cellY)
  end
  local visited = { [posKey()] = true }
  local revisits = {} -- cell -> times looped back onto it
  -- Safety leash: even with region planning, a genuinely unreachable dest
  -- (waiting on Surf, a badge) must not spin forever.
  local mapsSeen, mapCount = { [start] = true }, 1
  -- The region planner routes gate-split maps correctly (Saffron, Route 11)
  -- but a few gates -- Route 16's two-level LAST_MAP maze -- have edge-warp
  -- crossings walkOntoWarp cannot execute, where the older map planner's
  -- crossSeam / reEnterThroughGate could. So after this many region hops in
  -- a row fail to move, drop to the map planner for the rest of the trip:
  -- region planning where it helps, the proven map planner as the floor, so
  -- this never leaves the run worse than the map-only baseline.
  local REGION_FAIL_LIMIT = 3
  local regionFails, useMap = 0, false
  for _ = 1, MAX_TRAVEL_HOPS do
    local here = ow().map.id
    if not mapsSeen[here] then
      mapsSeen[here] = true
      mapCount = mapCount + 1
      if mapCount > MAX_TRAVEL_MAPS then
        say(("travelTo %s: wandered across %d maps without arriving (on %s) "
             .. "-- giving up"):format(tostring(dest), mapCount, here))
        note("travelTo: wandered too far to " .. tostring(dest), where)
        return false
      end
    end
    if here == dest then
      if here ~= start then
        say(("travelled %s -> %s"):format(tostring(start), tostring(dest)))
      end
      return true
    end

    -- Region-aware plan first (unless we have fallen back); map-level plan
    -- as the fallback.
    local p = ow().player
    local reg = not useMap and cellRegionOf(here, p.cellX, p.cellY)
    local hop, banKey, fromRegion
    if reg then
      local rp = planRegionRoute(regionNode(here, reg), dest, banned)
      if rp and #rp > 0 then hop, banKey, fromRegion = rp[1].edge, rp[1].bk, true end
    end
    if not hop then
      local mp = planMapRoute(here, dest, banned)
      if mp and #mp > 0 then
        hop = mp[1]
        banKey = here .. "|map|" .. edgeId(here, mp[1])
      end
    end
    if not hop then
      say(("travelTo %s: no way there from %s"):format(tostring(dest), tostring(here)))
      note("travelTo: no route to " .. tostring(dest), where)
      return false
    end

    local hopDesc = hop.warp and ("warp@" .. hop.warp.x .. "," .. hop.warp.y)
                    or hop.ledge and ("ledge@" .. hop.ledge.x .. "," .. hop.ledge.y)
                    or hop.cut and ("cut@" .. hop.cut.x .. "," .. hop.cut.y)
                    or ("cross " .. tostring(hop.dir))
    if os.getenv("POKEPORT_TRAVEL_DEBUG") then
      local wr = hop.warp and cellRegionOf(here, hop.warp.x, hop.warp.y)
      say(("[travel] at %s (%d,%d) reg=%s useMap=%s -> %s (warpReg=%s)")
          :format(here, p.cellX, p.cellY, tostring(reg), tostring(useMap),
                  hopDesc, tostring(wr)))
      if reg and not travelDumped then
        travelDumped = true
        local nodeKey = regionNode(here, reg)
        local g = regionGraph()
        local seen, q, h = { [nodeKey] = true }, { nodeKey }, 1
        local reachMaps = {}
        while h <= #q do
          local cur = q[h]; h = h + 1
          reachMaps[cur:match("^(.-)#")] = true
          for _, e in ipairs(g[cur] or {}) do
            if not seen[e.to] then seen[e.to] = true; q[#q + 1] = e.to end
          end
        end
        say(("   [reach] from %s: CELADON=%s LAVENDER=%s POKEMON_TOWER_6F=%s "
             .. "SAFFRON=%s"):format(nodeKey,
             tostring(reachMaps.CELADON_CITY ~= nil),
             tostring(reachMaps.LAVENDER_TOWN ~= nil),
             tostring(reachMaps.POKEMON_TOWER_6F ~= nil),
             tostring(reachMaps.SAFFRON_CITY ~= nil)))
      end
    end
    local before = posKey()
    doHop(hop)
    local pk = posKey()
    if pk == before then
      -- did not move at all: this hop is shut from here, ban and re-plan
      banned[banKey] = true
      if fromRegion then
        regionFails = regionFails + 1
        if regionFails >= REGION_FAIL_LIMIT and not useMap then
          useMap = true
          banned = {} -- the map planner has its own edge keys; start clean
          say(("travelTo %s: region hops keep failing on %s -- switching to "
               .. "the map planner"):format(tostring(dest), here))
        end
      end
      say(("travelTo %s: %s (%s) did not move; re-planning")
          :format(tostring(dest), here, hopDesc))
    elseif visited[pk] then
      -- looped back onto a cell we already stood on: ban the hop that did it
      banned[banKey] = true
      -- A loop counts against the region planner too, or a connection that
      -- crossSeam keeps landing on the same border cell (Pewter -> Route 3
      -- from an awkward spot a grind left us in) spins forever without ever
      -- reaching the "did not move" branch that triggers the fallback.
      if fromRegion then
        regionFails = regionFails + 1
        if regionFails >= REGION_FAIL_LIMIT and not useMap then
          useMap = true
          banned = {}
          say(("travelTo %s: region hops keep looping on %s -- switching to "
               .. "the map planner"):format(tostring(dest), here))
        end
      end
      -- Hard anti-livelock: the same cell revisited far too many times means
      -- neither planner is getting anywhere. Give up rather than spin.
      revisits[pk] = (revisits[pk] or 0) + 1
      if revisits[pk] > MAX_TRAVEL_REVISITS then
        say(("travelTo %s: stuck revisiting %s -- giving up")
            :format(tostring(dest), pk))
        note("travelTo: livelocked reaching " .. tostring(dest), where)
        return false
      end
      say(("travelTo %s: looped back to %s; trying another way")
          :format(tostring(dest), pk))
    else
      -- genuine progress: a region hop that worked resets the fail streak
      if fromRegion then regionFails = 0 end
      visited[pk] = true
    end
    visited._last = pk
  end
  say(("travelTo %s: gave up after %d hops, on %s")
      :format(tostring(dest), MAX_TRAVEL_HOPS, ow().map.id))
  note("travelTo: too many hops to " .. tostring(dest), where)
  return ow().map.id == dest
end

-- Reach a warp cell by ARRIVING through it rather than walking to it.
--
-- A dungeon floor is not one connected room, and the route crosses between
-- its pockets by going up or down and back. MT_MOON_B1F is the case that
-- forced this: it is four pockets joined only through B2F and 1F, so from
-- warp 5 at (21,17) there is no path at all to warp 7 at (23,3) -- the
-- unreachable log named it exactly, "npcs: none", because nothing was in
-- the way; there is simply no floor between them.
--
-- Warps are two-ended and the data says which end is which, so this is
-- exact rather than a search: MT_MOON_B2F's warp 4 at (5,7) declares
-- destWarp 7 into MT_MOON_B1F, and taking it lands us ON (23,3). Find the
-- far end, travel to that map, step through, and we arrive at the target
-- instead of failing to walk to it.
-- Cells we can currently walk to, NPCs counted as walls exactly as
-- bfsNextKey sees them. Shared by the "walled off" recoveries below.
local function reachableSet()
  local m, p = ow().map, ow().player
  local W, H = m.widthCells, m.heightCells
  local blocked = {}
  -- only this map's NPCs; see bfsNextKey for why a foreign one is poison
  for _, npc in ipairs(ow().npcs) do
    if npc.cellX >= 0 and npc.cellY >= 0 and npc.cellX < W and npc.cellY < H then
      blocked[npc.cellY * W + npc.cellX] = true
    end
  end
  local seen = { [p.cellY * W + p.cellX] = true }
  local q, head = { { p.cellX, p.cellY } }, 1
  while head <= #q do
    local c = q[head]; head = head + 1
    for _, d in ipairs(DIRS) do
      local nx, ny = c[1] + d[1], c[2] + d[2]
      local id = ny * W + nx
      if nx >= 0 and ny >= 0 and nx < W and ny < H and not seen[id]
         and not blocked[id] and passableCell(m, nx, ny) then
        seen[id] = true
        q[#q + 1] = { nx, ny }
      end
    end
  end
  return seen, W
end

-- Reach another region of THIS map by going through a gate and out its far
-- door.
--
-- The case arriveByWarp cannot take. ROUTE_16 is split in two by the gate
-- building at x 18-23: west (x<=17) holds the FLY house, east (x>=24) leads
-- to CELADON_CITY, and row 10 is the only crossing --
-- (17,10) -> ROUTE_16_GATE_1F -> (24,10). Both sides are the SAME map, so
-- travelTo thinks we have arrived; and every one of the gate's warps is
-- LAST_MAP with no destWarp, so arriveByWarp has no far end to aim at.
-- The result was a bot sealed in the western pocket reporting
-- "ROUTE_16 -> CELADON_CITY did not cross" until it ran out of rewinds.
--
-- So: step into a gate we CAN reach, then come back out through a door we
-- did not use, and see whether the target is reachable now.
local goingThroughGate = false

function reEnterThroughGate(tx, ty)
  if goingThroughGate then return false end
  local hereId = ow().map.id
  local seen, W = reachableSet()
  if seen[ty * W + tx] then return false end -- not a region problem
  -- Doors we can walk to that lead INTO a named sub-map, nearest first.
  --
  -- The destMap filter is a safety rail, and it was learned the hard way.
  -- Without it this entered ANY reachable warp -- including a building's
  -- own LAST_MAP exit -- so an ordinary unreachable waypoint (a Vermilion
  -- Gym trash can the puzzle had walled off for the moment) sent the bot
  -- WALKING OUT OF THE GYM and back in, over and over, until the process
  -- hung and was killed. A real gate crossing goes through a named map
  -- (ROUTE_16 -> ROUTE_16_GATE_1F); a LAST_MAP door just dumps us outside
  -- the current area, which is never the way to another region OF THIS map.
  local doors = {}
  for i, w in ipairs(ow().map.def.warps or {}) do
    if seen[w.y * W + w.x] and type(w.destMap) == "string"
       and w.destMap ~= "LAST_MAP" and G.data.maps[w.destMap] then
      doors[#doors + 1] = { idx = i, warp = w }
    end
  end
  local p = ow().player
  table.sort(doors, function(a, b)
    return math.abs(a.warp.x - p.cellX) + math.abs(a.warp.y - p.cellY)
         < math.abs(b.warp.x - p.cellX) + math.abs(b.warp.y - p.cellY)
  end)
  goingThroughGate = true
  local ok = false
  for k = 1, math.min(#doors, 3) do
    local door = doors[k]
    if not walkOntoWarp(door.warp.x, door.warp.y) then break end
    local inner = ow().map.id
    -- try the inner map's other exits back to where we came from
    local tried = 0
    for _, w2 in ipairs(ow().map.def.warps or {}) do
      local back = w2.destMap
      if (back == hereId or back == "LAST_MAP")
         and not (w2.x == ow().player.cellX and w2.y == ow().player.cellY) then
        tried = tried + 1
        if tried > 4 then break end
        if walkOntoWarp(w2.x, w2.y) and ow().map.id == hereId then
          local seen2, W2 = reachableSet()
          if seen2[ty * W2 + tx] then
            say(("crossed %s via %s and came out the far side; (%d,%d) is "
                 .. "reachable now"):format(hereId, tostring(inner), tx, ty))
            ok = true
            break
          end
          -- wrong side: go back in and try another door
          if not walkOntoWarp(door.warp.x, door.warp.y) then break end
        end
      end
    end
    if ok then break end
    -- make sure we are back on the map we started from before trying again
    if ow().map.id ~= hereId then
      local out = findWarpTo(hereId) or findWarpTo("LAST_MAP") or findWarpTo("")
      if out then walkOntoWarp(out.x, out.y) end
    end
  end
  goingThroughGate = false
  return ok
end

local arrivingByWarp = false

function arriveByWarp(tx, ty)
  if arrivingByWarp then return false end
  local m = ow().map
  local hereId = m.id
  local w = m.warpAtCell and m:warpAtCell(tx, ty)
  if not w then return false end
  local idx = w.index
  -- every (map, warp) pair whose far end is this exact warp
  local cands = {}
  for mapId, def in pairs(G.data.maps or {}) do
    for _, other in ipairs(def.warps or {}) do
      if other.destMap == hereId and other.destWarp == idx then
        cands[#cands + 1] = { map = mapId, warp = other }
      end
    end
  end
  if #cands == 0 then return false end
  arrivingByWarp = true
  local ok = false
  for k = 1, math.min(#cands, 3) do
    local c = cands[k]
    say(("goto (%d,%d) has no floor leading to it on %s; arriving through "
         .. "%s's warp at (%d,%d) instead")
        :format(tx, ty, hereId, c.map, c.warp.x, c.warp.y))
    if travelTo(c.map, hereId) then
      walkOntoWarp(c.warp.x, c.warp.y)
      local p = ow().player
      if ow().map.id == hereId and p.cellX == tx and p.cellY == ty then
        ok = true
        break
      end
    end
  end
  arrivingByWarp = false
  if ok then say(("arrived at (%d,%d) on %s"):format(tx, ty, hereId)) end
  return ok
end

-- Talk to the nurse and accept, mirroring tests/drivers/heal_test.lua:
-- welcome text -> ChoiceBox -> YES -> machine animation -> farewell.
local function talkToNurse(where)
  local nurse = findObject("_NURSE")
  if not nurse then
    note("center: no nurse", where)
    say(("center on %s: no nurse object on %s"):format(
        tostring(where), tostring(ow().map.id)))
    return false
  end
  -- her counter sits between you and her, so she is talked to from two
  -- tiles below facing up (heal_test stands at (3,3) for a nurse at (3,1))
  if not ops.goto_({ x = nurse.x, y = nurse.y + 2 }) then
    note("center: cannot reach the counter", where)
    say(("center on %s: could not reach the counter at (%d,%d)"):format(
        tostring(where), nurse.x, nurse.y + 2))
    return false
  end
  faceDir("up")
  press("a")
  U.wait(10)
  -- accept the prompt; ChoiceBox defaults to YES at index 1. Mashing A is
  -- safe in here -- unlike a shop, no screen in a Poké Center spends money.
  for _ = 1, 60 do
    if isChoice() then
      cursorTo("index", 1)
      press("a")
      break
    end
    if idle() then break end
    press("a")
    U.wait(5)
  end
  -- busy() already covers ow.healAnim, so idle() waits out the machine
  for _ = 1, 200 do
    if idle() then break end
    U.wait(6)
  end
  return mashUntilIdle()
end

local function totalHP()
  local t = 0
  for _, mon in ipairs(party()) do t = t + (mon.hp or 0) end
  return t
end

-- Leave the route, heal, and come back to the tile we left from.
-- Returns true only if HP actually went up: talkToNurse ends in
-- mashUntilIdle, which reports success for *reaching the overworld again*,
-- not for healing. Trusting that is what made the bot walk into the centre,
-- out again and straight back in on every following segment.
-- `forHealPoint` visits for the RESPAWN, not the HP.
--
-- talkToNurse writes wLastBlackoutMap (SetLastBlackoutMap), and that is
-- worth a detour on its own: without it the heal point stays wherever it
-- last happened to be, and a gym loss respawns a town behind. Judging the
-- visit by whether HP rose is exactly wrong here -- we go in healthy on
-- purpose -- so a heal-point visit is never counted as a failure and never
-- triggers the "nurse healed nothing" backoff.
local function visitPokeCenter(where, forHealPoint)
  local fromMap = ow().map.id
  local door = findWarpTo("POKECENTER")
  if not door then return false end -- no centre on this map
  local before = totalHP()
  if not walkOntoWarp(door.x, door.y) then
    note("center: could not get in", where)
    say(("center on %s: could not walk onto the door at (%d,%d)"):format(
        tostring(where), door.x, door.y))
    return false
  end
  talkToNurse(where)
  local healed = totalHP() > before
  -- The whole point of a forHealPoint visit is the nurse WRITING the
  -- respawn (SetLastBlackoutMap). Silence here is what hid the Route 10
  -- anchor failing on every pass: the log said "re-anchoring at ROUTE_10"
  -- while wipes kept waking in CERULEAN, because the talk never happened
  -- and nothing said so.
  local centreMap = ow().map.id
  if forHealPoint and not (G.save.lastHeal and G.save.lastHeal.map == centreMap) then
    say(("center on %s: nurse did NOT take the heal point (still %s)")
        :format(tostring(where),
                tostring(G.save.lastHeal and G.save.lastHeal.map)))
  end
  if forHealPoint then healed = true end
  if not healed then note("center: nurse restored nothing", where) end
  -- the centre's exit warps both lead to LAST_MAP
  local out = findWarpTo("LAST_MAP") or findWarpTo("")
  if out then walkOntoWarp(out.x, out.y) end
  if ow().map.id ~= fromMap then
    note("center: did not get back to " .. fromMap, where)
  end
  -- Deliberately NOT walking back to where we stood before healing.
  --
  -- Every route step is an absolute goto, so the segment re-paths from
  -- wherever we are and the backtrack buys nothing. It costs plenty: the
  -- saved tile is wherever the previous segment happened to stop, and when
  -- that is the edge of the map -- Viridian's southern row, if we had just
  -- walked up from Route 1 -- "returning" marches back down to the seam and
  -- slips into the next map, desyncing the run for good.
  return healed
end

-- Whether a fight is worth staying in: true if the bag holds something that
-- restores HP, or the map we are standing on has a centre to walk back to.
-- Read mid-battle by lowOnHP, which is why it is only assigned here.
canRestoreHP = function()
  for _, id in ipairs(HP_ITEMS) do
    if heldCount(id) then return true end
  end
  return findWarpTo("POKECENTER") ~= nil
end

-- Top up between segments, independently of the route's own heal steps.
--
-- PokeBotBad asks for a heal exactly where a speedrun needs one, and it
-- assumes levels we do not reach. Left to the route's heal steps alone the
-- party grinds down over a couple of maps and blacks out -- which is how
-- the first runs ended, every time in Viridian Forest.
-- Two thresholds again, for the same reason the flee guard has two: a
-- potion is scarce, a nurse is free. Spend an item only once a mon is
-- clearly hurt, but never walk out of a town with a centre less than full
-- -- the stretch that keeps killing us (Viridian Forest into Route 2) has
-- no centre anywhere along it, so whatever we leave Viridian with is all
-- we get.
local AUTO_HEAL_AT = 0.5      -- worth spending an item on
local CENTER_TOP_UP_AT = 0.95 -- worth walking to a free nurse for

-- segments to wait before trying another nurse, after one healed nothing
local centerCooldown = 0

-- The town whose Poké Center last wrote the heal point. A blackout sends us
-- to wLastBlackoutMap, so when this falls behind the route the respawn is
-- somewhere we finished with, and every death replays the walk back.
local healAnchor

-- worst HP fraction in the party, and the slot holding it
local function worstFraction()
  local slot = mostHurt()
  if not slot then return 1, nil end
  local mon = party()[slot]
  local max = mon.stats and mon.stats.hp or 0
  if max <= 0 then return 1, nil end
  return mon.hp / max, slot
end

-- How healthy we insist on being before walking into a map's fights.
--
-- This is the "how likely is the next trainer to kill me" judgement, made
-- from what we can actually see up front (we do not know the enemy until
-- the battle opens): how much of the party is still standing, and how
-- often this map has killed us before.
function riskThreshold(mapId)
  local usable = 0
  for _, mon in ipairs(party()) do
    if (mon.hp or 0) > 0 then usable = usable + 1 end
  end
  local need = AUTO_HEAL_AT
  -- a one-mon party has no second chance: a single bad matchup ends the
  -- run outright, so demand real headroom rather than half a bar
  if usable <= 1 then need = math.max(need, 0.8) end
  -- and every death here buys more caution, up to "arrive essentially full"
  local d = dangerAt(mapId)
  if d > 0 then need = math.min(0.95, need + 0.15 * math.min(d, 3)) end
  return need
end

-- `allowCenter` gates the Poké Center detour, and only the segment-boundary
-- call passes it.
--
-- A centre visit WARPS us -- it is not a walk we can undo -- and a map can be
-- split into regions a walk cannot cross. Cerulean is exactly that: a fence
-- divides it and the only ways through are two pass-through houses. Healing
-- part-way through the segment that crosses to the east half teleported the
-- bot back to the centre in the west half, where every remaining waypoint was
-- unreachable and the attempt died in a run of skips. Mid-segment healing is
-- items only; the nurse is a between-segments decision.
function autoHeal(where, need, allowCenter)
  if not idle() then return end
  need = need or AUTO_HEAL_AT
  local frac = worstFraction()

  -- the nurse is free and heals the whole party, so top up on the way past
  -- rather than waiting for anything to get dangerous
  if allowCenter and frac < math.max(need, CENTER_TOP_UP_AT) and centerCooldown <= 0
     and findWarpTo("POKECENTER") then
    if visitPokeCenter(where) then return end
    -- The walk there put no HP back. Retrying it next segment is how the
    -- bot ends up marching in and out of the same door forever, so stand
    -- down for a while and fall through to items instead.
    centerCooldown = 12
    say("nurse healed nothing on " .. tostring(where)
        .. "; not walking back for 12 segments")
  end

  if frac >= need then return end
  -- several passes: one potion rarely tops up a badly hurt mon, and a
  -- multi-mon party can have more than one below the line
  for _ = 1, 6 do
    local f, slot = worstFraction()
    if not slot or f >= need then return end
    local before = party()[slot].hp
    ops.heal({}, where)
    -- ops.heal reports "no HP item" by noting and returning true, so stop
    -- on anything that did not actually raise HP rather than spinning
    local after = party()[slot] and party()[slot].hp or 0
    if after <= before then return end
  end
end

-- Menu-driven ops still to implement. Each is a real menu interaction
-- (bag, party, PC) rather than something the route can express, so they
-- are stubbed loudly instead of guessed at.
-- The route names moves in its own vocabulary; these are the items that
-- teach them. Anything missing falls through to the stub and is logged.
local TEACH_ITEMS = {
  cut = "HM_CUT", fly = "HM_FLY", surf = "HM_SURF",
  strength = "HM_STRENGTH", flash = "HM_FLASH",
  -- NB: no `thrash`. Gen 1 has no Thrash TM -- the route's five `teach
  -- thrash` steps on Route 24 are accepting a LEVEL-UP learn prompt, which
  -- mashUntilIdle already answers with A. Left unmapped on purpose.
  dig = "TM_DIG", bubblebeam = "TM_BUBBLEBEAM", earthquake = "TM_EARTHQUAKE",
  thunderbolt = "TM_THUNDERBOLT", horn_drill = "TM_HORN_DRILL",
  rock_slide = "TM_ROCK_SLIDE", ice_beam = "TM_ICE_BEAM",
  mega_punch = "TM_MEGA_PUNCH", mega_kick = "TM_MEGA_KICK",
}

-- Party slot of the first species in `prefs` that we actually own. The route
-- lists alternatives ({"oddish","paras"}) because which one it caught varies.
local function slotForSpecies(prefs)
  if type(prefs) == "string" then prefs = { prefs } end
  local roster = party()
  for _, want in ipairs(prefs or {}) do
    local target = tostring(want):upper()
    for i, mon in ipairs(roster) do
      if tostring(mon.species):upper() == target then return i end
    end
  end
  return nil
end

local function slotKnowing(moveId)
  for i, mon in ipairs(party()) do
    for _, mv in ipairs(mon.moves or {}) do
      if tostring(mv.id):upper() == moveId then return i end
    end
  end
end

-- Teach an HM/TM. Same bag walk as a healing item: the party menu at the end
-- picks who learns it.
function ops.teach(s, where)
  local key = tostring(s.move or ""):lower()
  local item = TEACH_ITEMS[key]
  if not item then note("teach:" .. key, where) return true end
  if (heldCount(item) or 0) <= 0 then
    note("teach: no " .. item, where)
    say(("teach %s: no %s in the bag"):format(key, item))
    return false
  end
  -- Who can actually learn it. The route names a species (its TMs are aimed
  -- at the Nidoking it assumes we evolved), and when that mon is not in the
  -- party the old fallback was "slot 1" -- which handed THUNDERBOLT to a
  -- WARTORTLE, whose tmhm list does not contain it, so the TM was spent for
  -- nothing and the log blamed the teach. Compatibility is data we already
  -- have; consult it rather than guessing.
  local function canLearn(mon)
    local sp = mon and G.data.pokemon[mon.species]
    for _, m in ipairs(sp and sp.tmhm or {}) do
      if m == key:upper() then return true end
    end
    return false
  end
  local slot = slotForSpecies(s.mon)
  if slot and not canLearn(party()[slot]) then slot = nil end
  if not slot then
    for i, mon in ipairs(party()) do
      if canLearn(mon) then slot = i break end
    end
  end
  if not slot then
    note("teach: nobody can learn " .. key, where)
    say(("teach %s: nobody in the party can learn it"):format(key))
    return false
  end
  local who = party()[slot]
  say(("teaching %s to %s (slot %d)"):format(key,
      tostring(who and who.species or "?"), slot))
  local ok = useItemOn(item, slot, where)
  -- A full moveset opens MoveLearnMenu, which useItemOn just mashes A
  -- through -- so the TM is consumed and nothing is learned. That is how
  -- DIG silently failed on a level-30 WARTORTLE, and DIG is the route's
  -- ride back to Cerulean, so the run then had nowhere to go.
  --
  -- `index` past the last move means "give up"; rows 1..4 forget that move.
  -- We drop slot 1, which for the route's targets is the starter's weakest
  -- filler rather than anything it fights with.
  -- Drive the full-moveset flow.
  --
  -- MoveLearnMenu is NOT on top when it appears. Screens.push puts it on
  -- the stack and its :enter() immediately pushes a TextBox ("... is trying
  -- to learn ... Delete an older move?") which in turn pushes a ChoiceBox
  -- (src/ui/MoveLearnMenu.lua:34-50). So `top()` is a TextBox, the old
  -- `top().newMoveId` test never matched, and the forget flow never ran --
  -- the TM was consumed and nothing was learned. That is why a level-30
  -- WARTORTLE, whose tmhm list DOES contain DIG and BUBBLEBEAM (verified
  -- against pokered's base_stats/wartortle.asm -- our data is right), kept
  -- reporting "did NOT learn it", which took DIG away from the run.
  local function learnMenu()
    for _, st in ipairs(G.stack.states or {}) do
      if st.newMoveId and st.mon and st.index then return st end
    end
  end
  if waitFor(learnMenu, 30) then
    for _ = 1, 60 do
      local menu = learnMenu()
      if not menu then break end
      local t = top()
      if t == menu then
        -- the move list itself: forget slot 1, the starter's weakest filler
        if not cursorTo("index", 1) then break end
        press("a")
        U.wait(10)
      elseif isChoice() then
        cursorTo("index", 1) -- YES, delete a move
        press("a")
        U.wait(8)
      else
        press("a") -- text box
        U.wait(6)
      end
    end
    mashUntilIdle()
    say(("%s forgot a move to learn %s"):format(
        tostring(who and who.species or "?"), key))
  end
  -- The learn lands a frame or two after the menus close, so checking
  -- immediately reported "did NOT learn it" for a TM that had in fact
  -- worked -- DIG said it failed and then got used two segments later.
  -- Give it a moment before calling it.
  local learned = waitFor(function() return slotKnowing(key:upper()) ~= nil end, 20)
  if learned then
    say(("%s learned %s"):format(tostring(who and who.species or "?"), key))
    return true
  end
  say(("teach %s: %s did NOT learn it"):format(key,
      tostring(who and who.species or "?")))
  return false
end

-- Use a field move from the party menu (start_sub_menus.asm). CUT/SURF/
-- STRENGTH/FLY all live there, gated on the matching badge -- CUT needs
-- CASCADEBADGE (src/ui/PartyMenu.lua:342).
function ops.fieldMove(s, where)
  local move = tostring(s.move or ""):upper()
  local slot = slotKnowing(move)
  if not slot then
    -- DIG and FLY are TRANSPORT, and a transport step we cannot perform is
    -- a walk we have not taken yet rather than a dead end. Segment 72 is
    -- the case: `fieldMove dig` out of the Pokémon Fan Club is the whole of
    -- the route's Vermilion -> Cerulean trip, and if TM_DIG never made it
    -- into the bag this returned false, segments 73-81 all skipped against
    -- CERULEAN_CITY, and the rewind looped over Vermilion forever -- with a
    -- won gym behind it. Walking there is slower and always available.
    if (move == "DIG" or move == "FLY") and nextMapWanted
       and ow().map.id ~= nextMapWanted then
      say(("fieldMove %s: nobody knows it -- walking to %s instead")
          :format(move, tostring(nextMapWanted)))
      if travelTo(nextMapWanted, where) then return true end
    end
    note("fieldMove: nobody knows " .. move, where)
    say(("fieldMove %s: nobody in the party knows it"):format(move))
    return false
  end
  -- CUT acts on the tile the player is FACING (OverworldState:tryCut), and
  -- a `goto` leaves us facing whatever direction we last stepped. Without
  -- turning to the tree first the move fires into empty ground, the game
  -- says "There isn't anything", and the rewind loop retries it forever.
  -- So find the tree ourselves: a cuttable block is one listed in
  -- field.cutTreeSwaps, on a cell that is not walkable.
  if move == "CUT" then
    local m = ow().map
    local function cuttable(cx, cy)
      if not m:inBounds(cx, cy) or m:isWalkableCell(cx, cy) then return false end
      local block = m:blockAt(math.floor(cx / 2), math.floor(cy / 2))
      for _, sw in ipairs(G.data.field.cutTreeSwaps or {}) do
        if sw.before == block then return true end
      end
      return false
    end
    local p = ow().player
    local facing
    for _, d in ipairs({ { 0, 1, "down" }, { 0, -1, "up" },
                         { -1, 0, "left" }, { 1, 0, "right" } }) do
      if cuttable(p.cellX + d[1], p.cellY + d[2]) then facing = d[3] break end
    end
    if not facing then
      note("fieldMove: no tree adjacent", where)
      say(("fieldMove CUT: no cuttable tree next to (%d,%d) on %s")
          :format(p.cellX, p.cellY, tostring(where)))
      return false
    end
    faceDir(facing)
  end
  -- SURF mounts only when the FACING tile is water (ItemUseSurfboard --
  -- else _NoSurfingHereText and the submenu loops), and a goto leaves us
  -- facing wherever we last stepped. The route names the direction when
  -- it knows it; otherwise face whichever neighbour is water.
  if move == "SURF" then
    local m, p = ow().map, ow().player
    local facing = s.face
    if not facing then
      for _, d in ipairs({ { 0, 1, "down" }, { 0, -1, "up" },
                           { -1, 0, "left" }, { 1, 0, "right" } }) do
        if m:inBounds(p.cellX + d[1], p.cellY + d[2])
           and m:isWaterCell(p.cellX + d[1], p.cellY + d[2]) then
          facing = d[3] break
        end
      end
    end
    if not facing then
      note("fieldMove: no water adjacent", where)
      say(("fieldMove SURF: no water next to (%d,%d) on %s")
          :format(p.cellX, p.cellY, tostring(where)))
      return false
    end
    faceDir(facing)
  end

  -- A `teach` immediately precedes this in the route, and its bag/party
  -- menus are still unwinding when we get here. Opening START on top of
  -- that lands us somewhere else entirely, and the failure was silent --
  -- Vermilion taught CUT and then walked into the tree because this step
  -- did nothing at all, so the gym segment skipped.
  mashUntilIdle()
  press("start")
  U.wait(8)
  local menu = top()
  local row
  for i, it in ipairs(menu and menu.items or {}) do
    if it.label == "POKéMON" then row = i break end
  end
  if not row or not cursorTo("index", row) then
    note("fieldMove: no POKéMON row", where)
    say(("fieldMove %s: the START menu never opened"):format(move))
    backOut()
    return false
  end
  press("a")
  U.wait(10)
  if not cursorTo("index", slot) then
    note("fieldMove: no slot " .. slot, where)
    say(("fieldMove %s: could not select party slot %d"):format(move, slot))
    backOut()
    return false
  end
  press("a")
  U.wait(10)
  -- The per-mon submenu (STATS / SWITCH / field moves) is NOT a separate
  -- stack entry: PartyMenu keeps it on itself as .submenu / .subItems, with
  -- its own cursor in .subIndex (src/ui/PartyMenu.lua:327,379). Reading
  -- top().items here scans the party list instead and finds no CUT, which
  -- looked exactly like the badge gate refusing -- it was not; the save had
  -- CASCADEBADGE all along.
  local pm = top()
  if not (pm and pm.submenu and pm.subItems) then
    note("fieldMove: no submenu", where)
    say(("fieldMove %s: the party submenu never opened"):format(move))
    backOut()
    return false
  end
  local mrow
  for i, it in ipairs(pm.subItems) do
    if it.label == move then mrow = i break end
  end
  if not mrow then
    local have = {}
    for _, it in ipairs(pm.subItems) do have[#have + 1] = it.label end
    note("fieldMove: no " .. move .. " entry", where)
    say(("fieldMove %s: submenu offered %s"):format(move,
        table.concat(have, "/")))
    backOut()
    return false
  end
  -- .subIndex, not .index -- the party cursor is a different field
  if not cursorTo("subIndex", mrow) then
    note("fieldMove: submenu cursor stuck", where)
    say(("fieldMove %s: could not move the submenu cursor to row %d")
        :format(move, mrow))
    backOut()
    return false
  end
  press("a")
  U.wait(12)
  mashUntilIdle()
  say(("used %s on %s"):format(move, tostring(where)))

  -- DIG and FLY are the route's long-distance travel, and neither lands
  -- where the route thinks. DIG warps to wLastBlackoutMap: the route takes
  -- segment 72's `fieldMove dig` out of the Pokémon Fan Club expecting
  -- Cerulean, because a speedrun never heals at Vermilion -- but ours does,
  -- so the warp puts us straight back in Vermilion and segments 73-75 can
  -- never run. Walk the rest of the way rather than trusting the warp.
  if (move == "DIG" or move == "FLY") and nextMapWanted then
    -- Give the warp a moment to land before reading where we are.
    for _ = 1, 120 do
      if idle() and not inBattle() then break end
      if inBattle() then fightBattle() else mashUntilIdle() end
    end
    local here = ow().map.id
    if here ~= nextMapWanted then
      say(("%s landed on %s but the route wants %s -- travelling")
          :format(move, tostring(here), tostring(nextMapWanted)))
      travelTo(nextMapWanted, where)
    end
  end
  return true
end

-- Is this cell a cuttable tree? (A cutTreeSwaps block on an unwalkable
-- cell -- the same test ops.fieldMove uses to find one to face.)
local function cuttableCell(m, cx, cy)
  if not m:inBounds(cx, cy) or m:isWalkableCell(cx, cy) then return false end
  local block = m:blockAt(math.floor(cx / 2), math.floor(cy / 2))
  for _, sw in ipairs(G.data.field.cutTreeSwaps or {}) do
    if sw.before == block then return true end
  end
  return false
end

-- Reachability guard, so cutToward cannot recurse through ops.goto_.
local cutting = false

-- Cut a tree that is walling us off from (tx, ty).
--
-- Finds the trees on the frontier of where we can currently walk, picks the
-- one nearest the target, stands next to it and cuts. One tree per call --
-- the caller re-plans afterwards, so a pocket behind two trees opens over
-- two passes rather than needing a search over combinations.
function cutToward(tx, ty)
  if cutting then return false end
  if not slotKnowing("CUT") then return false end
  local m, p = ow().map, ow().player
  local W, H = m.widthCells, m.heightCells
  -- where we can get to right now, NPCs included as walls exactly as
  -- bfsNextKey sees them
  local blockedBy = {}
  -- only this map's NPCs; see bfsNextKey
  for _, npc in ipairs(ow().npcs) do
    if npc.cellX >= 0 and npc.cellY >= 0 and npc.cellX < W and npc.cellY < H then
      blockedBy[npc.cellY * W + npc.cellX] = true
    end
  end
  local seen = { [p.cellY * W + p.cellX] = true }
  local queue, head = { { p.cellX, p.cellY } }, 1
  while head <= #queue do
    local c = queue[head]; head = head + 1
    for _, d in ipairs(DIRS) do
      local nx, ny = c[1] + d[1], c[2] + d[2]
      local id = ny * W + nx
      if nx >= 0 and ny >= 0 and nx < W and ny < H and not seen[id]
         and not blockedBy[id] and m:isWalkableCell(nx, ny) then
        seen[id] = true
        queue[#queue + 1] = { nx, ny }
      end
    end
  end
  if seen[ty * W + tx] then return false end -- not a tree problem
  local best, bestD, stand
  for id in pairs(seen) do
    local cx, cy = id % W, math.floor(id / W)
    for _, d in ipairs(DIRS) do
      local nx, ny = cx + d[1], cy + d[2]
      if cuttableCell(m, nx, ny) then
        local dist = math.abs(nx - tx) + math.abs(ny - ty)
        if not bestD or dist < bestD then
          best, bestD, stand = { nx, ny }, dist, { cx, cy }
        end
      end
    end
  end
  if not best then return false end
  say(("goto (%d,%d) is walled off; cutting the tree at (%d,%d) from (%d,%d)")
      :format(tx, ty, best[1], best[2], stand[1], stand[2]))
  cutting = true
  ops.goto_({ x = stand[1], y = stand[2] })
  local ok = ops.fieldMove({ move = "cut" }, ow().map.id)
  cutting = false
  return ok and not cuttableCell(ow().map, best[1], best[2])
end

-- Push a Strength boulder (Victory Road's four, segments 183-186).
--
-- Two things here are easy to get wrong, both from push_boulder.asm
-- (mirrored in OverworldState:checkBoulderPush):
--
--  * The FIRST walk into a boulder only ARMS the push
--    (BIT_TRIED_PUSH_BOULDER); the second one moves it. A single held walk
--    looks like a wall and reports failure.
--  * BIT_STRENGTH_ACTIVE lives in wStatusFlags1 and is cleared on EVERY map
--    load, so it is re-armed per map rather than once per run.
function ops.push(s, where)
  local dir = tostring(s.face or "")
  if dir == "" then
    note("push: no direction", where)
    return false
  end
  if not ow().strengthActive then
    if not ops.fieldMove({ move = "strength" }, where) then
      note("push: could not activate STRENGTH", where)
      say("push: STRENGTH would not activate")
      return false
    end
  end
  faceDir(dir)
  local d = DELTA[dir]
  if not d then return false end
  local p = ow().player
  local bx, by = p.cellX + d[1], p.cellY + d[2]
  local boulder = ow():npcAtCell(bx, by)
  if not boulder then
    note("push: no boulder to push", where)
    say(("push %s: nothing pushable at (%d,%d) on %s")
        :format(dir, bx, by, ow().map.id))
    return false
  end
  for _ = 1, 8 do
    faceDir(dir)
    walk(dir, 12)
    if not ow():npcAtCell(bx, by) then
      say(("pushed the boulder %s on %s"):format(dir, ow().map.id))
      return true
    end
    U.wait(4)
  end
  note("push: boulder would not move", where)
  say(("push %s: the boulder at (%d,%d) did not move"):format(dir, bx, by))
  return false
end

-- FLY between towns -- by walking, because we can never actually Fly.
--
-- HM02 is picked up at segment 104 (ROUTE_16_FLY_HOUSE) and taught at 105,
-- but the route means it for a bird we never catch: our party is the
-- starter plus a NIDORAN line, and WARTORTLE's tmhm list has no FLY. So
-- `teach fly` legitimately fails and the move is never available.
--
-- Leaving this a stub was quietly fatal rather than merely slow. Segment
-- 105 flies to LAVENDER_TOWN, so the stub left us standing on ROUTE_16 and
-- segments 106-114 -- the ENTIRE Pokémon Tower arc, which is where Mr. Fuji
-- hands over the POKE_FLUTE -- all skipped. The run then walked into the
-- Route 16 SNORLAX with no flute, could not pass, and thrashed until it ran
-- out of rewinds. One stubbed op, sixty segments of consequences.
--
-- The step names its destination (dest=lavender, map=4), and `map` is a
-- Fly-menu index rather than a map id, so the next segment's map is the
-- reliable target.
local FLY_DESTS = {
  pallet = "PALLET_TOWN", viridian = "VIRIDIAN_CITY", pewter = "PEWTER_CITY",
  cerulean = "CERULEAN_CITY", lavender = "LAVENDER_TOWN",
  vermilion = "VERMILION_CITY", celadon = "CELADON_CITY",
  fuchsia = "FUCHSIA_CITY", cinnabar = "CINNABAR_ISLAND",
  saffron = "SAFFRON_CITY",
}

function ops.fly(s, where)
  local dest = FLY_DESTS[tostring(s.dest or ""):lower()] or nextMapWanted
  if not dest then
    note("fly: no destination", where)
    return false
  end
  if ow().map.id == dest then return true end
  say(("fly to %s: walking there instead"):format(dest))
  if travelTo(dest, where) then return true end
  note("fly: could not reach " .. dest, where)
  return false
end

for _, name in ipairs({ "swapItem",
                        "swapMove" }) do
  ops[name] = function(s, where)
    note(name, where)
    return true
  end
end

-- ---------------------------------------------------------------------
-- catching
-- ---------------------------------------------------------------------

-- Whether the run is over: nothing left standing. Blacking out revives the
-- party at the heal point, so this is checked while the battle that did it
-- is still resolving, before the revive lands. (Defined here rather than
-- with the runner below because catchWild watches for it too.)
local function wiped()
  local party = G.save and G.save.party or {}
  if #party == 0 then return false end
  for _, mon in ipairs(party) do
    if (mon.hp or 0) > 0 then return false end
  end
  return true
end
--
-- The route is built around a second Pokémon. Segment 16 buys 10 POKE_BALLs
-- for exactly this, segment 18 catches a Nidoran on Route 22, and Mt. Moon
-- evolves it into the Nidoking that every later TM is aimed at (thrash,
-- thunderbolt, horn drill, rock slide, ice beam). Skipping the catch left a
-- lone starter carrying a route balanced for two -- no switch, no revive --
-- which is what kept killing us in Viridian Forest.

local BALL_ORDER = { "POKE_BALL", "GREAT_BALL", "ULTRA_BALL" }

local function ballInBag()
  for _, id in ipairs(BALL_ORDER) do
    if (heldCount(id) or 0) > 0 then return id end
  end
end

-- Throw one ball at the current wild encounter.
--
-- Drives the real menus (battle menu -> ITEM -> the ball) the way ops.heal
-- does, rather than calling BattleState:throwBall, so a broken bag fails the
-- run instead of being quietly bypassed. In battle the bag has no USE/TOSS
-- submenu (BagMenu.lua:359), so selecting a ball throws it outright.
local function throwBall(battle, ball, where)
  local function failed(stage)
    local t = top()
    say(("catch: throw failed at %s on %s (top=%s, rows=%d, phase=%s)"):format(
        stage, tostring(where),
        (isList() and "list") or (isMenu() and "menu") or (t and "other")
          or "nothing",
        rows() and #rows() or 0, tostring(battle.phase)))
  end
  -- ITEM is index 3 of the 2x2 action grid (fight/pkmn/item/run)
  if not battleMenuTo(battle, 3) then failed("the ITEM slot") return false end
  press("a")
  if not waitFor(isList, 40) then failed("opening the bag") return false end
  local idx
  for i, row in ipairs(rows()) do
    if row.value == ball then idx = i break end
  end
  if not idx then failed("finding " .. ball .. " in the bag") return false end
  if not cursorTo("index", idx) then failed("the bag cursor") return false end
  -- in battle the bag has no USE/TOSS submenu, so A throws it outright
  press("a")
  U.wait(10)
  return true
end

-- How long to pace for a target before accepting we are not getting one.
-- Route 22 grass is a 25/256 encounter rate with Nidoran on 4 of 10 slots,
-- so this is many times the expected wait; it exists to end the segment,
-- not to be reached.
local CATCH_MAX_STEPS = 300
-- Hard ceiling on outer-loop passes regardless of which branch they take,
-- so a wedged battle cannot pin the run (see the loop below).
local CATCH_MAX_ITERATIONS = 1200

-- Only walking counts toward CATCH_MAX_STEPS, so a wait that never resolves
-- would spin forever. This bounds it.
local MAX_CATCH_SPINS = 400

-- Pace for wild encounters and spend balls on anything in `targets`.
--
-- Non-targets are fought rather than fled: we are underlevelled precisely
-- because the bot flees, and this is grass we are standing in anyway.
--
-- The catch WEAKENS first (weakenMoveIndex), then throws. This used to
-- throw at full HP on the reasoning that NIDORAN's catch rate is 235 and we
-- hold ten balls, so softening it only risked killing the target. That
-- holds for NIDORAN and not for the second catch: ODDISH is catch rate 45,
-- and a full-HP run at it spent six balls without ever sticking a shake.
-- Gen 1's formula scales with missing HP, so a safe hit is worth far more
-- than an extra ball -- and weakenMoveIndex only offers a move that leaves
-- the target alive with a margin, falling back to throwing when no move is
-- safe, so the original worry is handled rather than ignored.
local function catchWild(targets, where)
  targets = targets or catchTarget
  if not targets or #targets == 0 then
    note("catch: no target species", where)
    return true
  end
  local want = {}
  for _, s in ipairs(targets) do want[s] = true end
  local startSize = #party()
  local steps, thrown, spins, weakened = 0, 0, 0, 0
  local seen = {} -- species -> encounters, so a failed catch says what showed up
  local ball = ballInBag()
  -- No balls means no catch, and pacing the grass for 300 steps to discover
  -- that only feeds the encounters we cannot do anything with. Say so and
  -- move on -- an empty bag here points at the shop stop, not at this step.
  if not ball then
    note("catch: no balls in the bag", where)
    say(("catching %s on %s: NO BALLS -- check the shop stop that should "
         .. "have stocked them"):format(table.concat(targets, "/"), tostring(where)))
    return true
  end
  say(("catching %s on %s (party %d, %s x%d)"):format(
      table.concat(targets, "/"), tostring(where), startSize,
      ball, heldCount(ball) or 0))

  -- Bound the LOOP, not just the walking.
  --
  -- `steps` is the only bound the outer loop had, and it is incremented in
  -- exactly one branch -- the one that paces the grass. A battle that never
  -- resolves therefore re-enters the inBattle branch forever with `steps`
  -- frozen, and CATCH_MAX_STEPS can never trip. That is not theoretical: a
  -- level-13 ODDISH on ROUTE_6 pinned the run for 10,229 identical
  -- iterations of "found ODDISH after 21 steps -- throwing", never throwing
  -- (no failure logged), never catching, never running out of balls.
  -- Whatever wedges the battle, the driver must not livelock on it.
  local iterations = 0
  while steps < CATCH_MAX_STEPS do
    iterations = iterations + 1
    if iterations > CATCH_MAX_ITERATIONS then
      -- Name WHICH sub-state is holding the queue, not just the phase.
      --
      -- BattleState:updateQueue returns true (queue held) for four separate
      -- reasons -- waitingUI, waitFrames, draining, animPlaying -- and the
      -- phase alone cannot tell them apart. The first pass at this only
      -- reported phase=messages, which narrowed it to "the queue is stuck"
      -- and no further; afterQueue and the drain have since been ruled out
      -- (tests/parity_ball_miss.lua covers the phase contract). Print the
      -- lot so the next occurrence names the culprit instead of needing
      -- another run to guess again.
      local b = G.stack:top()
      say(("catch: livelocked on %s after %d iterations (steps=%d, thrown=%d, "
           .. "inBattle=%s, phase=%s, afterQueue=%s, queue=%d, waitingUI=%s, "
           .. "waitFrames=%s, draining=%s, animPlaying=%s) -- abandoning")
          :format(tostring(where), iterations, steps, thrown,
                  tostring(inBattle()), tostring(b and b.phase),
                  tostring(b and b.afterQueue), b and b.queue and #b.queue or -1,
                  tostring(b and b.waitingUI), tostring(b and b.waitFrames),
                  tostring(b and b.draining), tostring(b and b.animPlaying)))
      note("catch: livelocked", where)
      if inBattle() then fightBattle() end
      mashUntilIdle()
      return true
    end
    if blackedOut or wiped() then return false end
    if inBattle() then
      spins = 0
      -- Let the enemy side finish being built before deciding what this is.
      -- Reading it the instant the stack top becomes a battle can return nil
      -- and drop our target into the "just fight it" branch.
      waitFor(function()
        local b = G.stack:top()
        return not inBattle() or (b.enemy and b.enemy.mon) ~= nil
      end, 20)
      local battle = G.stack:top()
      local enemy = inBattle() and battle.enemy and battle.enemy.mon or nil
      local species = enemy and enemy.species
      if battle.kind == "wild" and species and want[species] then
        -- Our target. Keep throwing until it is ours, the balls run out or
        -- the battle ends some other way (it broke out and KO'd us).
        say(("found %s (level %d) after %d steps -- throwing"):format(
            species, enemy.level or 0, steps))
        local frames = 0
        while inBattle() and #party() == startSize and frames < 4000 do
          local b = G.stack:top()
          if b.phase == "menu" then
            -- our own mon fainted mid-catch: hand back to the fight loop,
            -- which owns the replacement menu and the blackout watch
            if b.player.mon.hp <= 0 then break end
            local ball = ballInBag()
            if not ball then
              note("catch: out of balls", where)
              break
            end
            -- Soften it up first. Gen 1's catch chance scales with missing
            -- HP, so full-HP throws are the worst odds on offer -- fine for
            -- a NIDORAN at catch rate 235, hopeless for an ODDISH at 45,
            -- which ate six balls without a single shake that stuck.
            -- weakenMoveIndex only ever offers a move that leaves the
            -- target alive with a margin; when nothing is safe it returns
            -- nil and we throw rather than risk killing what we came for.
            local weaken = weakenMoveIndex(b)
            if weaken then
              if battleMenuTo(b, 1) then
                press("a")
                U.wait(6)
                for _ = 1, 8 do
                  if b.moveIndex == weaken then break end
                  press(b.moveIndex > weaken and "up" or "down")
                  U.wait(2)
                end
                press("a")
                U.wait(6)
                weakened = weakened + 1
              end
            elseif not throwBall(b, ball, where) then
              note("catch: could not throw " .. ball, where)
              break
            else
              thrown = thrown + 1
            end
          else
            press("a")
            U.wait(3)
          end
          frames = frames + 4
        end
        if #party() > startSize then
          local got = party()[#party()]
          say(("caught %s (level %d) after %d ball%s and %d weakening hit%s "
               .. "-- party is now %d")
              :format(tostring(got and got.species or species),
                      got and got.level or 0, thrown,
                      thrown == 1 and "" or "s", weakened,
                      weakened == 1 and "" or "s", #party()))
          return true
        end
        if inBattle() then fightBattle() end
      else
        seen[species or "?"] = (seen[species or "?"] or 0) + 1
        fightBattle() -- not our target, but the XP still counts
      end
      autoHeal(where, riskThreshold(where))
    elseif busy() then
      -- Deliberately NOT mashUntilIdle: it fights whatever battle it finds
      -- (mashUntilIdle -> fightBattle). An encounter opens *during* the walk
      -- below, so the very next thing this loop did was hand our target to
      -- that wait, which killed it before the branch above ever saw it --
      -- the bot stood in the right grass, met the right Pokémon and never
      -- threw a ball. Advance text only and let the battle branch decide.
      press("a")
      U.wait(6)
      spins = spins + 1
      if spins > MAX_CATCH_SPINS then
        say(("catch: stuck waiting for the overworld on %s; giving up")
            :format(tostring(where)))
        return true
      end
    else
      -- encounters only fire on steps, so pace the grass we were left in
      spins = 0
      walk(steps % 2 == 0 and "up" or "down")
      steps = steps + 1
    end
  end
  local tally = {}
  for sp, n in pairs(seen) do tally[#tally + 1] = ("%s x%d"):format(sp, n) end
  table.sort(tally)
  note(("catch: no %s after %d steps (%d balls thrown)")
       :format(table.concat(targets, "/"), steps, thrown), where)
  say(("catch: gave up on %s after %d steps, %d balls thrown, %d weakening "
       .. "hits; met %s"):format(
      table.concat(targets, "/"), steps, thrown, weakened,
      #tally > 0 and table.concat(tally, ", ") or "nothing"))
  return true
end

-- Named handlers for the route's `manual` steps. Anything without one is
-- still stubbed loudly rather than guessed at.
local MANUAL = {}

-- Vermilion Gym's trash can lock puzzle (engine/events/hidden_events/
-- vermilion_gym_trash.asm). Two switches hide in the 15 cans; both open
-- the door block at (2,2) that walls Surge off. Until then the route's
-- gotos into the north half are simply unreachable and the gym segment
-- skips -- the bot walked in, wandered and walked back out.
--
-- We cannot read where the switches are, and we should not: the first is
-- re-rolled on every Vermilion City load AND on every wrong second guess,
-- so there is nothing stable to aim at. Just check cans until the door
-- opens. The vanilla odds are poor and the re-roll makes it memoryless,
-- hence the generous budget.
local function solveTrashcans(where)
  local cans = G.data.field.hiddenExtras
                 and G.data.field.hiddenExtras.trashCans
                 and G.data.field.hiddenExtras.trashCans.cans
  if not cans or #cans == 0 then
    note("trashcans: no can data", where)
    return false
  end
  local function solved() return G.save.flags.EVENT_2ND_LOCK_OPENED == true end
  if solved() then return true end
  local tries = 0
  for _ = 1, 12 do -- passes over the grid
    for _, can in ipairs(cans) do
      if solved() then
        say(("trashcans: both locks open after %d checks"):format(tries))
        return true
      end
      -- stand next to the can and face it; stepUpTo handles the approach
      if stepUpTo(can.x, can.y) then
        press("a")
        U.wait(8)
        mashUntilIdle()
        tries = tries + 1
      end
    end
  end
  note("trashcans: unsolved", where)
  say(("trashcans: %d checks and the door is still shut"):format(tries))
  return false
end

function MANUAL.trashcans(where) return solveTrashcans(where) end

-- Evolve with a stone (Mt. Moon's MOON_STONE on the route's NIDORINO).
--
-- The whole back half of the route's move plan is aimed at a NIDOKING --
-- thrash, thunderbolt, rock_slide, ice_beam all target it -- so leaving
-- this a stub did not merely skip a step, it silently invalidated every
-- later `teach`: with no NIDOKING in the party they fell through to slot 1
-- and were spent on a WARTORTLE that cannot learn them.
--
-- Data checked against pokered (data/pokemon/evos_moves.asm:1897,
-- EVOLVE_ITEM MOON_STONE -> NIDOKING); ours matches, and the engine already
-- returns { evolveTo = ... } from ItemEffects and runs Evolution.evolve in
-- BagMenu. Only the driver was missing.
local function evolveWithStone(species, item, where)
  local slot = slotForSpecies(species)
  if not slot then
    note("evolve: no " .. tostring(species[1] or species), where)
    say(("evolve: no %s in the party"):format(tostring(species[1] or species)))
    return false
  end
  if (heldCount(item) or 0) <= 0 then
    note("evolve: no " .. item, where)
    say(("evolve: no %s in the bag"):format(item))
    return false
  end
  local before = party()[slot] and party()[slot].species
  useItemOn(item, slot, where)
  -- the evolution scene is a long one; wait it out rather than stepping on it
  for _ = 1, 200 do
    if idle() then break end
    mashUntilIdle()
  end
  local after = party()[slot] and party()[slot].species
  if after ~= before then
    say(("%s evolved into %s"):format(tostring(before), tostring(after)))
    return true
  end
  say(("evolve: %s did not evolve"):format(tostring(before)))
  return false
end

function MANUAL.evolveNidoking(where)
  return evolveWithStone({ "NIDORINO", "NIDORAN_M" }, "MOON_STONE", where)
end

-- NIDORAN_M -> NIDORINO is EVOLVE_LEVEL 16 (evos_moves.asm), so it happens
-- on its own as the trainee levels; there is nothing to drive here. Kept as
-- a real handler rather than a stub so the end-of-run summary stops listing
-- it as skipped work.
function MANUAL.evolveNidorino() return true end

-- Ride an elevator to the floor the next segment wants.
--
-- Both elevators the route uses (CELADON_MART_ELEVATOR at segment 98,
-- SILPH_CO_ELEVATOR at 140) gate real geography: the mart's upper floors
-- and most of Silph are only reachable through them.
--
-- The floor menu opens from the map's own onEnter (data/scripts/story3.lua
-- `elevator`), so it is already up by the time we get here -- there is
-- nothing to interact with. Rows are the short floor tokens pokered prints
-- ("5F", "B2F"), which is exactly the tail of the destination map id, so
-- the next segment names the button to press.
-- Ride the elevator to `wantMap` (defaults to the next segment's floor).
--
-- The floor menu opens from the elevator's own onEnter, so it is already up
-- when we arrive. If it is NOT up -- we bounced in on a stray warp and the
-- menu was dismissed, or we are on the default 1F-exit oscillation -- step
-- back onto the car's warp to re-open it before giving up.
local function rideElevator(where, wantMap)
  local want = tostring(wantMap or nextMapWanted or "")
  local token = want:match("_([^_]+)$")
  if not token then
    note("elevator: no destination floor", where)
    say(("elevator on %s: no floor named to ride to"):format(tostring(where)))
    return false
  end
  local from = ow().map.id
  if not waitFor(isList, 20) then
    -- Re-open the floor menu: the car's exit warp re-enters the elevator,
    -- firing onEnter again. This is what breaks the un-ridden bounce.
    local car = findWarpTo("ELEVATOR") or findWarpTo("")
    if car then walkOntoWarp(car.x, car.y) end
    from = ow().map.id
  end
  if not waitFor(isList, 60) then
    note("elevator: no floor menu", where)
    say(("elevator on %s: the WHICH FLOOR? menu never opened"):format(from))
    return false
  end
  local idx
  for i, row in ipairs(rows() or {}) do
    if tostring(row.label) == token then idx = i break end
  end
  if not idx then
    -- The exact floor is not on this elevator -- the Celadon roof, say, is
    -- reached by stairs from 5F, not by the car. Ride to the highest floor
    -- offered instead (nearest the roof) and let the caller walk the last
    -- stairs. Better than failing and bouncing.
    local best, bestFloor
    for i, row in ipairs(rows() or {}) do
      local n = tonumber(tostring(row.label):match("%d+"))
      if n and (not bestFloor or n > bestFloor) then best, bestFloor = i, n end
    end
    if best then
      say(("elevator on %s: no %s floor; riding to the top (%s) instead")
          :format(from, token, tostring(rows()[best].label)))
      idx = best
    else
      local have = {}
      for _, row in ipairs(rows() or {}) do have[#have + 1] = tostring(row.label) end
      note("elevator: no floor " .. token, where)
      say(("elevator on %s: wanted %s, offered %s")
          :format(from, token, table.concat(have, "/")))
      backOut()
      return false
    end
  end
  if not cursorTo("index", idx) then backOut() return false end
  press("a")
  -- ShakeElevator runs the whole ride in place -- music stop, 100 scroll
  -- bounces, the PA chime -- and only then walks us out onto the floor.
  for _ = 1, 600 do
    if ow().map.id ~= from then break end
    if idle() then U.wait(4) else mashUntilIdle() end
  end
  local landed = ow().map.id
  if landed == want then
    say(("rode the elevator to %s"):format(token))
    return true
  end
  note("elevator: landed on " .. tostring(landed), where)
  say(("elevator: wanted %s, ended on %s"):format(want, tostring(landed)))
  return false
end

MANUAL.deptElevator = rideElevator
MANUAL.silphElevator = rideElevator

-- Escape the Pokémon Tower 6F MAROWAK with a POKé DOLL.
--
-- This is not a shortcut we could skip -- it is the route's only way past
-- 6F. The route never visits the Game Corner or ROCKET_HIDEOUT (checked:
-- no segment on either map), so it never holds the SILPH_SCOPE, and
-- Map.ghostBattles marks every POKEMON_TOWER floor `unlessItem =
-- "SILPH_SCOPE"`. Without the scope the ghost cannot be damaged at all, so
-- fighting it is an infinite battle; the POKE_DOLL bought at segment 94
-- (CELADON_MART_4F) is what gets us to 7F and Mr. Fuji -- and therefore to
-- the POKE_FLUTE and the Snorlax beyond it.
--
-- ItemUsePokeDoll works on wild battles only, which the ghost is.
function MANUAL.pokeDoll(where)
  -- The battle usually opens DURING the preceding goto, where fightBattle
  -- already throws the doll (the ghost branch). Arriving here with the
  -- event set means that worked; there is nothing left to do.
  if (G.save.flags or {}).EVENT_BEAT_GHOST_MAROWAK then
    say("MAROWAK already departed (doll thrown mid-goto)")
    return true
  end
  if (heldCount("POKE_DOLL") or 0) <= 0 then
    -- The Celadon 4F stop can fail (it did -- a clerk behind a counter
    -- the old stepUpTo could not reach), and without the doll the
    -- MAROWAK is unbeatable and the tower a dead end. The mart is a
    -- short walk from Lavender, so go buy one rather than write the
    -- attempt off; the segment loop travels back to the tower on its
    -- own when the manual step ends on the wrong map.
    say("pokeDoll: none in the bag -- walking to CELADON_MART_4F to buy one")
    local back = ow().map.id
    if travelTo("CELADON_MART_4F", where) then
      ops.shop({ list = "pokeDoll" }, "CELADON_MART_4F")
      travelTo(back, where)
    end
  end
  if (heldCount("POKE_DOLL") or 0) <= 0 then
    note("pokeDoll: none in the bag", where)
    say("pokeDoll: no POKE_DOLL (the Celadon 4F stop should have bought one)")
    return false
  end
  -- the ghost engages as we approach; give it a moment to open
  for _ = 1, 120 do
    if inBattle() then break end
    if busy() then mashUntilIdle() else U.wait(4) end
  end
  if not inBattle() then
    note("pokeDoll: no battle to escape", where)
    return false
  end
  local battle = G.stack:top()
  for _ = 1, 40 do
    if not inBattle() then break end
    if battle.phase == "menu" then
      if not battleMenuTo(battle, 3) then break end
      press("a")
      if not waitFor(isList, 40) then backOut() break end
      local idx
      for i, row in ipairs(rows() or {}) do
        if row.value == "POKE_DOLL" then idx = i break end
      end
      if not idx or not cursorTo("index", idx) then backOut() break end
      press("a")
      U.wait(12)
      mashUntilIdle(400)
      break
    end
    press("a")
    U.wait(4)
  end
  if inBattle() then
    note("pokeDoll: still in the battle", where)
    say("pokeDoll: the doll did not end the MAROWAK battle")
    return false
  end
  say("escaped the MAROWAK ghost with a POKé DOLL")
  return true
end

-- Buy drinks from the Celadon Mart roof vending machines.
--
-- This is the key that opens the middle of the map. All four Saffron gates
-- turn you back until the guards have been given a drink, and Saffron sits
-- between Celadon and Lavender -- so with no drink in the bag the route
-- cannot reach Lavender for the POKE_FLUTE, and travelTo reports "no route
-- to MR_FUJIS_HOUSE" however hard it searches. One FRESH_WATER opens every
-- gate permanently.
--
-- The machines are SIGNS (10,1) (11,1) (12,2), not clerks, so ops.shop
-- cannot drive them -- they open a plain ListMenu (data/scripts/story4.lua
-- vendingMachine) which stays up between purchases, showing a "popped out!"
-- box over itself each time.
--
-- Buys several: one goes to the guards, and the roof's thirsty girl trades
-- the others for TMs. Nothing later depends on those TMs, so a short bag or
-- a thin wallet is not a failure.
local VENDING_WANT = 3

function MANUAL.giveWater(where)
  local sign
  for _, s in ipairs(ow().map.def.signs or {}) do
    if tostring(s.text or s.id or ""):find("VENDING_MACHINE") then
      sign = s
      break
    end
  end
  if not sign then
    note("giveWater: no vending machine here", where)
    return false
  end
  -- a sign is read from the cell below it, facing up
  if not ops.goto_({ x = sign.x, y = sign.y + 1 }) then
    note("giveWater: cannot reach the vending machine", where)
    return false
  end
  faceDir("up")
  press("a")
  U.wait(10)
  if not waitFor(isList, 40) then
    note("giveWater: the vending machine did not open", where)
    say("giveWater: no vending menu appeared")
    backOut()
    return false
  end
  local bought = 0
  for _ = 1, VENDING_WANT do
    if not isList() then break end
    cursorTo("index", 1) -- FRESH_WATER, the cheapest at 200
    press("a")
    U.wait(12)
    -- the purchase (or "Not enough money") prints over the list; clear it
    for _ = 1, 20 do
      if isList() then break end
      press("a")
      U.wait(4)
    end
    bought = bought + 1
  end
  backOut()
  mashUntilIdle()
  local held = 0
  for _, d in ipairs({ "FRESH_WATER", "SODA_POP", "LEMONADE" }) do
    held = held + (heldCount(d) or 0)
  end
  say(("giveWater: %d vending purchases, %d drink(s) in the bag")
      :format(bought, held))
  if held <= 0 then
    note("giveWater: no drink bought", where)
    return false
  end
  return true
end

function MANUAL.catchNidoran(where) return catchWild(CATCH_SPECIES.nidoran, where) end
function MANUAL.catchOddish(where) return catchWild(CATCH_SPECIES.oddish, where) end

-- Use a field item that takes no target (the ESCAPE ROPE).
--
-- Same bag walk as useItemOn, but there is no party menu at the end: the
-- item just fires and warps us to the last heal point.
local function useFieldItem(itemId, where)
  press("start")
  U.wait(8)
  local menu = top()
  if not (menu and menu.screenId == "StartMenu") then
    note("useItem: start menu never opened", where)
    backOut()
    return false
  end
  local itemRow
  for i, it in ipairs(menu.items or {}) do
    if it.label == "ITEM" then itemRow = i break end
  end
  if not itemRow or not cursorTo("index", itemRow) then
    note("useItem: no ITEM row", where)
    backOut()
    return false
  end
  press("a")
  U.wait(10)
  local bag = top()
  if not (bag and bag.screenId == "BagMenu") then
    note("useItem: bag never opened", where)
    backOut()
    return false
  end
  local bagRow
  for i, r in ipairs(bag.items or {}) do
    if r.value == itemId then bagRow = i break end
  end
  if not bagRow or not cursorTo("index", bagRow) then
    note("useItem: no " .. itemId .. " in the bag", where)
    backOut()
    return false
  end
  press("a")
  U.wait(8)
  if isUseToss() then -- USE is row 1
    if not cursorTo("index", 1) then backOut() return false end
    press("a")
    U.wait(10)
  end
  -- the rope warps us out; let the map change land
  local from = ow().map.id
  for _ = 1, 150 do
    if ow().map.id ~= from then break end
    if busy() then press("a") end
    U.wait(6)
  end
  if ow().map.id == from then
    backOut()
    return false
  end
  return true
end

-- Walk out through the building's exit warp. The fallback for a missing
-- ESCAPE ROPE: it does not land us where the route expects, but standing
-- still inside a house guarantees the attempt dies, and walking out at
-- least gives the segment loop a chance to re-sync.
local function leaveByDoor(where)
  local out = findWarpTo("LAST_MAP") or findWarpTo("")
  if out and walkOntoWarp(out.x, out.y) then
    say(("left %s by the door (no ESCAPE ROPE)"):format(tostring(where)))
    return true
  end
  return false
end

function ops.useItem(s, where)
  local item = s.item and tostring(s.item):upper()
  if s.move then
    -- A TM teach routed through useItem upstream (TM26 EARTHQUAKE, five
    -- times at different checkpoints). The TM exists once, so the step is
    -- made idempotent: skip when somebody already knows the move, else
    -- hand it to the teach op, whose compatibility fallback picks the
    -- lead -- the mon that actually fights for us.
    local key = tostring(s.move):upper()
    if slotKnowing(key) then return true end
    return ops.teach({ move = s.move, mon = s.mon }, where)
  end
  if item ~= "ESCAPE_ROPE" then
    -- the other useItem steps are speedrun stat items and X ATTACKs
    note("useItem", where)
    return true
  end
  if (heldCount("ESCAPE_ROPE") or 0) > 0 and useFieldItem("ESCAPE_ROPE", where) then
    -- The rope warps to the heal point, which puts us INSIDE the town's
    -- Poké Center -- but the route's next segment is the town outside it.
    -- Without stepping out the bot just stands at the nurse while every
    -- remaining segment skips: "got the ticket, used the rope, then stood
    -- there".
    local landed = ow().map.id
    say(("escape rope out of %s -> %s"):format(tostring(where), tostring(landed)))
    if tostring(landed):find("POKECENTER") then leaveByDoor(landed) end
    return true
  end
  note("useItem: escape rope failed", where)
  return leaveByDoor(where)
end

-- Wake the Route 16 / Route 12 SNORLAX.
--
-- Defined down here because it needs useFieldItem. The flute must be USED
-- from the bag while standing next to it -- talking to Snorlax with the
-- flute in the bag does nothing (ItemEffects' adjacentSleepingSnorlax, and
-- data/scripts/story.lua's snorlaxWake). Waking it starts a static battle,
-- so the fight is driven before handing back.
function MANUAL.playPokeFlute(where)
  local snorlax
  for _, npc in ipairs(ow().npcs) do
    local id = tostring((npc.def and (npc.def.id or npc.def.sprite)) or "")
    if id:find("SNORLAX") then snorlax = npc break end
  end
  if not snorlax then
    note("playPokeFlute: no SNORLAX here", where)
    say(("playPokeFlute: nothing asleep on %s"):format(ow().map.id))
    return false
  end
  if (heldCount("POKE_FLUTE") or 0) <= 0 then
    note("playPokeFlute: no POKE_FLUTE", where)
    say("playPokeFlute: the flute is not in the bag (Mr. Fuji not yet reached?)")
    return false
  end
  if not stepUpTo(snorlax.cellX, snorlax.cellY) then
    note("playPokeFlute: cannot reach SNORLAX", where)
    return false
  end
  local p = ow().player
  local dx, dy = snorlax.cellX - p.cellX, snorlax.cellY - p.cellY
  faceDir((dx > 0 and "right") or (dx < 0 and "left")
          or (dy > 0 and "down") or "up")
  useFieldItem("POKE_FLUTE", where)
  -- waking it is a static battle, not a warp
  for _ = 1, 200 do
    if inBattle() then fightBattle()
    elseif idle() then break
    else mashUntilIdle() end
  end
  local still = false
  for _, npc in ipairs(ow().npcs) do
    local id = tostring((npc.def and (npc.def.id or npc.def.sprite)) or "")
    if id:find("SNORLAX") then still = true break end
  end
  if still then
    note("playPokeFlute: SNORLAX still there", where)
    return false
  end
  say("SNORLAX woke up and the way is clear")
  return true
end

function ops.manual(s, where)
  local fn = MANUAL[s.name]
  if not fn then
    note("manual:" .. s.name, where)
    return true
  end
  return fn(where)
end

-- ---------------------------------------------------------------------
-- runner
-- ---------------------------------------------------------------------

-- One pass over the route. Returns false if the party wiped, so the caller
-- can restart from a fresh game the way PokeBotBad's Strategies.reset does
-- -- a blackout dumps us at the heal point with the route pointing
-- somewhere else entirely, and there is no sane way to re-sync mid-run.
-- A cutscene rarely carries us past more than a couple of segments; a long
-- unbroken run of skips means the attempt is lost, not merely ahead.
local MAX_CONSECUTIVE_SKIPS = 8

-- How far back a lost attempt will rewind before giving up. Each rewind
-- goes strictly further back than the last.
local MAX_REWINDS = 4

-- How many times a lost attempt will WALK to the segment's map before
-- falling back to rewinding. Tried first because it resumes the route
-- where it left off rather than replaying, but it is a long walk, so a
-- run that keeps needing one is lost for some other reason.
local MAX_TRAVEL_RESCUES = 3

-- How many maps a deferred grind will try before being dropped.
local MAX_PENDING_GRINDS = 3

-- Grind wild encounters where we stand until the lead gains a level.
--
-- Used after a second death on the same segment: arriving healthy was not
-- enough, so the answer is levels rather than another attempt at the same
-- HP. We do NOT flee here (that is the point) and we top up between
-- encounters, so this doubles as the "heal until ready" half.
local recoverFromBlackout

-- Can a wild encounter fire on this cell?
--
-- Mirrors OverworldController's own test (the `grass / surfing / indoor`
-- branch around line 2307): grass with an encounter table, or any tile on an
-- indoor map that has one and is not the excluded tileset.
local function encounterCell(map, x, y)
  if not (G.data.encounters and G.data.encounters[map.id]) then return false end
  if map:isGrassCell(x, y) then return true end
  local indoor = G.data.field and G.data.field.indoorEncounters
  return indoor ~= nil
     and (map.def.index or -1) >= indoor.firstIndoorMap
     and map.def.tileset ~= indoor.excludedTileset
end

-- Walk to the nearest cell where an encounter can actually fire.
--
-- Without this, grindALevel paced up and down wherever the blackout left us
-- -- which is a POKé CENTER, indoors, with no encounter table at all. It
-- looked like the bot "wigging out" on the spot: 200 steps of walking into
-- the counter, no encounters possible, then "grind gave up".
local function gotoEncounterCell(map)
  local p = ow().player
  if encounterCell(map, p.cellX, p.cellY) then return true end
  local best, bestD
  for y = 0, (map.heightCells or 0) - 1 do
    for x = 0, (map.widthCells or 0) - 1 do
      if encounterCell(map, x, y) and map:isWalkableCell(x, y) then
        local d = math.abs(x - p.cellX) + math.abs(y - p.cellY)
        if not bestD or d < bestD then best, bestD = { x, y }, d end
      end
    end
  end
  if not best then return false end
  ops.goto_({ x = best[1], y = best[2] })
  p = ow().player
  return encounterCell(ow().map, p.cellX, p.cellY)
end

local function grindALevel(where)
  local lead = party()[1]
  if not lead or not lead.level then return false end
  -- Grinding only works where wild mons live. After a blackout we are
  -- standing in a Poké Center, so check before pacing rather than after.
  if not gotoEncounterCell(ow().map) then
    -- Nothing to fight here -- but a town is usually one step from a route
    -- that is all grass. Cerulean is the case that forced this: the rival
    -- north of town kept killing us, the city has no encounters at all, and
    -- so "train before trying again" could never do anything and the run
    -- was written off as hopeless while a full training ground sat one map
    -- away. Cross into a connected map that has wild mons and grind there;
    -- the segment loop re-syncs us afterwards.
    --
    -- A SINGLE seam hop to an adjacent grassy map -- never travelTo.
    --
    -- travelTo plans multi-hop and, when the direct seam is shut, hunts an
    -- alternate route: asked to reach ROUTE_3 for grinding from Pewter with
    -- that seam briefly unwalkable, it walked the bot clear across the map
    -- to ROUTE_21 and abandoned the run. Grinding only ever wants the grass
    -- next door, so cross exactly one connection with crossSeam (which uses
    -- the edge-exit idiom the old hand-rolled version got wrong -- it aimed
    -- at in-bounds cells and never reached the border) and give up if that
    -- one hop does not land somewhere with encounters.
    local from = ow().map
    local fromId = from.id
    local moved = false
    for dir, conn in pairs(from.def.connections or {}) do
      local dest = conn.map or conn.destMap
      if dest and G.data.encounters and G.data.encounters[dest] then
        say(("grind: %s has no wild mons; crossing %s into %s"):format(
            tostring(fromId), dir, tostring(dest)))
        crossSeam({ to = dest, dir = COMPASS_DIR[dir],
                    cells = seamCells(from.def, dir, conn) })
        if ow().map.id ~= fromId and G.data.encounters[ow().map.id] then
          moved = true
          break
        end
      end
    end
    if not (moved and gotoEncounterCell(ow().map)) then
      say(("grind: no wild encounters reachable from %s; skipping")
          :format(tostring(from.id)))
      return false
    end
  end
  local target = lead.level + 1
  say(("grinding on %s: %s is level %d, want %d")
      :format(tostring(where), tostring(lead.species or "lead"), lead.level, target))
  local sinceBattle = 0
  local stuckPaces = 0
  for _ = 1, 900 do
    if blackedOut then return false end
    local now = party()[1]
    if not now or (now.level or 0) >= target then
      say(("grind done: level %d"):format(now and now.level or 0))
      return true
    end
    if inBattle() then
      grinding = true -- suppress the flee guard: fleeing earns no XP
      fightBattle()
      grinding = false
      sinceBattle = 0
      autoHeal(where, 0.7)
    elseif busy() then
      mashUntilIdle()
    else
      -- Encounters only fire on steps taken ON an encounter tile, so pacing
      -- is only useful while we are still standing on one -- two steps in a
      -- straight line can walk off the grass strip entirely.
      local p = ow().player
      if not encounterCell(ow().map, p.cellX, p.cellY) then
        if not gotoEncounterCell(ow().map) then
          say("grind gave up: walked off the grass and cannot get back")
          return false
        end
      end
      -- Pace along whichever axis actually moves. The old strictly
      -- vertical pace zeroed out on a one-cell-tall grass strip -- both
      -- steps hit walls, no step means no encounter roll, and 200 idle
      -- iterations later the grind reported "no encounters here" while
      -- standing in perfectly good grass (Route 2's northern patch).
      local before = ow().player
      local bx, by = before.cellX, before.cellY
      if not walk(sinceBattle % 2 == 0 and "up" or "down") then
        walk(sinceBattle % 2 == 0 and "left" or "right")
      end
      local after = ow().player
      if after.cellX ~= bx or after.cellY ~= by then
        stuckPaces = 0
      else
        stuckPaces = (stuckPaces or 0) + 1
        if stuckPaces > 24 then
          say("grind gave up: boxed in, nothing to pace on")
          return false
        end
      end
      sinceBattle = sinceBattle + 1
      if sinceBattle > 200 then
        say("grind gave up: no encounters here")
        return false
      end
    end
  end
  return false
end

-- Levels to ask for in one recovery.
local MAX_GRIND_LEVELS = 3

-- Deaths between grind sessions. A death never ends the run -- we go back
-- and try again -- but every Nth one buys levels first. Retrying is cheap
-- and the RNG wins plenty of close fights on its own; a grind is minutes of
-- pacing, so it is paid periodically rather than per death.
local DEATHS_PER_GRIND = 10
-- Gyms are walls, not variance: fixed roster, always entered healed, and
-- nothing to spend before Pewter. Grind sooner there. See recoverFromBlackout.
local DEATHS_PER_GRIND_GYM = 3

-- How far back a death is allowed to rewind us before we walk back to the
-- segment instead. Past this the replay costs more than the trip.
local MAX_RESUME_REWIND = 12

-- Grind up to `n` levels, topping up in between. Returns levels actually
-- gained, which is the number that matters: a death is only worth retrying
-- if we came back stronger than we went in.
local function grindLevels(n, where)
  local lead = party()[1]
  local before = lead and lead.level or 0
  for round = 1, n do
    if blackedOut then break end
    if not grindALevel(where) then break end
    -- items only between rounds; a nurse trip warps us off the grass and
    -- grindALevel would just have to walk back to it
    autoHeal(where, 0.9)
    if round < n then
      say(("training on: %d of %d levels"):format(round, n))
    end
  end
  local now = party()[1]
  return math.max(0, (now and now.level or 0) - before)
end

-- ---------------------------------------------------------------------
-- checkpoints
-- ---------------------------------------------------------------------
--
-- Every blocker so far has been late in the route, and re-reaching it costs
-- a full replay from Pallet Town. So when the run gets stuck, write the
-- game's own save plus the segment we died on; POKEPORT_ROUTE_RESUME=1 then
-- picks up there instead of starting over. Fix, resume, see the fix -- in
-- seconds rather than a quarter of an hour.
--
--   POKEPORT_ROUTE_STOP_ON_STUCK=1  save and stop rather than restarting
--   POKEPORT_ROUTE_RESUME=1         load the checkpoint instead of a new game
--   POKEPORT_ROUTE_CHECKPOINT=path  where it lives
local CHECKPOINT_PATH = os.getenv("POKEPORT_ROUTE_CHECKPOINT")
                        or "/tmp/pokeport_route_checkpoint.lua"
local STOP_ON_STUCK = os.getenv("POKEPORT_ROUTE_STOP_ON_STUCK") == "1"

local function saveCheckpoint(i, reason)
  -- Game:writeSave(), NOT G:save -- `Game.save` is the save DATA table, so
  -- calling it as a method fails with "attempt to call method 'save'".
  local ok, err = pcall(function() G:writeSave() end)
  if not ok then
    say(("checkpoint: the game would not save (%s)"):format(tostring(err)))
    return false
  end
  local fh = io.open(CHECKPOINT_PATH, "w")
  if not fh then
    say("checkpoint: could not write " .. CHECKPOINT_PATH)
    return false
  end
  fh:write("-- written by tests/drivers/route.lua; safe to delete\n")
  fh:write(("return { segment = %d, reason = %q, map = %q }\n")
           :format(i, tostring(reason), tostring(ow().map.id)))
  fh:close()
  say(("checkpoint: saved at segment %d/%d on %s (%s) -- resume with "
       .. "POKEPORT_ROUTE_RESUME=1"):format(i, #ROUTE, tostring(ow().map.id),
                                            tostring(reason)))
  return true
end

local function loadCheckpoint()
  local chunk = loadfile(CHECKPOINT_PATH)
  if not chunk then return nil end
  local ok, data = pcall(chunk)
  if not ok or type(data) ~= "table" or type(data.segment) ~= "number" then
    return nil
  end
  return data
end

local function runRoute(startIndex)
  local failures, skips = 0, 0
  -- the last segment we actually ran: a blackout only shows up once we are
  -- already at the heal point, so this is what the death gets attributed to
  local lastRanMap
  local diedOn = {} -- segment index -> deaths this attempt
  -- segment index -> deaths in a row where training gained no levels.
  -- Reported, not acted on: no death count writes off a segment any more.
  -- A long barren streak means the grind cannot reach a training ground
  -- from where we keep waking up, which is a bug to go and read, not a
  -- reason to stop the run.
  local barren = {}
  -- Rewinding: each one must go strictly further back than the last, or a
  -- pair of segments could bounce us between them forever.
  local rewinds, rewindFloor = 0, #ROUTE + 1
  -- Cross-map rescues spent getting un-lost. Capped for the same reason
  -- rewinds are: travelling to the segment's map fixes being in the wrong
  -- PLACE, and if we keep ending up lost anyway the problem is something
  -- else and retrying the walk forever just burns the attempt quietly.
  local travels = 0
  -- Grinds owed but not yet spendable (see recoverFromBlackout): the death
  -- happens in a gym, the wake-up is in a Poké Center, and the grass is
  -- somewhere between the two.
  local pendingGrind = 0
  blackedOut = false -- each attempt starts from a fresh game

  -- Recover from a blackout instead of throwing the run away.
  --
  -- We respawn at the last heal point, fully healed, so the only thing
  -- missing is a way back. Rather than pathfind cross-map, hand the route
  -- itself the job: rewind to the most recent segment that starts on the
  -- map we woke up in, and let the normal waypoints walk us forward again.
  -- That is usually a handful of segments, not a restart.
  local function resumeIndexFor(i, mapId)
    for j = i, 1, -1 do
      if ROUTE[j].map == mapId then return j end
    end
  end

  -- Returns the segment index to resume from, or nil to abandon the attempt.
  function recoverFromBlackout(i, wokeOn, diedMap)
    blackedOut = false
    diedOn[i] = (diedOn[i] or 0) + 1

    -- Losing the lab rival costs nothing in the original: the battle counts
    -- either way (oaks_lab.lua sets EVENT_BATTLED_RIVAL_IN_OAKS_LAB on a
    -- loss too), we keep the starter, and the story carries on. So the lab
    -- has no work left for us and the honest resume is to step OVER it.
    -- Rewinding onto it the way the generic path would walks back in to
    -- re-run `talk` and a `battle` op that can no longer fire; restarting --
    -- what this used to do -- threw the run away over a near-even level-5
    -- mirror match we would only lose again just as often.
    if diedMap == "OAKS_LAB" and ROUTE[i + 1] and ROUTE[i + 1].map == wokeOn then
      say(("wiped to the lab rival -- the battle still counted, resuming from "
           .. "segment %d/%d"):format(i + 1, #ROUTE))
      return i + 1
    end

    -- Get out of the Poké Center before anything else.
    --
    -- A blackout leaves us INSIDE one, where no encounter can ever fire, so
    -- training attempted from here reports "no wild encounters reachable on
    -- <TOWN>_POKECENTER" and gains nothing -- every time, for every death.
    -- Cerulean burned three deaths that way before declaring itself
    -- hopeless. Step out first; the grind and the resume both want the town.
    if tostring(wokeOn):find("POKECENTER") then
      local out = findWarpTo("LAST_MAP") or findWarpTo("")
      if out and walkOntoWarp(out.x, out.y) then wokeOn = ow().map.id end
    end

    -- Second death on the same segment: arriving healthy clearly is not
    -- enough, so come back STRONGER rather than merely repeating the attempt.
    --
    -- Dying is a signal that we are underlevelled, and the answer to
    -- underlevelled is levels: grind, heal, grind again, top up once more and
    -- walk back in. A segment is NEVER abandoned for killing us, however
    -- many times -- the run just keeps going back.
    --
    -- The grind runs every DEATHS_PER_GRIND deaths rather than on every one.
    -- Retrying is cheap and the RNG alone wins plenty of fights that were
    -- close; a grind session is minutes of walking in circles, so paying it
    -- per death made a bad segment eat the whole run in training rather
    -- than in attempts.
    -- Gyms grind sooner than the rest of the route.
    --
    -- A route death is often just variance -- a bad crit, a trainer met at
    -- the wrong HP -- and walking back is cheap, so ten tries before paying
    -- for a grind is a fair trade there. A gym is not that: the roster is
    -- fixed, we arrive healed every time, and there is no item to spend
    -- before Pewter (Viridian Mart sells no POTION at all and the Pewter
    -- shop is segment 28, AFTER Brock at 26). So a gym that beat us will
    -- beat us again in the same way, and levels are the only variable we
    -- control. Brock took seven deaths in a row at ten-per-grind, each one
    -- a free walk back to the same loss.
    local gymHere = tostring(ROUTE[i] and ROUTE[i].map):find("GYM") ~= nil
    local everyN = gymHere and DEATHS_PER_GRIND_GYM or DEATHS_PER_GRIND
    if diedOn[i] % everyN == 0 then
      say(("segment %d/%d has killed us %dx this attempt -- training before "
           .. "another try"):format(i, #ROUTE, diedOn[i]))
      -- ask for more the more it has beaten us, capped so one bad segment
      -- cannot eat the whole run
      local want = math.min(diedOn[i] - 1, MAX_GRIND_LEVELS)
      local gained = grindLevels(want, wokeOn)
      -- Grinding MOVES us. gotoEncounterCell walks to the nearest cell that
      -- can actually spawn something, and when the wake-up map has no wild
      -- mons at all that means crossing into a neighbour -- "PEWTER_CITY
      -- has no wild mons; crossing south into ROUTE_2". Everything below
      -- decides where to resume from `wokeOn`, so leaving it stale resumes
      -- onto a segment for the town while we are standing on the route:
      -- "resuming from segment 29/197" followed immediately by "skipping
      -- segment 29: expects PEWTER_CITY, on ROUTE_2", and then every
      -- segment through Mt. Moon skipping in one burst.
      wokeOn = ow().map.id
      if blackedOut then
        -- died while training: we are back at the heal point, which is where
        -- we were going to resume from anyway. Clear it and carry on.
        blackedOut = false
        say("died while training")
      end
      if gained > 0 then
        barren[i] = 0
        say(("training done: %d level%s gained, healing before another try")
            :format(gained, gained == 1 and "" or "s"))
        -- the last top-up before walking back in; the nurse is free and we
        -- are standing next to one
        autoHeal(wokeOn, 1.0, true)
      else
        -- We wake in a Poké Center, where no encounter can fire, so this
        -- often cannot grind HERE at all. Carry the intent and let the main
        -- loop spend it on the first map with wild mons -- the grass the
        -- route walks us back through.
        barren[i] = (barren[i] or 0) + 1
        pendingGrind = math.min((pendingGrind or 0) + 1, MAX_PENDING_GRINDS)
        say(("training gained nothing (%d in a row); deferred to the next map "
             .. "with wild encounters"):format(barren[i]))
        -- Deliberately NOT a give-up. A segment is never written off for
        -- killing us, however often: the run keeps trying, and a grind
        -- session every DEATHS_PER_GRIND deaths is what changes the odds
        -- between attempts. A grind that gains nothing is worth logging,
        -- not worth ending a run over -- the training ground is often just
        -- somewhere this recovery could not reach yet.
      end
    end

    -- We respawn INSIDE a Poké Center, and the route walks *past* centres
    -- far more often than through them -- only 3 of 197 segments are one.
    -- So the map we wake up on is usually absent from the route entirely.
    -- Step outside and resume from the city instead of giving up: this is
    -- what made a death in Pewter Gym restart the whole run even though we
    -- had already beaten Brock.
    -- Step outside BEFORE choosing where to resume.
    --
    -- We always wake inside a Poké Center, and when the route happens to have
    -- a segment for that town's centre, resumeIndexFor matches it and we
    -- resume onto a step whose waypoints only make sense on the way IN. The
    -- segment then walks straight back out, logs "left ... partway through;
    -- re-syncing", and we die at the same place again: Cerulean looped
    -- 40 -> die at 46 -> 40 with the failure count climbing 13, 16, 20, 24.
    -- Resuming from the town is always the useful answer.
    if tostring(wokeOn):find("POKECENTER") then
      local out = findWarpTo("LAST_MAP") or findWarpTo("")
      if out and walkOntoWarp(out.x, out.y) then wokeOn = ow().map.id end
    end
    local j = resumeIndexFor(i, wokeOn)
    if not j then
      local out = findWarpTo("LAST_MAP") or findWarpTo("")
      if out and walkOntoWarp(out.x, out.y) then
        wokeOn = ow().map.id
        j = resumeIndexFor(i, wokeOn)
      end
    end
    -- Resuming a LONG way back is worse than walking back.
    --
    -- resumeIndexFor picks the most recent segment starting on the map we
    -- are standing on, which is fine when that is a step or two behind and
    -- ruinous when it is not. Dying on ROUTE_9 (segment 76) and grinding
    -- beforehand left us on ROUTE_4, whose most recent segment is 38 -- so
    -- one death discarded thirty-eight segments, and everything from Mt.
    -- Moon forward had to be replayed to get back to the fight that killed
    -- us. Walking back to where we died costs minutes; replaying costs the
    -- run. Only accept a rewind that is genuinely nearby.
    if j and (i - j) > MAX_RESUME_REWIND then
      say(("wiped on %s -- the nearest segment on %s is %d/%d, %d back; "
           .. "walking to %s instead"):format(tostring(diedMap),
          tostring(wokeOn), j, #ROUTE, i - j, ROUTE[i].map))
      if travelTo(ROUTE[i].map, wokeOn) then return i end
      say("the walk back failed; falling back to the rewind")
    end
    -- Nothing in the route starts where we woke up. Walk back to the map
    -- the segment we died on wants and carry on from there -- the run is
    -- never restarted or abandoned over a death, so this has to produce an
    -- answer. Vermilion is the case that needs it: dying on ROUTE_6 wakes
    -- us in VERMILION_POKECENTER, which no segment starts on.
    if not j and travelTo(ROUTE[i].map, wokeOn) then
      say(("wiped on %s, woke on %s with no segment there -- travelled back "
           .. "to %s"):format(tostring(diedMap), tostring(wokeOn), ROUTE[i].map))
      return i
    end
    if not j then
      -- Even the walk failed. Retry the segment where we stand rather than
      -- throwing the attempt away; the loop's own map-wait and the
      -- lost-segment rescue get another go at re-syncing us.
      say(("wiped on %s, woke on %s -- no segment starts there and the walk "
           .. "back failed; retrying segment %d/%d anyway")
          :format(tostring(diedMap), tostring(wokeOn), i, #ROUTE))
      return i
    end
    say(("wiped on %s (now %dx) -- woke on %s, resuming from segment %d/%d "
         .. "instead of restarting")
        :format(tostring(diedMap), dangerAt(diedMap), tostring(wokeOn), j, #ROUTE))
    return j
  end

  -- Every way an attempt can be written off funnels through here, so
  -- POKEPORT_ROUTE_STOP_ON_STUCK covers deaths as well as lost-in-the-route
  -- skips: checkpoint, then stop instead of replaying from Pallet Town.
  -- Returns nil to stop the whole run, false to restart the attempt.
  local function abandon(at, reason)
    saveCheckpoint(at, reason)
    if STOP_ON_STUCK then return nil end
    return false
  end

  local i = (startIndex and startIndex > 1) and (startIndex - 1) or 0
  while i < #ROUTE do
    i = i + 1
    local seg = ROUTE[i]
    -- ops.fieldMove and the elevator handler read where the NEXT segment
    -- wants us; set it up here so both can see it from the loop's top.
    nextMapWanted = ROUTE[i + 1] and ROUTE[i + 1].map or nil

    -- Standing in an elevator? Ride out to the floor we need, before the
    -- map-wait can react to a bounce.
    --
    -- An elevator is entered two ways, and both end here: on purpose (the
    -- route's segment 98), or by accident -- a floor's elevator-door warp
    -- at (1,1) catching a goto mid-climb. Either way, an un-ridden car
    -- oscillates on its default 1F exit (ELEVATOR <-> 1F forever), which is
    -- what wedged the run at Celadon. Checking the PHYSICAL map, not
    -- seg.map, catches the accidental case the seg.map-only check missed.
    -- Ride to seg.map's own floor when we were mid-climb, or to the next
    -- segment's floor when this segment IS the elevator.
    if tostring(ow().map.id):find("ELEVATOR") then
      local floor = tostring(seg.map):find("ELEVATOR") and nextMapWanted or seg.map
      rideElevator("elevator", floor)
      if tostring(seg.map):find("ELEVATOR") then goto nextSegment end
    end

    -- Once the essential Celadon Mart shopping is done, LEAVE.
    --
    -- The only things the mart is climbed for are the POKE_DOLL (4F, the
    -- Marowak escape) and a drink (roof, the Saffron gates). After those,
    -- the route's remaining mart segments -- 5F again, the elevator, 1F --
    -- are pure descent, and they are a warp bounce-trap: the elevator drops
    -- you onto the reciprocal warp and oscillates ELEVATOR <-> 1F forever.
    -- So when both essentials are in the bag and we are still in the mart,
    -- walk out to CELADON_CITY and jump to the segment that resumes there,
    -- skipping the whole fragile descent.
    local function hasDrink()
      for _, d in ipairs({ "FRESH_WATER", "SODA_POP", "LEMONADE" }) do
        if (heldCount(d) or 0) > 0 then return true end
      end
      return false
    end
    if tostring(seg.map):find("CELADON_MART")
       and (heldCount("POKE_DOLL") or 0) > 0 and hasDrink() then
      for j = i, math.min(i + 8, #ROUTE) do
        if ROUTE[j].map == "CELADON_CITY" then
          say(("Celadon Mart done (POKE_DOLL + drink) -- leaving to "
               .. "CELADON_CITY, resuming segment %d/%d"):format(j, #ROUTE))
          if travelTo("CELADON_CITY", seg.map) then i = j - 1 end
          goto nextSegment
        end
      end
    end

    -- The route rides the Celadon elevator only to descend to 1F, and every
    -- Celadon floor is joined by stairs, so the elevator is optional there
    -- and a liability (see the bounce-trap note in mapGraph). If this
    -- segment IS the elevator and we are not in it, skip it -- the next
    -- segment's floor is reached by the stairs-based travelTo below.
    if tostring(seg.map):find("CELADON_MART_ELEVATOR") then
      goto nextSegment
    end

    -- Multi-floor interior: climb by stairs via travelTo, not the route's
    -- per-floor gotos. Celadon Mart is six floors joined by up/down stairs
    -- (and an elevator), and the route walks each floor by hand -- a path
    -- that keeps stepping onto the wrong staircase or the elevator door and
    -- desyncing, which is what skipped the ROOF and its Fresh Water (the
    -- key to every Saffron gate). travelTo targets each specific stair warp
    -- and climbs cleanly; the segment's own steps then handle the in-floor
    -- shopping once we are on the right floor.
    if ow().map.id ~= seg.map and tostring(seg.map):find("CELADON_MART") then
      travelTo(seg.map, seg.map)
    end

    -- Wait for the map to actually be the one this segment describes.
    --
    -- PokeBotBad advances its path list on map CHANGE (action/walk.lua:91)
    -- rather than by counting steps, and that difference matters: a warp
    -- or a cutscene can still be in flight when the previous segment's
    -- last waypoint lands. Oak's escort is the worst case -- it walks the
    -- player from Pallet Town into the lab over many frames, so running
    -- the lab segment immediately fires the starter pick and the rival
    -- battle out in Pallet Town, where they silently do nothing. The
    -- rival then never leaves, and blocks the route on the return visit.
    if ow().map.id ~= seg.map then
      for _ = 1, 240 do
        if ow().map.id == seg.map then break end
        if inBattle() then fightBattle()
        elseif busy() then mashUntilIdle()
        else U.wait(5) end
      end
    end
    local here = ow().map.id
    if here ~= seg.map then
      -- Never run a segment's steps on the wrong map: the waypoints are
      -- meaningless there and the interactions land on whatever happens
      -- to be adjacent. Skip it and let a later segment re-sync.
      -- A blackout is the one mismatch that will never re-sync: it drops us
      -- at the heal point while the route points somewhere else, so every
      -- remaining segment skips in one burst and the attempt reports a
      -- full-length pass over nothing. End it here instead.
      if blackedOut then
        -- `here` is the heal point, not where we died -- blame the last
        -- segment we actually ran, or the memory learns "Poké Center is
        -- dangerous" and nothing useful.
        recordDeath(lastRanMap)
        local resumed = recoverFromBlackout(i, here, lastRanMap)
        if not resumed then return abandon(i, "died too many times") end
        i = resumed - 1 -- the loop's own i = i + 1 lands us on it
        goto nextSegment
      end
      -- We are on a sub-map the route has finished with, and nothing walks
      -- us out of it. Any map with a LAST_MAP warp is one we entered from
      -- somewhere else, so that warp is the way back to a map the route
      -- still has segments for.
      --
      -- Poké Centers are the case that made this obvious (a blackout or an
      -- ESCAPE ROPE drops us in one), but they are not the only one:
      -- VERMILION_DOCK strands us the same way. Its segment 68 is the single
      -- step `goto (14,2)` -- the gangplank tile we are already standing on
      -- when we disembark -- while the exit is warp 1 at (14,0), which the
      -- route never mentions. The bot stood on the arrival tile and skipped
      -- every remaining segment.
      local wayOut = findWarpTo("LAST_MAP")
      if wayOut then
        local from = here
        if walkOntoWarp(wayOut.x, wayOut.y) then
          here = ow().map.id
          say(("stepped out of %s onto %s"):format(tostring(from), tostring(here)))
          if here == seg.map then
            skips = 0
            goto runSegment
          end
        end
      end
      say(("skipping segment %d/%d: expects %s, on %s")
          :format(i, #ROUTE, seg.map, here))
      failures = failures + 1
      skips = skips + 1
      -- Skipping is meant to step over a segment a cutscene carried us
      -- past. A long unbroken run of them means we are lost, and carrying
      -- on is actively dangerous: the route revisits maps, so segment 175
      -- (the ENDGAME Viridian Gym) matches "VIRIDIAN_CITY" just as well as
      -- segment 12 does. One desynced attempt did exactly that and spent
      -- its remaining time walking a level-12 party into a gym locked
      -- until seven badges.
      if skips > MAX_CONSECUTIVE_SKIPS then
        -- Rewind FURTHER before writing the attempt off.
        --
        -- Resuming lands us on a segment that merely *matches* the map we
        -- woke on, which is not the same as one that LEADS anywhere: after
        -- a Cerulean death the resume sat on CERULEAN_CITY while segments
        -- 46+ wanted ROUTE_24, BILLS_HOUSE, VERMILION... and every one
        -- skipped. The route already contains the walk we need -- it is
        -- just earlier in the list. So step back to an earlier segment on
        -- the map we are actually standing on and let the route drive us
        -- forward again, rather than giving up on a run that is merely
        -- pointed at the wrong entry.
        local j
        for k = math.min(rewindFloor, i) - 1, 1, -1 do
          if ROUTE[k].map == here then j = k break end
        end
        if j and rewinds < MAX_REWINDS then
          rewinds = rewinds + 1
          rewindFloor = j
          skips = 0
          say(("lost on %s -- rewinding to segment %d/%d (rewind %d/%d) "
               .. "instead of abandoning"):format(here, j, #ROUTE, rewinds,
                                                  MAX_REWINDS))
          i = j - 1
          goto nextSegment
        end
        -- Last resort, AFTER the rewind has run out of ideas.
        --
        -- Ordering matters and was learned the hard way: this used to run
        -- BEFORE the rewind, on the theory that walking to the segment's
        -- map is more honest than replaying. It is -- but it is also a long
        -- walk that MOVES us, and moving invalidates the rewind targets
        -- behind it. A Mt. Moon attempt that the rewind alone had always
        -- recovered instead travelled to MT_MOON_1F, failed to find the
        -- B1F staircase, rewound from there and walked back out to ROUTE_4
        -- worse off than it started. The rewind is cheap and proven; this
        -- is neither, so it only gets the cases the rewind cannot take.
        if travels < MAX_TRAVEL_RESCUES and travelTo(seg.map, here) then
          travels = travels + 1
          skips = 0
          say(("travelled to %s -- resuming segment %d/%d (rescue %d/%d)")
              :format(seg.map, i, #ROUTE, travels, MAX_TRAVEL_RESCUES))
          i = i - 1
          goto nextSegment
        end
        -- A failed travelTo still moves us -- it abandons the trip wherever
        -- the last hop landed -- so report where we actually are.
        here = ow().map.id
        say(("lost: %d segments skipped in a row, abandoning attempt at %d/%d")
            :format(skips, i, #ROUTE))
        return abandon(i, ("lost on %s, expected %s"):format(here, seg.map))
      end
      goto nextSegment
    end
    ::runSegment::
    skips = 0
    lastRanMap = seg.map
    -- Spend a deferred grind as soon as we are somewhere it can work.
    if pendingGrind > 0 and G.data.encounters and G.data.encounters[seg.map] then
      if grindALevel(seg.map) then
        pendingGrind = 0
      else
        pendingGrind = pendingGrind - 1 -- do not keep retrying forever
      end
    end
    -- About to walk into a gym: stop at the town's Poké Center first.
    --
    -- Two payoffs, and the second is the bigger one. It heals to full for
    -- free, and the nurse writes the heal point (SetLastBlackoutMap), so a
    -- loss respawns us next door instead of wherever we last healed. Without
    -- this the bot arrived at Brock healthy, never touched Pewter's centre,
    -- and its respawn was still VIRIDIAN -- so every Brock death cost a full
    -- recrossing of Viridian Forest. It died to Brock on the first attempt in
    -- three runs straight, and paid that walk each time.
    -- RESTORED: the pre-gym Poké Center stop (allowCenter = true).
    --
    -- It was removed because the nurse writes the heal point and the route
    -- TRAVELS by heal point: segment 72 leaves the Pokémon Fan Club with
    -- `fieldMove dig`, DIG warps to the last Poké Center town, and the
    -- route assumes that is Cerulean -- so topping up at Vermilion before
    -- Surge silently retargeted the trip and stranded the run. The note
    -- left here said the fix was "NOT to put this back as it was -- it is
    -- to make the return trip independent of the heal point".
    --
    -- That is now done: ops.fieldMove re-targets DIG and FLY through
    -- travelTo when the landing map is not what the next segment wants, so
    -- where we last healed no longer steers the route. The precondition is
    -- met, so the stop comes back.
    --
    -- It is worth real time. Without it the heal point stays wherever it
    -- happened to be -- a ROUTE_3 death after Pewter woke us in VIRIDIAN
    -- and cost a full re-crossing of Viridian Forest -- and gym losses
    -- respawn a town behind instead of next door.
    -- nextMapWanted is already set at the loop top (ops.fieldMove and the
    -- elevator handler both read it); nextSeg here is just for the gym test.
    local nextSeg = ROUTE[i + 1]
    if nextSeg and tostring(nextSeg.map):find("GYM") then
      -- Unconditional, NOT via autoHeal's threshold.
      --
      -- autoHeal only walks to a nurse when HP is under the bar, and we
      -- arrive at gyms healthy -- so routing this through it did nothing at
      -- all: PEWTER_GYM still killed us five times with VIRIDIAN as the
      -- respawn, paying a re-crossing of Viridian Forest each time. The
      -- heal is the smaller half of this stop; the heal POINT is the point.
      visitPokeCenter(seg.map, true)
      healAnchor = seg.map
      autoHeal(seg.map, 0.95, true)
    end
    -- Keep the respawn near where we actually are.
    --
    -- A blackout warps to wLastBlackoutMap, and the nurse is the only thing
    -- that moves it. Left alone it lags badly: with VERMILION as the last
    -- centre, a death in ROCK_TUNNEL_B1F woke us there and resumed eight
    -- segments back, replaying the Fan Club DIG and the whole underground
    -- walk to Cerulean -- twice in a row, which is most of what a stalled
    -- run is actually spending its time on.
    --
    -- Once per town, and only when we are ACTUALLY STANDING on that town.
    --
    -- The guard is `ow().map.id == seg.map`, and it is load-bearing, not
    -- belt-and-braces. findWarpTo reads the CURRENT map, but the fire
    -- condition keyed on seg.map -- so when a warp had bounced us onto a
    -- different map than the segment expected, this dove into whatever
    -- centre the map we happened to be standing on had. That is exactly how
    -- it broke the S.S. Anne: boarding put us on the ship, an edge-warp
    -- bounced us back to VERMILION_CITY, and this then marched into
    -- Vermilion's Poké Center while the segment wanted SS_ANNE_1F, skipping
    -- the entire ship -- and with it HM01 CUT, which the run needs 15
    -- segments later to clear the Route 9 tree.
    --
    -- Re-anchoring is a convenience (cheaper deaths); it must never perturb
    -- a segment that is mid-warp. On our own map with a centre, and not
    -- already anchored here.
    if ow().map.id == seg.map and healAnchor ~= seg.map
       and findWarpTo("POKECENTER") then
      local was = healAnchor
      healAnchor = seg.map
      say(("re-anchoring the heal point at %s (was %s)")
          :format(seg.map, tostring(was)))
      visitPokeCenter(seg.map, true)
    end
    -- The Indigo lobby is the one nurse with no POKECENTER warp -- we are
    -- already standing in the building she works in. Anchor the respawn
    -- here before the Elite Four: a loss otherwise wakes us a region away
    -- (travelTo cannot re-cross Victory Road's boulder puzzles), and the
    -- lobby segment is what a blackout resumes from, so the walk back to
    -- Lorelei's door is the route's own steps. Restock while we are here:
    -- five fights, no nurse between them, and the bag holds whatever
    -- survived Victory Road.
    if seg.map == "INDIGO_PLATEAU_LOBBY" and ow().map.id == seg.map then
      if healAnchor ~= seg.map then
        healAnchor = seg.map
        say("re-anchoring the heal point at the Indigo lobby nurse")
        talkToNurse(seg.map)
      end
      ops.shop({ list = "indigo" }, seg.map)
    end
    if centerCooldown > 0 then centerCooldown = centerCooldown - 1 end
    -- the one place a nurse detour is safe: between segments, where the
    -- next segment re-paths from wherever the warp left us
    autoHeal(seg.map, riskThreshold(seg.map), true)

    -- (Elevator handling now lives at the top of the loop, keyed on the
    -- PHYSICAL map, so it catches both the intended arrival and an
    -- accidental entry mid-climb. See there.)
    for si, s in ipairs(seg.steps) do
      if blackedOut or wiped() then
        recordDeath(seg.map)
        -- wait out the warp to the heal point before deciding where we are
        for _ = 1, 240 do
          if idle() and not inBattle() then break end
          if inBattle() then fightBattle() else mashUntilIdle() end
        end
        local resumed = recoverFromBlackout(i, ow().map.id, seg.map)
        if not resumed then return abandon(i, "died too many times") end
        i = resumed - 1
        goto nextSegment
      end
      -- A warp, a ledge hop or a gate shove can move us off this segment's
      -- map partway through it. Its remaining waypoints are meaningless
      -- here: out of bounds they look like the route's "leave by this edge"
      -- idiom, so we spend the rest of the segment shoving Red into a
      -- border -- e.g. Viridian's (20,35) run while still on ROUTE_1, which
      -- pushes right into Route 1's east wall over and over. Stop and let
      -- the map-wait at the top of the loop re-sync us.
      if ow().map.id ~= seg.map then
        say(("left %s partway through segment %d/%d (now on %s); re-syncing")
            :format(seg.map, i, #ROUTE, ow().map.id))
        failures = failures + 1
        break
      end
      -- Re-check health before EVERY step, not just at the segment
      -- boundary. Route trainers engage on sight as we walk past them --
      -- they never come through ops.battle -- so a segment that began
      -- healthy can still march a nearly-dead lead into a fight it cannot
      -- flee (trainers refuse). Route 3 after Brock is exactly this: the
      -- gauntlet IS the map, and the old per-segment check only looked
      -- once, before the first of them.
      autoHeal(seg.map, riskThreshold(seg.map))
      local fn = ops[s.op == "goto" and "goto_" or s.op]
      if not fn then
        note("UNHANDLED:" .. s.op, seg.map)
      else
        -- ops receive whether this is the segment's final step; goto_ uses
        -- it to decide a warp is an intended exit rather than an arrival tile
        local ok = fn(s, seg.map, si == #seg.steps)
        if ok == false then failures = failures + 1 end
      end
    end
    if i % 10 == 0 then
      say(("segment %d/%d  map=%s  failures=%d"):format(i, #ROUTE, ow().map.id, failures))
    end
    ::nextSegment::
  end

  say("---- route complete ----")
  say(("segments: %d   failures: %d"):format(#ROUTE, failures))
  return true
end

local function report()
  local keys = {}
  for k in pairs(skipped) do keys[#keys + 1] = k end
  table.sort(keys)
  if #keys > 0 then
    say("skipped ops:")
    for _, k in ipairs(keys) do say(("  %-40s x%d"):format(k, skipped[k])) end
  end
end

return function(game)
  G = game
  loadMemory()
  do
    local known = {}
    for map, n in pairs(deaths) do known[#known + 1] = ("%s x%d"):format(map, n) end
    table.sort(known)
    local wallCount = 0
    for _, n in pairs(walls) do
      if n >= WALL_CONFIRM then wallCount = wallCount + 1 end
    end
    if #known > 0 or wallCount > 0 then
      say(("memory (%s): deaths %s; %d cells to route around")
          :format(MEMORY_PATH,
                  #known > 0 and table.concat(known, ", ") or "none", wallCount))
    else
      say("memory: empty -- first run, everything looks safe")
    end
  end
  local attempts = tonumber(os.getenv("POKEPORT_ROUTE_ATTEMPTS")) or 5
  -- Resume from a checkpoint instead of replaying from Pallet Town. Only
  -- the first attempt resumes; if it fails again, the retries are honest
  -- runs from the start.
  local resume
  if os.getenv("POKEPORT_ROUTE_RESUME") == "1" then
    resume = loadCheckpoint()
    if resume then
      say(("resuming from checkpoint: segment %d/%d on %s (%s)")
          :format(resume.segment, #ROUTE, tostring(resume.map),
                  tostring(resume.reason)))
    else
      say("POKEPORT_ROUTE_RESUME=1 but no usable checkpoint; starting fresh")
    end
  end
  for attempt = 1, attempts do
    say(("==== attempt %d/%d ===="):format(attempt, attempts))
    if attempt == 1 and resume then
      local SaveData = require("src.core.SaveData")
      local loaded, recovered = SaveData.load()
      if loaded then
        U.wait(5)
        G:restoreSave(loaded, recovered)
        U.wait(30)
        mashUntilIdle()
        local stopped = runRoute(resume.segment)
        if stopped == nil then say("stopped at a checkpoint") break end
        if stopped then say("run finished") break end
        say("checkpoint attempt failed; starting a clean run")
        resume = nil
        goto nextAttempt
      end
      say("checkpoint save would not load; starting fresh")
      resume = nil
    end
    if attempt > 1 then
      -- power-cycle back to the title and start over, the way a speedrun
      -- bot resets a dead run (Strategies.reset). Cheaper and far more
      -- predictable than trying to re-sync the route from a heal point.
      G:returnToTitle()
      U.wait(60)
    end
    -- Start a genuinely NEW game.
    --
    -- U.newGame taps A on the title menu, which is only NEW GAME when no
    -- save exists -- with one, CONTINUE is first and the tap loads it. The
    -- checkpoint feature writes saves, so it silently turned every "clean"
    -- run into a resume: a fresh run reported being lost at segment 9 while
    -- standing in VERMILION_CITY, hundreds of segments from where it should
    -- have been. Pick the row by label instead of trusting its position.
    U.wait(5)
    press("start")
    U.wait(10)
    press("a")
    U.wait(10)
    local title = top()
    local newRow
    for i, it in ipairs(title and title.items or {}) do
      if it.label == "NEW GAME" then newRow = i break end
    end
    if newRow then
      if cursorTo("index", newRow) then
        press("a")
        U.wait(10)
      end
      -- mash through Oak's speech and the naming presets
      for _ = 1, 400 do
        press("a")
        U.wait(2)
        if G.overworld and G.stack:top() == G.overworld then break end
      end
      U.wait(10)
    else
      say("title menu had no NEW GAME row; falling back to U.newGame")
      U.newGame(game)
    end
    mashUntilIdle()
    local result = runRoute()
    if result == nil then say("stopped at a checkpoint") break end
    if result then
      say("run finished")
      break
    end
    say("restarting after a wipe")
    ::nextAttempt::
  end
  report()
end
