-- Parity: Oak's lab starter-ball Pokédex preview (#110).
-- pret StarterDex (engine/events/starter_dex.asm) temporarily sets the
-- owned bits so ShowPokedexData prints the full entry before the player
-- has caught anything.  Also: English R/B prints only the kind string
-- (no " POKéMON" suffix — that clipped "LIZARD" to "LIZARD POKé").
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end

local S = require("tests.harness").suite("parity starter dex")
local check, eq = S.check, S.eq

local Font = require("src.render.Font")
Font.load(Data)

local DexEntryMenu = require("src.ui.DexEntryMenu")
local SaveData = require("src.core.SaveData")
local mapScripts = require("data.scripts.init")

local function fakeGame()
  return {
    data = Data,
    save = SaveData.newGame(),
    input = { wasPressed = function() return false end },
    stack = { pop = function() end },
  }
end

local function drawCapture(menu)
  local drawn = {}
  local saved = Font.draw
  Font.draw = function(text, x, y)
    drawn[#drawn + 1] = { text = tostring(text), x = x, y = y }
    return Font.width(text)
  end
  menu:draw()
  Font.draw = saved
  return drawn
end

local function findText(drawn, needle)
  for _, d in ipairs(drawn) do
    if d.text == needle or d.text:find(needle, 1, true) then return d end
  end
  return nil
end

-- === 1) unowned entry without forceOwned stays "Data unknown." ===
do
  local game = fakeGame()
  game.save.pokedex = { seen = {}, owned = {} }
  local menu = DexEntryMenu.new(game, "CHARMANDER")
  local drawn = drawCapture(menu)
  check(findText(drawn, "Data unknown."),
        "unowned Charmander shows Data unknown without forceOwned")
  check(not findText(drawn, "Obviously prefers"),
        "unowned Charmander hides description without forceOwned")
  check(not findText(drawn, "HT "),
        "unowned Charmander hides height without forceOwned")
end

-- === 2) forceOwned shows full entry without mutating save ===
do
  local game = fakeGame()
  game.save.pokedex = { seen = {}, owned = {} }
  local menu = DexEntryMenu.new(game, { species = "CHARMANDER", forceOwned = true })
  check(menu.forceOwned, "forceOwned flag sticks on the menu")
  local drawn = drawCapture(menu)
  check(findText(drawn, "Obviously prefers"),
        "forceOwned Charmander shows dex description")
  check(findText(drawn, "HT "),
        "forceOwned Charmander shows height")
  check(not findText(drawn, "Data unknown."),
        "forceOwned Charmander does not show Data unknown")
  check(not game.save.pokedex.owned.CHARMANDER,
        "forceOwned preview does not mark Charmander owned")
end

-- === 3) kind is the bare English string (no POKéMON suffix) ===
do
  local game = fakeGame()
  game.save.pokedex = { seen = {}, owned = { CHARMANDER = true } }
  local menu = DexEntryMenu.new(game, "CHARMANDER")
  local drawn = drawCapture(menu)
  local kind = findText(drawn, "LIZARD")
  check(kind and kind.text == "LIZARD",
        "kind draws as LIZARD only (English R/B PlaceString)")
  check(not findText(drawn, "POKéMON"),
        "kind line does not append POKéMON")
  check(kind.x + Font.width(kind.text) <= 160,
        "LIZARD kind fits on-screen (no clip)")
end

-- === 4) Oak's lab starter scripts request forceOwned ===
do
  local balls = {
    "TEXT_OAKSLAB_CHARMANDER_POKE_BALL",
    "TEXT_OAKSLAB_SQUIRTLE_POKE_BALL",
    "TEXT_OAKSLAB_BULBASAUR_POKE_BALL",
  }
  for _, textId in ipairs(balls) do
    local script = mapScripts.talkScript("OAKS_LAB", textId)
    local found
    for _, row in ipairs(script) do
      if row[1] == "push_screen" and row[2] == "DexEntryMenu" then
        found = row[3]
        break
      end
    end
    check(type(found) == "table" and found.forceOwned == true
          and type(found.species) == "string",
          textId .. " pushes DexEntryMenu with forceOwned")
  end
end

S.finish()
