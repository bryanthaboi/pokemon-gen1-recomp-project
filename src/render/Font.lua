-- Text renderer using the real extracted font sheets and charmap.
-- Glyphs live on *pages*: font.png holds codes $80-$FF, font_extra.png
-- $60-$7F (borders etc), and a mod registers more (a kana block at $100,
-- a replacement sheet for an existing page) through the font registry,
-- which merges into data.font.pages.  A page may set its own `advance`
-- for variable-width text; the default is the GB's flat 8px.
-- The charmap is matched greedily (longest sequence first) so multi-byte
-- UTF-8 chars and ligature glyphs like 'd 'l 's map to single glyphs.

local Assets = require("src.render.Assets")

local Font = {}

local GLYPH = 8

local state
local loadedFrom

-- the two vanilla pages as the legacy def spells them, so a cache that
-- predates the pages table still loads and a mod that registers only one
-- page replaces just that one
local function pagesOf(def)
  local pages = {}
  if def.image then
    pages.main = { image = def.image, base = def.mainBase or 0x80,
                   glyphsPerRow = def.glyphsPerRow or 16 }
  end
  if def.imageExtra then
    pages.extra = { image = def.imageExtra, base = def.extraBase or 0x60,
                    glyphsPerRow = def.glyphsPerRow or 16 }
  end
  for id, page in pairs(def.pages or {}) do
    if type(page) == "table" and page.image then pages[id] = page end
  end
  return pages
end

function Font.load(data)
  loadedFrom = data
  local def = data.font
  state = { def = def, pages = {}, order = {}, byFirstByte = {} }
  for id, page in pairs(pagesOf(def)) do
    local ok, img = pcall(Assets.image, page.image)
    if ok then
      local iw, ih = img:getDimensions()
      local perRow = page.glyphsPerRow or math.floor(iw / GLYPH)
      local quads = {}
      for i = 0, perRow * math.floor(ih / GLYPH) - 1 do
        quads[i] = love.graphics.newQuad((i % perRow) * GLYPH,
          math.floor(i / perRow) * GLYPH, GLYPH, GLYPH, iw, ih)
      end
      local entry = { id = id, image = img, quads = quads,
                      base = page.base, advance = page.advance or GLYPH }
      state.pages[id] = entry
      state.order[#state.order + 1] = entry
    end
  end
  -- highest base first: a code resolves against the last page that starts
  -- at or below it, which is exactly what the old main/extra chain did
  table.sort(state.order, function(a, b) return a.base > b.base end)

  -- Bucket the charmap by first byte for fast greedy matching, longest
  -- sequence first *within* each bucket.  The sort is ours rather than
  -- the extractor's: a mod's page ships its own entries and nothing has
  -- put them in length order.
  local function bucket(entry)
    if type(entry) ~= "table" or type(entry.seq) ~= "string"
        or entry.seq == "" then return end
    local b = entry.seq:byte(1)
    state.byFirstByte[b] = state.byFirstByte[b] or {}
    table.insert(state.byFirstByte[b], entry)
  end
  for _, entry in ipairs(def.charmap or {}) do bucket(entry) end
  for _, page in pairs(def.pages or {}) do
    for _, entry in ipairs(type(page) == "table" and page.charmap or {}) do
      bucket(entry)
    end
  end
  for _, entries in pairs(state.byFirstByte) do
    table.sort(entries, function(a, b) return #a.seq > #b.seq end)
  end

  Font.BORDER = {}
  for key, code in pairs(Font.DEFAULT_BORDER) do Font.BORDER[key] = code end
  for key, code in pairs(def.border or {}) do Font.BORDER[key] = code end
end

-- re-run load against the data it last saw, so hot reload picks up an
-- edited sheet or a newly merged page
function Font.invalidate()
  if loadedFrom then Font.load(loadedFrom) end
end

Assets.register(Font.invalidate)

-- the page a glyph code draws from, or nil when nothing covers it
local function pageFor(code)
  if not state then return nil end
  for _, page in ipairs(state.order) do
    if code >= page.base then return page end
  end
  return nil
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
  local page = pageFor(code)
  if not page then return end
  local quad = page.quads[code - page.base]
  if quad then love.graphics.draw(page.image, quad, x, y) end
end

-- how far the pen moves past a glyph; 8 unless its page says otherwise
function Font.advanceOf(code)
  local page = pageFor(code)
  return page and page.advance or GLYPH
end

-- Pixel width of a string (glyph advances, not UTF-8 byte length).
-- Multi-byte charmap entries like "¥" are one glyph; callers that
-- right-align with `#text * 8` mis-place them.
function Font.width(text)
  local w = 0
  for _, code in ipairs(Font.encode(text)) do
    w = w + Font.advanceOf(code)
  end
  return w
end

-- Draw a plain single-line string at pixel (x, y).  Returns the width
-- drawn, which is #codes * 8 for every fixed-width page.
function Font.draw(text, x, y)
  local codes = Font.encode(text)
  local pen = x
  for _, code in ipairs(codes) do
    Font.drawCode(code, pen, y)
    pen = pen + Font.advanceOf(code)
  end
  return pen - x
end

-- Border glyph codes (font_extra.png, from charmap.asm $79-$7E).  A font
-- that draws its boxes from different glyphs sets data.font.border and
-- Font.load folds it over these; the table itself stays writable so a mod
-- can retheme one corner without shipping a whole page.
Font.DEFAULT_BORDER = {
  tl = 0x79, h = 0x7A, tr = 0x7B, v = 0x7C, bl = 0x7D, br = 0x7E,
}
Font.BORDER = {}
for key, code in pairs(Font.DEFAULT_BORDER) do Font.BORDER[key] = code end

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
