-- Two-pass renderer.  The UI pass is the classic 160x144 Game Boy canvas
-- drawn at the integer window fit scale S, letterboxed in the window.
-- The world pass (overworld survey zoom) is a variable-size canvas that
-- fills the *entire* window at the effective integer scale s',  so black
-- letterbox voids become more map, not empty bars.  Both use nearest-
-- neighbor filtering.
-- Spec: docs/new-features.md (survey zoom)

local Zoom = require("src.render.Zoom")
local Tilt = require("src.render.Tilt")
local PaletteFX = require("src.render.PaletteFX")

local Renderer = {}

Renderer.WIDTH = 160
Renderer.HEIGHT = 144

-- Tilt mode: the upright billboard canvas is grown by this many world
-- pixels on every side beyond the ground world view, so a structure or
-- sprite standing near a view edge still draws in full instead of being
-- clipped where the ground canvas ends (a receding tree wall at the top of
-- the view rises above row 0; a fence at the bottom-left drops below/left).
-- endFrame composites the padded canvas back with a matching offset.
Renderer.UPRIGHT_MARGIN = 160

function Renderer:init()
  self.canvas = love.graphics.newCanvas(self.WIDTH, self.HEIGHT)
  self.canvas:setFilter("nearest", "nearest")
  self.worldCanvas = nil
  self.worldActive = false
  -- tilt mode only: a transparent overlay canvas the size of the world
  -- canvas that receives the upright billboard pass (sprites + standing
  -- FX, drawn at their projected ground anchors).  It composites flat over
  -- the projected ground in endFrame; never touched while tilt is off.
  self.uprightCanvas = nil
  self.uprightActive = false
end

-- integer scale that fits the GB UI viewport in the window
function Renderer:fitScale()
  local ww, wh = love.graphics.getDimensions()
  return math.max(1, math.floor(math.min(ww / self.WIDTH, wh / self.HEIGHT)))
end

-- world-pass canvas size in world pixels: enough to fill the window at s'.
-- In tilt mode the canvas grows (both dimensions, by Tilt.viewGrowth) so
-- the projected ground plane still covers the whole window with no
-- background peeking at the receded top/bottom corners; flat mode returns
-- exactly today's size (growth factor is 1 when tilt is inactive).
function Renderer:worldViewSize()
  local ww, wh = love.graphics.getDimensions()
  local s = Zoom.scale(self:fitScale())
  local vw, vh = Zoom.fillViewSize(s, ww, wh)
  if Tilt.active() then
    local g = Tilt.viewGrowth()
    vw, vh = math.ceil(vw * g), math.ceil(vh * g)
  end
  return vw, vh
end

-- transparent: the world pass shows through (UI pass draws overlays only)
function Renderer:beginFrame(transparent)
  self.worldActive = false
  self.uprightActive = false
  -- warp-fade overlay from Transition (issue #121); cleared each frame so
  -- a popped transition cannot leave a sticky black veil
  self.worldFadeAlpha = nil
  -- last frame's trueColor rects and sprite redraws go before anything
  -- draws this one
  PaletteFX.clearTrueColor()
  PaletteFX.clearSpriteRedraws()
  PaletteFX.setPass("ui")
  love.graphics.setCanvas(self.canvas)
  if transparent then
    love.graphics.clear(0, 0, 0, 0)
  else
    love.graphics.clear(1, 1, 1, 1)
  end
end

function Renderer:beginWorldPass()
  local vw, vh = self:worldViewSize()
  if not self.worldCanvas or self.worldCanvas:getWidth() ~= vw
     or self.worldCanvas:getHeight() ~= vh then
    -- free the old canvas before replacing it: a zoom/tilt tween changes
    -- the view size every frame, so without this the superseded canvases
    -- pile up in VRAM until a GC finalizer happens to run
    if self.worldCanvas and self.worldCanvas.release then self.worldCanvas:release() end
    self.worldCanvas = love.graphics.newCanvas(vw, vh)
    self.worldCanvas:setFilter("nearest", "nearest")
  end
  self.worldActive = true
  PaletteFX.setPass("world")
  love.graphics.setCanvas(self.worldCanvas)
  love.graphics.clear(1, 1, 1, 1)
end

function Renderer:endWorldPass()
  PaletteFX.setPass("ui")
  love.graphics.setCanvas(self.canvas)
end

-- Tilt mode's upright pass: standing things (sprites, tall-grass feet
-- overdraw, screen-anchored FX) draw here instead of into the ground
-- world canvas, each already projected to its ground anchor and colorized
-- with its map's SGB palette (see OverworldController:billboard).  The
-- canvas is transparent so the projected ground shows through the gaps;
-- endFrame blits it flat over the projected ground.  Sized/filtered like
-- the world canvas but kept separate so the ground can be projected as a
-- plane while these stay upright.  Only entered while Tilt.active().
function Renderer:beginUprightPass()
  local vw, vh = self:worldViewSize()
  local M = self.UPRIGHT_MARGIN
  local cw, ch = vw + 2 * M, vh + 2 * M
  if not self.uprightCanvas or self.uprightCanvas:getWidth() ~= cw
     or self.uprightCanvas:getHeight() ~= ch then
    if self.uprightCanvas and self.uprightCanvas.release then self.uprightCanvas:release() end
    self.uprightCanvas = love.graphics.newCanvas(cw, ch)
    self.uprightCanvas:setFilter("nearest", "nearest")
  end
  self.uprightActive = true
  PaletteFX.setPass(nil)
  love.graphics.setCanvas(self.uprightCanvas)
  love.graphics.clear(0, 0, 0, 0)
  -- shift the whole pass into the padded canvas so billboards keep drawing
  -- in flat world-canvas coordinates (0..vw, 0..vh) while the margin catches
  -- anything that overhangs an edge; endFrame undoes it with the same offset
  love.graphics.push()
  love.graphics.translate(M, M)
end

-- return to the ground world canvas (the world pass owns it until draw()
-- calls endWorldPass)
function Renderer:endUprightPass()
  PaletteFX.setPass("world")
  love.graphics.pop()
  love.graphics.setCanvas(self.worldCanvas)
end

-- Perspective mesh shader for tilt mode.  The mesh already carries CPU-
-- projected 2D corner positions (from Tilt.groundPoint), so the vertex
-- stage does no projection; instead it passes each corner's depthScale as
-- the per-vertex "q" and pre-multiplies the texture coords by it.  The
-- fragment divides back, which reconstructs perspective-correct texture
-- interpolation across the whole quad (no affine-warp seams) using the
-- exact same projection the billboards will anchor to.  false = headless /
-- no shader support, in which case the renderer stays on the flat blit.
local TILT_SHADER = [[
  varying float vScale;
#ifdef VERTEX
  attribute float VertexScale;
  vec4 position(mat4 transform_projection, vec4 vertex_position) {
    vScale = VertexScale;
    VaryingTexCoord = vec4(VertexTexCoord.xy * VertexScale, 0.0, 1.0);
    return transform_projection * vertex_position;
  }
#endif
#ifdef PIXEL
  vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    return Texel(tex, tc / vScale) * color;
  }
#endif
]]

function Renderer:tiltShader()
  if self._tiltShader == nil then
    local ok, sh = pcall(love.graphics.newShader, TILT_SHADER)
    self._tiltShader = ok and sh or false
  end
  return self._tiltShader or nil
end

-- Dynamic 4-vertex ground quad; positions/depthScale are refreshed each
-- frame from Tilt.meshCorners.  The custom VertexScale attribute rides the
-- perspective "q" through to the shader above.
function Renderer:tiltMesh()
  if self._tiltMesh == nil then
    local format = {
      { "VertexPosition", "float", 2 },
      { "VertexTexCoord", "float", 2 },
      { "VertexScale", "float", 1 },
    }
    local ok, mesh = pcall(love.graphics.newMesh, format, 4, "fan", "dynamic")
    self._tiltMesh = ok and mesh or false
  end
  return self._tiltMesh or nil
end

-- Draw the world pass through the tilt projection.  Two steps: (1) a
-- canvas-to-canvas palette pre-pass that bakes the SGB world zones into a
-- colorized ground canvas in flat space (a perspective transform breaks
-- the rectangular scissors endFrame normally uses), then (2) project that
-- canvas onto the tilted plane via the perspective mesh, scaled/centred
-- exactly like the flat world blit.  `target` is the canvas to project
-- into (nil = default framebuffer; presentCanvas when CRT is on).
-- Returns true on success; false (no shader/mesh) tells endFrame to fall
-- back to the flat blit unchanged.
function Renderer:drawTiltedWorld(zoneList, s, wox, woy, target)
  local shader = self:tiltShader()
  local mesh = self:tiltMesh()
  if not (shader and mesh) then return false end
  local wvw = self.worldCanvas:getWidth()
  local wvh = self.worldCanvas:getHeight()

  -- colorized ground canvas, resized to match the world canvas.  Linear
  -- sampling softens the pixel shimmer the perspective warp would cause
  -- (the flat path keeps nearest).  TODO(tilt): optionally render this at
  -- 2x for extra crispness.
  if not self.tiltCanvas or self.tiltCanvas:getWidth() ~= wvw
     or self.tiltCanvas:getHeight() ~= wvh then
    if self.tiltCanvas and self.tiltCanvas.release then self.tiltCanvas:release() end
    self.tiltCanvas = love.graphics.newCanvas(wvw, wvh)
    self.tiltCanvas:setFilter("linear", "linear")
  end

  love.graphics.setCanvas(self.tiltCanvas)
  love.graphics.clear(1, 1, 1, 1)
  love.graphics.setColor(1, 1, 1, 1)
  local zoneShader = zoneList and zoneList[1] and PaletteFX.shader() or nil
  if zoneShader then
    love.graphics.setShader(zoneShader)
    -- same trueColor sentinel the flat blit honors (14 §trueColor)
    local bare = false
    for _, z in ipairs(zoneList) do
      local plain = z.colors == false
      if plain ~= bare then
        bare = plain
        love.graphics.setShader(not plain and zoneShader or nil)
      end
      if not plain then PaletteFX.sendColors(zoneShader, z.colors) end
      local x, y = math.max(0, z.x), math.max(0, z.y)
      local x2, y2 = math.min(wvw, z.x + z.w), math.min(wvh, z.y + z.h)
      if x2 > x and y2 > y then
        love.graphics.setScissor(x, y, x2 - x, y2 - y)
        love.graphics.draw(self.worldCanvas, 0, 0)
      end
    end
    love.graphics.setScissor()
    love.graphics.setShader()
  else
    love.graphics.draw(self.worldCanvas, 0, 0)
  end

  -- project onto the tilted plane into the present target (or screen)
  love.graphics.setCanvas(target)
  mesh:setTexture(self.tiltCanvas)
  mesh:setVertices(Tilt.meshCorners(wvw, wvh))
  love.graphics.push()
  love.graphics.translate(wox, woy)
  love.graphics.scale(s, s)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setShader(shader)
  love.graphics.draw(mesh)
  love.graphics.setShader()
  love.graphics.pop()
  return true
end

-- clamp a scissor rect to the viewport box
local function scissorClamped(x, y, w, h, ox, oy, vpw, vph)
  local x2, y2 = math.min(x + w, ox + vpw), math.min(y + h, oy + vph)
  x, y = math.max(x, ox), math.max(y, oy)
  if x2 <= x or y2 <= y then return false end
  love.graphics.setScissor(x, y, x2 - x, y2 - y)
  return true
end

-- Splice the pass's trueColor rects (reported by the renderers that drew
-- a record carrying the flag) onto the end of its zone list, so each one
-- re-blits its region with no shader over the colorized pass.  An absent
-- or empty zone list is left alone: that already draws the whole canvas
-- unshaded, which is what the rects were asking for.
local function withTrueColor(zoneList, pass)
  local rects = PaletteFX.trueColorRects(pass)
  if not (rects[1] and zoneList and zoneList[1]) then return zoneList end
  local merged = {}
  for i = 1, #zoneList do merged[i] = zoneList[i] end
  for i = 1, #rects do merged[#merged + 1] = rects[i] end
  return merged
end

-- zones: optional list of SGB palette regions (see PaletteFX) in
-- 160x144 UI space, applied to the UI pass.  worldZones: optional
-- regions in world-canvas pixels (overworld survey zoom colors each
-- visible map area separately), applied to the world pass; the world
-- pass falls back to the UI zones when absent.  Each zone is drawn
-- scissored through the shade-remap shader, later zones on top.
-- When GBC FX is active the composite is drawn into presentCanvas and
-- presented through the GBC FX shader as a final pass.
function Renderer:endFrame(zones, worldZones)
  love.graphics.setCanvas()
  local ww, wh = love.graphics.getDimensions()
  local S = self:fitScale()
  local vpw, vph = self.WIDTH * S, self.HEIGHT * S
  local ox = math.floor((ww - vpw) / 2)
  local oy = math.floor((wh - vph) / 2)
  local GBCFX = require("src.render.GBCFX")
  -- Forced mono/Classic modes still need a whole-screen zone when a state
  -- exposes no SGB packets (raw DMG canvas), so sendColors can remap.
  zones = PaletteFX.ensureZones(zones)
  if worldZones then worldZones = PaletteFX.ensureZones(worldZones) end
  -- the UI rects are in 160x144 canvas space and the world rects in world-
  -- canvas pixels, matching the zone list each is appended to.  A world
  -- pass with no world zones falls back to the UI list, whose coordinate
  -- space the world rects are not in, so they are dropped there.
  zones = withTrueColor(zones, "ui")
  worldZones = withTrueColor(worldZones, "world")

  local needPresent = GBCFX.active()
  local present = nil
  if needPresent then
    if not self.presentCanvas or self.presentCanvas:getWidth() ~= ww
       or self.presentCanvas:getHeight() ~= wh then
      self.presentCanvas = love.graphics.newCanvas(ww, wh)
      self.presentCanvas:setFilter("linear", "linear")
    end
    present = self.presentCanvas
    love.graphics.setCanvas(present)
  end
  love.graphics.setColor(0, 0, 0, 1)
  love.graphics.rectangle("fill", 0, 0, ww, wh)
  love.graphics.setColor(1, 1, 1, 1)

  -- blit `canvas` at integer `scale` into origin (bx, by), scissored to
  -- the (boxX, boxY, boxW, boxH) screen rect.  zoneScale converts zone
  -- coords (canvas-space) into screen pixels.
  local function blit(canvas, scale, zoneList, zoneScale, bx, by, boxX, boxY, boxW, boxH)
    local shader = zoneList and zoneList[1] and PaletteFX.shader() or nil
    if not shader then
      love.graphics.setScissor(boxX, boxY, boxW, boxH)
      love.graphics.draw(canvas, bx, by, 0, scale, scale)
      love.graphics.setScissor()
      return
    end
    love.graphics.setShader(shader)
    -- a colors == false zone is the trueColor opt-out: its rect draws with
    -- no shader at all.  Nothing sets one without a mod, so a vanilla zone
    -- list never toggles and issues exactly the calls it always did.
    local bare = false
    for _, z in ipairs(zoneList) do
      local plain = z.colors == false
      if plain ~= bare then
        bare = plain
        love.graphics.setShader(not plain and shader or nil)
      end
      if not plain then PaletteFX.sendColors(shader, z.colors) end
      if scissorClamped(bx + z.x * zoneScale, by + z.y * zoneScale,
                        z.w * zoneScale, z.h * zoneScale,
                        boxX, boxY, boxW, boxH) then
        love.graphics.draw(canvas, bx, by, 0, scale, scale)
      end
    end
    love.graphics.setScissor()
    love.graphics.setShader()
  end

  if self.worldActive then
    local s = Zoom.scale(S)
    local wvw = self.worldCanvas:getWidth()
    local wvh = self.worldCanvas:getHeight()
    local wox = math.floor((ww - wvw * s) / 2)
    local woy = math.floor((wh - wvh * s) / 2)
    -- Tilt mode projects the ground world pass through the perspective mesh
    -- (SGB zones baked in beforehand -- see drawTiltedWorld -- so no zone
    -- scissoring here).  drawTiltedWorld returns false when tilt is off or
    -- projection is unavailable (headless / no shader); then the ground
    -- falls through to the flat blit, keeping the flat frame byte-for-byte
    -- identical to today.
    local projected =
      Tilt.active() and self:drawTiltedWorld(worldZones or zones, s, wox, woy, present)
    if not projected then
      if worldZones then
        blit(self.worldCanvas, s, worldZones, s, wox, woy, 0, 0, ww, wh)
      else
        blit(self.worldCanvas, s, zones, S, wox, woy, 0, 0, ww, wh)
      end
      -- OBP-baked overworld sprites replay on top of the zone pass (GBC
      -- mode per-object coloring; see PaletteFX.markSpriteRedraw).  Grass
      -- feet-overdraw entries carry `colors` and re-colorize through the
      -- color-0-keyed shade-remap shader so they keep hiding sprite feet.
      local redraws = PaletteFX.spriteRedraws()
      if redraws[1] then
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.setScissor(0, 0, ww, wh)
        local activeShader = nil
        for _, r in ipairs(redraws) do
          local wanted = r.colors
            and (r.keyed and PaletteFX.keyedShader() or PaletteFX.shader())
            or nil
          if wanted ~= activeShader then
            activeShader = wanted
            love.graphics.setShader(wanted)
          end
          if wanted then PaletteFX.sendColors(wanted, r.colors) end
          if r.quad then
            love.graphics.draw(r.image, r.quad, wox + r.x * s, woy + r.y * s,
                               0, s * r.sx, s)
          else
            love.graphics.draw(r.image, wox + r.x * s, woy + r.y * s,
                               0, s * r.sx, s)
          end
        end
        if activeShader then love.graphics.setShader() end
        love.graphics.setScissor()
      end
    end
    -- Composite the tilt upright pass over the ground (projected or, in the
    -- rare no-shader fallback, flat).  It already carries its billboards'
    -- projected positions and per-sprite SGB colorization on a transparent
    -- canvas, so it just needs the same centred integer-scale blit the flat
    -- world pass uses -- no zone scissoring.  uprightActive is only ever
    -- set in tilt mode, so flat frames skip this and stay identical.
    if self.uprightActive then
      local M = self.UPRIGHT_MARGIN
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.setScissor(0, 0, ww, wh)
      love.graphics.draw(self.uprightCanvas, wox - M * s, woy - M * s, 0, s, s)
      love.graphics.setScissor()
    end
    -- Screen-space warp fade (Transition) over the full world composite so
    -- survey zoom / tilt edges darken with the center, not only the 160x144
    -- UI letterbox.  Drawn before the UI blit so menus above a fade still
    -- composite normally if one is ever stacked that way.
    local fade = self.worldFadeAlpha
    if fade and fade > 0 then
      love.graphics.setColor(0, 0, 0, fade)
      love.graphics.rectangle("fill", 0, 0, ww, wh)
      love.graphics.setColor(1, 1, 1, 1)
    end
  end
  -- UI stays in the classic centered GB letterbox
  blit(self.canvas, S, zones, S, ox, oy, ox, oy, vpw, vph)

  if present then
    love.graphics.setCanvas()
    GBCFX.present(present, S)
  end
  self.worldActive = false
  self.uprightActive = false
  PaletteFX.setPass(nil)
end

return Renderer
