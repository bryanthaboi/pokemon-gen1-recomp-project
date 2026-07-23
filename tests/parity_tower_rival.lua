-- Parity test: Pokémon Tower 2F rival leaves after defeat (#111).
--
-- pokered PokemonTower2FDefeatedRivalScript (scripts/PokemonTower2F.asm):
-- after EVENT_BEAT_POKEMON_TOWER_RIVAL, walk RightThenDown or
-- DownThenRight (EVENT_POKEMON_TOWER_RIVAL_ON_LEFT when the player is on
-- (15,5)), then HideObject TOGGLE_POKEMON_TOWER_2F_RIVAL.  The port used
-- to end after DefeatedText, so he stayed and HowsYourDex could re-fire.
--
-- Self-contained; run via `luajit tests/parity_tower_rival.lua`.
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local S = require("tests.harness").suite("parity tower rival")
local check, eq = S.check, S.eq

package.loaded["src.render.TextBox"] = {
  new = function(_, text, done) return { text = text, done = done } end,
}
package.loaded["src.core.Music"] = {
  play = function() end,
  playOnce = function() return true end,
  stop = function() end,
}

local story = dofile("data/scripts/story.lua")
local tower = story.POKEMON_TOWER_2F
check(tower ~= nil, "POKEMON_TOWER_2F map script exists")
check(type(tower.rivalScript) == "function", "rivalScript helper exported")
check(type(tower.onStep) == "function", "onStep ambush exists")
check(type(tower.onEnter) == "function", "onEnter hide repair exists")

local RIGHT_THEN_DOWN =
  { "right", "down", "down", "right", "down", "down", "right", "right" }
local DOWN_THEN_RIGHT =
  { "down", "down", "right", "right", "right", "right", "down", "down" }

local function dirsEqual(a, b)
  if type(a) ~= "table" or #a ~= #b then return false end
  for i = 1, #b do if a[i] ~= b[i] then return false end end
  return true
end

local function findWalk(rows)
  for _, r in ipairs(rows) do
    if r[1] == "walk_npc" then return r end
  end
end

-- (1) both approach tiles pick the pokered exit movement
do
  local below = tower.rivalScript(14)
  local left = tower.rivalScript(15)
  local wBelow, wLeft = findWalk(below), findWalk(left)
  check(wBelow ~= nil, "player-below script has walk_npc")
  check(wLeft ~= nil, "rival-on-left script has walk_npc")
  eq(wBelow[2], 1, "walk targets object index 1 (rival)")
  check(dirsEqual(wBelow[3], RIGHT_THEN_DOWN),
        "player at x=14 uses RightThenDownMovement")
  check(dirsEqual(wLeft[3], DOWN_THEN_RIGHT),
        "player at x=15 uses DownThenRightMovement")
end

-- (2) win path: flag, defeat text, walk, hide -- in order
do
  local rows = tower.rivalScript(14)
  local preds = {
    { "set_flag EVENT_BEAT_POKEMON_TOWER_RIVAL",
      function(r) return r[1] == "set_flag"
        and r[2] == "EVENT_BEAT_POKEMON_TOWER_RIVAL" end },
    { "show_text DefeatedText",
      function(r) return r[1] == "show_text"
        and r[2] == "_PokemonTower2FRivalDefeatedText" end },
    { "walk_npc exit",
      function(r) return r[1] == "walk_npc" end },
    { "hide_object POKEMONTOWER2F_RIVAL",
      function(r) return r[1] == "hide_object"
        and r[2] == "POKEMON_TOWER_2F"
        and r[3] == "POKEMONTOWER2F_RIVAL" end },
  }
  local pi = 1
  for _, r in ipairs(rows) do
    if pi <= #preds and preds[pi][2](r) then pi = pi + 1 end
  end
  for i = 1, #preds do
    check(i < pi, "rival script has, in order: " .. preds[i][1])
  end
end

-- (3) onStep: only the encounter coords, and not after the beat flag
do
  local ran
  local game = { save = { flags = {} }, data = {} }
  local ow = {
    runner = {
      isRunning = function() return false end,
      run = function(_, rows) ran = rows end,
    },
    player = { facing = "down" },
    npcByIndex = function() return { def = { name = "POKEMONTOWER2F_RIVAL" } } end,
  }
  check(tower.onStep(game, ow, 15, 5), "onStep fires on (15,5)")
  check(ran ~= nil and findWalk(ran) ~= nil, "onStep runs exit-walk script")
  check(dirsEqual(findWalk(ran)[3], DOWN_THEN_RIGHT),
        "onStep (15,5) picks DownThenRight")
  eq(ow.player.facing, "left", "onStep (15,5) faces the rival")

  ran = nil
  check(tower.onStep(game, ow, 14, 6), "onStep fires on (14,6)")
  check(dirsEqual(findWalk(ran)[3], RIGHT_THEN_DOWN),
        "onStep (14,6) picks RightThenDown")

  check(not tower.onStep(game, ow, 14, 5), "onStep ignores rival's own tile")
  game.save.flags.EVENT_BEAT_POKEMON_TOWER_RIVAL = true
  check(not tower.onStep(game, ow, 15, 5), "beaten: onStep is inert")
end

-- (4) onEnter hides a stuck rival once the beat flag is set
do
  local Commands = require("src.script.Commands")
  local hidden = {}
  local realHide = Commands.hide_object
  Commands.hide_object = function(_, mapId, name)
    hidden[#hidden + 1] = { mapId, name }
  end

  tower.onEnter({ save = { flags = {} } }, {})
  eq(#hidden, 0, "onEnter: no hide while unbeaten")

  tower.onEnter({
    save = { flags = { EVENT_BEAT_POKEMON_TOWER_RIVAL = true } },
  }, {})
  eq(#hidden, 1, "onEnter: hide once beaten")
  eq(hidden[1][1], "POKEMON_TOWER_2F", "onEnter hide map")
  eq(hidden[1][2], "POKEMONTOWER2F_RIVAL", "onEnter hide object")

  Commands.hide_object = realHide
end

S.finish()
