-- SGB-style colorization post-pass.  The Super Game Boy colored the DMG
-- picture by assigning 4-color palettes to rectangular screen regions
-- (ATTR_BLK packets, data/sgb/sgb_packets.asm).  States expose
-- sgbPalettes() returning a list of zones; the finished 160x144 frame is
-- then drawn once per zone through a shader that remaps the four DMG
-- shades to that zone's palette.
--
-- Port display option: COLORS (GBC / OG / OG INV / GBC INV / CLASSIC)
-- transforms every zone's palette at send time via effectiveColors.

local PaletteFX = {}

local shader -- false = unavailable (headless / no shader support)

-- Cycle order matches OptionsMenu / hotkey 2
PaletteFX.MODES = { "gbc", "og", "og_inv", "gbc_inv", "classic" }
PaletteFX.MODE_LABELS = {
  gbc = "GBC", og = "OG", og_inv = "OG INV",
  gbc_inv = "GBC INV", classic = "CLASSIC",
}
PaletteFX.mode = "gbc"

-- Classic DMG pea-soup greens (#9BBC0F / #8BAC0F / #306230 / #0F380F)
PaletteFX.CLASSIC = {
  { 155, 188, 15 }, { 139, 172, 15 }, { 48, 98, 48 }, { 15, 56, 15 },
}

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

-- named palette from data/generated/palettes.lua (nil on stale builds)
function PaletteFX.pal(data, name)
  local p = data.palettes
  return p and p.palettes[name] or nil
end

-- the species' palette (data/pokemon/palettes.asm), MEWMON for unknowns.
-- transformed forces PAL_GRAYMON (Ditto's palette) regardless of species
-- (engine/gfx/palettes.asm DeterminePaletteID: bit TRANSFORMED, a; a
-- Transformed mon's pic is tinted gray, not the copied species' own
-- SGB color).
function PaletteFX.monPal(data, species, transformed)
  local p = data.palettes
  if not p then return nil end
  if transformed then return p.palettes.GRAYMON end
  return p.palettes[p.pokemon[species] or "MEWMON"]
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
  for _, m in ipairs(PaletteFX.MODES) do
    if m == mode then
      PaletteFX.mode = mode
      return
    end
  end
  PaletteFX.mode = "gbc"
end

function PaletteFX.cycleMode()
  local cur = PaletteFX.mode or "gbc"
  local idx = 1
  for i, m in ipairs(PaletteFX.MODES) do
    if m == cur then idx = i; break end
  end
  PaletteFX.mode = PaletteFX.MODES[idx % #PaletteFX.MODES + 1]
  return PaletteFX.mode
end

function PaletteFX.applyOptions(opts)
  PaletteFX.setMode(opts and opts.colors or "gbc")
end

function PaletteFX.modeLabel(mode)
  return PaletteFX.MODE_LABELS[mode or PaletteFX.mode] or "GBC"
end

-- When a state exposes no SGB zones but COLORS needs a forced palette
-- (OG / OG INV / CLASSIC), invent a whole-screen zone so the shade-remap
-- shader still runs.  GBC / GBC INV leave nil alone (raw DMG canvas).
function PaletteFX.ensureZones(zones)
  if zones and zones[1] then return zones end
  local mode = PaletteFX.mode or "gbc"
  if mode == "og" or mode == "og_inv" or mode == "classic" then
    return { PaletteFX.whole(PaletteFX.GRAYS) }
  end
  return zones
end

-- Transform a 4-color palette for the active COLORS display mode.
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
