-- Text renderer using the real extracted font sheets and charmap.
-- font.png holds glyph codes $80-$FF, font_extra.png $60-$7F (borders etc).
-- The charmap is matched greedily (longest sequence first) so multi-byte
-- UTF-8 chars and ligature glyphs like 'd 'l 's map to single glyphs.

local Font = {}

local state

function Font.load(data)
  local def = data.font
  local main = love.graphics.newImage(def.image)
  local extra = love.graphics.newImage(def.imageExtra)
  state = {
    def = def,
    main = main,
    extra = extra,
    mainQuads = {},
    extraQuads = {},
    byFirstByte = {},
  }
  local function buildQuads(img, quads)
    local iw, ih = img:getDimensions()
    local perRow = iw / 8
    for i = 0, perRow * (ih / 8) - 1 do
      quads[i] = love.graphics.newQuad((i % perRow) * 8,
                                       math.floor(i / perRow) * 8, 8, 8, iw, ih)
    end
  end
  buildQuads(main, state.mainQuads)
  buildQuads(extra, state.extraQuads)
  -- charmap comes sorted longest-first from the extractor; bucket by first
  -- byte for fast greedy matching
  for _, entry in ipairs(def.charmap) do
    local b = entry.seq:byte(1)
    state.byFirstByte[b] = state.byFirstByte[b] or {}
    table.insert(state.byFirstByte[b], entry)
  end
end

-- Convert a text string into a list of glyph codes.  Unknown characters
-- render as space (and are reported once).
local reported = {}
function Font.encode(text)
  local codes = {}
  local i = 1
  while i <= #text do
    local candidates = state.byFirstByte[text:byte(i)]
    local matched = false
    if candidates then
      for _, entry in ipairs(candidates) do
        local n = #entry.seq
        if text:sub(i, i + n - 1) == entry.seq then
          codes[#codes + 1] = entry.code
          i = i + n
          matched = true
          break
        end
      end
    end
    if not matched then
      local ch = text:sub(i, i)
      if not reported[ch] and ch:byte() >= 32 then
        reported[ch] = true
        require("src.core.Logger").warn("font: no glyph for %q", ch)
      end
      codes[#codes + 1] = 0x7F -- space
      i = i + 1
    end
  end
  return codes
end

function Font.drawCode(code, x, y)
  local def = state.def
  if code >= def.mainBase then
    love.graphics.draw(state.main, state.mainQuads[code - def.mainBase], x, y)
  elseif code >= def.extraBase then
    love.graphics.draw(state.extra, state.extraQuads[code - def.extraBase], x, y)
  end
end

-- Draw a plain single-line string at pixel (x, y).
function Font.draw(text, x, y)
  local codes = Font.encode(text)
  for i, code in ipairs(codes) do
    Font.drawCode(code, x + (i - 1) * 8, y)
  end
  return #codes * 8
end

-- Border glyph codes (font_extra.png, from charmap.asm $79-$7E)
Font.BORDER = {
  tl = 0x79, h = 0x7A, tr = 0x7B, v = 0x7C, bl = 0x7D, br = 0x7E,
}

-- Draw a Game Boy style bordered box in tile coordinates.
function Font.drawBox(tx, ty, tw, th)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", tx * 8, ty * 8, tw * 8, th * 8)
  local B = Font.BORDER
  Font.drawCode(B.tl, tx * 8, ty * 8)
  Font.drawCode(B.tr, (tx + tw - 1) * 8, ty * 8)
  Font.drawCode(B.bl, tx * 8, (ty + th - 1) * 8)
  Font.drawCode(B.br, (tx + tw - 1) * 8, (ty + th - 1) * 8)
  for i = 1, tw - 2 do
    Font.drawCode(B.h, (tx + i) * 8, ty * 8)
    Font.drawCode(B.h, (tx + i) * 8, (ty + th - 1) * 8)
  end
  for j = 1, th - 2 do
    Font.drawCode(B.v, tx * 8, (ty + j) * 8)
    Font.drawCode(B.v, (tx + tw - 1) * 8, (ty + j) * 8)
  end
end

return Font
