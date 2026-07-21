-- Parity test, Viridian City's two old men + the Pokédex object swap.
--
-- pokered has TWO old men on this map (data/maps/objects/ViridianCity.asm):
--
--   object_event 18, 9, SPRITE_GAMBLER_ASLEEP, STAY, NONE,       ..._OLD_MAN_SLEEPY
--   object_event 17, 5, SPRITE_GAMBLER,        WALK, LEFT_RIGHT, ..._OLD_MAN
--
-- The sleeper only ever grumbles "private property" and shoves you back
-- down; he never wakes, moves or hides.  The coffee ask and the catch
-- tutorial belong to the walking man, who starts OFF
-- (data/maps/toggleable_objects.asm) and is swapped in for the sleeper
-- when Oak hands over the Pokédex (scripts/OaksLab.asm:602-606).  The
-- north corridor is gated on EVENT_GOT_POKEDEX at exactly (19,9)
-- (ViridianCityCheckGotPokedexScript), not on either man's visibility.
--
-- All three of those were wrong at once: the port merged both men into
-- the sleeper, never ran the swap (so the walking man stayed hidden for
-- the entire game), and gated the corridor on the sleeper being hidden --
-- which made talking to him and answering "yes, I'm in a hurry" the only
-- way out of Viridian.  Self-contained; run via `luajit tests/parity_viridian.lua`.
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local Data = require("src.core.Data")
if not (Data.maps and Data.maps.VIRIDIAN_CITY) then Data:load() end
-- The gate builds a real TextBox, which wants a loaded Font atlas we have
-- no graphics device for. The hook requires it lazily, so a stub in
-- package.loaded is enough to exercise the branch headlessly -- we only
-- care that the step was blocked and that a box was pushed, not what it
-- rendered (parity_flavor already covers the text labels themselves).
package.loaded["src.render.TextBox"] = {
  new = function(_, text, onDone) return { text = text, onDone = onDone } end,
}
local init = require("data.scripts.init")
local S = require("tests.harness").suite("parity viridian")
local check = S.check

local function rowsOf(script)
  return type(script) == "table" and script or nil
end

-- find the first row whose command is `cmd`; returns index, row
local function findRow(rows, cmd, arg2)
  for i, row in ipairs(rows or {}) do
    if row[1] == cmd and (arg2 == nil or row[2] == arg2) then return i, row end
  end
end

-- ---------------------------------------------------------------------
-- (1) the sleeper is text-and-shove only
-- ---------------------------------------------------------------------

local sleepy = rowsOf(init.talkScript("VIRIDIAN_CITY", "TEXT_VIRIDIANCITY_OLD_MAN_SLEEPY"))
check(sleepy ~= nil, "sleeper resolves to a row-list script")
if sleepy then
  check(findRow(sleepy, "show_text", "_ViridianCityOldManSleepyPrivatePropertyText") ~= nil,
        "sleeper shows the private-property text")
  check(findRow(sleepy, "move_player") ~= nil, "sleeper shoves the player back")
  -- the bugs: his script must NOT own the other man's dialogue, and must
  -- never hide himself (pokered's HideObject fires from Oak's lab instead)
  check(findRow(sleepy, "ask") == nil, "sleeper does not ask about coffee")
  check(findRow(sleepy, "old_man_demo") == nil, "sleeper does not run the catch demo")
  check(findRow(sleepy, "hide_object") == nil, "sleeper never hides himself")
end

-- ---------------------------------------------------------------------
-- (2) the walking old man owns the coffee ask + the real catch tutorial
-- ---------------------------------------------------------------------

local oldMan = rowsOf(init.talkScript("VIRIDIAN_CITY", "TEXT_VIRIDIANCITY_OLD_MAN"))
-- a Lua function handler here would mean data/scripts/flavor/viridian_city.lua
-- (which loads AFTER story.lua) had silently won the talk-table merge back
check(oldMan ~= nil, "walking old man resolves to a row-list script, not a handler")
if oldMan then
  local askAt = findRow(oldMan, "ask", "_ViridianCityOldManHadMyCoffeeNowText")
  check(askAt ~= nil, "walking old man asks the coffee question")
  check(findRow(oldMan, "old_man_demo") ~= nil, "walking old man runs the catch demo")
  -- polarity: the question is "Are you in a hurry?", so YES is the refusal
  -- (ViridianCityOldManText: `and a / jr z, .refused` -- wCurrentMenuItem 0
  -- is YES).  jump_if_true must therefore land on the "Time is money" line.
  local jAt, jRow = findRow(oldMan, "jump_if_true")
  check(jAt ~= nil and askAt ~= nil and jAt > askAt, "the yes/no branch follows the ask")
  if jRow then
    local target = oldMan[jRow[2]]
    check(target ~= nil and target[1] == "show_text"
          and target[2] == "_ViridianCityOldManTimeIsMoneyText",
          "YES (in a hurry) brushes you off rather than starting the demo")
  end
  -- pokered prints this AFTER the demo battle (EndCatchTrainingScript)
  local demoAt = findRow(oldMan, "old_man_demo")
  local weakenAt = findRow(oldMan, "show_text", "_ViridianCityOldManYouNeedToWeakenTheTargetText")
  check(demoAt and weakenAt and weakenAt > demoAt,
        "the weaken-the-target line comes after the demo, not before it")
end

-- ---------------------------------------------------------------------
-- (3) the Pokédex performs the swap (OaksLab.asm:602-606)
-- ---------------------------------------------------------------------

local oak1 = rowsOf(init.talkScript("OAKS_LAB", "TEXT_OAKSLAB_OAK1"))
check(oak1 ~= nil, "Oak's main script resolves")
if oak1 then
  local dexAt = findRow(oak1, "set_flag", "EVENT_GOT_POKEDEX")
  check(dexAt ~= nil, "Oak sets EVENT_GOT_POKEDEX")
  local hideAt = findRow(oak1, "hide_object", "VIRIDIAN_CITY")
  local showAt = findRow(oak1, "show_object", "VIRIDIAN_CITY")
  check(hideAt ~= nil, "the Pokédex hides the Viridian sleeper")
  check(showAt ~= nil, "the Pokédex shows the walking Viridian old man")
  if hideAt then
    check(oak1[hideAt][3] == "VIRIDIANCITY_OLD_MAN_SLEEPY", "hides the right object")
  end
  if showAt then
    check(oak1[showAt][3] == "VIRIDIANCITY_OLD_MAN", "shows the right object")
  end
  check(dexAt and hideAt and showAt and hideAt > dexAt and showAt > dexAt,
        "the swap runs on the branch that grants the Pokédex")
end

-- ---------------------------------------------------------------------
-- (4) every jump target in the touched scripts is in range
--
-- Inserting the two swap rows renumbered Oak's whole 30-row jump table.
-- An off-by-one there is invisible until a branch silently runs the wrong
-- line, so check every target lands on a real row (or the end sentinel,
-- #rows + 1) across both files.
-- ---------------------------------------------------------------------

local JUMPS = { jump = true, jump_if_true = true, jump_if_false = true }
local checkedJumps = 0
for _, modname in ipairs({ "data.scripts.oaks_lab", "data.scripts.story" }) do
  local mod = require(modname)
  -- oaks_lab returns one map's table; story returns { [mapId] = table }
  local maps = mod.talk and { [modname] = mod } or mod
  for mapId, m in pairs(maps) do
    if type(m) == "table" and m.talk then
      for const, script in pairs(m.talk) do
        local rows = rowsOf(script)
        if rows then
          for i, row in ipairs(rows) do
            if type(row) == "table" and JUMPS[row[1]] then
              local t = row[2]
              checkedJumps = checkedJumps + 1
              check(type(t) == "number" and t >= 1 and t <= #rows + 1,
                    ("%s/%s row %d: %s -> %s in range"):format(
                      mapId, const, i, tostring(row[1]), tostring(t)))
            end
          end
        end
      end
    end
  end
end
check(checkedJumps > 0, "found jump rows to range-check (got " .. checkedJumps .. ")")

-- ---------------------------------------------------------------------
-- (5) the corridor gate keys off EVENT_GOT_POKEDEX at (19,9)
-- ---------------------------------------------------------------------

local onStep = init.get("VIRIDIAN_CITY").onStep
check(type(onStep) == "function", "VIRIDIAN_CITY has an onStep hook")

local function step(flags, x, y)
  local pushed = 0
  local game = {
    save = { flags = flags, inventory = {}, objectToggles = {} },
    data = Data,
    stack = { push = function() pushed = pushed + 1 end },
  }
  local ow = { player = {}, scriptMove = function() end }
  local ok, blocked = pcall(onStep, game, ow, x, y)
  return ok, blocked, pushed
end

if type(onStep) == "function" then
  local ok, blocked, pushed = step({}, 19, 9)
  check(ok, "onStep runs at the gate cell")
  check(ok and blocked == true, "(19,9) is blocked without the Pokédex")
  check(ok and pushed == 1, "being blocked shows a text box")

  local ok2, blocked2 = step({ EVENT_GOT_POKEDEX = true }, 19, 9)
  check(ok2 and blocked2 ~= true, "(19,9) is walkable once you have the Pokédex")

  -- the old port blocked the whole 3-wide corridor (x 17-19, y<=8); pokered
  -- blocks one cell, and the sleeper/girl bodies do the rest
  local ok3, blocked3 = step({}, 19, 8)
  check(ok3 and blocked3 ~= true, "(19,8) north of the gate is not itself gated")
  local ok4, blocked4 = step({}, 17, 8)
  check(ok4 and blocked4 ~= true, "(17,8) is not gated (only (19,9) triggers)")
end

S.finish()
