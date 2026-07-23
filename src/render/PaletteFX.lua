-- SGB-style colorization post-pass.  The Super Game Boy colored the DMG
-- picture by assigning 4-color palettes to rectangular screen regions
-- (ATTR_BLK packets, data/sgb/sgb_packets.asm).  States expose
-- sgbPalettes() returning a list of zones; the finished 160x144 frame is
-- then drawn once per zone through a shader that remaps the four DMG
-- shades to that zone's palette.
--
-- Port display option: COLORS (GBC / RED++ / OG / OG INV / GBC INV / CLASSIC)
-- transforms every zone's palette at send time via effectiveColors.
-- RED++ swaps the named-palette pack for pokered-gbc SuperPalettes
-- (data/palettes_gbc.lua), including per-species mon colors.

local GameVersion = require("src.core.GameVersion")

local PaletteFX = {}

local shader -- false = unavailable (headless / no shader support)
local gbcPack -- false = missing; nil = not loaded yet

-- Cycle order matches OptionsMenu / hotkey 2.  The three real colorizations
-- come first (OG RED = GBC hardware, SGB = per-map Super Game Boy, RED++ =
-- pokered-gbc per-tile), then the DMG-shade novelty modes.
PaletteFX.MODES = { "ogred", "gbc", "redpp", "og", "og_inv", "gbc_inv", "classic" }
-- `gbc`/`gbc_inv` keep their save-value ids for back-compat; their LABELS are
-- "SGB"/"SGB INV" because that is what the mode actually is (the old "GBC"
-- label was a misnomer -- it never was the real Game Boy Color palette).
PaletteFX.MODE_LABELS = {
  ogred = "OG RED", gbc = "SGB", redpp = "RED++", og = "OG",
  og_inv = "OG INV", gbc_inv = "SGB INV", classic = "CLASSIC",
}
PaletteFX.mode = "gbc"

-- Classic DMG pea-soup greens (#9BBC0F / #8BAC0F / #306230 / #0F380F)
PaletteFX.CLASSIC = {
  { 155, 188, 15 }, { 139, 172, 15 }, { 48, 98, 48 }, { 15, 56, 15 },
}

-- OG RED: the Game Boy Color boot-ROM auto-palette for Pokemon Red.  Pokemon
-- Red ships no CGB code (pokered's wOnCGB is hardwired 0), so on a Game Boy
-- Color the boot ROM colorizes it with ONE global palette pair -- a red
-- background and green objects -- applied to the whole game with no per-map
-- variation (that variety was the Super Game Boy's doing, i.e. SGB mode).
-- Lightest shade first, matching the SGB palette tables.  Values verified
-- against hardware captures of Pallet Town and Oak's Lab.
PaletteFX.GBC_BG = {
  { 255, 255, 255 }, { 255, 132, 132 }, { 148, 58, 58 }, { 0, 0, 0 },
}
PaletteFX.GBC_OBJ = {
  { 255, 255, 255 }, { 123, 255, 49 }, { 0, 132, 0 }, { 0, 0, 0 },
}

-- OG BLUE: Pokemon Blue's Game Boy Color boot-ROM auto-palette.  Same
-- one-global-pair scheme as OG RED (Blue also ships no CGB code), but the
-- boot ROM colorizes the background blue instead of red -- so "OG RED" for a
-- Blue playthrough is white -> light blue -> dark blue -> black, mirroring
-- GBC_BG channel-for-channel so the blue reads at the same brightness.  The
-- OBJ (sprite) palette stays the same green, matching how Red and Blue share
-- the green-character look on a Game Boy Color.
PaletteFX.GBC_BG_BLUE = {
  { 255, 255, 255 }, { 132, 132, 255 }, { 58, 58, 148 }, { 0, 0, 0 },
}

-- The active game's OG boot-ROM background palette: blue for a Blue
-- playthrough, red otherwise.  White (index 1) and black (index 4) are
-- identical across versions, so callers that only touch the endpoints
-- (e.g. BattleState's zone white/black snap) need no version branch.
function PaletteFX.ogBg()
  if GameVersion.isBlue() then return PaletteFX.GBC_BG_BLUE end
  return PaletteFX.GBC_BG
end

local INV_MAP = { [0] = 3, [1] = 2, [2] = 1, [3] = 0 }

function PaletteFX.shader()
  if shader == nil then
    local ok, sh = pcall(love.graphics.newShader, [[
      extern vec3 c0; extern vec3 c1; extern vec3 c2; extern vec3 c3;
      vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
        vec4 p = Texel(tex, tc);
        vec3 mapped = p.r > 0.83 ? c0 : (p.r > 0.5 ? c1 : (p.r > 0.17 ? c2 : c3));
        return vec4(mapped, p.a);
      }
    ]])
    shader = ok and sh or false
  end
  return shader or nil
end

-- Shade-remap variant that also keys shade 0 (DMG white / lightest gray)
-- to transparent -- the GB OBJ-to-BG priority trick.  Tilt mode's upright
-- pass uses it for tall-grass feet overdraw: the patch must be colorized
-- to match the ground grass it hides, yet let the sprite show through the
-- grass tile's white gaps.  The flat path gets this from TileRenderer's
-- color-0 key plus the whole-canvas zone colorization at blit time; the
-- upright canvas is composited with no zone pass, so the two are fused
-- into one shader here.  Same c0..c3 uniforms as shader(), so sendColors
-- feeds it identically.
local keyedShader -- false = unavailable (headless / no shader support)

function PaletteFX.keyedShader()
  if keyedShader == nil then
    local ok, sh = pcall(love.graphics.newShader, [[
      extern vec3 c0; extern vec3 c1; extern vec3 c2; extern vec3 c3;
      vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
        vec4 p = Texel(tex, tc);
        vec3 mapped = p.r > 0.83 ? c0 : (p.r > 0.5 ? c1 : (p.r > 0.17 ? c2 : c3));
        float a = (p.r > 0.83 && p.g > 0.83 && p.b > 0.83) ? 0.0 : p.a;
        return vec4(mapped, a);
      }
    ]])
    keyedShader = ok and sh or false
  end
  return keyedShader or nil
end

-- ATTR_BLK inclusive tile rect -> pixel-space zone.  colors == false is
-- the trueColor opt-out: a real zone whose rect blits with no shader, so
-- full-color art survives the pass.  nil still means "no zone at all".
function PaletteFX.zone(colors, tx1, ty1, tx2, ty2)
  if colors == nil then return nil end
  return { colors = colors, x = tx1 * 8, y = ty1 * 8,
           w = (tx2 - tx1 + 1) * 8, h = (ty2 - ty1 + 1) * 8 }
end

-- the trueColor zone a sprite/tileset record asks for by name
function PaletteFX.trueColorZone(tx1, ty1, tx2, ty2)
  return PaletteFX.zone(false, tx1, ty1, tx2, ty2)
end

-- ------- trueColor zone collection

-- A sprites/tilesets record carrying trueColor = true must not reach the
-- shade-remap shader (14 §trueColor propagation), but the states that
-- build the zone list know nothing about which records the frame drew.
-- So the renderer that draws one reports its covering rect here, in the
-- coordinates of the canvas it is filling, and Renderer:endFrame appends
-- the frame's rects to that pass's zone list as colors == false zones --
-- the region is then re-blit unshaded on top of the colorized pass.
-- No vanilla record sets the flag, so both buckets stay empty every frame
-- and the zone lists are exactly the ones the states returned.
local trueColorRects = { ui = {}, world = {} }
local currentPass = nil

-- which canvas the renderer is filling.  nil for a pass that composites
-- with no zone list of its own (tilt's upright billboards carry their own
-- per-sprite colorization), which drops its rects on the floor.
function PaletteFX.setPass(name)
  currentPass = trueColorRects[name] and name or nil
end

function PaletteFX.clearTrueColor()
  for _, rects in pairs(trueColorRects) do
    for i = #rects, 1, -1 do rects[i] = nil end
  end
end

function PaletteFX.markTrueColor(x, y, w, h)
  local rects = currentPass and trueColorRects[currentPass]
  if not rects or w <= 0 or h <= 0 then return end
  rects[#rects + 1] = { colors = false, x = x, y = y, w = w, h = h }
end

function PaletteFX.trueColorRects(name)
  return trueColorRects[name] or {}
end

function PaletteFX.whole(colors)
  return PaletteFX.zone(colors, 0, 0, 19, 17)
end

-- Red++ / pokered-gbc SuperPalette pack (committed; optional if absent).
function PaletteFX.gbcPack()
  if gbcPack == nil then
    local ok, pack = pcall(require, "data.palettes_gbc")
    gbcPack = ok and pack or false
  end
  return gbcPack or nil
end

function PaletteFX.usesGbcPack(mode)
  mode = mode or PaletteFX.mode
  return mode == "redpp"
end

-- Whether the active mode bakes a per-OBJ palette onto overworld sprites
-- (the OBP bake + post-zone redraw path).  ONLY OG RED does: it wears the
-- GBC boot-ROM green object palette (PaletteFX.GBC_OBJ) so the player and
-- NPCs stay green over the red background, exactly like Pokemon Red on a
-- Game Boy Color.  SGB mode deliberately does NOT: an SGB OBJ carries no
-- palette of its own, so the characters tint with the whole-map region
-- palette along with the terrain (the Super Game Boy never colored Pokemon
-- Red's sprites separately -- baking a per-sprite palette there was the
-- "reds coloring on the player/NPCs" bug).  RED++ colors sprites through
-- the usesGbcPack() path in SpriteRenderer instead.
function PaletteFX.usesSpriteObp(mode)
  return (mode or PaletteFX.mode) == "ogred"
end

-- ------- post-zone sprite redraw (GBC mode)
--
-- In GBC mode the world canvas still runs through the per-map zone
-- shade-remap shader, which would corrupt an OBP-baked sprite's true-color
-- pixels.  So SpriteRenderer draws the baked sprite into the canvas (its
-- pixels come out zone-tinted there) AND records the draw here;
-- Renderer:endFrame replays the list on top of the finished zone pass,
-- scaled into screen space -- the GBC's OBJ-over-BG compositing, one draw
-- late.  Entries carrying `colors` are re-colorized draws (the tall-grass
-- feet overdraw, which must keep hiding sprite feet) issued through the
-- color-0-keyed shade-remap shader.  World pass only; cleared per frame.
local spriteRedraws = {}

function PaletteFX.clearSpriteRedraws()
  for i = #spriteRedraws, 1, -1 do spriteRedraws[i] = nil end
end

function PaletteFX.markSpriteRedraw(image, quad, x, y, sx, colors, keyed)
  if currentPass ~= "world" then return end
  spriteRedraws[#spriteRedraws + 1] =
    { image = image, quad = quad, x = x, y = y, sx = sx or 1,
      colors = colors, keyed = keyed }
end

-- whether a draw issued right now would land in the redraw list -- the
-- OBP bake is only correct when the replay can restore it after the zone
-- pass (tilt's upright pass colorizes per-billboard instead, so sprites
-- there keep the raw sheet)
function PaletteFX.spriteRedrawPassActive()
  return currentPass == "world"
end

function PaletteFX.spriteRedraws()
  return spriteRedraws
end

-- Active named-palette table for COLORS: RED++ uses data/palettes_gbc.lua,
-- everything else uses the ROM-imported data.palettes.
function PaletteFX.pack(data)
  if PaletteFX.usesGbcPack() then
    local g = PaletteFX.gbcPack()
    if g then return g end
  end
  return data and data.palettes or nil
end

-- SuperPalettes that differ between Red and Blue (pokered data/sgb/
-- sgb_palettes.asm IF DEF(_RED)/_BLUE).  data/palettes_gbc.lua is the
-- Red-derived pokered-gbc pack, so under RED++ a Blue playthrough must
-- read these from the ROM-imported table or the title ribbon stays red
-- and the Game Corner reels keep Red's pink (issue #128).
local BLUE_VERSIONED = {
  LOGO1 = true, SLOTS2 = true, SLOTS3 = true, SLOTS4 = true,
}

local function romNamedPal(data, name)
  local p = data and data.palettes
  return p and p.palettes and p.palettes[name]
end

-- named palette from the active pack (nil on stale builds / missing name).
-- RED++ falls back to the ROM pack for names the gbc table omits (rare).
-- OG RED short-circuits EVERY name to the one global GBC boot-ROM BG palette
-- (the hardware had a single BGP for the whole game), so terrain zones,
-- battle HP bars / text, and menu boxes all come out red -- everything a
-- background tile drew.  Objects do not come through here (they bake
-- GBC_OBJ green), so this stays a BG-only hook.
function PaletteFX.pal(data, name)
  if PaletteFX.mode == "ogred" then return PaletteFX.ogBg() end
  if GameVersion.isBlue() and BLUE_VERSIONED[name] then
    local fromRom = romNamedPal(data, name)
    if fromRom then return fromRom end
  end
  local p = PaletteFX.pack(data)
  local c = p and p.palettes[name]
  if c then return c end
  if PaletteFX.usesGbcPack() then
    return romNamedPal(data, name)
  end
  return nil
end

-- the species' palette (data/pokemon/palettes.asm), MEWMON for unknowns.
-- transformed forces PAL_GRAYMON (Ditto's palette) regardless of species
-- (engine/gfx/palettes.asm DeterminePaletteID: bit TRANSFORMED, a; a
-- Transformed mon's pic is tinted gray, not the copied species' own
-- SGB color).  RED++ uses per-species pals from mon_palettes.asm.
function PaletteFX.monPal(data, species, transformed)
  -- OG RED: a battle mon pic is a BG tile on the Game Boy Color (drawn into
  -- the tilemap, colored by BGP), so it wears the global red BG palette, not
  -- a per-species one -- matching the hardware capture where both mons are
  -- red/pink on the white field.
  if PaletteFX.mode == "ogred" then return PaletteFX.ogBg() end
  local p = PaletteFX.pack(data)
  if not p then return nil end
  if transformed then
    return p.palettes.GRAYMON
        or (data and data.palettes and data.palettes.palettes.GRAYMON)
  end
  local name = p.pokemon[species] or "MEWMON"
  local c = p.palettes[name]
  if c then return c end
  if PaletteFX.usesGbcPack() and data and data.palettes then
    name = data.palettes.pokemon[species] or "MEWMON"
    return data.palettes.palettes[name]
  end
  return nil
end

-- palette name a species currently resolves to (for image-cache keys)
function PaletteFX.monPalName(data, species, transformed)
  if transformed then return "GRAYMON" end
  local p = PaletteFX.pack(data)
  if p and p.pokemon[species] then return p.pokemon[species] end
  if data and data.palettes and data.palettes.pokemon[species] then
    return data.palettes.pokemon[species]
  end
  return "MEWMON"
end

-- ------- true GBC overworld coloring (color/loadpalettes.asm,
-- color/data/*, color/sprites.asm ColorOverworldSprite) -------------------
--
-- RED++ pairs its named-palette battle/mon colors above with pokered-gbc's
-- real per-tile system: LoadTilesetPalette assigns one of 8 four-color BG
-- palettes to every tile GRAPHIC in a tileset (by tile id, not by map
-- position), and LoadTownPalette swaps just the ROOF slot (index 6) per
-- town/route. `data/palettes_gbc.lua`'s `world` table holds the extracted
-- data (tools/extract/palettes.py extract_gbc_world); these queries are
-- mode-independent (only check the pack exists) so TileRenderer can
-- precompute geometry once regardless of the active COLORS mode -- callers
-- that resolve to actual on-screen COLOR should gate on usesGbcPack()
-- themselves, the same way they already gate other RED++-only behavior.
--
-- LoadTilesetPalette's 3 hardcoded single-tile fixes (Celadon Mart) and
-- LoadTownPalette's Route 6/Saffron y<2 roof split are control flow, not
-- data, so they are not in the extracted pack -- they live here instead.
local TILE_GROUP_EXCEPTIONS = {
  -- tile ids $4b-$4f -> BLUE (outside sky, seen through the mart's roof)
  CELADON_MART_ROOF = { tiles = { [0x4b] = true, [0x4c] = true, [0x4d] = true,
                                  [0x4e] = true, [0x4f] = true }, group = 3 },
  -- tile $37 -> BROWN (counter miscoloration fix)
  CELADON_MART_3F   = { tiles = { [0x37] = true }, group = 5 },
  -- tiles $07/$08/$17/$18 -> YELLOW (bench, blue by default)
  CELADON_MART_1F   = { tiles = { [0x07] = true, [0x08] = true,
                                  [0x17] = true, [0x18] = true }, group = 4 },
}

-- keyed by tileset id (applies on every map that uses it), consulted after
-- the per-map table above
local TILESET_GROUP_EXCEPTIONS = {
  -- tile $22 (the hollow-square grave marker) -> GRAY: the extracted pack
  -- files it under the bright blue family, which makes a purely
  -- decorative floor marker read as an interactive pad
  CEMETERY = { tiles = { [0x22] = true }, group = 0 },
}

-- pokered-gbc's lobby.bst repoints the Celadon roof table's flat top
-- (block 29, cells 5/6/9/10) at a duplicate tile ($5a, BROWN) so the
-- tabletop and the checkerboard floor -- both raw tile $37 -- can take
-- different palettes; the vanilla-derived blockset shares the one tile
-- id, so the RED++ atlas path re-creates the duplicate: the alias slot
-- is baked as a copy of `tile` in `group`'s colors, and the listed
-- 0-based block cells draw the alias instead of the shared tile.
PaletteFX.TILE_ALIASES = {
  CELADON_MART_ROOF = {
    { block = 29, cells = { [5] = true, [6] = true, [9] = true, [10] = true },
      tile = 0x37, alias = 0x5a, group = 5 },
  },
}
local ROOF_GROUP = 6
local ROUTE_6_SAFFRON = { mapId = "ROUTE_6", useMapId = "SAFFRON_CITY", cellYBelow = 2 }

-- whether the extracted pack has real per-tile GBC data for this tileset
-- (false for a mod tileset with no pokered-gbc counterpart, or when the
-- pack failed to load at all)
function PaletteFX.hasWorldTileset(tileset)
  local pack = PaletteFX.gbcPack()
  local w = pack and pack.world
  return (w and w.tileGroups[tileset]) ~= nil
end

-- the palette-group (0-7) a tile GRAPHIC id resolves to in this tileset,
-- with the current map's tile-id exceptions (if any) applied first
function PaletteFX.worldGroupAt(tileset, mapId, tileId)
  local pack = PaletteFX.gbcPack()
  local w = pack and pack.world
  local groups = w and w.tileGroups[tileset]
  if not groups then return nil end
  local exc = TILE_GROUP_EXCEPTIONS[mapId]
  if exc and exc.tiles[tileId] then return exc.group end
  exc = TILESET_GROUP_EXCEPTIONS[tileset]
  if exc and exc.tiles[tileId] then return exc.group end
  return groups[tileId] or 7 -- TEXT: tile ids past the tileset's 96 (menus)
end

-- this tileset's resolved 8-entry {r,g,b}x4 palette array, with the ROOF
-- slot swapped to the current town/route (Route 6's north end uses
-- Saffron's roof colors while the player stands in its top 2 cell rows,
-- like pokered's wYCoord check -- data is Game.data, for the map lookup)
function PaletteFX.worldGroupColors(data, tileset, mapId, playerCellY)
  local pack = PaletteFX.gbcPack()
  local w = pack and pack.world
  local base = w and w.groupColors[tileset]
  if not base then return nil end
  if not w.roofGroup[tileset] then return base end
  local roofMapId = mapId
  if mapId == ROUTE_6_SAFFRON.mapId and playerCellY
     and playerCellY < ROUTE_6_SAFFRON.cellYBelow then
    roofMapId = ROUTE_6_SAFFRON.useMapId
  end
  local roofMap = data and data.maps and data.maps[roofMapId]
  local roof = roofMap and w.roofByMapIndex[roofMap.index]
  if not roof then return base end
  local out = {}
  for i = 1, 8 do out[i] = base[i] end
  -- LoadTownPalette only overwrites W2_BgPaletteData + $32, i.e. colors 1
  -- and 2 (0-indexed) of the 4-color ROOF slot -- color 0 (background,
  -- typically the sky-through-gaps white) and color 3 (outline black) keep
  -- the tileset's own OUTDOOR_ROOF/INDOOR_ROOF base, only the roof
  -- material's 2 middle shades are town-specific
  local base4 = base[ROOF_GROUP + 1]
  out[ROOF_GROUP + 1] = { base4[1], roof[1], roof[2], base4[4] }
  return out
end

-- an overworld sprite's resolved 4-color OBJ palette (ColorOverworldSprite),
-- or nil when unassigned/unavailable, plus the resolved group index (for
-- callers that want a stable cache key without hashing the colors table).
-- spriteDef carries the ROM picture-id crosswalk in its `source` field
-- ("ROM:SpriteSheetPointerTable[N]"); seed (any stable per-instance value,
-- e.g. an NPC's `id`) resolves the "random" sentinel -- a deliberate
-- approximation of ColorOverworldSprite's per-OAM-slot pseudo-random pick
-- (`swap a; and 3` on the sprite's OAM offset, which has no equivalent
-- here): a stable hash instead, so the same NPC instance always shows the
-- same one of the 4 SPR_PAL_* colors.
function PaletteFX.spriteObp(spriteDef, seed)
  local pack = PaletteFX.gbcPack()
  local w = pack and pack.world
  local src = spriteDef and spriteDef.source
  if not (w and src) then return nil end
  local idx = tonumber(src:match("%[(%d+)%]"))
  -- RedBikeSprite loads outside SpriteSheetPointerTable
  -- (LoadBikePlayerSpriteGraphics), so its source carries no bracketed
  -- index; it wears the player's own palette, same as SPRITE_RED
  if not idx and src:find("RedBikeSprite", 1, true) then idx = 0 end
  local group = idx and w.spriteAssignment[idx]
  if group == nil then return nil end
  if group == "random" then
    local h = 0
    seed = tostring(seed or "")
    for i = 1, #seed do h = (h * 31 + seed:byte(i)) % 4294967296 end
    group = h % 4
  end
  return w.spritePalettes[group], group
end

-- GetHealthBarColor (home/palettes.asm) on the standard 48px bar
function PaletteFX.barPalName(hp, maxHp)
  local px = maxHp > 0 and math.floor(hp * 48 / maxHp) or 0
  if hp > 0 and px < 1 then px = 1 end
  return px >= 27 and "GREENBAR" or px >= 10 and "YELLOWBAR" or "REDBAR"
end

-- convenience: a single whole-screen zone for a named palette
function PaletteFX.wholeNamed(data, name)
  local c = PaletteFX.pal(data, name)
  return c and { PaletteFX.whole(c) } or nil
end

-- The four DMG grays the extracted art uses (255/170/85/0), as a
-- palette-shaped table -- shade index 0 (lightest) first, like the SGB
-- palettes in data/generated/palettes.lua.
PaletteFX.GRAYS = { { 255, 255, 255 }, { 170, 170, 170 },
                    { 85, 85, 85 }, { 0, 0, 0 } }

-- Permute a 4-color palette through a BGP-style shade map
-- (map[i] = the shade color index i displays as, i = 0..3).  Emulates
-- pokered's SetAnimationBGPalette / AnimationFlashScreen* writes to
-- rBGP composed with the SGB colorization: the SGB colors the remapped
-- DMG shade, so a screen region shows palette[map[shade]].
function PaletteFX.permute(colors, map)
  if not map then return colors end
  return { colors[map[0] + 1], colors[map[1] + 1],
           colors[map[2] + 1], colors[map[3] + 1] }
end

function PaletteFX.setMode(mode)
  local prev = PaletteFX.mode
  local ok = false
  for _, m in ipairs(PaletteFX.MODES) do
    if m == mode then
      PaletteFX.mode = mode
      ok = true
      break
    end
  end
  if not ok then PaletteFX.mode = "gbc" end
  -- battle pics and overworld sprites bake the active pack into ImageData;
  -- drop those caches when the pack (or any COLORS mode) changes so the
  -- next draw re-tints
  if prev ~= PaletteFX.mode then
    pcall(function() require("src.battle.BattleState").invalidate() end)
    pcall(function() require("src.render.SpriteRenderer").invalidate() end)
    -- RED++'s baked tileset atlas (TileRenderer.getGbcAtlas) is built once
    -- per loaded map, so a mode toggle needs every cached Map/TileRenderer
    -- dropped and the currently-visible one rebuilt in place -- otherwise
    -- the on-screen map keeps its stale (wrong-mode) atlas until the next
    -- map transition happens to reload it.
    pcall(function()
      require("src.world.MapLoader").invalidateAll()
      local Game = require("src.core.Game")
      if Game.overworld and Game.overworld.map and Game.overworld.reloadMap then
        Game.overworld:reloadMap(Game.overworld.map.id, "colors")
      end
    end)
  end
end

function PaletteFX.cycleMode()
  local cur = PaletteFX.mode or "gbc"
  local idx = 1
  for i, m in ipairs(PaletteFX.MODES) do
    if m == cur then idx = i; break end
  end
  PaletteFX.setMode(PaletteFX.MODES[idx % #PaletteFX.MODES + 1])
  return PaletteFX.mode
end

function PaletteFX.applyOptions(opts)
  PaletteFX.setMode(opts and opts.colors or "gbc")
end

function PaletteFX.modeLabel(mode)
  mode = mode or PaletteFX.mode
  -- The GBC boot-ROM mode wears the running game's name: it is red for Red and
  -- blue for Blue (see ogBg), so a Blue playthrough shows "OG BLUE".
  if mode == "ogred" and GameVersion.isBlue() then return "OG BLUE" end
  return PaletteFX.MODE_LABELS[mode] or "GBC"
end

-- When a state exposes no SGB zones but COLORS needs a forced palette
-- (OG / OG INV / CLASSIC), invent a whole-screen zone so the shade-remap
-- shader still runs.  GBC / RED++ / GBC INV leave nil alone (raw DMG canvas).
function PaletteFX.ensureZones(zones)
  if zones and zones[1] then return zones end
  local mode = PaletteFX.mode or "gbc"
  if mode == "og" or mode == "og_inv" or mode == "classic" then
    return { PaletteFX.whole(PaletteFX.GRAYS) }
  end
  return zones
end

-- Transform a 4-color palette for the active COLORS display mode.
-- GBC and RED++ pass the zone colors through (RED++ already swapped the
-- pack in pal/monPal); OG* / CLASSIC replace; GBC INV permutes shades.
function PaletteFX.effectiveColors(c)
  if not c then return nil end
  local mode = PaletteFX.mode or "gbc"
  if mode == "og" then
    return PaletteFX.GRAYS
  elseif mode == "og_inv" then
    return PaletteFX.permute(PaletteFX.GRAYS, INV_MAP)
  elseif mode == "classic" then
    return PaletteFX.CLASSIC
  elseif mode == "gbc_inv" then
    return PaletteFX.permute(c, INV_MAP)
  end
  return c
end

-- send a 4-color (0-255 RGB) palette to the shade-remap shader, after
-- applying the active COLORS display mode
function PaletteFX.sendColors(shader, c)
  c = PaletteFX.effectiveColors(c)
  if not c then return end
  shader:send("c0", { c[1][1] / 255, c[1][2] / 255, c[1][3] / 255 })
  shader:send("c1", { c[2][1] / 255, c[2][2] / 255, c[2][3] / 255 })
  shader:send("c2", { c[3][1] / 255, c[3][2] / 255, c[3][3] / 255 })
  shader:send("c3", { c[4][1] / 255, c[4][2] / 255, c[4][3] / 255 })
end

return PaletteFX
