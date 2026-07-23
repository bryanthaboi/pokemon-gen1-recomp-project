-- The overworld state: renders the current map (plus connected map
-- strips), runs the player, NPCs, warps, connections, encounters, ledges,
-- surfing, Cut trees, trainer sight lines, and dispatches interactions to
-- map scripts (data/scripts/), marts, nurses or extracted text.

local Camera = require("src.render.Camera")
local Collision = require("src.world.Collision")
local Encounter = require("src.world.Encounter")
local FieldDefaults = require("src.world.FieldDefaults")
local Logger = require("src.core.Logger")
local Map = require("src.world.Map")
local MapLoader = require("src.world.MapLoader")
local NPC = require("src.world.NPC")
local PaletteFX = require("src.render.PaletteFX")
local Player = require("src.world.Player")
local Runtime = require("src.mods.Runtime")
local Screens = require("src.ui.Screens")
local ScriptRunner = require("src.script.ScriptRunner")
local Tilt = require("src.render.Tilt")
local TextBox = require("src.render.TextBox")
local Transition = require("src.render.Transition")
local Warp = require("src.world.Warp")

-- isOverworld marks the live world state for WorldAPI's stack scan
local OverworldState = { isOpaque = true, isOverworld = true }

local Game -- set on enter (avoids circular require at load time)

local mapScripts -- registry of hand-ported map scripts

local COMPASS = { up = "north", down = "south", left = "west", right = "east" }
local DIRVEC = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }

-- healing machine ball screen positions (PokeCenterOAMData dbsprite
-- rows are raw shadow-OAM bytes, so the hardware's -8/-16 OAM origin
-- applies: screen = tile*8 + pixel offset - 8/16); [3] = OAM_XFLIP
local HEAL_BALL_XY = {
  { 40, 27 }, { 48, 27, true },
  { 40, 32 }, { 48, 32, true },
  { 40, 37 }, { 48, 37, true },
}

-- the healing machine's flash beat (FlashSprite8Times: rOBP1 ^= $28)
-- swaps the two middle shades of the monitor/ball art in place
local HEAL_FLASH_MAP = { [0] = 0, [1] = 2, [2] = 1, [3] = 3 }

-- object_event spawn filter (toggleable_objects, items taken, beaten
-- static encounters), shared by the current map's real NPCs and the
-- visual-only ghosts on connected neighbor maps
local function objectVisible(save, mapId, obj)
  local toggles = save.objectToggles and save.objectToggles[mapId] or {}
  local visible = not obj.hidden
  if obj.name and toggles[obj.name] ~= nil then
    visible = toggles[obj.name]
  end
  if obj.item and save.itemsTaken
     and save.itemsTaken[mapId .. "_obj_" .. obj.index] then
    visible = false
  end
  if obj.pokemon and save.defeatedTrainers[mapId .. "_obj_" .. obj.index] then
    visible = false
  end
  return visible
end
OverworldState.objectVisible = objectVisible -- exposed for tests + reuse

-- NPC instance pool: one NPC object per map object, keyed by the
-- NPC.id format ("<mapId>_obj_<index>").  The same instance serves as
-- a neighbor-map ghost and as the real NPC once that map is entered,
-- so positions/facings carry across connection seams.
local function pooledNPC(pool, data, mapId, obj)
  local key = mapId .. "_obj_" .. obj.index
  local npc = pool[key]
  if not npc then
    npc = NPC.new(data, mapId, obj)
    pool[key] = npc
    if Runtime.wants("world.npc_spawned") then
      Runtime.emit("world.npc_spawned",
        { mapId = mapId, npcId = key, runtime = obj.runtime == true })
    end
  end
  return npc
end
OverworldState.pooledNPC = pooledNPC -- exposed for tests

-- connection hops rendered around the current map: two, so
-- corner-adjacent maps (connections of connections) don't pop in and
-- out of the survey zoom at the seams (constants.world.neighborHops)
local NEIGHBOR_HOPS = 2

-- Neighbor placement (pure; exposed for tests): walk the connection
-- graph `hops` connections out, composing the strip offsets, deduped
-- by map id (BFS, so a direct connection always wins over a two-hop
-- path).  Offsets are world pixels; connection offsets are in blocks
-- (32 px), the same alignment the connection macro encodes
-- (macros/scripts/maps.asm: _x = offset * -2 walk cells for
-- north/south, _y = offset * -2 for west/east).
-- reachW/reachH (optional, world pixels): with a full zoom-out the view
-- shows far more world than the fixed hop count covers, so any map whose
-- body could overlap the current map's rect inflated by the view
-- half-extents joins the set (and keeps the walk going) regardless of how
-- many connections away it sits -- otherwise far map bodies pop between
-- real tiles and the border filler when a crossing re-roots the BFS.
function OverworldState.computeNeighbors(maps, rootId, hops, reachW, reachH)
  local out = {}
  local rootDef = maps[rootId]
  local placed = { [rootId] = true }
  local queue = { { def = rootDef, ox = 0, oy = 0, hops = 0 } }
  local qi = 1
  local function inReach(def, ox, oy)
    if not (reachW and reachH and rootDef) then return false end
    return ox + def.width * 32 > -reachW
       and ox < rootDef.width * 32 + reachW
       and oy + def.height * 32 > -reachH
       and oy < rootDef.height * 32 + reachH
  end
  while queue[qi] do
    local cur = queue[qi]
    qi = qi + 1
    for dir, conn in pairs(cur.def.connections or {}) do
      local destDef = maps[conn.map]
      if destDef and not placed[conn.map] then
        placed[conn.map] = true
        local ox, oy
        if dir == "north" then
          ox, oy = conn.offset * 32, -destDef.height * 32
        elseif dir == "south" then
          ox, oy = conn.offset * 32, cur.def.height * 32
        elseif dir == "west" then
          ox, oy = -destDef.width * 32, conn.offset * 32
        else
          ox, oy = cur.def.width * 32, conn.offset * 32
        end
        ox, oy = cur.ox + ox, cur.oy + oy
        if cur.hops + 1 <= hops or inReach(destDef, ox, oy) then
          table.insert(out, { id = conn.map, ox = ox, oy = oy })
          if cur.hops + 1 < hops or inReach(destDef, ox, oy) then
            table.insert(queue,
                         { def = destDef, ox = ox, oy = oy,
                           hops = cur.hops + 1 })
          end
        end
      end
    end
  end
  return out
end

function OverworldState:enter(mapId, x, y, facing)
  Game = require("src.core.Game")
  Game.overworld = self
  Collision.load(Game.data) -- tile-pair (elevation) collisions
  Encounter.load(Game.data) -- constants.encounterBuckets
  mapScripts = require("data.scripts.init")
  self.camera = Camera.new()
  self.runner = ScriptRunner.new(Game, self)
  self.scriptMoves = {}
  self.pendingScripts = {}
  self.parallelRunners = {}
  self.parallelQueue = {}
  self.npcMoveLocks = {}
  self.marchers = {}
  -- one-shot trainer-engagement state: must not survive a save/load or
  -- a fresh entry, or a stale flag can freeze player input forever
  self.engaging = false
  self.emote = nil
  -- survives save/load: a loaded game may start inside a building whose
  -- exit mat is a LAST_MAP warp
  self.lastOutdoor = Game.save.lastOutdoor
  self.justWarped = false
  self:setMap(mapId, x, y, facing, { via = "boot" })
end

function OverworldState:setMap(mapId, x, y, facing, opts)
  local fromMapId = self.map and self.map.id
  if fromMapId then
    Runtime.emit("map.exited", { mapId = fromMapId, toMapId = mapId })
  end
  -- ambient choreography is per-map: parallel runners die here, and the
  -- departing map's queued scripts go with them unless the enqueuer
  -- asked to persist across the warp
  if self.parallelRunners then
    for i = #self.parallelRunners, 1, -1 do
      self:killParallel(self.parallelRunners[i])
    end
    self.parallelQueue = {}
  end
  self.marchers = {}
  local queue = self.pendingScripts
  if queue then
    for i = #queue, 1, -1 do
      local entry = queue[i]
      if entry.mapId ~= mapId
         and not (entry.extra and entry.extra.persistAcrossWarp) then
        table.remove(queue, i)
      end
    end
  end
  -- a scripted tile-anim override lasts until map change
  if self.tileAnimOverride then
    self.tileAnimOverride.tileset.animation = self.tileAnimOverride.animation
    self.tileAnimOverride = nil
  end
  self.map = MapLoader.load(Game.data, mapId)
  -- STRENGTH deactivates on every real map load (home/overworld.asm
  -- EnterMap -> ResetUsingStrengthOutOfBattleBit clears BIT_STRENGTH_ACTIVE
  -- of wStatusFlags1).  setMap is the single choke point for every map-id
  -- change -- warps and seamless connection crossings alike -- so an
  -- unconditional reset here reproduces that default clear path.  It is
  -- deliberately NOT part of Game.save: the flag lives in plain WRAM, not
  -- SRAM, so it must not survive a save/load.  Not reset in afterBattle:
  -- pokered keeps STRENGTH across a same-map battle return (EnterMap skips
  -- the reset when BIT_BATTLE_OVER_OR_BLACKOUT is set).
  self.strengthActive = false
  -- Cut trees grow back when the map reloads (like the original)
  if self.cutBlocks and self.cutBlocks[mapId] then
    for _, c in ipairs(self.cutBlocks[mapId]) do
      self.map:setBlock(c.bx, c.by, c.block)
    end
    self.map.renderer:rebuild()
    self.cutBlocks[mapId] = nil
  end
  -- Silph Co card key doors: the .blk layouts ship with the doorways
  -- open; each floor's map script stamps the closed door block on load
  -- until its unlock event is set (scripts/SilphCo2F.asm
  -- SilphCo2FGateCallbackScript et al., closed blocks $54/$5f/$20)
  local closedDoors = FieldDefaults.fieldValue(Game.data, "cardKeyDoors",
                                               "closedDoors")
  local floorDoors = closedDoors and closedDoors[mapId]
  if floorDoors then
    local stamped = false
    for _, door in ipairs(floorDoors) do
      local want = Game.save.flags[door.event] and door.open or door.block
      if self.map:blockAt(door.bx, door.by) ~= want then
        self.map:setBlock(door.bx, door.by, want)
        stamped = true
      end
    end
    if stamped then self.map.renderer:rebuild() end
  end
  -- forced dismount only where riding is disallowed (IsBikeRidingAllowed,
  -- home/overworld.asm: bike_riding_tilesets.asm tilesets plus the
  -- ROUTE_23/INDIGO_PLATEAU map exceptions)
  if Game.save.onBike and not self:bikeAllowed(mapId) then
    Game.save.onBike = false
  end
  -- the Route 16/18 gate map scripts clear the Cycling Road's
  -- BIT_ALWAYS_ON_BIKE every frame (scripts/Route16Gate1F.asm /
  -- Route18Gate1F.asm `res BIT_ALWAYS_ON_BIKE`); entering the gate is
  -- the walking exit from the forced-bike stretch
  for _, m in ipairs(FieldDefaults.fieldValue(Game.data, "forcedMovement",
                                              "clearMaps") or {}) do
    if m == mapId then Game.save.forcedBike = nil break end
  end
  -- leaving the Safari Zone maps ends any running Safari game
  if Game.save.safari and not Map.inRegion(self.map.def, "SAFARI", "SAFARI_ZONE") then
    Game.save.safari = nil
  end
  -- Rock Tunnel darkness (wMapPalOffset, home/overworld.asm): dark
  -- until FLASH is used; the light persists between the tunnel floors
  -- and resets once outside
  local darkDef = Game.data.field.darkMaps
  self.dark = false
  if darkDef then
    local isDark = false
    for _, m in ipairs(darkDef.maps) do
      if m == mapId then isDark = true break end
    end
    if isDark then
      self.dark = not Game.save.flashLit
    else
      Game.save.flashLit = nil
    end
  end
  if Game.data.field.flyWarps[mapId] then
    Game.save.visited = Game.save.visited or {}
    Game.save.visited[mapId] = true
  end
  -- NPC instances persist across connection crossings in self.npcPool
  -- (keyed by NPC.id): a neighbor map's wandering ghosts ARE the
  -- objects that become the real NPCs when the player crosses the
  -- seam, so nothing snaps back to its spawn point in view of the
  -- survey zoom.  Warps rebuild from scratch, like the original's
  -- per-entry sprite init (home/overworld.asm LoadMapHeader
  -- .loadSpriteData).
  if not (opts and opts.seamless and self.npcPool) then
    self.npcPool = {}
  end
  self.npcs = {}
  for _, obj in ipairs(self.map.def.objects or {}) do
    if objectVisible(Game.save, mapId, obj) then
      local npc = pooledNPC(self.npcPool, Game.data, mapId, obj)
      npc.frozen = false
      table.insert(self.npcs, npc)
    end
  end
  if self.player then
    self.player.cellX, self.player.cellY = x, y
    self.player.px, self.player.py = x * 16, y * 16
    self.player.facing = facing or self.player.facing
    self.player.moving = false
    self.player.targetX, self.player.targetY = nil, nil
  else
    self.player = Player.new(Game.data, x, y, facing)
  end
  self.entities = { self.player }
  for _, n in ipairs(self.npcs) do table.insert(self.entities, n) end

  -- opts.keepMusic: the Oak-escort warp keeps MUSIC_MEET_PROF_OAK
  -- playing into the lab (BIT_NO_MAP_MUSIC in wStatusFlags7);
  -- keepMusicOnce is the play_music opts.keep one-shot of the same bit
  local keepMusic = (opts and opts.keepMusic) or self.keepMusicOnce
  self.keepMusicOnce = nil
  if not keepMusic then
    require("src.core.Music").playMap(Game.data, mapId, Game.save.onBike,
                                      self.player.surfing)
  end

  -- forced bike/surf tiles fire the moment the player is placed on the
  -- map, like EnterMap's unconditional CheckForceBikeOrSurf farcall
  -- (home/overworld.asm) -- a warp can land directly on one (the Route
  -- 16/18 gate exits), and the scripted door-mat walkout that follows
  -- suppresses onStepComplete, so waiting for a plain step never mounts
  self:checkForcedMovement()

  -- snap the camera immediately: the overworld doesn't update while a
  -- Transition is on top, so a stale camera would show the new map at
  -- the old scroll position for the whole fade-in
  self.camera:follow(self.player.px, self.player.py,
                     Game.renderer:worldViewSize())

  -- fires before the onEnter chain so a listener sees the map in the same
  -- state the map script does
  Runtime.emit("map.entered", {
    mapId = mapId, map = self.map, fromMapId = fromMapId,
    via = (opts and opts.via)
          or (opts and opts.seamless and "connection")
          or (fromMapId and "warp" or "boot"),
  })

  -- map-enter hooks (hand-ported map scripts, e.g. Victory Road barriers).
  -- fromMapId lets elevators seed a valid walk-out floor when the ROM
  -- car warps still point at a missing map (Silph's UNUSED_MAP_ED) and
  -- the player B-cancels the floor menu without .UpdateWarp.
  local hooks = mapScripts.get(mapId)
  if hooks and hooks.onEnter then
    hooks.onEnter(Game, self, fromMapId)
  end

  self:rebuildNeighbors()
  Logger.info("map: %s at (%d,%d)", mapId, x, y)
  -- Route22Gate_Script rewrites wLastMap from the player's Y on entry
  -- too (not only on step), so a save/load mid-gate keeps exits correct
  self:syncLastMapRewrite()
end

-- Neighbor maps drawn at the composed connection offsets: at least the
-- configured hop count out (the GB only ever streamed a 32px strip of
-- the single directly connected map -- home/overworld.asm .loadNewMap),
-- widened to everything the current view size can show so a full
-- zoom-out never runs past the rendered set.  Re-run whenever the view
-- grows (zoom/resize), not only on setMap.
--
-- Neighbors are built eagerly here.  A TileRenderer is now a light object --
-- the tile layer draws windowed to the camera, so nothing per-map is
-- constructed up front (see TileRenderer) -- so there is no build cost to
-- amortize and no prefetch race to lose at a seam.  That is what the old
-- one-per-frame streaming queue existed to hide, and it is gone.
function OverworldState:rebuildNeighbors()
  local mapId = self.map.id
  self.neighbors = {}
  local hops = FieldDefaults.world(Game.data, "neighborHops") or NEIGHBOR_HOPS
  local vw, vh = Game.renderer:worldViewSize()
  self.neighborViewW, self.neighborViewH = vw, vh
  -- resident set the eviction pass must never touch: the current map plus
  -- every drawn neighbor
  local keep = { [mapId] = true }
  for _, n in ipairs(OverworldState.computeNeighbors(Game.data.maps, mapId,
                                                     hops,
                                                     math.floor(vw / 2) + 64,
                                                     math.floor(vh / 2) + 64)) do
    keep[n.id] = true
    local m = MapLoader.load(Game.data, n.id)
    table.insert(self.neighbors, { map = m, ox = n.ox, oy = n.oy })
  end
  -- bound resident memory: drop maps behind us that are neither current nor
  -- a drawn neighbor, releasing their window batch / border image / atlas
  MapLoader.trim(keep)

  -- visual-only NPCs on connected maps (survey zoom): same spawn filter
  -- as a real map entry, but they never join self.entities -- no sight
  -- lines, triggers, dialogue or player collision.  Instances are
  -- shared with the real-NPC pool, so positions carry across the seam.
  self.ghosts = {}
  for _, nb in ipairs(self.neighbors) do
    local peers = {}
    for _, obj in ipairs(nb.map.def.objects or {}) do
      if objectVisible(Game.save, nb.map.id, obj) then
        local npc = pooledNPC(self.npcPool, Game.data, nb.map.id, obj)
        table.insert(peers, npc)
        table.insert(self.ghosts,
                     { npc = npc, map = nb.map, ox = nb.ox, oy = nb.oy,
                       peers = peers })
      end
    end
  end
end

-- SGB overworld palette (engine/gfx/palettes.asm SetPal_Overworld):
-- towns use their own palette, routes PAL_ROUTE, interiors the town or
-- route they are in (wLastMap = our lastOutdoor), with tileset and
-- Elite Four special cases -- all of it field.palettes now.

-- one rung of the cascade: byMap, then byTileset, then byPrefix.  Returns
-- nil when the map matches nothing, which is what sends the lookup on to
-- the last-outdoor memory.
local function paletteLookup(palettes, mapId, tileset)
  local byMap = palettes.byMap
  if byMap and byMap[mapId] then return byMap[mapId] end
  local byTileset = palettes.byTileset
  if byTileset and tileset and byTileset[tileset] then return byTileset[tileset] end
  for _, row in ipairs(palettes.byPrefix or {}) do
    if row.prefix and mapId:find(row.prefix, 1, true) == 1 then return row.palette end
  end
  return nil
end

-- name -> name so the map.palette chain has a vanilla link to wrap
local function samePalette(name) return name end

function OverworldState:paletteNameFor(map)
  local palettes = FieldDefaults.field(Game.data, "palettes")
  local name = map.def.palette or paletteLookup(palettes, map.id, map.def.tileset)
  if not name then
    -- Interiors inherit the outdoor map they sit in. Before the player has
    -- been outdoors at all, that is wLastMap's zero-fill -- map 0,
    -- PALLET_TOWN -- and NOT the spawn: the vanilla spawn (REDS_HOUSE_2F)
    -- is itself an interior and would fall through to the ROUTE default.
    -- defaultHeal derives the same zero-fill map (wLastBlackoutMap shares
    -- the reasoning) and lets a total conversion redirect it.
    local boot = (Game.data.field and Game.data.field.boot) or {}
    local last = self.lastOutdoor and self.lastOutdoor.id
                 or require("src.core.SaveData").defaultHeal(boot).map
    local lastDef = last and Game.data.maps[last]
    name = (last and paletteLookup(palettes, last, lastDef and lastDef.tileset))
           or palettes.default
  end
  if not Runtime.wantsHook("map.palette") then return name end
  return Runtime.call("map.palette", samePalette, name, map)
end

-- UI-pass palette (text boxes and menus tint with the current map).  OG RED
-- resolves every name to the one global red BG palette inside PaletteFX.pal,
-- so this needs no mode-specific branch.
function OverworldState:sgbPalettes()
  local PaletteFX = require("src.render.PaletteFX")
  return PaletteFX.wholeNamed(Game.data, self:paletteNameFor(self.map))
end

-- World-pass palette zones in world-canvas pixels: each visible map
-- area keeps its own SGB palette (a deliberate step past the original,
-- which recolored the whole screen per map -- see the survey zoom
-- entry in docs/known-differences.md).  Border fill inherits the
-- current map's palette.
--
-- RED++ true overworld coloring does NOT go through this zone/shader
-- system at all: TileRenderer bakes real per-tile GBC colors straight into
-- a recolored tileset atlas (see TileRenderer's gbcAtlas), and
-- SpriteRenderer bakes sprites' OBP colors the same way, so the world
-- canvas is already final RGB by the time this runs. Returning an EMPTY
-- list here (when the current map has that baked atlas) skips the shader
-- entirely -- Renderer:endFrame's blit sees zoneList[1] == nil and falls
-- back to a plain, unshaded draw. Returning plain `nil` would NOT do this:
-- endFrame treats a nil worldZones as "no world-specific zones, reuse the
-- UI pass's zones" (sgbPalettes' whole-screen named-palette zone), which
-- would re-run the DMG shade-remap over already-true-color pixels using
-- an unrelated 4-color palette -- exactly the "colors are wrong" bug this
-- fixes.
function OverworldState:sgbWorldZones()
  local PaletteFX = require("src.render.PaletteFX")
  if PaletteFX.usesGbcPack() and self.map.renderer and self.map.renderer.gbcAtlas then
    return {}
  end
  local base = PaletteFX.pal(Game.data, self:paletteNameFor(self.map))
  if not base then return nil end
  local vw, vh = Game.renderer:worldViewSize()
  local cam = self.camera
  local zones = { { colors = base, x = 0, y = 0, w = vw, h = vh } }
  for _, nb in ipairs(self.neighbors) do
    local colors = PaletteFX.pal(Game.data, self:paletteNameFor(nb.map))
    if colors then
      table.insert(zones, { colors = colors,
                            x = math.floor(nb.ox - cam.x),
                            y = math.floor(nb.oy - cam.y),
                            w = nb.map.def.width * 32,
                            h = nb.map.def.height * 32 })
    end
  end
  return zones
end

function OverworldState:npcByIndex(index)
  for _, n in ipairs(self.npcs) do
    if n.def.index == index then return n end
  end
  return nil
end

-- Bike riding allowlist (field.bikeRiding, from bike_riding_tilesets.asm
-- + IsBikeRidingAllowed's map exceptions); BagMenu's mount check reads
-- the same table.
function OverworldState:bikeAllowed(mapId)
  local br = Game.data.field.bikeRiding
  if not br then return Map.isOutdoor(self.map.def) end
  for _, m in ipairs(br.maps) do
    if m == mapId then return true end
  end
  for _, t in ipairs(br.tilesets) do
    if t == self.map.def.tileset then return true end
  end
  return false
end

-- The battle transition's dungeon wipe uses the explicit map lists in
-- data/maps/dungeon_maps.asm (field.dungeonTransitionMaps): singles plus
-- inclusive map-id ranges -- faithful to the original's omissions
-- (Victory Road 2F/3F, the Rocket Hideout, Diglett's Cave, ... miss out).
function OverworldState:isDungeonTransitionMap()
  local dm = Game.data.field.dungeonTransitionMaps
  if not dm then return false end
  for _, m in ipairs(dm.maps) do
    if m == self.map.id then return true end
  end
  local idx = self.map.def.index
  for _, r in ipairs(dm.ranges) do
    local first = Game.data.maps[r.first]
    local last = Game.data.maps[r.last]
    if first and last and idx >= first.index and idx <= last.index then
      return true
    end
  end
  return false
end

-- Start a battle behind the into-battle transition: flash, then the
-- wipe picked by trainer/level/dungeon (GetBattleTransitionID).
function OverworldState:pushBattle(battle)
  local BattleTransition = require("src.render.BattleTransition")
  local lead
  for _, mon in ipairs(Game.save.party) do
    if mon.hp > 0 then lead = mon break end
  end
  local enemyLevel = battle.enemy and battle.enemy.mon and battle.enemy.mon.level or 0
  -- the battle theme starts with the wipe, not after it
  -- (audio/play_battle_music.asm runs before the transition)
  if battle.computeMusicKind then
    require("src.core.Music").playBattle(Game.data, battle:computeMusicKind())
  end
  Game.stack:push(BattleTransition.new(Game, function()
    Game.stack:push(battle)
  end, {
    trainer = battle.kind == "trainer",
    stronger = lead ~= nil and enemyLevel >= lead.level + 3,
    dungeon = self:isDungeonTransitionMap(),
  }))
end

-- -------------------------------------------------------------------------
-- update
-- -------------------------------------------------------------------------

-- Queue a script for a map's onEnter hook to run once it is safe to.  A
-- map load (setMap -> onEnter) can happen mid-warp, while the triggering
-- warp command's runner is still suspended-alive; starting a runner there
-- would trip ScriptRunner:run's assert(not isRunning()).  So onEnter stashes
-- the script here and update() drains the FIFO head once the world is
-- idle, one script per idle frame.
function OverworldState:queueScript(script, extra)
  local queue = self.pendingScripts
  if not queue then
    queue = {}
    self.pendingScripts = queue
  end
  queue[#queue + 1] = { script = script, extra = extra,
                        mapId = self.map and self.map.id }
  -- a runaway-loop tripwire, not a hard cap
  if #queue > 16 then
    Logger.warn("queueScript: %d scripts pending on %s",
                #queue, tostring(self.map and self.map.id))
  end
end

function OverworldState:drainPendingScripts()
  local queue = self.pendingScripts
  if queue and queue[1] and not self.transitioning
     and not self.runner:isRunning() and #self.scriptMoves == 0 then
    local pending = table.remove(queue, 1)
    self.runner:run(pending.script, pending.extra)
  end
end

-- Start a background script in one of the bounded parallel slots (09
-- §4.6); overflow waits FIFO-style behind the slots.  rowsOrRef is a row
-- array or "MAP_ID/name" naming a map_scripts `scripts` entry.
local PARALLEL_SLOTS = 4

function OverworldState:startParallel(rowsOrRef, extra)
  local rows = rowsOrRef
  if type(rowsOrRef) == "string" then
    local MapScripts = require("src.script.MapScripts")
    local mapId, name = rowsOrRef:match("^([^/]+)/(.+)$")
    rows = mapId and MapScripts.namedScript(mapId, name)
    if not rows then
      Logger.warn("run_parallel: no script '%s'", tostring(rowsOrRef))
      return
    end
    -- a named entry belongs to its contribution: a caller with no
    -- attribution of its own runs it as the owner
    if not (extra and extra.source) then
      local source = MapScripts.namedSource(mapId, name)
      if source then
        extra = extra or {}
        extra.source = source
      end
    end
  end
  local queue = self.parallelQueue
  if not queue then
    queue = {}
    self.parallelQueue = queue
  end
  queue[#queue + 1] = { rows = rows, extra = extra }
  if #queue > 16 then
    Logger.warn("run_parallel: %d scripts waiting for a slot", #queue)
  end
end

function OverworldState:killParallel(runner)
  runner.co = nil
  for i, live in ipairs(self.parallelRunners or {}) do
    if live == runner then
      table.remove(self.parallelRunners, i)
      break
    end
  end
  for entity, holder in pairs(self.npcMoveLocks or {}) do
    if holder == runner then self.npcMoveLocks[entity] = nil end
  end
end

-- Parallel runners tick after the main runner and never touch the input
-- lockout: isRunning() checks consult only self.runner, exactly as
-- before.  Dead runners free their slot and their NPC move locks.
function OverworldState:updateParallel()
  local pool = self.parallelRunners
  if not pool then return end
  for i = #pool, 1, -1 do
    if not pool[i]:isRunning() then
      self:killParallel(pool[i])
    end
  end
  local queue = self.parallelQueue
  while queue and queue[1] and #pool < PARALLEL_SLOTS do
    local next_ = table.remove(queue, 1)
    local runner = ScriptRunner.new(Game, self)
    runner.parallel = true
    pool[#pool + 1] = runner
    runner:run(next_.rows, next_.extra)
  end
  for _, runner in ipairs(pool) do runner:update() end
end

function OverworldState:update(dt)
  -- deferred cutscene launch (see queueScript): run a queued script only
  -- once the triggering warp's transition has finished, its runner has gone
  -- dead, and no scripted walk is mid-step.  This is how the HALL_OF_FAME
  -- room cutscene starts a frame after the Champions Room warp completes.
  self:drainPendingScripts()
  self.runner:update()
  self:updateParallel()
  -- keep the player sprite in sync with the bike state (the drawer
  -- picks the red_bike sheet while riding)
  self.player.onBike = Game.save.onBike
  -- the rendered neighbor set depends on the view size; zooming out (or
  -- resizing) past what setMap computed re-runs the walk in place
  if self.map and (self.neighborViewW or 0) > 0 then
    local vw, vh = Game.renderer:worldViewSize()
    if vw ~= self.neighborViewW or vh ~= self.neighborViewH then
      self:rebuildNeighbors()
    end
  end
  if self.dustAnim then
    local da = self.dustAnim
    da.frames = da.frames - 1
    if da.frames <= 0 then
      self.dustAnim = nil
      if da.onDone then da.onDone() end
    end
  end
  if self.cutAnim then
    local ca = self.cutAnim
    ca.frames = ca.frames - 1
    if ca.frames <= 0 then
      self.cutAnim = nil
      if ca.onDone then ca.onDone() end
    end
  end
  if self.healAnim then
    local ha = self.healAnim
    local Music = require("src.core.Music")
    if ha.jinglePlaying and not ha.jingleDone then
      ha.jingleDone = not Music.oneShotPlaying()
    end
    local ev = OverworldState.stepHealAnim(ha)
    if ev == "ball" then
      require("src.core.Sound").play(Game.data, "Healing_Machine")
    elseif ev == "jingle" then
      ha.jinglePlaying = Music.playOnce(Game.data, "Music_PkmnHealed")
      ha.jingleDone = not ha.jinglePlaying
    elseif ev == "done" then
      local done = ha.onDone
      self.healAnim = nil
      if done then done() end
    end
    return
  end
  if self.flyAnim then
    self.flyAnim.frames = self.flyAnim.frames - 1
    if self.flyAnim.frames <= 0 then
      self.flyAnim = nil
      self.player.inputLocked = false
      local d = self.flyDest
      self.flyDest = nil
      if d then
        -- the bird carries the player in on landing, with its own
        -- SFX_FLY (EnterMapAnim .flyAnimation)
        self.arriveWarp = "fly"
        self:startWarpTo(d.map, d.x, d.y, "down", nil, { via = "fly" })
      end
      return
    end
  end

  -- delayed one-shot SFX (the teleport-in spin's second note)
  if self.delaySfx then
    self.delaySfx.frames = self.delaySfx.frames - 1
    if self.delaySfx.frames <= 0 then
      require("src.core.Sound").play(Game.data, self.delaySfx.key)
      self.delaySfx = nil
    end
  end

  -- the emotion-bubble pause holds the world for a beat
  if self.emote then
    self.emote.frames = self.emote.frames - 1
    if self.emote.frames <= 0 then
      local done = self.emote.onDone
      self.emote = nil
      if done then done() end
    end
    self.player:update()
    return
  end

  for _, npc in ipairs(self.npcs) do
    npc:update(self.map, self.entities)
  end

  for _, g in ipairs(self.ghosts) do
    g.npc:update(g.map, g.peers)
  end

  self:updateScriptMoves()

  -- emote is included: a cutscene hold queued from a scriptMove onDone
  -- (e.g. Oak's lab Delay3 after his entry walk) is assigned mid-frame,
  -- after the early emote return above already missed it.  Without this,
  -- one frame of handleInput can sneak through -- holding UP during the
  -- escort then walks an extra tile before PlayerEntryMovementRLE, and
  -- the player lands on desk Oak.
  local scripted = self.runner:isRunning() or #self.scriptMoves > 0
                   or self.engaging or self.emote
  if not scripted and not self.transitioning then
    self:checkTrainerSight()
    -- CheckFightingMapTrainers (home/trainers.asm) zeroes hJoyHeld and
    -- sets wJoyIgnore the instant a trainer engages, before the loop's
    -- direction handling (JoypadOverworld runs the map script first) --
    -- the player can never start another step after being spotted.
    scripted = self.runner:isRunning() or #self.scriptMoves > 0
               or self.engaging or self.emote
  end
  if not scripted and not self.transitioning then
    self:handleInput()
  end

  local stepped = self.player:update()
  -- the warp-arrival cell goes stale the instant the player's real cell
  -- leaves it, scripted walk-outs included -- pokered re-checks warps
  -- after simulated steps too (CheckWarpsNoCollision), so a forced
  -- door-mat exit must not leave the door permanently inert
  local entry = self.warpEntryCell
  if entry and (self.player.cellX ~= entry.x or self.player.cellY ~= entry.y) then
    self.warpEntryCell = nil
  end
  if stepped and not scripted then
    self:onStepComplete()
  end

  self.camera:follow(self.player.px, self.player.py,
                     Game.renderer:worldViewSize())

  -- pan_camera offset rides on top of the follow; the ramp resumes its
  -- runner when it lands
  local pan = self.cameraPan
  if pan then
    if pan.frames then
      pan.t = pan.t + 1
      local k = math.min(1, pan.t / pan.frames)
      pan.ox = pan.fromX + (pan.toX - pan.fromX) * k
      pan.oy = pan.fromY + (pan.toY - pan.fromY) * k
      if pan.t >= pan.frames then
        pan.frames = nil
        local done = pan.onDone
        pan.onDone = nil
        if done then done() end
      end
    end
    self.camera.x = self.camera.x + pan.ox
    self.camera.y = self.camera.y + pan.oy
  end
end

-- any direction currently held (hJoyHeld & PAD_CTRL_PAD)
function OverworldState:dirHeld()
  local input = Game.input
  return input:isDown("up") or input:isDown("down")
      or input:isDown("left") or input:isDown("right")
end

function OverworldState:handleInput()
  local input = Game.input

  if input:wasPressed("a") then
    self:interact()
    return
  end
  if input:wasPressed("start") then
    require("src.core.Sound").play(Game.data, "Start_Menu")
    Screens.push(Game, "StartMenu")
    return
  end

  for _, dir in ipairs({ "up", "down", "left", "right" }) do
    if input:isDown(dir) then
      if not self.player.moving and self.player.facing == dir then
        if self:checkEdgeExit(dir) then return end
        if self:checkLedgeHop(dir) then return end
        if self:checkBoulderPush(dir) then return end
      end
      local result, why = self.player:tryMove(dir, self.map, self.entities)
      if result == "blocked" then
        -- a collision while standing on a warp square fires the warp
        -- when the extra check passes (CheckWarpsCollision: route-gate
        -- doorways, dock entrances, ...)
        local w = Warp.onCollision(self.map, Game.data.field.warpCarpets,
                                   self.player.cellX, self.player.cellY, dir)
        if w then
          self:takeWarp(w.def)
          return result
        end
      end
      if result == "blocked" and why ~= "entity" then
        if (self.bumpCooldown or 0) <= 0 then
          require("src.core.Sound").play(Game.data, "Collision")
          self.bumpCooldown = 16
        end
      end
      self.bumpCooldown = math.max(0, (self.bumpCooldown or 0) - 1)
      return result
    end
  end

  -- Cycling Road's downhill pull: with no d-pad held the bike rolls
  -- south (home/overworld.asm JoypadOverworld's simulated PAD_DOWN)
  local fm = Game.data.field.forcedMovement
  if fm and Game.save.onBike and not self.player.moving then
    for _, m in ipairs(fm.slopeMaps or {}) do
      if m == self.map.id then
        self.player.facing = "down"
        self.player:tryMove("down", self.map, self.entities)
        return
      end
    end
  end
end

-- Strength boulders (engine/overworld/push_boulder.asm TryPushingBoulder):
-- walking into one with STRENGTH in the party pushes it one cell, but
-- only on the second consecutive push attempt (BIT_TRIED_PUSH_BOULDER);
-- SFX_PUSH_BOULDER when the push starts, dust puff + SFX_CUT after.
function OverworldState:checkBoulderPush(dir)
  local p = self.player
  local fx, fy = Collision.target(p.cellX, p.cellY, dir)
  local npc = self:npcAtCell(fx, fy)
  if not npc or not Map.isPushable(npc.def) or npc.moving then
    self.boulderTried = nil -- pokered resets when no boulder is in front
    return false
  end
  -- BIT_STRENGTH_ACTIVE (wStatusFlags1): set only by the party-menu
  -- STRENGTH action on this map and cleared on every map load.
  -- push_boulder.asm TryPushingBoulder gates on nothing else -- it never
  -- re-checks the party's moves or badges at push time, so once STRENGTH
  -- is activated any party member can push (even if the STRENGTH-knowing
  -- mon is later boxed/swapped out).
  if not self.strengthActive then return false end
  if self.boulderTried ~= npc then
    self.boulderTried = npc
    return false -- first attempt only arms the push
  end
  local bx, by = Collision.target(fx, fy, dir)
  if not self.map:inBounds(bx, by) then self.boulderTried = nil return false end
  if not self.map:isWalkableCell(bx, by) then
    -- boulders may be pushed into holes/switch spots that aren't walkable
    if not self.map:isWarpTileCell(bx, by) then
      self.boulderTried = nil
      return false
    end
  end
  if Collision.occupied(self.entities, bx, by, npc) then
    self.boulderTried = nil
    return false
  end
  require("src.core.Sound").play(Game.data, "Push_Boulder")
  self:scriptMove(npc, dir, 1, function()
    self.boulderTried = nil
    -- dust smoke + SFX_CUT once the boulder settles (DoBoulderDustAnimation)
    self:startDustAnim(fx, fy, function()
      require("src.core.Sound").play(Game.data, "Cut")
    end)
    if self:boulderIntoHole(npc) then return end
    Runtime.emit("world.boulder_moved", { mapId = self.map.id, npcId = npc.id,
                                          x = npc.cellX, y = npc.cellY })
    local hooks = mapScripts.get(self.map.id)
    if hooks and hooks.onBoulderMoved then
      hooks.onBoulderMoved(Game, self, npc)
    end
  end)
  return true
end

-- The dust puff (engine/overworld/dust_smoke.asm AnimateBoulderDust):
-- the 8x8 smoke tile drawn as a 2x2 block over the vacated cell,
-- flickering for 8 steps of ~4 frames.
function OverworldState:startDustAnim(cx, cy, onDone)
  self.dustAnim = { x = cx, y = cy, frames = 32, onDone = onDone }
end

-- Ledge hops (data/tilesets/ledge_tiles.asm): standing tile + ledge tile
-- in front + matching input direction -> jump two cells.
function OverworldState:checkLedgeHop(dir)
  local p = self.player
  local tileset = self.map.def.tileset
  local standing = self.map:cellTile(p.cellX, p.cellY)
  local fx, fy = Collision.target(p.cellX, p.cellY, dir)
  if not self.map:inBounds(fx, fy) then return false end
  local front = self.map:cellTile(fx, fy)
  -- a row without a tileset applies everywhere; the vanilla rows are all
  -- OVERWORLD, which is what the deleted hard gate used to say
  for _, ledge in ipairs(Game.data.field.ledges) do
    if (ledge.tileset or "OVERWORLD") == tileset
       and ledge.facing == dir and ledge.input == dir
       and ledge.standingTile == standing and ledge.ledgeTile == front then
      local lx, ly = Collision.target(fx, fy, dir)
      if self.map:inBounds(lx, ly)
         and not Collision.occupied(self.entities, lx, ly, p)
         and self.map:isWalkableCell(lx, ly) then
        require("src.core.Sound").play(Game.data, "Ledge")
        p.hopFrames, p.hopTotal = 32, 32 -- jump arc (cosmetic)
        self:scriptMove(p, dir, 2)
        return true
      end
    end
  end
  return false
end

-- walking off the map edge: connection crossing or edge warp (exit mats)
function OverworldState:checkEdgeExit(dir)
  local p = self.player
  local tx, ty = Collision.target(p.cellX, p.cellY, dir)
  if self.map:inBounds(tx, ty) then return false end

  local w = Warp.onEdge(self.map, p.cellX, p.cellY, dir)
  if w then
    self:takeWarp(w.def)
    return true
  end

  local conn = self.map:connection(COMPASS[dir])
  if conn then
    return self:crossConnection(dir, conn)
  end
  return false
end

-- Landing cell on the connected map for a step off this map's edge in
-- `dir` (same math as crossConnection).  Returns destDef, tilesetDef, x, y
-- or nil when there is no usable connection.
function OverworldState:connectionLanding(dir)
  local conn = self.map:connection(COMPASS[dir])
  if not conn then return nil end
  local dest = Game.data.maps[conn.map]
  if not dest then return nil end
  local ts = Game.data.tilesets[dest.tileset]
  if not ts then return nil end
  local p = self.player
  local destW, destH = dest.width * 2, dest.height * 2
  local x, y
  if dir == "up" then
    x, y = p.cellX - conn.offset * 2, destH - 1
  elseif dir == "down" then
    x, y = p.cellX - conn.offset * 2, 0
  elseif dir == "left" then
    x, y = destW - 1, p.cellY - conn.offset * 2
  else
    x, y = 0, p.cellY - conn.offset * 2
  end
  x = math.max(0, math.min(destW - 1, x))
  y = math.max(0, math.min(destH - 1, y))
  return dest, ts, x, y, conn
end

-- Map connections: the connected map's strip offset is in blocks; arriving
-- coordinates follow destX = curX - offset*2 (see docs/extraction-notes.md).
-- The crossing scrolls continuously: the map data swaps while the player
-- is placed one cell before the entry point (their old world position,
-- which the neighbor strips render identically) and walks the seam step.
function OverworldState:crossConnection(dir, conn)
  local dest, ts, x, y = self:connectionLanding(dir)
  if not dest then
    Logger.warn("connection to unknown map %s", tostring(conn and conn.map))
    return false
  end
  local p = self.player
  -- pokered's collision check reads the NEIGHBOR strip's tile bytes, so
  -- stepping off the edge onto a solid tile of the connected map bumps
  -- exactly like an in-map wall. Without this read, Pallet's south
  -- shore (land at x2-3) walked straight onto ROUTE_21 (3,0) -- a
  -- collision tile -- stranding the player on a cell no walk can leave.
  if not Map.defPassable(dest, ts, x, y, p.surfing) then
    return false
  end
  self:setMap(conn.map, x, y, p.facing, { seamless = true })
  -- place the player one cell before the seam (their old world spot,
  -- which the neighbor strip renders identically) and start the step
  -- into the new map RIGHT NOW so there is no one-frame stall at the
  -- boundary (updateScriptMoves already ran this frame; kicking the
  -- move here lets player:update animate the first pixel immediately)
  local d = DIRVEC[dir]
  p.cellX, p.cellY = x - d[1], y - d[2]
  p.px, p.py = p.cellX * 16, p.cellY * 16
  self.camera:follow(p.px, p.py)
  p.facing = dir
  p.targetX, p.targetY = x, y
  p.moving = true
  p.progress = 0
  p.stepFramesCur = Game.save.onBike
    and (FieldDefaults.world(Game.data, "bikeStepFrames") or 8)
    or (FieldDefaults.world(Game.data, "stepFrames") or 16)
  return true
end

-- ItemUseSurfboard's simulated pad press: step onto the facing cell, or
-- cross a map connection when that cell is off this map's edge (Cinnabar
-- east coast -> Route 20 water, and the reverse dismount ashore).
function OverworldState:stepForwardOrCrossEdge(dir)
  dir = dir or self.player.facing
  local fx, fy = Collision.target(self.player.cellX, self.player.cellY, dir)
  if not self.map:inBounds(fx, fy) then
    return self:checkEdgeExit(dir)
  end
  self:scriptMove(self.player, dir, 1)
  return true
end

-- IsNextTileShoreOrWater across a connection strip: pokered loads the
-- neighbor's tiles into the border, so wTileInFrontOfPlayer is the
-- connected map's tile even when the facing cell is off this map.
-- Shore/water classification still uses THIS map's tileset rules
-- (SHIP_PORT's $32 dock exception), matching the asm.
function OverworldState:facingIsShoreOrWater()
  if not self:tilesetHasWater() then return false end
  local fx, fy = self.player:facingCell()
  if self.map:inBounds(fx, fy) then
    return self.map:isWaterCell(fx, fy)
  end
  local dest, ts, x, y = self:connectionLanding(self.player.facing)
  if not dest then return false end
  local tile = Map.defCellTile(dest, ts, x, y)
  if tile == nil then return false end
  return self.map.waterTiles[tile] or false
end

-- tryToStopSurfing land check, including a land landing across a map
-- connection (surf off Cinnabar's east coast water back onto the coast).
function OverworldState:facingIsLandDismount()
  local p = self.player
  local fx, fy = p:facingCell()
  if self.map:inBounds(fx, fy) then
    return self.map:isWalkableCell(fx, fy)
       and Collision.canMove(self.map, self.entities, p, p.facing)
  end
  local dest, ts, x, y = self:connectionLanding(p.facing)
  if not dest then return false end
  if not Map.defIsWalkableCell(dest, ts, x, y) then return false end
  -- IsSpriteInFrontOfPlayer2: no current-map sprite can sit past the edge
  return not Collision.occupied(self.entities, fx, fy, p)
end

-- -------------------------------------------------------------------------
-- interactions
-- -------------------------------------------------------------------------

-- HM field moves are gated by badges like the original
-- (constants.hmBadges; distinct from constants.hmMoves, the forget gate).
-- Gen 1 allows field use from fainted party members (party menu + name
-- lookup for Cut/Surf messages); do not require mon.hp > 0 here.
function OverworldState:partyKnows(moveId)
  local gate = (FieldDefaults.constant(Game.data, "hmBadges") or {})[moveId]
  local badge = gate and gate.badge
  if badge and not Game.save.inventory[badge] then
    return nil
  end
  for _, mon in ipairs(Game.save.party) do
    for _, mv in ipairs(mon.moves) do
      if mv.id == moveId then return mon end
    end
  end
  return nil
end

-- The rejection loop shared by the Good and Super Rods
-- (item_effects.asm ItemUseGoodRod .RandomLoop / ReadSuperRodData): an
-- odd random byte is no bite; otherwise a 2-bit pick rerolls until it
-- lands inside the group, so the bite odds are size/(size+4)
-- (1/3 for the Good Rod's pair, up to 1/2 for 4-mon Super Rod groups).
local function rollFishingGroup(group)
  while true do
    local r = love.math.random(0, 255)
    if r % 2 == 1 then return nil end
    local pick = math.floor(r / 2) % 4
    if pick < #group then
      local slot = group[pick + 1]
      return { species = slot.species, level = slot.level }
    end
  end
end

-- field.fishing: `always` hooks that catch every time (the Old Rod),
-- `pool` a fixed candidate list, `perMap` the field key holding per-map
-- groups.  The rejection-loop odds above stay engine behavior.
local function fishingPool(data, rod, mapId)
  local def = (FieldDefaults.field(data, "fishing") or {})[rod]
  if not def then return nil end
  if def.pool then return def.pool end
  if def.perMap then
    local groups = data.field[def.perMap]
    return groups and groups[mapId]
  end
  return nil, def.always
end

local function catchFrom(pool, always)
  if always then return { species = always.species, level = always.level } end
  if pool and #pool > 0 then return rollFishingGroup(pool) end
  return nil
end

-- Fishing (engine/items/item_effects.asm FishingInit + engine/overworld):
-- Old Rod always hooks a L5 Magikarp; Good Rod bites ~1/3 for
-- Goldeen/Poliwag L10; Super Rod uses the map's extracted fishing group
-- (no group means "Not even a nibble!").
function OverworldState:goFishing(rod)
  local pool, always = fishingPool(Game.data, rod, self.map.id)
  local enc
  if Runtime.wantsHook("encounter.fishing") then
    -- the chain may inspect or replace the candidate list before the roll
    enc = Runtime.call("encounter.fishing", function(_, _, candidates)
      return catchFrom(candidates, always)
    end, rod, self.map.id, pool)
  else
    enc = catchFrom(pool, always)
  end
  -- the bobber waits a beat before the verdict (the original's
  -- FishingInit dot animation); the rod pose draws in the meantime
  self.fishing = { facing = self.player.facing }
  Game.stack:push(TextBox.new(Game, ". . .", function()
    self.fishing = nil
    if not enc then
      Game.stack:push(TextBox.new(Game, "Not even a nibble!"))
      return
    end
    Game.stack:push(TextBox.new(Game, "Oh!\nIt's a bite!", function()
      local BattleState = require("src.battle.BattleState")
      local battle = BattleState.newWild(Game, enc.species, enc.level, { hooked = true })
      if Game.save.safari and Map.inRegion(self.map.def, "SAFARI", "SAFARI_ZONE") then
        battle:makeSafari(Game.save.safari)
      end
      battle.onFinish = function(result) self:afterBattle(result, battle) end
      self:pushBattle(battle)
    end))
  end))
end

-- Fly to a visited town (called from the party menu).
function OverworldState:flyTo(mapId)
  local spot = Game.data.field.flyWarps[mapId]
  if not spot then return end
  require("src.core.Sound").play(Game.data, "Fly")
  Game.save.onBike = false
  Game.save.forcedBike = nil -- HandleFlyWarpOrDungeonWarp res BIT_ALWAYS_ON_BIKE
  self.player.surfing = false
  -- the bird carries the player off westward before the warp
  -- (engine/overworld/player_animations.asm LoadBirdSpriteGraphics)
  self.flyAnim = { frames = 48 }
  self.player.inputLocked = true
  self.flyDest = { map = mapId, x = spot.x, y = spot.y }
end

function OverworldState:npcAtCell(cx, cy)
  for _, npc in ipairs(self.npcs) do
    if (npc.cellX == cx and npc.cellY == cy) or
       (npc.targetX == cx and npc.targetY == cy) then
      return npc
    end
  end
  return nil
end

-- what the A press resolved to, for world.interacted's listeners
local function interacted(self, fx, fy, kind, target)
  Runtime.emit("world.interacted", { mapId = self.map.id, x = fx, y = fy,
                                     kind = kind, target = target })
end

function OverworldState:interact()
  local p = self.player
  local fx, fy = p:facingCell()

  local npc = self:npcAtCell(fx, fy)
  if not npc and self.map:isCounterCell(fx, fy) then
    -- talk across counters (mart clerks, nurses); uses the tileset's
    -- counter tiles from tileset_headers.asm
    local fx2, fy2 = Collision.target(fx, fy, p.facing)
    npc = self:npcAtCell(fx2, fy2)
  end
  if npc then
    if not npc.moving then
      self:talkTo(npc)
    end
    interacted(self, fx, fy, "npc", npc)
    return
  end

  local sign = self.map:signAtCell(fx, fy)
  if sign then
    self:showMapText(sign.text, nil)
    interacted(self, fx, fy, "sign", sign)
    return
  end

  -- Silph Co card key doors (engine/events/card_key.asm)
  if self:tryCardKeyDoor(fx, fy) then
    interacted(self, fx, fy, "door")
    return
  end

  -- hidden items / coins / slot machines / PC tiles / bench guys /
  -- gym statues / trash cans (data/events/hidden_events.asm)
  if self:tryHiddenObject(fx, fy) then
    interacted(self, fx, fy, "hidden")
    return
  end

  -- No overworld A-press hook for field moves: pokered has no such hook
  -- anywhere -- CUT and SURF (like FLY/FLASH/DIG/TELEPORT/STRENGTH) are
  -- only ever chosen from the party menu's per-mon field-move submenu
  -- (start_sub_menus.asm .outOfBattleMovePointers), and only succeed if
  -- the player happens to be facing a cuttable tree / water at the moment
  -- of selection.  See PartyMenu's cut/surf actions -> useCutFieldMove /
  -- useSurfFieldMove below.

  -- map-script interact hook (hand-ported hidden events like the
  -- museum fossil exhibits)
  local hooks = mapScripts.get(self.map.id)
  if hooks and hooks.onInteract and hooks.onInteract(Game, self, fx, fy) then
    interacted(self, fx, fy, "script")
    return
  end

  -- tileset-generic reads (PrintBookshelfText): facing up into a
  -- bookshelf/statue/shelf tile prints its stock line
  if self:tryBookshelf(fx, fy) then
    interacted(self, fx, fy, "bookshelf")
    return
  end
  interacted(self, fx, fy, "none")
end

-- field.bookshelves (data/tilesets/bookshelf_tile_ids.asm): tileset id +
-- collision tile -> what to show.  Only fires facing up, like the
-- original.  An entry carries `kind` (one of the five vanilla flavors),
-- `text` (a data.text key) or `screen` (a state module to push).
function OverworldState:tryBookshelf(fx, fy)
  if self.player.facing ~= "up" then return false end
  if not self.map:inBounds(fx, fy) then return false end
  local shelves = FieldDefaults.field(Game.data, "bookshelves")
  local table_ = shelves and shelves[self.map.def.tileset]
  if not table_ then return false end
  local entry = table_[self.map:cellTile(fx, fy)]
  if not entry then return false end
  local t = Game.data.text
  if entry.text then
    Game.stack:push(TextBox.new(Game, t[entry.text] or entry.text))
    return true
  end
  if entry.screen then
    -- Blue's house shelf opens the TOWN MAP (TownMapText)
    pcall(Screens.push, Game, entry.screen)
    return true
  end
  local kind = entry.kind
  if kind == "books" then
    -- Celadon Mansion's Diglett sculpture (book_or_sculpture.asm):
    -- MANSION tileset + faced cell's top-left tile $38
    if self.map.def.tileset == "MANSION"
       and self.map:tileAt(fx * 2, fy * 2) == 0x38 then
      Game.stack:push(TextBox.new(Game, t._DiglettSculptureText
        or "It's a sculpture\nof DIGLETT."))
      return true
    end
    Game.stack:push(TextBox.new(Game, t._PokemonBooksText
      or "Crammed full of\nPOKéMON books!"))
  elseif kind == "stuff" then
    Game.stack:push(TextBox.new(Game, t._PokemonStuffText
      or "There's a slew of\nPOKéMON stuff!"))
  elseif kind == "elevator" then
    Game.stack:push(TextBox.new(Game, t._ElevatorText
      or "An elevator!"))
  elseif kind == "statues" then
    -- IndigoPlateauStatues: the plaque, then one of the two lines
    -- keyed by the statue's column (XCoord bit 0)
    local line = (self.player.cellX % 2 == 0) and t._IndigoPlateauStatuesText2
                 or t._IndigoPlateauStatuesText3
    Game.stack:push(TextBox.new(Game,
      (t._IndigoPlateauStatuesText1 or "INDIGO PLATEAU") .. "\f"
      .. (line or "POKéMON LEAGUE HQ")))
  end
  return true
end

-- Hidden events at the faced cell (data/events/hidden_events.asm):
-- HiddenItems give their item once, HiddenCoins fill the COIN CASE,
-- StartSlotMachine seats open the minigame.  Taken spots persist in
-- save.hiddenTaken.
function OverworldState:tryHiddenObject(fx, fy)
  local field = Game.data.field
  local save = Game.save
  local key = self.map.id .. "_" .. fx .. "_" .. fy

  for _, h in ipairs(field.hiddenItems and field.hiddenItems[self.map.id] or {}) do
    if h.x == fx and h.y == fy then
      save.hiddenTaken = save.hiddenTaken or {}
      if save.hiddenTaken[key] then return false end
      if not require("src.inventory.Bag").add(save, h.item, 1) then
        Game.stack:push(TextBox.new(Game, "You can't carry\nany more items!"))
        return true
      end
      save.hiddenTaken[key] = true
      local name = Game.data.items[h.item] and Game.data.items[h.item].name or h.item
      -- hidden items always play SFX_GET_ITEM_2 (hidden_items.asm)
      require("src.core.Sound").play(Game.data, "Get_Item2")
      Game.stack:push(TextBox.new(Game,
        ("%s found\n%s!"):format(save.player.name, name)))
      return true
    end
  end

  for _, h in ipairs(field.hiddenCoins and field.hiddenCoins[self.map.id] or {}) do
    if h.x == fx and h.y == fy then
      save.hiddenTaken = save.hiddenTaken or {}
      if save.hiddenTaken[key] then return false end
      if not save.inventory.COIN_CASE then return false end
      save.hiddenTaken[key] = true
      save.coins = math.min(9999, (save.coins or 0) + h.coins)
      require("src.core.Sound").play(Game.data, "Get_Item2")
      Game.stack:push(TextBox.new(Game,
        ("%s found\n%d coins!"):format(save.player.name, h.coins)))
      return true
    end
  end

  -- broken-machine and can't-play texts are pokered's exact strings
  -- (_GameCornerOutOfOrderText etc., data/text/text_2.asm)
  local txt = Game.data.text or {}
  for seatIndex, h in ipairs(field.slotMachines and field.slotMachines[self.map.id] or {}) do
    if h.x == fx and h.y == fy then
      if h.state == "out_of_order" then
        Game.stack:push(TextBox.new(Game, txt._GameCornerOutOfOrderText
          or "OUT OF ORDER\nThis is broken."))
      elseif h.state == "out_to_lunch" then
        Game.stack:push(TextBox.new(Game, txt._GameCornerOutToLunchText
          or "OUT TO LUNCH\nThis is reserved."))
      elseif h.state == "keys" then
        Game.stack:push(TextBox.new(Game, txt._GameCornerSomeonesKeysText
          or "Someone's keys!\nThey'll be back."))
      elseif not save.inventory.COIN_CASE then
        Game.stack:push(TextBox.new(Game, txt._GameCornerCoinCaseText
          or "A COIN CASE is\nrequired!"))
      elseif (save.coins or 0) == 0 then
        -- AbleToPlaySlotsCheck: a COIN CASE with no coins can't play
        Game.stack:push(TextBox.new(Game, txt._GameCornerNoCoinsText
          or "You don't have\nany coins!"))
      else
        -- one machine per visit is secretly lucky
        -- (wLuckySlotHiddenEventIndex, engine/slots/game_corner_slots.asm)
        Screens.push(Game, "SlotMachine", seatIndex == self.luckySlot)
      end
      return true
    end
  end

  -- Bill's cell-separator PC (data/events/hidden_events.asm: hidden_event
  -- 1,4 BillsHousePC SPRITE_FACING_UP)
  if self.map.id == "BILLS_HOUSE" and fx == 1 and fy == 4
     and self.player.facing == "up" then
    self:billsHousePC()
    return true
  end

  local extras = field.hiddenExtras
  if not extras then return false end
  local facing = self.player.facing

  -- Pokémon Center PCs and other PC tiles
  for _, h in ipairs(extras.pcTiles[self.map.id] or {}) do
    if h.x == fx and h.y == fy and (not h.facing or h.facing == facing) then
      self:openPC()
      return true
    end
  end

  -- bench guys (data/events/bench_guys.asm)
  for _, h in ipairs(extras.benchGuys[self.map.id] or {}) do
    if h.x == fx and h.y == fy and (not h.facing or h.facing == facing) then
      local text = h.text and Game.data.text["_" .. h.text]
      if text then
        Game.stack:push(TextBox.new(Game, text))
        return true
      end
    end
  end

  -- gym statues (engine/events/hidden_events/gym_statues.asm): show
  -- the gym plaque; the player's name joins the winners once the
  -- badge is earned
  for _, h in ipairs(extras.gymStatues[self.map.id] or {}) do
    if h.x == fx and h.y == fy and facing == "up" then
      local gym = require("data.scripts.gyms")[self.map.id]
      if gym then
        local key = save.inventory[gym.badge] and "_GymStatueText2" or "_GymStatueText1"
        local text = Game.data.text[key]
                     or "{RAM}\nPOKéMON GYM\nLEADER: {RAM}"
        text = text:gsub("{RAM:wGymCityName}", gym.city)
                   :gsub("{RAM:wGymLeaderName}", gym.leader)
        Game.stack:push(TextBox.new(Game, text))
        return true
      end
    end
  end

  -- the Vermilion Gym trash can lock puzzle
  if self.map.id == "VERMILION_GYM" then
    for _, h in ipairs(extras.trashCans.cans or {}) do
      if h.x == fx and h.y == fy then
        self:trashCanSwitch(h.can)
        return true
      end
    end
  end

  return false
end

-- Card key doors: on the Silph Co maps, facing a locked-door tile with
-- the CARD KEY replaces the door block with the open one
-- (engine/events/card_key.asm PrintCardKeyText).
function OverworldState:tryCardKeyDoor(fx, fy)
  local ck = Game.data.field.cardKeyDoors
  if not ck then return false end
  local onList = false
  for _, m in ipairs(ck.maps) do
    if m == self.map.id then onList = true break end
  end
  if not onList or not self.map:inBounds(fx, fy) then return false end
  local tile = self.map:cellTile(fx, fy)
  local openBlock
  if self.map.id == "SILPH_CO_11F" then
    if tile == ck.silphCo11F.doorTile then openBlock = ck.silphCo11F.openBlock end
  else
    for _, t in ipairs(ck.doorTiles) do
      if tile == t then openBlock = ck.openBlock break end
    end
  end
  if not openBlock then return false end
  local t = Game.data.text
  if not Game.save.inventory.CARD_KEY then
    Game.stack:push(TextBox.new(Game,
      t._CardKeyFailText or "Darn! It needs a\nCARD KEY!"))
    return true
  end
  require("src.core.Sound").play(Game.data, "Go_Inside")
  local bx, by = math.floor(fx / 2), math.floor(fy / 2)
  self:replaceBlock(bx, by, openBlock)
  -- opened doors stay open across reloads (the per-door unlock events
  -- the floors' gate callbacks check, EVENT_SILPH_CO_n_UNLOCKED_DOOR*)
  local closedDoors = FieldDefaults.fieldValue(Game.data, "cardKeyDoors",
                                               "closedDoors")
  for _, door in ipairs(closedDoors and closedDoors[self.map.id] or {}) do
    if door.bx == bx and door.by == by then
      Game.save.flags[door.event] = true
      break
    end
  end
  Game.stack:push(TextBox.new(Game,
    (t._CardKeySuccessText1 or "Bingo!")
    .. (t._CardKeySuccessText2 or "\nThe CARD KEY\nopened the door!")))
  return true
end

-- The Vermilion Gym trash can puzzle
-- (engine/events/hidden_events/vermilion_gym_trash.asm GymTrashScript):
-- the first switch hides in a random even can, rolled on every
-- Vermilion City map load (scripts/VermilionCity.asm VermilionCity_Script
-- .setFirstLockTrashCanIndex -- see M.VERMILION_CITY.onEnter in
-- data/scripts/story.lua) and re-rolled on every failed second-can
-- guess; the second switch is drawn from the GymTrashCans candidate
-- table (bug included).  Opening both unlocks the door block at (2,2)
-- (scripts/VermilionGym.asm VermilionGymSetDoorTile).
function OverworldState:trashCanSwitch(canIndex)
  local t = Game.data.text
  local save = Game.save
  local tc = Game.data.field.hiddenExtras.trashCans
  local trashText = t._VermilionGymTrashText or "Nope, there's\nonly trash here."
  -- "Don't do the trash can puzzle if it's already been done."
  if save.flags.EVENT_2ND_LOCK_OPENED then
    Game.stack:push(TextBox.new(Game, trashText))
    return
  end
  save.trashPuzzle = save.trashPuzzle or {}
  local puz = save.trashPuzzle
  if puz.opened1 then
    -- migrate mid-puzzle saves from before the port tracked the real
    -- EVENT_1ST_LOCK_OPENED flag
    save.flags.EVENT_1ST_LOCK_OPENED = true
    puz.opened1 = nil
  end
  if not puz.first then
    -- normally rolled by Vermilion City's map load (the only way in);
    -- covers saves from before that hook and debug warps straight in
    puz.first = love.math.random(0, 7) * 2 -- Random & $0e: even cans
  end
  if not save.flags.EVENT_1ST_LOCK_OPENED then
    if canIndex ~= puz.first then
      Game.stack:push(TextBox.new(Game, trashText))
      return
    end
    -- .openFirstLock: SetEvent EVENT_1ST_LOCK_OPENED, then pick where
    -- the second switch hides.  GymTrashCans rows are `mask,
    -- cand1..cand4` where the mask doubles as the candidate count
    -- (2, 3 or 4).  The asm ANDs the mask with a random byte (its
    -- nibble swap is distribution-neutral) and uses `result - 1` as a
    -- byte offset into the candidates:
    --   mask 3: result 1-3 -> candidate 1-3
    --   mask 2: result 2   -> candidate 2 (candidate 1 unreachable)
    --   mask 4: result 4   -> candidate 4 (candidates 1-3 unreachable)
    --   result 0: `dec a` underflows to $ff and the read lands on the
    --   ROM bank's zero padding, so the second switch lands in can 0
    --   regardless of adjacency (the documented GymTrashCans bug)
    save.flags.EVENT_1ST_LOCK_OPENED = true
    local adj = tc.adjacent[puz.first]
    local masked = require("bit").band(love.math.random(0, 255), #adj)
    puz.second = masked == 0 and 0 or adj[masked]
    -- VermilionGymTrashSuccessText1's text_asm tail plays SFX_SWITCH only
    -- after the text has printed (text_far ...; text_asm;
    -- WaitForSoundToFinish; PlaySound SFX_SWITCH; WaitForSoundToFinish),
    -- and DisplayTextID's WaitForTextScrollButtonPress then holds the box
    -- until the player dismisses it -- so the beep belongs on close, not
    -- open.
    Game.stack:push(TextBox.new(Game,
      t._VermilionGymTrashSuccessText1
      or "Hey! There's a\nswitch under the\ntrash!\fThe 1st electric\nlock opened!",
      function() require("src.core.Sound").play(Game.data, "Switch") end))
    return
  end
  -- .trySecondLock
  if canIndex == puz.second then
    -- .openSecondLock: only VermilionGymTrashSuccessText3 prints
    -- (SuccessText2 is unused in pokered)
    save.flags.EVENT_2ND_LOCK_OPENED = true
    -- the clear floor block opens the doors (VermilionGymSetDoorTile)
    local door = FieldDefaults.fieldValue(Game.data, "hiddenExtras",
                                          "trashCans", "doorBlock")
    self:replaceBlock(door.bx, door.by, door.block)
    -- SuccessText3's text_asm tail plays SFX_GO_INSIDE after the text
    -- prints, so the beep fires as the box closes, not as it opens.
    Game.stack:push(TextBox.new(Game,
      t._VermilionGymTrashSuccessText3
      or "The 2nd electric\nlock opened!\fThe motorized door\nopened!",
      function() require("src.core.Sound").play(Game.data, "Go_Inside") end))
  else
    -- wrong can: ResetEvent EVENT_1ST_LOCK_OPENED and immediately
    -- re-roll the first switch (Random & $e)
    save.flags.EVENT_1ST_LOCK_OPENED = nil
    puz.first = love.math.random(0, 7) * 2
    puz.second = nil
    -- VermilionGymTrashFailText's text_asm tail plays SFX_DENIED after the
    -- text prints, so the beep fires as the box closes, not as it opens.
    Game.stack:push(TextBox.new(Game,
      t._VermilionGymTrashFailText
      or "Nope! There's\nonly trash here.\fHey! The electric\nlocks were reset!",
      function() require("src.core.Sound").play(Game.data, "Denied") end))
  end
end

-- Bill's House PC (engine/events/hidden_events/bills_house_pc.asm
-- BillsHousePC).  Check order matches pokered:
--   1) EVENT_LEFT_BILLS_HOUSE_AFTER_HELPING -> Eevee collection list
--   2) EVENT_USED_CELL_SEPARATOR_ON_BILL   -> teleporter monitor text
--   3) EVENT_BILL_SAID_USE_CELL_SEPARATOR  -> cell-separator cutscene
--   4) else                               -> teleporter monitor text
-- Leaving after the SS Ticket (Route25ToggleBillsScript) arms (1).
function OverworldState:billsHousePC()
  local t = Game.data.text
  local flags = Game.save.flags
  if flags.EVENT_LEFT_BILLS_HOUSE_AFTER_HELPING then
    self:billsHousePokemonList()
    return
  end
  if flags.EVENT_USED_CELL_SEPARATOR_ON_BILL
     or not flags.EVENT_BILL_SAID_USE_CELL_SEPARATOR then
    Game.stack:push(TextBox.new(Game, t._BillsHouseMonitorText
      or "TELEPORTER is\ndisplayed on the\nPC monitor."))
    return
  end
  require("src.core.Music").stop()
  Game.stack:push(TextBox.new(Game, t._BillsHouseInitiatedText
    or "{PLAYER} initiated\nTELEPORTER's Cell\nSeparator!", function()
    flags.EVENT_USED_CELL_SEPARATOR_ON_BILL = true
    require("src.core.Sound").play(Game.data, "Switch")
    self:queueScript({
      { "wait", 32 },
      { "play_sound", "Tink" },
      { "wait", 80 },
      { "play_sound", "Shrink" },
      { "wait", 48 },
      { "play_sound", "Tink" },
      { "wait", 32 },
      { "play_sound", "Get_Item1" },
      { "wait", 30 },
    }, { onDone = function() self:billsHouseBillExits() end })
  end))
end

-- BillsHousePokemonList: EEVEE / FLAREON / JOLTEON / VAPOREON + CANCEL;
-- picking one runs DisplayPokedex (DexEntryMenu) and returns to the list.
function OverworldState:billsHousePokemonList()
  local t = Game.data.text
  local Menu = require("src.ui.Menu")
  local function openList()
    local species = { "EEVEE", "FLAREON", "JOLTEON", "VAPOREON" }
    local items = {}
    for _, id in ipairs(species) do
      local def = Game.data.pokemon[id]
      table.insert(items, {
        label = (def and def.name) or id,
        keepOpen = true,
        onSelect = function()
          local dex = Game.save.pokedex
          if dex then dex.seen[id] = true end
          Screens.push(Game, "DexEntryMenu", id)
        end,
      })
    end
    table.insert(items, { label = "CANCEL" })
    -- TextBoxBorder b=10,c=9 at (0,0) -> total tw=11, th=12
    Game.stack:push(Menu.new(Game, items,
      { tx = 0, ty = 0, tw = 11, th = 12 }))
  end
  Game.stack:push(TextBox.new(Game, t._BillsHousePokemonListText1
    or "BILL's favorite\nPOKéMON list!", openList))
end

-- BillsHouseBillExitsMachineScript: human Bill appears inside the machine
-- at (1,2) and walks out to his spot at (4,4); the map music resumes and
-- EVENT_MET_BILL / EVENT_MET_BILL_2 arm the SS-Ticket dialogue.  The Eevee
-- PC list arms later, on the first Route 25 load after the ticket
-- (EVENT_LEFT_BILLS_HOUSE_AFTER_HELPING).
function OverworldState:billsHouseBillExits()
  local Commands = require("src.script.Commands")
  local ctx = { game = Game, save = Game.save, overworld = self }
  Commands.show_object(ctx, "BILLS_HOUSE", "BILLSHOUSE_BILL1")
  local function done()
    Game.save.flags.EVENT_MET_BILL = true
    Game.save.flags.EVENT_MET_BILL_2 = true
    require("src.core.Music").playMap(Game.data, self.map.id,
                                      Game.save.onBike, self.player.surfing)
  end
  local bill
  for _, n in ipairs(self.npcs) do
    if n.def and n.def.name == "BILLSHOUSE_BILL1" then bill = n break end
  end
  if not (bill and self.map.id == "BILLS_HOUSE") then
    done()
    return
  end
  bill.cellX, bill.cellY = 1, 2
  bill.px, bill.py = 16, 32
  bill.facing = "down"
  self:scriptMove(bill, "down", 1, function()
    self:scriptMove(bill, "right", 3, function()
      self:scriptMove(bill, "down", 1, done)
    end)
  end)
end

-- Any hidden item still unfound NEAR the player? (the ITEMFINDER,
-- engine/items/itemfinder.asm HiddenItemNear: coord > clamp0(player-5)
-- and coord <= player+4 (Y) / player+5 (X) -- the clamp excludes
-- coordinate 0 whenever the player coordinate is <= 4, like the original)
function OverworldState:hasHiddenItemLeft()
  local list = Game.data.field.hiddenItems and Game.data.field.hiddenItems[self.map.id]
  if not list then return false end
  local taken = Game.save.hiddenTaken or {}
  local px, py = self.player.cellX, self.player.cellY
  local function near(c, v, hiAdd)
    return v > math.max(c - 5, 0) and v <= c + hiAdd
  end
  for _, h in ipairs(list) do
    if not taken[self.map.id .. "_" .. h.x .. "_" .. h.y]
       and near(py, h.y, 4) and near(px, h.x, 5) then
      return true
    end
  end
  return false
end

function OverworldState:tilesetHasWater()
  for _, t in ipairs(Game.data.field.waterTilesets) do
    if t == self.map.def.tileset then return true end
  end
  return false
end

-- field.seafoam[map].surfBlocked: cells where SURF is refused until the
-- listed events fire (IsSurfingAllowed's SEAFOAM_ISLANDS_B4F stairs case)
function OverworldState:surfBlockedHere()
  local blocked = FieldDefaults.fieldValue(Game.data, "seafoam", self.map.id,
                                           "surfBlocked")
  if not blocked then return false end
  local p = self.player
  for _, cell in ipairs(blocked) do
    if p.cellX == cell.x and p.cellY == cell.y then
      local cleared = true
      for _, e in ipairs(cell.untilEvents or {}) do
        if not Game.save.flags[e] then cleared = false break end
      end
      if not cleared then return true end
    end
  end
  return false
end

-- Gen 1 has no confirmation prompt: using SURF gets straight on
-- (_SurfingGotOnText, item_effects.asm .surf).  Called from the party
-- menu's SURF action (via useSurfFieldMove) once the facing tile has been
-- confirmed to be water -- there is no overworld A-press hook.
function OverworldState:trySurf(fx, fy)
  local mon = self:partyKnows("SURF")
  if not mon then return end
  local name = mon.nickname or Game.data.pokemon[mon.species].name
  local p = self.player
  p.surfing = true
  require("src.core.Music").setSurfing(Game.data, true)
  local text = (Game.data.text._SurfingGotOnText or "{PLAYER} got on\n{RAM:wNameBuffer}!")
               :gsub("{RAM:wNameBuffer}", name)
  Game.stack:push(TextBox.new(Game, text, function()
    -- start_sub_menus.asm .surf: UseItem returns (mount + text done),
    -- then GBPalWhiteOutWithDelay3 blinks before the simulated forward
    -- press steps onto the water (or across a connection strip, like
    -- Cinnabar's east coast onto Route 20)
    local Transition = require("src.render.Transition")
    if Transition.whiteFlash then
      Game.stack:push(Transition.whiteFlash(Game, nil, function()
        self:stepForwardOrCrossEdge(p.facing)
      end))
    else
      self:stepForwardOrCrossEdge(p.facing)
    end
  end))
end

function OverworldState:tryCut(fx, fy)
  -- UsedCut (engine/overworld/cut.asm) gates on the TILESET before
  -- anything else: only OVERWORLD (tree tile $3d) and GYM (plant tile
  -- $50) have cuttable anything. Matching raw block ids alone
  -- false-positives on every other tileset -- block ids are only
  -- meaningful within one tileset, so Route 23 (PLATEAU) had blocks
  -- matching a swap's `before`, and applying it wrote a block id that
  -- does not exist in PLATEAU's block table: the renderer indexed nil
  -- and the game crashed. The same false match is what made the bot
  -- chain-cut "ornamental bushes" around Saffron and Celadon.
  local ts = self.map.def.tileset
  local tile = self.map:cellTile(fx, fy)
  local isGrass = (ts == "OVERWORLD" and tile == 0x52)
  if not ((ts == "OVERWORLD" and tile == 0x3d)
          or (ts == "GYM" and tile == 0x50)
          or isGrass) then
    return false
  end
  local bx, by = math.floor(fx / 2), math.floor(fy / 2)
  local block = self.map:blockAt(bx, by)
  local swap
  for _, sw in ipairs(Game.data.field.cutTreeSwaps) do
    if sw.before == block then swap = sw break end
  end
  if not swap or (not isGrass and self.map:isWalkableCell(fx, fy)) then return false end
  local mon = self:partyKnows("CUT")
  if not mon then return false end
  -- gen 1 confirms nothing (engine/overworld/cut.asm UsedCut): the
  -- _UsedCutText message, then the tree vanishes with dust + SFX_CUT
  local name = mon.nickname or Game.data.pokemon[mon.species].name
  local text = (Game.data.text._UsedCutText or "{RAM:wNameBuffer} hacked\naway with CUT!")
               :gsub("{RAM:wNameBuffer}", name)
  Game.stack:push(TextBox.new(Game, text, function()
    self.cutBlocks = self.cutBlocks or {}
    self.cutBlocks[self.map.id] = self.cutBlocks[self.map.id] or {}
    table.insert(self.cutBlocks[self.map.id],
                 { bx = bx, by = by, block = block })
    self.map:setBlock(bx, by, swap.after)
    self.map.renderer:rebuild()
    local finish = function()
      require("src.core.Sound").play(Game.data, "Cut")
    end
    if isGrass then
      -- AnimCut .grass: tall grass gets the leaf-swirl / dust puff, not
      -- the tree-split slide
      self:startDustAnim(fx, fy, finish)
    elseif ts == "OVERWORLD" then
      -- the tree splits in half and slides apart (AnimCut .cutTreeLoop);
      -- the GYM plant keeps the shared dust/leaf puff
      self:startCutTreeAnim(fx, fy, finish)
    else
      self:startDustAnim(fx, fy, finish)
    end
  end))
  return true
end

-- The cut-tree split (engine/overworld/cut.asm InitCutAnimOAM +
-- engine/overworld/cut2.asm AnimCut): the tree sprite's top half slides
-- +1px and its bottom half -1px per frame for 8 frames, flickering,
-- before the swapped block shows through.  Falls back to the dust puff
-- when the extracted tree sprite is unavailable.
function OverworldState:startCutTreeAnim(cx, cy, onDone)
  local fxDef = Game.data.field.overworldFx
  if not (fxDef and fxDef.cutTree) then
    return self:startDustAnim(cx, cy, onDone)
  end
  self.cutAnim = { x = cx, y = cy, frames = 8, total = 8, onDone = onDone }
end

-- Party-menu SURF entry (start_sub_menus.asm .surf): badge-check SOULBADGE,
-- farcall IsSurfingAllowed, then UseItem(SURFBOARD) -> ItemUseSurfboard
-- (item_effects.asm), which either tries to dismount (already surfing) or
-- runs IsNextTileShoreOrWater on the tile the player is FACING and jumps
-- to SurfingAttemptFailed (_NoSurfingHereText) if it isn't water.  This is
-- a side-effect-free check that reports which text/flow the caller should
-- use; the actual mount happens in trySurf on "ok".  Returns:
--   "no_badge"    -> SOULBADGE missing / no SURF mon (_NewBadgeRequiredText)
--   "forced_bike" -> on the Cycling Road (_CyclingIsFunText)
--   "current"     -> Seafoam B4F stairs before the boulders (_CurrentTooFastText)
--   "dismount"    -> already surfing, facing dry land; caller steps forward
--   "no_place"    -> already surfing, nowhere to land (_SurfingNoPlaceToGetOffText)
--   "no_water"    -> not facing water (_NoSurfingHereText)
--   "ok"          -> facing water; caller may call trySurf(fx, fy)
function OverworldState:useSurfFieldMove()
  if not self:partyKnows("SURF") then return "no_badge" end
  local p = self.player
  -- IsSurfingAllowed (engine/overworld/field_move_messages.asm): surfing
  -- is refused while BIT_ALWAYS_ON_BIKE of wStatusFlags6 is set (the
  -- Cycling Road, armed by the forced-bike tiles and cleared by the
  -- Route 16/18 gate scripts / fly + dungeon warps / blackouts), and on
  -- SEAFOAM_ISLANDS_B4F standing on the stairs square (dbmapcoord 7,11)
  -- until both EVENT_SEAFOAM4_BOULDER*_DOWN_HOLE events are set.
  if Game.save.forcedBike then return "forced_bike" end
  if self:surfBlockedHere() then return "current" end
  if p.surfing then
    -- ItemUseSurfboard .tryToStopSurfing: blocked by a sprite in front
    -- (IsSpriteInFrontOfPlayer2), a water tile-pair collision, or a
    -- facing tile that isn't in the tileset's land-passable list;
    -- otherwise the player walks forward off the water.  Facing a land
    -- cell across a map connection (Cinnabar east coast) counts too --
    -- pokered reads that landing from the connection strip.
    if self:facingIsLandDismount() then
      return "dismount"
    end
    return "no_place"
  end
  -- IsNextTileShoreOrWater, including connection-strip water (issue #125)
  if not self:facingIsShoreOrWater() then
    return "no_water"
  end
  return "ok"
end

-- Party-menu CUT entry (start_sub_menus.asm .cut -> predef UsedCut,
-- engine/overworld/cut.asm): badge-check CASCADEBADGE then check the tile
-- the player is FACING against the tileset's cut-tree ids; _NothingToCutText
-- (and .loop back to the submenu) if it isn't cuttable.  Side-effect-free
-- check mirroring useSurfFieldMove; tryCut does the actual cut on "ok".
-- Returns:
--   "no_badge" -> CASCADEBADGE missing / no CUT mon (_NewBadgeRequiredText)
--   "nothing"  -> not facing a cuttable tree (_NothingToCutText)
--   "ok"       -> facing a cuttable tree; caller may call tryCut(fx, fy)
function OverworldState:useCutFieldMove()
  if not self:partyKnows("CUT") then return "no_badge" end
  local fx, fy = self.player:facingCell()
  if not self.map:inBounds(fx, fy) then return "nothing" end
  -- same tileset/tile gate as tryCut (UsedCut, engine/overworld/cut.asm):
  -- a tree BLOCK also contains fence/path cells, and facing those is
  -- "nothing to cut" in vanilla
  local ts = self.map.def.tileset
  local tile = self.map:cellTile(fx, fy)
  local isGrass = (ts == "OVERWORLD" and tile == 0x52)
  if not ((ts == "OVERWORLD" and tile == 0x3d)
          or (ts == "GYM" and tile == 0x50)
          or isGrass) then
    return "nothing"
  end
  local bx, by = math.floor(fx / 2), math.floor(fy / 2)
  local block = self.map:blockAt(bx, by)
  local swap
  for _, sw in ipairs(Game.data.field.cutTreeSwaps) do
    if sw.before == block then swap = sw break end
  end
  if not swap or (not isGrass and self.map:isWalkableCell(fx, fy)) then return "nothing" end
  return "ok"
end

function OverworldState:talkTo(npc)
  npc.frozen = true
  local unfreeze = function() npc.frozen = false end
  local d = npc.def

  -- hand-ported scripts always win
  if mapScripts.talkScript(self.map.id, d.text) then
    self:showMapText(d.text, npc, unfreeze)
    return
  end

  -- item balls (object_event item argument)
  if d.item then
    if not require("src.inventory.Bag").add(Game.save, d.item, 1) then
      Game.stack:push(TextBox.new(Game, "You can't carry\nany more items!"))
      return
    end
    Game.save.itemsTaken = Game.save.itemsTaken or {}
    Game.save.itemsTaken[npc.id] = true
    for i, n in ipairs(self.npcs) do
      if n == npc then table.remove(self.npcs, i) break end
    end
    for i, e in ipairs(self.entities) do
      if e == npc then table.remove(self.entities, i) break end
    end
    local name = Game.data.items[d.item] and Game.data.items[d.item].name or d.item
    local ddef = Game.data.items[d.item]
    require("src.core.Sound").play(Game.data,
      (ddef and ddef.keyItem) and "Get_Key_Item" or "Get_Item1")
    Game.stack:push(TextBox.new(Game,
      ("%s found\n%s!"):format(Game.save.player.name, name)))
    return
  end

  -- static wild encounters (object_event species+level args: the
  -- legendary birds, Mewtwo, the Vermilion Machop, ...)
  if d.pokemon then
    npc:facePlayer(self.player)
    local text = select(1, Game.data:resolveText(self.map.def.label, d.text))
                 or "Gyaoo!"
    local BattleState = require("src.battle.BattleState")
    Game.stack:push(TextBox.new(Game, text, function()
      local battle = BattleState.newWild(Game, d.pokemon, d.level)
      battle.onFinish = function(result)
        if result ~= "lose" and result ~= "run" then
          Game.save.defeatedTrainers[npc.id] = true
          for i, n in ipairs(self.npcs) do
            if n == npc then table.remove(self.npcs, i) break end
          end
          for i, e in ipairs(self.entities) do
            if e == npc then table.remove(self.entities, i) break end
          end
        end
        self:afterBattle(result, battle)
        unfreeze()
      end
      self:pushBattle(battle)
    end))
    return
  end

  -- generic trainers (object_event trainer args + extracted headers)
  if d.trainerClass and not self:trainerDefeated(npc) then
    npc:facePlayer(self.player)
    self:engageTrainer(npc, unfreeze)
    return
  end
  if d.trainerClass and self:trainerDefeated(npc) then
    local header = Game.data:trainerHeader(self.map.def.label, d.index)
    local after = header and header.after and Game.data.text[header.after]
    if after then
      npc:facePlayer(self.player)
      Game.stack:push(TextBox.new(Game, after, unfreeze))
      return
    end
  end

  -- marts / nurses / PCs via TX_SCRIPT markers
  local entry = Game.data:textEntry(self.map.def.label, d.text)
  if entry then
    if entry.mart then
      npc:facePlayer(self.player)
      Game.stack:push(TextBox.new(Game, "Hi there!\nMay I help you?", function()
        Screens.push(Game, "ShopMenu", entry.mart)
        unfreeze()
      end))
      return
    end
    if entry.nurse then
      npc:facePlayer(self.player)
      self:nurseHeal(unfreeze, npc)
      return
    end
    if entry.pc then
      self:openPC(unfreeze)
      return
    end
    if entry.cableClub then
      npc:facePlayer(self.player)
      self:cableClubReceptionist(unfreeze)
      return
    end
  end

  self:showMapText(d.text, npc, unfreeze)
end

local function sameItems(_, items) return items end

-- The Pokémon Center PC: BILL's PC (boxes), the player's item storage,
-- and PROF.OAK's dex rating (engine/menus/players_pc.asm,
-- engine/events/pokedex_rating.asm).  The assembled entries run through
-- the ui.pc.items hook; LOG OFF is appended after it so a mod cannot
-- orphan the exit.
function OverworldState:openPC(onDone)
  require("src.core.Sound").play(Game.data, "Turn_On_PC")
  local Menu = require("src.ui.Menu")
  local done = onDone or function() end
  local flags = Game.save.flags or {}
  local items = {}

  -- the box PC reads "SOMEONE'S PC" until you meet Bill, then "BILL'S PC"
  -- (engine/menus/pokemon_pc.asm gates on EVENT_MET_BILL; we reach that
  -- when Bill hands over the SS Ticket)
  local metBill = flags.EVENT_MET_BILL or flags.EVENT_GOT_SS_TICKET
  table.insert(items, {
    label = metBill and "BILL'S PC" or "SOMEONE'S PC",
    onSelect = function()
      require("src.core.Sound").play(Game.data, "Enter_PC")
      Screens.push(Game, "BoxMenu")
      done()
    end,
  })

  -- the player's item storage is always available
  table.insert(items, {
    label = (Game.save.player.name or "RED") .. "'s PC",
    onSelect = function()
      Screens.push(Game, "PlayerPC")
      done()
    end,
  })

  -- Prof. Oak's dex rating only appears once you have the Pokédex
  if flags.EVENT_GOT_POKEDEX then
    table.insert(items, {
      label = "PROF.OAK's PC",
      onSelect = function()
        self:dexRating()
        done()
      end,
    })
  end

  local hooked = Runtime.call("ui.pc.items", sameItems, Game, items)
  if type(hooked) == "table" then
    items = hooked
  else
    Logger.error("ui.pc.items returned %s; keeping the vanilla items",
                 type(hooked))
  end

  local logOff = function()
    require("src.core.Sound").play(Game.data, "Turn_Off_PC")
    done()
  end
  table.insert(items, { label = "LOG OFF", onSelect = logOff })
  -- pokered sets BIT_NO_MENU_BUTTON_SOUND for the whole PC session
  -- (engine/overworld/pokecenter_pc.asm / player_pc.asm); DisplayPCMainMenu
  -- calls TextBoxBorder with c=14 (interior width, +2 for the border), so
  -- tw here (total width) is 16
  Game.stack:push(Menu.new(Game, items,
    { tx = 0, ty = 0, tw = 16, th = #items * 2 + 2, onCancel = logOff,
      noSound = true }))
end

-- Prof. Oak's dex rating service (engine/events/pokedex_rating.asm):
-- the completion line with seen AND owned counts, then the per-decade
-- rating text.
function OverworldState:dexRating()
  require("src.core.Sound").play(Game.data, "Pokedex_Rating")
  local seen, owned = 0, 0
  for _ in pairs(Game.save.pokedex.seen or {}) do seen = seen + 1 end
  for _ in pairs(Game.save.pokedex.owned or {}) do owned = owned + 1 end
  local key
  if owned >= 150 then
    key = "_DexRatingText_Own150To151"
  else
    local lo = math.floor(owned / 10) * 10
    key = ("_DexRatingText_Own%dTo%d"):format(lo, lo + 9)
  end
  local rating = Game.data.text[key] or "Keep it up!"
  local completion = Game.data.text._DexCompletionText
    or "POKéDEX comp-\nletion is:\f{NUM:hDexRatingNumMonsSeen} POKéMON seen\n{NUM:hDexRatingNumMonsOwned} POKéMON owned\fPROF.OAK's\nRating:"
  completion = completion
    :gsub("{NUM:hDexRatingNumMonsSeen[^}]*}", tostring(seen))
    :gsub("{NUM:hDexRatingNumMonsOwned[^}]*}", tostring(owned))
  Game.stack:push(TextBox.new(Game, completion .. "\f" .. rating))
end

-- AnimateHealingMachine (engine/overworld/healing_machine.asm): the
-- monitor lights, then one ball per party mon appears every 30 frames
-- (SFX_HEALING_MACHINE each); the healed jingle plays while the machine
-- sprites flash 8 times (an OBP1 xor every 10 frames), then a 32-frame
-- beat once the jingle ends.  Pure per-frame step over the ha table
-- ({ balls, lit, timer, visible, jingleDone }); returns "ball"/"jingle"/
-- "done" when the caller must fire the matching side effect.
function OverworldState.stepHealAnim(ha)
  ha.timer = ha.timer + 1
  ha.phase = ha.phase or "balls"
  if ha.phase == "balls" then
    -- .partyLoop: a ball lights with the machine sfx, then 30 frames
    if ha.lit == 0 or ha.timer >= 30 then
      ha.timer = 0
      if ha.lit < ha.balls then
        ha.lit = ha.lit + 1
        return "ball"
      end
      ha.phase = "flash"
      ha.flashes = 0
      return "jingle"
    end
  elseif ha.phase == "flash" then
    -- FlashSprite8Times: xor the OBJ palette every 10 frames, 8 times
    if ha.timer >= 10 then
      ha.timer = 0
      ha.visible = not ha.visible
      ha.flashes = ha.flashes + 1
      if ha.flashes >= 8 then
        ha.phase = "wait"
        ha.visible = true
      end
    end
  elseif ha.phase == "wait" then
    -- .waitLoop2: hold until the jingle ends, then 32 more frames
    if not ha.jingleDone then
      ha.timer = 0
    elseif ha.timer >= 32 then
      return "done"
    end
  end
end

-- Nurse dialogue uses the real engine strings (data/text/text_4.asm via
-- engine/events/pokecenter.asm): welcome (plus "Shall we heal" the first
-- time), a YES/NO, then the machine animation between "we need your
-- POKéMON" and "fighting fit".
function OverworldState:nurseHeal(onDone, npc)
  local t = Game.data.text
  local bye = t._PokemonCenterFarewellText or "We hope to see\nyou again!"
  local hello = t._PokemonCenterWelcomeText
                or "Welcome to our\nPOKéMON CENTER!"
  if not Game.save.usedPokecenter then
    Game.save.usedPokecenter = true -- BIT_USED_POKECENTER
    hello = hello .. "\f"
            .. (t._ShallWeHealYourPokemonText or "Shall we heal your\nPOKéMON?")
  end
  Game.stack:push(TextBox.new(Game, hello, nil, { choice = function(yes)
    if not yes then
      Game.stack:push(TextBox.new(Game, bye, onDone))
      return
    end
    local need = t._NeedYourPokemonText or "OK. We'll need\nyour POKéMON."
    Game.stack:push(TextBox.new(Game, need, function()
      -- the nurse turns to the machine, the map music stops, and the
      -- party heals before the machine runs (predef HealParty)
      if npc then npc.facing = "left" end
      require("src.core.Music").stop()
      local Pokemon = require("src.pokemon.Pokemon")
      for _, mon in ipairs(Game.save.party) do
        Pokemon.heal(mon)
      end
      Game.save.lastHeal = { -- SetLastBlackoutMap
        map = self.map.id, x = self.player.cellX, y = self.player.cellY,
        -- the town door of this interior, for LAST_MAP exits after a
        -- blackout/ESCAPE ROPE warp here
        outdoor = self.lastOutdoor
          and { id = self.lastOutdoor.id, x = self.lastOutdoor.x, y = self.lastOutdoor.y }
          or nil,
      }
      self.healAnim = { balls = #Game.save.party, lit = 0, timer = 0,
                        visible = true,
                        -- map anchor: the player's cell when healing
                        -- began (the GB's fixed screen coords assume it
                        -- BG-aligned at (64,64))
                        px = self.player.cellX * 16,
                        py = self.player.cellY * 16 }
      self.healAnim.onDone = function()
        if npc then npc:facePlayer(self.player) end
        self:finishNurseHeal(bye, onDone)
      end
    end))
  end }))
end

function OverworldState:finishNurseHeal(bye, onDone)
  local t = Game.data.text
  local fit = t._PokemonFightingFitText or "Your POKéMON are\nfighting fit!"
  Game.stack:push(TextBox.new(Game, fit .. "\f" .. bye, onDone))
end

-- The Cable Club link receptionist (TX_SCRIPT_CABLE_CLUB_RECEPTIONIST ->
-- CableClubNPC, engine/link/cable_club_npc.asm): the welcome line, then
-- without the POKéDEX she's still "making preparations"; with it she asks
-- to apply (YES/NO), saves the game (SaveGameData + SFX_SAVE) and opens
-- the link.  The port's enet link menu (src/link/LinkState.lua) stands in
-- for the original serial handshake; declining prints "Please come again!"
function OverworldState:cableClubReceptionist(onDone)
  local t = Game.data.text
  local welcome = t._CableClubNPCWelcomeText or "Welcome to the\nCable Club!"
  if not Game.save.flags.EVENT_GOT_POKEDEX then
    -- CableClubNPC .didNotConnect path before the pokedex
    Game.stack:push(TextBox.new(Game, welcome .. "\f"
      .. (t._CableClubNPCMakingPreparationsText
          or "We're making\npreparations.\vPlease wait."), onDone))
    return
  end
  local apply = t._CableClubNPCPleaseApplyHereHaveToSaveText
    or "Please apply here.\fBefore opening\nthe link, we have\vto save the game."
  Game.stack:push(TextBox.new(Game, welcome .. "\f" .. apply, nil,
    { choice = function(yes)
      if not yes then
        Game.stack:push(TextBox.new(Game,
          t._CableClubNPCPleaseComeAgainText or "Please come\nagain!", onDone))
        return
      end
      Game:writeSave()
      require("src.core.Sound").play(Game.data, "Save")
      local ok, LinkState = pcall(require, "src.link.LinkState")
      if ok and LinkState then
        Game.stack:push(LinkState.new(Game))
      end
      if onDone then onDone() end
    end }))
end

-- -------------------------------------------------------------------------
-- trainers
-- -------------------------------------------------------------------------

function OverworldState:trainerDefeated(npc)
  if Game.save.defeatedTrainers[npc.id] then return true end
  local header = Game.data:trainerHeader(self.map.def.label, npc.def.index)
  if header and header.event and Game.save.flags[header.event] then
    return true
  end
  return false
end

-- Run the pre-battle text -> battle -> won text -> flags sequence.
function OverworldState:engageTrainer(npc, onDone)
  local d = npc.def
  Runtime.emit("world.trainer_engaged", { npc = npc, trainerClass = d.trainerClass,
                                          partyIndex = d.trainerParty })
  local header = Game.data:trainerHeader(self.map.def.label, d.index)
  local battleText = header and header.battle and Game.data.text[header.battle]
  if not battleText then
    battleText = select(1, Game.data:resolveText(self.map.def.label, d.text))
                 or "I like shorts!\nThey're comfy and\neasy to wear!"
  end
  local wonText = header and header.won and Game.data.text[header.won]

  local BattleState = require("src.battle.BattleState")
  Game.stack:push(TextBox.new(Game, battleText, function()
    local battle = BattleState.newTrainer(Game, d.trainerClass, d.trainerParty)
    battle.onFinish = function(result)
      if result == "win" then
        Game.save.defeatedTrainers[npc.id] = true
        if header and header.event then
          Game.save.flags[header.event] = true
        end
        self:checkVictoryRewards(d.trainerClass, d.trainerParty)
        local after = function()
          self:afterBattle(result, battle)
          if onDone then onDone() end
        end
        if wonText then
          Game.stack:push(TextBox.new(Game, wonText, after))
        else
          after()
        end
      else
        self:afterBattle(result, battle)
        if onDone then onDone() end
      end
    end
    self:pushBattle(battle)
  end))
end

-- Badges/items awarded after specific battles (data/scripts/victories.lua).
-- `deactivate` retires unfought gym/dojo trainers the way the originals'
-- SetEvent / SetEventRange do after the leader victory.
-- `hide` is { { mapId, objName }, ... } — HideObject on those toggles
-- (e.g. Brock victory clears PEWTERCITY_YOUNGSTER / ROUTE22_RIVAL1).
function OverworldState:checkVictoryRewards(trainerClass, partyIndex)
  local victories = require("data.scripts.victories")
  local reward = victories[trainerClass .. "#" .. tostring(partyIndex or 1)]
  if not reward then return self:runVictoryHook() end
  if reward.flag then
    if Game.save.flags[reward.flag] then return self:runVictoryHook() end
    Game.save.flags[reward.flag] = true
  end
  if reward.deactivate then
    for _, flag in ipairs(reward.deactivate) do
      Game.save.flags[flag] = true
    end
  end
  if reward.hide then
    local Commands = require("src.script.Commands")
    local ctx = { game = Game, save = Game.save, overworld = self }
    for _, entry in ipairs(reward.hide) do
      Commands.hide_object(ctx, entry[1], entry[2])
    end
  end
  local lines = {}
  if reward.badge then
    Game.save.inventory[reward.badge] = 1
    local name = Game.data.items[reward.badge] and Game.data.items[reward.badge].name
                 or reward.badge
    table.insert(lines, ("%s received\nthe %s!"):format(Game.save.player.name, name))
  end
  if reward.item then
    local inv = Game.save.inventory
    inv[reward.item] = (inv[reward.item] or 0) + 1
    local name = Game.data.items[reward.item] and Game.data.items[reward.item].name
                 or reward.item
    table.insert(lines, ("%s received\n%s!"):format(Game.save.player.name, name))
  end
  if #lines > 0 then
    Game.stack:push(TextBox.new(Game, table.concat(lines, "\f")))
  end
  self:runVictoryHook()
end

-- pokered reloads the map after every battle, re-running the map
-- script (e.g. LoreleiShowOrHideExitBlock); this hook is the port's
-- equivalent so seals/toggles refresh without leaving the map
function OverworldState:runVictoryHook()
  local hooks = mapScripts.get(self.map.id)
  if hooks and hooks.onVictory then hooks.onVictory(Game, self) end
end

-- STAY trainers with a facing spot the player crossing their line of
-- sight (range from the extracted trainer headers), walk up and battle.
function OverworldState:checkTrainerSight()
  if self.player.moving or self.engaging then return end
  if Game.stack:top() ~= self then return end
  local p = self.player
  for _, npc in ipairs(self.npcs) do
    local d = npc.def
    -- CheckFightingMapTrainers engages ANY aligned trainer sprite,
    -- walkers included (they sight between steps)
    if d.trainerClass and not npc.moving
       and not self:trainerDefeated(npc)
       and not mapScripts.talkScript(self.map.id, d.text) then
      local header = Game.data:trainerHeader(self.map.def.label, d.index)
      local range = header and header.range or 0
      local vec = DIRVEC[npc.facing]
      if range > 0 and vec then
        local dist
        if vec[1] ~= 0 and npc.cellY == p.cellY then
          dist = (p.cellX - npc.cellX) * vec[1]
        elseif vec[2] ~= 0 and npc.cellX == p.cellX then
          dist = (p.cellY - npc.cellY) * vec[2]
        end
        -- pokered's TrainerEngage / CheckSpriteCanSeePlayer compares screen
        -- coordinates only (home/trainers.asm, engine/overworld/
        -- trainer_sight.asm) -- there is no line-of-sight obstruction check.
        -- An aligned trainer within range engages through interposed NPCs and
        -- unwalkable tiles, and the scripted walk-up below (scriptMove) also
        -- ignores collision, so the trainer simply walks/overlaps through
        -- anything on the line -- exactly as OAM sprites overlap on hardware.
        if dist and dist >= 1 and dist <= range then
          self:startTrainerApproach(npc, dist)
          return
        end
      end
    end
  end
end

-- data/trainers/encounter_types.asm
local FEMALE_TRAINERS = {
  OPP_LASS = true, OPP_JR_TRAINER_F = true, OPP_BEAUTY = true,
  OPP_COOLTRAINER_F = true,
}
local EVIL_TRAINERS = {
  OPP_UNUSED_JUGGLER = true, OPP_GAMBLER = true, OPP_ROCKER = true,
  OPP_JUGGLER = true, OPP_CHIEF = true, OPP_SCIENTIST = true,
  OPP_GIOVANNI = true, OPP_ROCKET = true,
}

function OverworldState:startTrainerApproach(npc, dist)
  self.engaging = true
  npc.frozen = true
  -- the encounter sting (PlayTrainerMusic): evil / female / male by
  -- class; rivals and gym leaders keep their own music
  local cls = npc.def.trainerClass
  if cls and not cls:find("RIVAL") then
    local theme = EVIL_TRAINERS[cls] and "Music_MeetEvilTrainer"
                  or FEMALE_TRAINERS[cls] and "Music_MeetFemaleTrainer"
                  or "Music_MeetMaleTrainer"
    require("src.core.Music").play(Game.data, theme)
  end
  local function fight()
    self:engageTrainer(npc, function()
      npc.frozen = false
      self.engaging = false
    end)
  end
  -- the "!" bubble pause before the walk-up (EmotionBubble holds the
  -- world for 60 frames, engine/overworld/emotion_bubbles.asm)
  self.emote = {
    npc = npc, frames = 60,
    onDone = function()
      if dist > 1 then
        self:scriptMove(npc, npc.facing, dist - 1, fight)
      else
        fight()
      end
    end,
  }
end

-- Dispatch a TEXT_* constant: hand-ported script first, then extracted text.
function OverworldState:showMapText(textConst, npc, onDone)
  local mapLabel = self.map.def.label
  local script = mapScripts.talkScript(self.map.id, textConst)
  if script then
    if npc then npc:facePlayer(self.player) end
    if type(script) == "function" then
      -- Lua talk handlers for logic that doesn't fit command rows
      script(Game, self, npc, onDone or function() end)
      return
    end
    -- the winning contribution's rows run as their owner (09 §4.4): mod:
    -- field routing, strict dispatch and error reports all read the source
    self.runner:run(script, { npc = npc, onDone = onDone,
      source = mapScripts.talkSource(self.map.id, textConst) })
    return
  end
  local text, needsAsm = Game.data:resolveText(mapLabel, textConst)
  if text then
    if needsAsm then
      Logger.warn("%s/%s uses text_asm; showing plain text (port a script in data/scripts/)",
                  mapLabel, textConst)
    end
    if npc then npc:facePlayer(self.player) end
    Game.stack:push(TextBox.new(Game, text, onDone))
  else
    Logger.warn("no text for %s/%s", mapLabel, textConst)
    if onDone then onDone() end
  end
end

-- -------------------------------------------------------------------------
-- step events
-- Field poison (engine/events/poison.asm ApplyOutOfBattlePoisonDamage):
-- every 4th step, 1 HP per poisoned mon; the BG flickers dark with
-- SFX_POISONED; fainted mons get their message; a whole-party faint
-- blacks out like a lost battle.  Returns true when the step should
-- stop (a text box is up).
function OverworldState:applyFieldPoison()
  local save = Game.save
  local interval = FieldDefaults.world(Game.data, "poisonStepInterval") or 4
  save.poisonSteps = ((save.poisonSteps or 0) + 1) % interval
  if save.poisonSteps ~= 0 then return false end
  local damage = FieldDefaults.world(Game.data, "poisonDamage") or 1
  local anyPoisoned, fainted = false, {}
  for _, mon in ipairs(save.party) do
    if mon.status == "PSN" and mon.hp > 0 then
      anyPoisoned = true
      mon.hp = mon.hp - damage
      if mon.hp <= 0 then
        mon.hp = 0
        mon.status = nil -- the original clears status on the faint
        table.insert(fainted, mon)
      end
    end
  end
  if not anyPoisoned then return false end
  require("src.core.Sound").play(Game.data, "Poisoned")
  self.poisonFlash = 12
  local queue = {}
  for _, mon in ipairs(fainted) do
    local name = mon.nickname or Game.data.pokemon[mon.species].name
    table.insert(queue, ("%s\nfainted!"):format(name))
  end
  local alive = false
  for _, mon in ipairs(save.party) do
    if mon.hp > 0 then alive = true break end
  end
  local function showNext()
    local msg = table.remove(queue, 1)
    if msg then
      Game.stack:push(TextBox.new(Game, msg, showNext))
      return
    end
    if not alive then
      Game.stack:push(TextBox.new(Game,
        ("%s blacked\nout!"):format(save.player.name), function()
        local Pokemon = require("src.pokemon.Pokemon")
        for _, mon in ipairs(save.party) do Pokemon.heal(mon) end
        save.money = math.floor(save.money
          / (FieldDefaults.world(Game.data, "blackoutMoneyDivisor") or 2))
        Runtime.emit("world.blacked_out",
          { save = save, healTarget = self:healPoint() })
        self:warpToHealPoint()
      end))
    end
  end
  if #queue > 0 or not alive then
    showNext()
    return true
  end
  return false
end

-- -------------------------------------------------------------------------

-- the two vanilla links the encounter chains wrap, hoisted so an empty
-- chain allocates no closure
local function rollVanilla(encDef, ctx) return Encounter.roll(encDef, ctx.rng) end
local function sameEncounter(enc) return enc end

-- The wild pick, wrapped in encounter.roll (returns nil to suppress, a
-- table without calling next to force) and then encounter.species (which
-- transforms a non-nil roll before repel filtering).  With no wrapper on
-- either name this is the bare Encounter.roll, same RNG draws and all.
function OverworldState:rollEncounter(encDef, terrain)
  if not (Runtime.wantsHook("encounter.roll")
          or Runtime.wantsHook("encounter.species")) then
    return Encounter.roll(encDef)
  end
  local ctx = { mapId = self.map.id, terrain = terrain, rng = love.math.random }
  local enc = Runtime.call("encounter.roll", rollVanilla, encDef, ctx)
  if enc then
    enc = Runtime.call("encounter.species", sameEncounter, enc, ctx)
  end
  return enc
end

function OverworldState:onStepComplete()
  local p = self.player

  -- hot path: the payload is only built when something is listening
  if Runtime.wants("world.stepped") then
    Runtime.emit("world.stepped", { mapId = self.map.id, x = p.cellX, y = p.cellY,
                                    tile = self.map:cellTile(p.cellX, p.cellY) })
  end

  -- dismounting a surf: landing on a walkable cell ends it
  if p.surfing and self.map:isWalkableCell(p.cellX, p.cellY) then
    p.surfing = false
    require("src.core.Music").setSurfing(Game.data, false)
  end

  -- Route 22 Gate rewrites LAST_MAP by Y before warps/guards fire
  self:syncLastMapRewrite()

  -- hand-ported step triggers (Pallet intro, Saffron gate guards, ...)
  local hooks = mapScripts.get(self.map.id)
  if hooks and hooks.onStep then
    if hooks.onStep(Game, self, p.cellX, p.cellY) then
      return
    end
  end

  -- spinner arrow tiles (Viridian Gym, Rocket Hideout)
  if self:checkSpinner() then return end

  -- badge-check guards (Route 22 gate / Route 23)
  if self:checkBadgeGate() then return end

  -- forced bike/surf tiles + the Seafoam surf currents
  if self:checkForcedMovement() then return end
  if self:checkSeafoamCurrent() then return end

  -- the Safari game step counter (engine/events/hidden_events/safari_game.asm)
  if self:safariStep() then return end

  -- day-care: the boarded Pokémon gains 1 exp per step (like the original)
  if Game.save.daycare and Game.save.daycare.mon then
    Game.save.daycare.steps = (Game.save.daycare.steps or 0)
      + (FieldDefaults.world(Game.data, "daycareExpPerStep") or 1)
  end

  -- out-of-battle poison (engine/events/poison.asm): every 4th step
  -- each poisoned mon loses 1 HP, with the screen flicker + sound
  if self:applyFieldPoison() then return end

  self.boulderTried = nil -- a completed step ends any armed boulder push

  -- arriving on a door/warp tile warp; a non-door warp square also fires
  -- when the extra check passes and the d-pad is held
  -- (CheckWarpsNoCollision)
  -- The cell we warped in on is inert until we step off it: standing on it,
  -- or being walked back onto it before leaving, does not re-fire (see
  -- warpEntryCell where it is set). Once we are on any other cell it clears
  -- and every warp is live again.
  local entry = self.warpEntryCell
  if entry and (p.cellX ~= entry.x or p.cellY ~= entry.y) then
    self.warpEntryCell = nil
    entry = nil
  end
  if self.justWarped then
    self.justWarped = false
  elseif entry then
    -- still standing on the warp we arrived through; do not re-trigger it
  else
    local w = Warp.onArrive(self.map, p.cellX, p.cellY)
    if not w and self:dirHeld() then
      w = Warp.onCollision(self.map, Game.data.field.warpCarpets,
                           p.cellX, p.cellY, p.facing)
    end
    if w then
      self:takeWarp(w.def)
      return
    end
  end

  if Game.save.repelSteps and Game.save.repelSteps > 0 then
    Game.save.repelSteps = Game.save.repelSteps - 1
    if Game.save.repelSteps == 0 then
      -- no encounter on the exact wear-off step (wild_encounters.asm
      -- .lastRepelStep returns CantEncounter)
      Game.stack:push(TextBox.new(Game, "REPEL's effect\nwore off."))
      return
    end
  end

  -- wild encounters in grass, on water while surfing, or -- on indoor
  -- maps whose tileset is not FOREST -- on EVERY tile
  -- (wild_encounters.asm: caves, towers, the Mansion, Power Plant)
  local encDef = Game.data.encounters[self.map.id]
  local enc
  local indoor = Game.data.field.indoorEncounters
  if p.surfing and encDef and encDef.water and self.map:isWaterCell(p.cellX, p.cellY) then
    enc = self:rollEncounter({ grass = encDef.water }, "water")
  elseif self.map:isGrassCell(p.cellX, p.cellY) then
    enc = self:rollEncounter(encDef, "grass")
  elseif indoor and self.map.def.index >= indoor.firstIndoorMap
         and self.map.def.tileset ~= indoor.excludedTileset then
    enc = self:rollEncounter(encDef, "indoor")
  end
  if enc then
    -- REPEL blocks wild mons weaker than the lead
    local lead = Game.save.party[1]
    if Game.save.repelSteps and Game.save.repelSteps > 0
       and lead and enc.level < lead.level then
      return
    end
    local BattleState = require("src.battle.BattleState")
    local battle = BattleState.newWild(Game, enc.species, enc.level)
    -- map.ghostBattles: unidentifiable without the named item (the
    -- Pokemon Tower's Silph Scope)
    local ghost = Map.ghostBattles(self.map.def)
    if ghost and not (ghost.unlessItem and Game.save.inventory[ghost.unlessItem]) then
      battle:makeGhost()
    end
    -- Safari game encounters use the BALL/BAIT/ROCK/RUN menu
    if Game.save.safari and Map.inRegion(self.map.def, "SAFARI", "SAFARI_ZONE") then
      battle:makeSafari(Game.save.safari)
    end
    battle.onFinish = function(result) self:afterBattle(result, battle) end
    self:pushBattle(battle)
    return
  end
end

-- Spinner arrow tiles (scripts/{ViridianGym,RocketHideoutB2F,B3F}.asm
-- via field.spinners): landing on one plays the arrow SFX and slides the
-- player along the extracted movement list; the landing cell may be
-- another arrow, which chains.
function OverworldState:checkSpinner()
  local list = Game.data.field.spinners and Game.data.field.spinners[self.map.id]
  if not list then return false end
  local p = self.player
  for _, sp in ipairs(list) do
    if sp.x == p.cellX and sp.y == p.cellY then
      require("src.core.Sound").play(Game.data, "Arrow_Tiles")
      self:runSpinnerMoves(sp.moves, 1)
      return true
    end
  end
  return false
end

function OverworldState:runSpinnerMoves(moves, i)
  local mv = moves[i]
  if not mv then
    self.player.spinning = false
    if not self:checkSpinner() and self.player.surfing then
      self:checkSeafoamCurrent()
    end
    return
  end
  self.player.spinning = true -- spin the sprite while sliding
  self:scriptMove(self.player, mv.dir, mv.count, function()
    self:runSpinnerMoves(moves, i + 1)
  end)
end

-- Badge-check guards (scripts/Route22Gate.asm, scripts/Route23.asm via
-- field.badgeGates): stepping on a guard row without the badge turns
-- you back; with it, the guard waves you through once.

-- field.lastMapRewrites: maps that rewrite wLastMap from the player's
-- position every frame.  Rules are ordered, first match wins, the last row
-- is the default -- pokered Route22Gate_Script is Y < 4 -> ROUTE_23, else
-- ROUTE_22, which is what makes the gate's north exit leave onto Route 23.
-- All four of its door warps are LAST_MAP.
function OverworldState.rewrittenLastMap(rewrite, cellX, cellY)
  local value = rewrite.axis == "x" and cellX or cellY
  for _, rule in ipairs(rewrite.rules or {}) do
    if (rule.below == nil or value < rule.below)
       and (rule.atLeast == nil or value >= rule.atLeast) then
      return rule.map
    end
  end
  return nil
end

function OverworldState:syncLastMapRewrite()
  if not self.map then return end
  local rewrites = FieldDefaults.field(Game.data, "lastMapRewrites")
  local rewrite = rewrites and rewrites[self.map.id]
  if not rewrite then return end
  local id = OverworldState.rewrittenLastMap(rewrite, self.player.cellX,
                                             self.player.cellY)
  if not id or (self.lastOutdoor and self.lastOutdoor.id == id) then return end
  local warps = Game.data.maps[id] and Game.data.maps[id].warps
  local w = warps and warps[1]
  self:rememberOutdoor(id, w and w.x or 0, w and w.y or 0)
end

-- field.badgeGates is keyed by map; the record's shape picks the rule.
-- `coords` is the Route 22 gate's single checkpoint (one-shot pass text),
-- `guards` the Route 23 ladder of per-row guards.
function OverworldState:checkBadgeGate()
  local gates = Game.data.field.badgeGates
  local g = gates and gates[self.map.id]
  if not g then return false end
  local p = self.player
  local t = Game.data.text

  if g.coords then
    local passedFlag = FieldDefaults.fieldValue(Game.data, "badgeGates",
                                                self.map.id, "passedFlag")
                       or ("PASSED_" .. self.map.id)
    for _, c in ipairs(g.coords) do
      if p.cellX == c.x and p.cellY == c.y then
        if Game.save.inventory[g.badge] then
          if not Game.save.flags[passedFlag] then
            Game.save.flags[passedFlag] = true
            -- Route22GateGuardGoRightAheadText plays sound_get_item_1
            require("src.core.Sound").play(Game.data, "Get_Item1")
            Game.stack:push(TextBox.new(Game,
              t["_" .. g.passText] or "Go right ahead!"))
          end
          return false
        end
        -- Route22GateGuardNoBoulderbadgeText plays SFX_DENIED
        require("src.core.Sound").play(Game.data, "Denied")
        Game.stack:push(TextBox.new(Game,
          (t["_" .. g.failText] or "You don't have the\nBOULDERBADGE yet!")
          .. (t._Route22GateGuardICantLetYouPassText or ""), function()
            self:scriptMove(p, "down", 1)
          end))
        return true
      end
    end
    return false
  end

  if g.guards then
    for _, guard in ipairs(g.guards) do
      if p.cellY == guard.y and (not guard.maxX or p.cellX <= guard.maxX)
         and not Game.save.flags[guard.event] then
        local badgeName = Game.data.items[guard.badge]
                          and Game.data.items[guard.badge].name or guard.badge
        if Game.save.inventory[guard.badge] then
          Game.save.flags[guard.event] = true
          -- Route23OhThatIsTheBadgeText plays sound_get_item_1
          require("src.core.Sound").play(Game.data, "Get_Item1")
          local text = (t["_" .. g.passText] or
                        "Oh! That is the\n{RAM}!"):gsub("{RAM:wNameBuffer}", badgeName)
          Game.stack:push(TextBox.new(Game, text))
          return false
        end
        -- Route23YouDontHaveTheBadgeYetText plays SFX_DENIED
        require("src.core.Sound").play(Game.data, "Denied")
        local text = (t["_" .. g.failText] or
                      "You don't have the\n{RAM} yet!"):gsub("{RAM:wNameBuffer}", badgeName)
        Game.stack:push(TextBox.new(Game, text, function()
          self:scriptMove(p, "down", 1)
        end))
        return true
      end
    end
  end
  return false
end

-- Forced bike/surf tiles (data/maps/force_bike_surf.asm): the Cycling
-- Road entrances force you onto the BICYCLE (or turn you back without
-- one); the Seafoam current mouths force surfing.
function OverworldState:checkForcedMovement()
  local fm = Game.data.field.forcedMovement
  if not fm then return false end
  local p = self.player
  for _, tile in ipairs(fm.tiles[self.map.id] or {}) do
    if p.cellX == tile.x and p.cellY == tile.y then
      if tile.mode == "bike" then
        -- CheckForceBikeOrSurf (engine/overworld/player_state.asm) also
        -- sets BIT_ALWAYS_ON_BIKE of wStatusFlags6 here -- the flag
        -- IsSurfingAllowed reads to refuse SURF on the Cycling Road.
        -- Cleared by the Route 16/18 gate scripts, fly/dungeon warps and
        -- blackouts (see setMap / flyTo / warpToHealPoint).
        if Game.save.onBike then
          Game.save.forcedBike = true
          return false
        end
        if (Game.save.inventory.BICYCLE or 0) > 0 then
          -- CheckForceBikeOrSurf mounts silently; _CyclingIsFunText only
          -- exists as IsSurfingAllowed's refusal (engine/overworld/
          -- field_move_messages.asm), never as a mount message.
          Game.save.onBike = true
          Game.save.forcedBike = true
          require("src.core.Music").playMap(Game.data, self.map.id, true)
        else
          Game.stack:push(TextBox.new(Game, "You need a\nBICYCLE for the\nCycling Road!",
            function()
              local back = ({ up = "down", down = "up",
                              left = "right", right = "left" })[p.facing]
              self:scriptMove(p, back, 1)
            end))
          return true
        end
      elseif tile.mode == "surf" then
        p.surfing = true
        require("src.core.Music").setSurfing(Game.data, true)
      end
      return false
    end
  end
  return false
end

-- The Seafoam Islands surf currents (scripts/SeafoamIslandsB3F/B4F.asm
-- via field.seafoam): while the plug boulders aren't down, the water
-- drags the player along the extracted movement lists; the B4F pool
-- edge pushes you back up until the B3F boulders fall.
function OverworldState:checkSeafoamCurrent()
  local sf = Game.data.field.seafoam and Game.data.field.seafoam[self.map.id]
  if not sf then return false end
  local p = self.player
  local function allSet(events)
    for _, e in ipairs(events or {}) do
      if not Game.save.flags[e] then return false end
    end
    return true
  end

  if sf.forcedExit and p.surfing and not allSet(sf.forcedExit.activeUntilEvents) then
    for _, c in ipairs(sf.forcedExit.coords) do
      if p.cellX == c.x and p.cellY == c.y then
        require("src.core.Sound").play(Game.data, "Collision")
        self:scriptMove(p, "up", c.y == 17 and 2 or 1)
        return true
      end
    end
  end

  if not p.surfing then return false end
  local active = {}
  if not allSet(sf.currentsDisabledByEvents) then
    for _, c in ipairs(sf.currents or {}) do table.insert(active, c) end
  end
  if sf.entryCurrent then
    local plugged = true
    for _, h in ipairs((sf.pluggedByHolesOn or {}).holes or {}) do
      if not Game.save.flags[h.boulderEvent] then plugged = false end
    end
    if not plugged then table.insert(active, sf.entryCurrent) end
  end
  for _, c in ipairs(active) do
    if p.cellX == c.x and p.cellY == c.y then
      self:runSpinnerMoves(c.moves, 1)
      return true
    end
  end
  return false
end

-- Boulder holes (Seafoam4HolesCoords etc.): a boulder pushed onto a
-- hole falls to the floor below, permanently plugging a current.
function OverworldState:seafoamHolesFor(mapId)
  local out = {}
  for owner, sf in pairs(Game.data.field.seafoam or {}) do
    if owner == mapId then
      for _, h in ipairs(sf.holes or {}) do
        table.insert(out, { hole = h, destMap = sf.holeDestination })
      end
    end
    if sf.pluggedByHolesOn and sf.pluggedByHolesOn.map == mapId then
      for _, h in ipairs(sf.pluggedByHolesOn.holes or {}) do
        table.insert(out, { hole = h, destMap = owner })
      end
    end
  end
  return out
end

-- toggleable_objects.asm names (TOGGLE_SEAFOAM_ISLANDS_B3F_BOULDER_1)
-- vs object_event const names (SEAFOAMISLANDSB3F_BOULDER1)
local function toggleToObjectName(mapId, toggleName)
  local prefix = "TOGGLE_" .. mapId .. "_"
  if toggleName:sub(1, #prefix) ~= prefix then return nil end
  return mapId:gsub("_", "") .. "_" .. toggleName:sub(#prefix + 1):gsub("_", "")
end

function OverworldState:boulderIntoHole(npc)
  for _, entry in ipairs(self:seafoamHolesFor(self.map.id)) do
    local h = entry.hole
    if npc.cellX == h.x and npc.cellY == h.y then
      require("src.core.Sound").play(Game.data, "Faint_Thud")
      Game.save.flags[h.boulderEvent] = true
      local toggles = Game.save.objectToggles or {}
      Game.save.objectToggles = toggles
      if h.hideObject then
        local name = toggleToObjectName(self.map.id, h.hideObject)
        if name then
          toggles[self.map.id] = toggles[self.map.id] or {}
          toggles[self.map.id][name] = false
        end
      end
      if h.showObject and entry.destMap then
        local name = toggleToObjectName(entry.destMap, h.showObject)
        if name then
          toggles[entry.destMap] = toggles[entry.destMap] or {}
          toggles[entry.destMap][name] = true
        end
      end
      for i = #self.npcs, 1, -1 do
        if self.npcs[i] == npc then table.remove(self.npcs, i) end
      end
      for i = #self.entities, 1, -1 do
        if self.entities[i] == npc then table.remove(self.entities, i) end
      end
      Game.stack:push(TextBox.new(Game, "The boulder fell\nthrough the hole!"))
      return true
    end
  end
  return false
end

-- Safari game step/ball bookkeeping.  502 steps per ¥500 game; running
-- out of steps (or balls, checked after battles) ends the game and
-- returns to the gate (engine/events/hidden_events/safari_game.asm).
-- The oracle gates on EVENT_IN_SAFARI_ZONE, not the current map (see
-- home/overworld.asm:307-310); that flag is set right before the
-- entrance auto-walk off SAFARI_ZONE_GATE and cleared only when the
-- player returns to the gate (or uses an Escape Rope), so every
-- interior Safari Zone map -- the 4 zone quadrants plus the 4 rest
-- houses plus the secret house -- counts, and the gate itself never
-- does.
-- field.safari.stepMaps
function OverworldState:inSafariStepZone()
  for _, m in ipairs(FieldDefaults.fieldValue(Game.data, "safari", "stepMaps") or {}) do
    if m == self.map.id then return true end
  end
  return false
end

function OverworldState:safariStep()
  local st = Game.save.safari
  if not st or not self:inSafariStepZone() then return false end
  st.steps = st.steps - 1
  if st.steps > 0 then return false end
  self:safariGameOver("PA: Ding-dong!\nTime's up!")
  return true
end

function OverworldState:safariGameOver(text)
  require("src.core.Sound").play(Game.data, "Safari_Zone_PA")
  Game.save.safari = nil
  local t = Game.data.text
  Game.stack:push(TextBox.new(Game,
    (text or "") .. "\f" .. (t._GameOverText or "PA: Your SAFARI\nGAME is over!"),
    function()
      local exit_ = FieldDefaults.fieldValue(Game.data, "safari", "exitWarp")
      self:startWarpTo(exit_.map, exit_.x, exit_.y, exit_.facing or "down")
    end))
end

-- Blackouts return to the last heal point; evolutions run after battles.
-- battle is optional; when given, Oak's Lab OPP_RIVAL1 losses skip the
-- blackout (pret HandlePlayerBlackOut) so the map script can HealParty.
function OverworldState:afterBattle(result, battle)
  local lead = Game.save.party[1]
  Logger.info("battle over: %s (lead %s %d/%d)", tostring(result),
              lead and lead.species or "-", lead and lead.hp or 0,
              lead and lead.stats.hp or 0)
  local Evolution = require("src.pokemon.Evolution")
  local function evolutions()
    Evolution.checkParty(Game)
  end
  if result == "lose" then
    local oaksLabRival = battle and battle.oppClass == "OPP_RIVAL1"
      and self.map and self.map.id == "OAKS_LAB"
    if oaksLabRival then
      -- stay in the lab; OaksLabRivalEndBattleScript heals and continues
      evolutions()
      return
    end
    -- blackout: revive the party at the last heal point; half the
    -- money is lost (like the original)
    local Pokemon = require("src.pokemon.Pokemon")
    for _, mon in ipairs(Game.save.party) do
      Pokemon.heal(mon)
    end
    Game.save.money = math.floor(Game.save.money
      / (FieldDefaults.world(Game.data, "blackoutMoneyDivisor") or 2))
    Runtime.emit("world.blacked_out",
      { save = Game.save, healTarget = self:healPoint() })
    self:warpToHealPoint(evolutions)
  else
    -- throwing the last SAFARI BALL ends the game
    if Game.save.safari and Game.save.safari.balls <= 0 then
      self:safariGameOver("PA: You're out of\nSAFARI BALLs!")
    end
    evolutions()
  end
end

-- -------------------------------------------------------------------------
-- warps
-- -------------------------------------------------------------------------

-- field.boot: where a save with no heal point of its own returns to.  The
-- lastHeal record wins; otherwise the new game's own spawn cell.
function OverworldState:healPoint()
  local boot = Game.data.field.boot or {}
  return Game.save.lastHeal or boot.lastHeal
    or { map = boot.startMap, x = boot.startX, y = boot.startY }
end

function OverworldState:takeWarp(warpDef)
  local last = self.lastOutdoor
  if warpDef.destMap == "LAST_MAP" and not last then
    -- old saves / unexpected states: never crash on an exit mat, fall
    -- back to the heal point's town door (or the boot spawn)
    Logger.warn("LAST_MAP warp with no remembered outdoor map; using heal point")
    local heal = self:healPoint()
    last = heal.outdoor or { id = heal.map, x = heal.x, y = heal.y }
  end
  local fromMap = self.map.id
  local destMap, x, y = Warp.destination(Game.data, warpDef, last)
  Runtime.emit("player.warped", { fromMap = fromMap, toMap = destMap,
                                  x = x, y = y, warp = warpDef })
  -- facing carries across the warp (leaving a gate sideways keeps you
  -- walking sideways; house exit mats are stepped onto facing down)
  local facing = self.player.facing
  -- warp pads and fall-through holes are not doors (WarpFound2
  -- .indoorMaps: IsPlayerStandingOnWarpPadOrHole routes them through
  -- LeaveMapAnim/EnterMapAnim instead of the door SFX)
  local pad = self.map.warpPadOrHoleAt
              and self.map:warpPadOrHoleAt(self.player.cellX, self.player.cellY)
  if pad == "pad" then
    -- teleporter: spin out with the exit SFX, spin back in on arrival
    -- (player_animations.asm _LeaveMapAnim / EnterMapAnim)
    require("src.core.Sound").play(Game.data, "Teleport_Exit1")
    self.player.spinning = true
    self.player.spinTimer = 0
    self.arriveWarp = "teleport"
    self:startWarpTo(destMap, x, y, facing)
    return
  elseif pad == "hole" then
    -- falling through a hole: no door SFX, no walk-out step
    self:startWarpTo(destMap, x, y, facing)
    return
  end
  self.doorWarp = true -- door SFX + outdoor walk-out step
  self:startWarpTo(destMap, x, y, facing)
end

-- Remember the outdoor side for LAST_MAP exits (pokered's wLastMap).
function OverworldState:rememberOutdoor(id, x, y)
  self.lastOutdoor = { id = id, x = x, y = y }
  Game.save.lastOutdoor = self.lastOutdoor
end

-- Warp to the last heal point (blackout, ESCAPE ROPE, DIG/TELEPORT).
-- The heal point is usually an interior, so LAST_MAP exits are re-pointed
-- at its remembered town door rather than wherever the player left from.
function OverworldState:warpToHealPoint(onDone)
  local heal = self:healPoint()
  self.player.surfing = false
  -- HandleFlyWarpOrDungeonWarp + DisplayPlayerBlackedOutText both clear
  -- BIT_ALWAYS_ON_BIKE (home/overworld.asm / home/text_script.asm)
  Game.save.forcedBike = nil
  -- rematerializing plays the teleport-in poof (EnterMapAnim in
  -- engine/overworld/player_animations.asm: SFX_TELEPORT_ENTER_1, then
  -- ENTER_2 after the spin-down); blackouts take this path too
  self.arriveWarp = "teleport"
  self:startWarpTo(heal.map, heal.x, heal.y, "down", onDone)
  if heal.outdoor then
    self:rememberOutdoor(heal.outdoor.id, heal.outdoor.x, heal.outdoor.y)
  end
end

-- opts.keepMusic: scripted warps mid-cutscene keep the current song
-- playing across the map change, like BIT_NO_MAP_MUSIC (wStatusFlags7)
-- does for the Oak escort (engine/overworld/auto_movement.asm
-- PalletMovementScript_OakMoveLeft sets it; scripts/OaksLab.asm
-- OaksLabFollowedOakScript clears it and calls PlayDefaultMusic).
function OverworldState:startWarpTo(mapId, x, y, facing, onDone, opts)
  -- ANY transition off an outdoor map remembers the outdoor side, so
  -- scripted warps (the Oak walk-in) keep LAST_MAP exits working.
  -- CheckIfInOutsideMap (home/overworld.asm) treats PLATEAU (Route 23 /
  -- Indigo Plateau) as outside too, alongside OVERWORLD -- without it,
  -- LAST_MAP exits taken off Route 23/Indigo Plateau (the Route 22 Gate
  -- back door, the Indigo Plateau lobby doors) resolve against a stale
  -- remembered map instead.
  if Map.isOutside(self.map.def, FieldDefaults.field(Game.data, "outsideTilesets"))
     and mapId ~= self.map.id then
    self:rememberOutdoor(self.map.id, self.player.cellX, self.player.cellY)
  end
  self.transitioning = true
  local doorWarp = self.doorWarp
  self.doorWarp = nil
  local arriveWarp = self.arriveWarp
  self.arriveWarp = nil
  Game.stack:push(Transition.new(Game, function()
    self:setMap(mapId, x, y, facing or "down", opts)
    self.justWarped = true
    -- The warp we land ON stays inert until we physically step off it, so a
    -- warp whose destination cell is itself a warp cannot bounce us straight
    -- back (elevator cars, stacked stair/door mats). This generalizes the
    -- one-step justWarped guard, which only skipped the very next frame's
    -- check and so let a mon walked back onto the pad re-trigger it.
    self.warpEntryCell = { x = x, y = y }
    -- Fly/Teleport/Dig/Escape-Rope/blackout landings poof the player
    -- back in (player_animations.asm EnterMapAnim); ordinary door
    -- warps never take this branch
    if arriveWarp == "fly" then
      require("src.core.Sound").play(Game.data, "Fly")
    elseif arriveWarp == "teleport" then
      require("src.core.Sound").play(Game.data, "Teleport_Enter1")
      -- ENTER_2 caps the spin-down a moment later
      self.delaySfx = { frames = 40, key = "Teleport_Enter2" }
      -- the sprite spins down into place (EnterMapAnim
      -- PlayerSpinWhileMovingDown), not just the SFX
      self.player.spinning = true
      self.player.spinTimer = 0
      self.player.spinFrames = 48
      self.player.spinTotal = 48
      self.player.spinDrop = true
    end
    if doorWarp then
      local outdoor = Map.isOutdoor(self.map.def)
      require("src.core.Sound").play(Game.data,
                                     outdoor and "Go_Outside" or "Go_Inside")
      -- stepping out of an outdoor door/cave entrance (the original's
      -- walk-out). Auto-walk leaves the mat, so the arrival disable
      -- (warpEntryCell / justWarped) is unnecessary -- and would let you
      -- stand on the door without re-entering if you hold back into it.
      if outdoor and self.player.facing == "down"
         and self.map:isWarpTileCell(self.player.cellX, self.player.cellY) then
        self.warpEntryCell = nil
        self.justWarped = false
        self:scriptMove(self.player, "down", 1)
      end
    end
  end, function()
    self.transitioning = false
    if onDone then onDone() end
  end))
end

-- Re-read a map record after its data changed (WorldAPI:invalidateMap,
-- dev-mode hot reload).  The neighbors go too: their strips render the
-- same tileset.  When the active map is the one that changed, the player
-- is clamped back in bounds, the NPC pool is reused so runtime handles
-- survive, and the tile-pair table is re-read.
function OverworldState:reloadMap(mapId, reason)
  MapLoader.invalidate(mapId)
  for _, nb in ipairs(self.neighbors or {}) do MapLoader.invalidate(nb.map.id) end
  if self.map and self.map.id == mapId then
    local p = self.player
    local x, y, facing = p.cellX, p.cellY, p.facing
    Collision.load(Game.data)
    self:setMap(mapId, x, y, facing, { seamless = true, via = "reload" })
    if not self.map:inBounds(x, y) then
      local heal = self:healPoint()
      Logger.warn("map %s reloaded out from under the player; sending to %s",
                  mapId, tostring(heal.map))
      self:setMap(heal.map, heal.x, heal.y, "down", { via = "reload" })
    end
  end
  Runtime.emit("map.reloaded", { mapId = mapId, reason = reason or "invalidate" })
end

-- Append a runtime object to a map record and, when that map is live,
-- instantiate it through the shared pool so it crosses seams like an
-- imported object.  Runtime objects are never serialized into map data.
function OverworldState:addRuntimeObject(mapId, objDef, owner)
  local def = Game.data.maps[mapId]
  if not def then return nil, "unknown map: " .. tostring(mapId) end
  def.objects = def.objects or {}
  local index = 0
  for _, obj in ipairs(def.objects) do
    if (obj.index or 0) > index then index = obj.index end
  end
  objDef.index = index + 1
  objDef.runtime = true
  objDef.owner = owner
  table.insert(def.objects, objDef)
  local npcId = mapId .. "_obj_" .. objDef.index
  if self.map and self.map.id == mapId and self.npcPool then
    local npc = pooledNPC(self.npcPool, Game.data, mapId, objDef)
    npc.frozen = false
    table.insert(self.npcs, npc)
    table.insert(self.entities, npc)
  end
  return npcId
end

-- Drop a runtime object again; imported objects are refused, and so is
-- another mod's.
function OverworldState:removeRuntimeObject(npcId, owner)
  for mapId, def in pairs(Game.data.maps) do
    for i, obj in ipairs(def.objects or {}) do
      if obj.runtime and mapId .. "_obj_" .. obj.index == npcId then
        if owner ~= nil and obj.owner ~= owner then
          return nil, "not owned by " .. tostring(owner)
        end
        table.remove(def.objects, i)
        if self.npcPool then self.npcPool[npcId] = nil end
        for _, list in ipairs({ self.npcs or {}, self.entities or {} }) do
          for j = #list, 1, -1 do
            if list[j].id == npcId then table.remove(list, j) end
          end
        end
        return true
      end
    end
  end
  return nil, "no runtime object " .. tostring(npcId)
end

-- Replace a map block (Victory Road barriers, Cut trees) and redraw.
function OverworldState:replaceBlock(bx, by, block)
  self.map:setBlock(bx, by, block)
  self.map.renderer:rebuild()
  Runtime.emit("world.block_replaced",
    { mapId = self.map.id, bx = bx, by = by, block = block })
end

-- -------------------------------------------------------------------------
-- scripted movement
-- -------------------------------------------------------------------------

function OverworldState:scriptMove(entity, dir, tiles, onDone)
  table.insert(self.scriptMoves, {
    entity = entity, dir = dir, remaining = tiles, onDone = onDone,
  })
end

-- A step-in-place beat: the entity plays one walk-cycle animation (16
-- frames) without translating, keeping its current facing.  Ports the
-- NPC_CHANGE_FACING movement byte (engine/overworld/movement.asm
-- ChangeFacingDirection -> zero-delta TryWalking), used for Oak marching
-- on the lab door mat at the tail of RLEList_ProfOakWalkToLab.
function OverworldState:marchInPlace(entity, onDone)
  table.insert(self.scriptMoves, {
    entity = entity, inPlace = true, remaining = 1, onDone = onDone,
  })
end

-- Advance scripted moves in two phases so a chained step (a new move
-- queued by a completing move's onDone) begins the SAME frame the
-- previous one ends -- back-to-back 16-frame tiles like the GB's
-- simulated-joypad / NPC scripted movement, with no idle frame between
-- tiles.  Phase 1 retires finished moves (which may chain new ones);
-- phase 2 then starts every not-yet-moving move.
function OverworldState:updateScriptMoves()
  local i = 1
  while i <= #self.scriptMoves do
    local mv = self.scriptMoves[i]
    if not mv.entity.moving and mv.remaining <= 0 then
      table.remove(self.scriptMoves, i)
      if mv.onDone then mv.onDone() end
      -- don't advance i: a move chained by onDone may now sit at i
    else
      i = i + 1
    end
  end
  for _, mv in ipairs(self.scriptMoves) do
    local e = mv.entity
    if not e.moving and mv.remaining > 0 then
      if mv.inPlace then
        e.moving = true
        e.marching = true
        e.progress = 0
      else
        e.facing = mv.dir
        local tx, ty = Collision.target(e.cellX, e.cellY, mv.dir)
        e.targetX, e.targetY = tx, ty
        e.moving = true
        e.progress = 0
      end
      mv.remaining = mv.remaining - 1
    end
  end
  -- march_in_place toggles: re-arm the in-place cycle each time it ends.
  -- Not a scriptMove, so an ambient marcher never trips the input lockout.
  for entity in pairs(self.marchers or {}) do
    if not entity.moving then
      entity.moving = true
      entity.marching = true
      entity.progress = 0
    end
  end
end

-- -------------------------------------------------------------------------
-- draw / save
-- -------------------------------------------------------------------------

function OverworldState:draw()
  Game.renderer:beginWorldPass()
  self:drawWorld()
  Game.renderer:endWorldPass()
  self:drawUI()
end

-- The SGB palette a tilt-mode billboard at flat foot (fx, fy) sits under.
-- World zones are rectangles in flat world-canvas space (the current map's
-- base fills the view; neighbour maps stack on top), so the last zone that
-- contains the foot wins -- the same later-zone-on-top priority the flat
-- blit's scissoring gives.  nil when there are no zones (headless / stale
-- palettes), which leaves the billboard uncolorized.
local function zoneColorsAt(zones, fx, fy)
  if not zones then return nil end
  for i = #zones, 1, -1 do
    local z = zones[i]
    if fx >= z.x and fx < z.x + z.w and fy >= z.y and fy < z.y + z.h then
      return z.colors
    end
  end
  return zones[1] and zones[1].colors or nil
end

-- Draw a standing thing as an upright billboard (tilt mode only).  ONLY the
-- ground tilts: a standing thing draws UPRIGHT and UNSCALED -- pixel-identical
-- to flat mode (same crisp nearest-neighbour art, nothing sheared, resized or
-- clipped).  The single thing tilt changes about it is its on-screen anchor:
-- its foot (fx, fy -- the baseline centre of its cell, in world-canvas
-- pixels) moves to where that ground point projects, Tilt.groundPoint(fx,fy).
-- depthScale is deliberately ignored for sizing.  `colors` is the SGB palette
-- of the map the foot stands on: the flat path colorizes the whole world
-- canvas at blit time, but the upright canvas composites with no zone pass,
-- so each billboard carries its own colorization here.  `keyed` selects the
-- color-0-keyed palette variant (tall-grass feet overdraw, which must show the
-- sprite through the tile's white gaps) over the plain one (sprites, FX
-- overlays).  drawFn issues the actual draws in flat world-canvas coordinates;
-- the transform just slides them from the flat foot onto the projected anchor.
function OverworldState:billboard(fx, fy, vw, vh, colors, keyed, drawFn)
  local sx, sy = Tilt.groundPoint(fx, fy, vw, vh)
  local shader = colors and (keyed and PaletteFX.keyedShader()
                             or PaletteFX.shader()) or nil
  if shader then
    PaletteFX.sendColors(shader, colors)
    love.graphics.setShader(shader)
  end
  love.graphics.push()
  love.graphics.translate(sx - fx, sy - fy)
  drawFn()
  love.graphics.pop()
  if shader then love.graphics.setShader() end
end

function OverworldState:drawWorld()
  -- advance the water/flower tile animation (runs under dialogs too)
  require("src.render.TileRenderer").tick()
  -- let the renderer know whether a spinner puzzle is currently sliding
  -- the player, so it can flicker the arrow tiles between the blur and
  -- static graphic (engine/overworld/spinners.asm LoadSpinnerArrowTiles)
  require("src.render.TileRenderer").setSpinning(self.player.spinning)
  local cam = self.camera
  -- ShakeElevator's oscillation (engine/overworld/elevator.asm) writes
  -- hSCY, which scrolls the BG layer only -- tiles bounce while OAM
  -- sprites stay put.  ElevatorShake drives bgShakeY; zero elsewhere.
  local bgY = cam.y + (self.bgShakeY or 0)
  -- border block tiled behind everything the ring doesn't reach
  local vw, vh = Game.renderer:worldViewSize()
  -- Only things that actually stand (player, NPCs, ghosts, items and the FX
  -- attached to them) leave the ground canvas to billboard upright in a
  -- separate pass anchored to the projected ground (:billboard).  Everything
  -- else -- map tiles, which includes buildings/trees/fences/signs, since in
  -- Gen 1 those are background tiles rather than sprites -- draws into the
  -- one ground canvas exactly as in flat mode and tilts with it as a single
  -- rigid plane (Renderer projects that whole canvas through the mesh when
  -- tilt is active).  So the ground draw calls below never change with tilt;
  -- only the sprite/FX draw path below them branches.  The sorts below only
  -- reorder (no draws), so they run once for both paths.
  local tilt = Tilt.active()
  self.map.renderer:drawBorderFill(cam.x, bgY, vw, vh)
  self.map.renderer:draw(cam.x, bgY, vw, vh)
  for _, nb in ipairs(self.neighbors) do
    nb.map.renderer:drawMapOnly(cam.x - nb.ox, bgY - nb.oy, vw, vh)
  end
  -- per-billboard SGB palette source; only needed (and only paid for) when
  -- tilting.  nil headless / on stale palettes -> billboards go uncolorized.
  local zones = tilt and self.sgbWorldZones and self:sgbWorldZones() or nil

  -- ghost NPCs on neighbor maps, y-sorted among themselves
  table.sort(self.ghosts,
             function(a, b) return a.npc.py + a.oy < b.npc.py + b.oy end)
  table.sort(self.entities, function(a, b) return a.py < b.py end)

  -- === shared FX draw bodies ==========================================
  -- Each draws at flat world-canvas offsets; the tilt path wraps the
  -- standing ones in an upright billboard, the flat path calls them inline
  -- in their historical order.  (Bodies are byte-identical to the pre-tilt
  -- inline code, so the flat draw sequence is unchanged.)

  -- the Pokémon Center heal machine (PokeCenterOAMData): the monitor
  -- tile over the machine's screen and one ball per healed mon in two
  -- mirrored columns, all blinking during the jingle flash.  The GB
  -- draws it at fixed screen coords with the player's cell BG-aligned
  -- at (64,64); anchoring those coords to where the player stood keeps
  -- the overlay on the machine at any zoom.
  local function fxHeal()
    if not self.healAnim then return end
    local ha = self.healAnim
    local fxDef = Game.data.field.overworldFx
    if self.healMachineImg == nil and fxDef and fxDef.healMachine then
      local ok, img = pcall(love.graphics.newImage, fxDef.healMachine.path)
      self.healMachineImg = ok and img or false
    end
    local img = self.healMachineImg
    if img then
      if not self.healMachineQuads then
        local w, h = img:getWidth(), img:getHeight()
        self.healMachineQuads = {
          love.graphics.newQuad(0, 0, 8, 8, w, h), -- monitor ($7c)
          love.graphics.newQuad(0, 8, 8, 8, w, h), -- ball ($7d)
        }
      end
      -- the jingle flash recolors the machine sprites in place
      -- (FlashSprite8Times XORs rOBP1; the sprites never disappear):
      -- ha.visible == false is the flashed half of each beat, drawn with
      -- the light/dark shades swapped instead of skipped
      local shader
      if not ha.visible then
        shader = PaletteFX.shader()
        if shader then
          PaletteFX.sendColors(shader,
            PaletteFX.permute(PaletteFX.GRAYS, HEAL_FLASH_MAP))
          love.graphics.setShader(shader)
        end
      end
      -- TileRenderer windows with -floor(cam), so the overlay must use the
      -- same snap or a fractional camera (odd fill/tilt view sizes) parks
      -- the balls a pixel off the machine tiles
      local ox = ha.px - 64 - math.floor(cam.x)
      local oy = ha.py - 64 - math.floor(cam.y)
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.draw(img, self.healMachineQuads[1], ox + 44, oy + 20)
      for i = 1, math.min(ha.lit, #HEAL_BALL_XY) do
        local b = HEAL_BALL_XY[i]
        if b[3] then -- right column: OAM_XFLIP
          love.graphics.draw(img, self.healMachineQuads[2],
                             ox + b[1] + 8, oy + b[2], 0, -1, 1)
        else
          love.graphics.draw(img, self.healMachineQuads[2],
                             ox + b[1], oy + b[2])
        end
      end
      if shader then love.graphics.setShader() end
    end
  end

  -- the Cut/boulder dust puff: the smoke tile drawn 2x2 over the cell,
  -- flickering (AnimateBoulderDust XORs the OBJ palette every step)
  local function fxDust()
    if not self.dustAnim then return end
    local fxDef = Game.data.field.overworldFx
    local smoke = fxDef and fxDef.smoke
    if smoke then
      if self.smokeImg == nil then
        local ok, img = pcall(love.graphics.newImage, smoke.path)
        self.smokeImg = ok and img or false
      end
      if self.smokeImg then
        local da = self.dustAnim
        local dx = da.x * 16 - cam.x
        local dy = da.y * 16 - cam.y
        local flicker = math.floor(da.frames / 4) % 2 == 0
        love.graphics.setColor(1, 1, 1, flicker and 1 or 0.55)
        for i = 0, 1 do
          for j = 0, 1 do
            love.graphics.draw(self.smokeImg, dx + i * 8, dy + j * 8)
          end
        end
        love.graphics.setColor(1, 1, 1, 1)
      end
    end
  end

  -- the cut tree splitting apart (AnimCut): top half slides right,
  -- bottom half slides left, 1px per frame, flickering as they go
  local function fxCutTree()
    if not self.cutAnim then return end
    local fxDef = Game.data.field.overworldFx
    local tree = fxDef and fxDef.cutTree
    if not tree then return end
    if self.cutTreeImg == nil then
      local ok, img = pcall(love.graphics.newImage, tree.path)
      self.cutTreeImg = ok and img or false
    end
    local img = self.cutTreeImg
    if not img then return end
    if not self.cutTreeQuads then
      local w, h = img:getWidth(), img:getHeight()
      self.cutTreeQuads = {
        love.graphics.newQuad(0, 0, 16, 8, w, h), -- top half
        love.graphics.newQuad(0, 8, 16, 8, w, h), -- bottom half
      }
    end
    local ca = self.cutAnim
    local off = (ca.total or 8) - ca.frames
    local dx = ca.x * 16 - cam.x
    local dy = ca.y * 16 - cam.y
    local flicker = ca.frames % 2 == 0
    love.graphics.setColor(1, 1, 1, flicker and 1 or 0.55)
    love.graphics.draw(img, self.cutTreeQuads[1], dx + off, dy)
    love.graphics.draw(img, self.cutTreeQuads[2], dx - off, dy + 8)
    love.graphics.setColor(1, 1, 1, 1)
  end

  -- the "!" bubble above a trainer who spotted the player
  local function fxEmote()
    if not (self.emote and self.emote.npc) then return end
    local npc = self.emote.npc
    local ex = npc.px - cam.x + 4
    local ey = npc.py - cam.y - 14
    local bubble = Game.data.field.emotionBubbles
    local drawn = false
    if bubble and bubble.path then
      local ok, img = pcall(function()
        self.emoteImg = self.emoteImg or love.graphics.newImage(bubble.path)
        return self.emoteImg
      end)
      -- EXCLAMATION_BUBBLE is index 0 -> first crop; the emote command
      -- picks question/happy crops instead
      local bi = self.emote.bubble or 1
      local rect = bubble.bubbles and bubble.bubbles[bi]
      if ok and img and rect then
        love.graphics.setColor(1, 1, 1, 1)
        -- one Quad per bubble crop, cached: this draws every frame the "!"
        -- (or the emote-command crops) is up, so a fresh Quad here churned
        -- the GC.  The bubble set is small and fixed, so the cache is bounded.
        self.emoteQuads = self.emoteQuads or {}
        local q = self.emoteQuads[bi]
        if not q then
          q = love.graphics.newQuad(rect.x, rect.y, rect.w, rect.h,
                                    img:getDimensions())
          self.emoteQuads[bi] = q
        end
        love.graphics.draw(img, q, ex, ey)
        drawn = true
      end
    end
    if not drawn then
      local Font = require("src.render.Font")
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.rectangle("fill", ex, ey, 10, 12)
      love.graphics.setColor(0, 0, 0, 1)
      love.graphics.rectangle("line", ex + 0.5, ey + 0.5, 10, 12)
      Font.draw("!", ex + 1, ey + 2)
      love.graphics.setColor(1, 1, 1, 1)
    end
  end

  -- Rock Tunnel darkness: a small window of light around the player
  -- until FLASH is used (the original darkens the palette instead);
  -- fills the whole world view, so surveying doesn't peek past it
  local function fxDark()
    if not self.dark then return end
    local px = self.player.px - cam.x + 8
    local py = self.player.py - cam.y + 8
    local r = 28
    love.graphics.setColor(0, 0, 0, 1)
    love.graphics.rectangle("fill", 0, 0, vw, math.max(0, py - r))
    love.graphics.rectangle("fill", 0, py + r, vw, vh - (py + r))
    love.graphics.rectangle("fill", 0, py - r, math.max(0, px - r), r * 2)
    love.graphics.rectangle("fill", px + r, py - r, vw - (px + r), r * 2)
    love.graphics.setColor(1, 1, 1, 1)
  end

  -- the FLY bird sweeping off with the player
  local function fxBird()
    if not self.flyAnim then return end
    local birdId = FieldDefaults.fieldValue(Game.data, "playerSprites", "fly")
    if not self.birdSprite and birdId and Game.data.sprites[birdId] then
      local SR = require("src.render.SpriteRenderer")
      self.birdSprite = SR.new(Game.data.sprites[birdId])
    end
    if self.birdSprite then
      local t = 48 - self.flyAnim.frames
      local bx = self.player.px - t * 4
      local by = self.player.py - math.floor(t * 1.5)
      love.graphics.setColor(1, 1, 1, 1)
      self.birdSprite:draw(bx, by, cam.x, cam.y, "left",
                           math.floor(t / 4) % 2, false)
    end
  end

  -- fishing pose: the rod tile over the faced water (gfx/fishing.asm)
  local function fxRod()
    if not self.fishing then return end
    local fx = Game.data.field.overworldFx
    local rod = fx and fx.fishingRod
    if rod then
      if self.rodImg == nil then
        local ok, img = pcall(love.graphics.newImage, rod.path)
        self.rodImg = ok and img or false
      end
      if self.rodImg then
        local p = self.player
        local vec = DIRVEC[self.fishing.facing] or DIRVEC.down
        local rx = p.px - cam.x + 4 + vec[1] * 12
        local ry = p.py - cam.y + 4 + vec[2] * 12
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.draw(self.rodImg, rx, ry)
      end
    end
  end

  if not tilt then
    -- === FLAT PATH: everything into the one world canvas, as before =====
    -- OBP-baked sprites replay after the zone pass in GBC mode, so their
    -- grass feet-overdraw must replay over them too, colorized with the
    -- current map's palette (see PaletteFX.markSpriteRedraw)
    local grassColors = PaletteFX.usesSpriteObp()
      and PaletteFX.pal(Game.data, self:paletteNameFor(self.map)) or nil
    for _, g in ipairs(self.ghosts) do
      g.npc:draw(cam.x - g.ox, cam.y - g.oy)
    end
    for _, e in ipairs(self.entities) do
      if not (self.flyAnim and e == self.player) then
        e:draw(cam.x, cam.y)
        -- tall grass overdraws the sprite's feet (GB sprite priority);
        -- the overdraw is BG tiles, so it rides the shake offset too
        love.graphics.setColor(1, 1, 1, 1)
        if self.map:isGrassCell(e.cellX, e.cellY) then
          self.map.renderer:drawCellBottom(e.cellX, e.cellY, cam.x, bgY)
          if grassColors then
            self.map.renderer:markCellBottomRedraw(e.cellX, e.cellY,
                                                   cam.x, bgY, grassColors)
          end
        end
        if e.targetX and self.map:isGrassCell(e.targetX, e.targetY) then
          self.map.renderer:drawCellBottom(e.targetX, e.targetY, cam.x, bgY)
          if grassColors then
            self.map.renderer:markCellBottomRedraw(e.targetX, e.targetY,
                                                   cam.x, bgY, grassColors)
          end
        end
      end
    end
    fxHeal()
    fxDust()
    fxCutTree()
    fxEmote()
    fxDark()
    fxBird()
    fxRod()
  else
    -- === TILT PATH: ground-hugging FX stay on the projected ground, all
    -- standing things billboard upright over it in a separate pass. ======
    -- Dust / cut / the Poké Center heal overlay hug the BG (the heal
    -- machine is a tileset graphic; its OAM balls must ride that plane or
    -- they float off the machine once the ground foreshortens).  Flat mode
    -- draws them last, over the sprites, in the same canvas; here the two
    -- layers are separate and composited ground-under-upright, so drawing
    -- them now into the still-active ground canvas is order-equivalent.
    fxHeal()
    fxDust()
    fxCutTree()

    Game.renderer:beginUprightPass()

    -- One y-sorted list of ALL upright billboards -- sprites (player, NPCs,
    -- ghosts) -- keyed on baseline world y (the foot / base row).  Farther
    -- rows project higher/smaller, so back-to-front is just ascending
    -- baseline y.
    local items = {}
    for _, g in ipairs(self.ghosts) do
      items[#items + 1] = { y = g.npc.py + g.oy + 16, kind = "ghost", g = g }
    end
    for _, e in ipairs(self.entities) do
      if not (self.flyAnim and e == self.player) then
        items[#items + 1] = { y = e.py + 16, kind = "entity", e = e }
      end
    end
    table.sort(items, function(a, b) return a.y < b.y end)

    for _, it in ipairs(items) do
      if it.kind == "ghost" then
        -- ghosts billboard just like real entities (foot offset folds in the
        -- neighbour map's ox/oy that ghost draws already apply via the camera)
        local g = it.g
        local fx = g.npc.px - cam.x + g.ox + 8
        local fy = g.npc.py - cam.y + g.oy + 16
        self:billboard(fx, fy, vw, vh, zoneColorsAt(zones, fx, fy), false,
                       function() g.npc:draw(cam.x - g.ox, cam.y - g.oy) end)
      else
        local e = it.e
        local fx = e.px - cam.x + 8
        local fy = e.py - cam.y + 16
        local colors = zoneColorsAt(zones, fx, fy)
        self:billboard(fx, fy, vw, vh, colors, false,
                       function() e:draw(cam.x, cam.y) end)
        -- tall-grass feet overdraw glued to the sprite: same anchor + depth
        -- so it keeps hiding the feet, color-0-keyed palette so its white
        -- gaps still show the sprite through (drawCellBottomRaw lets the
        -- billboard own the shader; bgY keeps the elevator-shake offset).
        if self.map:isGrassCell(e.cellX, e.cellY) then
          self:billboard(fx, fy, vw, vh, colors, true, function()
            love.graphics.setColor(1, 1, 1, 1)
            self.map.renderer:drawCellBottomRaw(e.cellX, e.cellY, cam.x, bgY)
          end)
        end
        if e.targetX and self.map:isGrassCell(e.targetX, e.targetY) then
          self:billboard(fx, fy, vw, vh, colors, true, function()
            love.graphics.setColor(1, 1, 1, 1)
            self.map.renderer:drawCellBottomRaw(e.targetX, e.targetY, cam.x, bgY)
          end)
        end
      end
    end

    -- Standing world FX: each billboards at the ground foot of the
    -- character it belongs to, so it stays upright over the tilted ground.
    --   emote bubble  -> the spotting NPC's foot (rides above its head)
    --   fly bird, rod -> the player's foot
    -- (heal machine is ground-hugging -- drawn above with dust/cut)
    if self.emote and self.emote.npc then
      local fx = self.emote.npc.px - cam.x + 8
      local fy = self.emote.npc.py - cam.y + 16
      self:billboard(fx, fy, vw, vh, zoneColorsAt(zones, fx, fy), false, fxEmote)
    end
    if self.flyAnim then
      local fx = self.player.px - cam.x + 8
      local fy = self.player.py - cam.y + 16
      self:billboard(fx, fy, vw, vh, zoneColorsAt(zones, fx, fy), false, fxBird)
    end
    if self.fishing then
      local fx = self.player.px - cam.x + 8
      local fy = self.player.py - cam.y + 16
      self:billboard(fx, fy, vw, vh, zoneColorsAt(zones, fx, fy), false, fxRod)
    end

    -- Rock Tunnel darkness is a screen-space light window, not a ground
    -- object -- draw it flat into the upright canvas so it darkens the
    -- final composited scene uniformly (the subtle tilt keeps the
    -- projected player near the flat light centre).
    fxDark()

    Game.renderer:endUprightPass()
  end

end

-- screen-space overlays: drawn to the UI canvas at normal scale
function OverworldState:drawUI()
  -- poison step flicker (ChangeBGPalColor0_4Frames: dark for two
  -- 4-frame pulses)
  if self.poisonFlash and self.poisonFlash > 0 then
    self.poisonFlash = self.poisonFlash - 1
    local pulse = math.floor(self.poisonFlash / 4) % 2 == 1
    if pulse then
      love.graphics.setColor(0, 0, 0, 0.45)
      love.graphics.rectangle("fill", 0, 0, 160, 144)
      love.graphics.setColor(1, 1, 1, 1)
    end
  end
end

function OverworldState:captureSave(save)
  save.player.map = self.map.id
  save.player.x = self.player.cellX
  save.player.y = self.player.cellY
  save.player.facing = self.player.facing
end

return OverworldState
