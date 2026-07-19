-- one 16x8-glyph page starting at $80 plus the ASCII charmap rows the
-- tests print with; the placeholder sheet is 4-shade grayscale
local charmap = {}
-- A-Z at $80.., 0-9 at $F6.., space at $7F like the vanilla map
for i = 0, 25 do
  charmap[#charmap + 1] = { code = 0x80 + i, seq = string.char(65 + i) }
end
for i = 0, 9 do
  charmap[#charmap + 1] = { code = 0xF6 + i, seq = string.char(48 + i) }
end
charmap[#charmap + 1] = { code = 0x7F, seq = " " }

return {
  image = "tests/fixture_data/assets/fix_font.png",
  charmap = charmap,
}
