-- Parity test: Mom heal rest (#113) and Silph Co. 9F nurse fade.
--
-- pokered RedsHouse1FMomText / RedsHouse1FMomHealScript:
--   pre-starter -> WakeUpText; else YouShouldRest -> GBFadeOutToWhite ->
--   HealParty -> MUSIC_PKMN_HEALED (wait) -> GBFadeInFromWhite ->
--   LookingGreatText.
-- SilphCo9FNurseText: heal then white fade / Delay3 / fade in (no jingle).
--
-- Self-contained; run via `luajit tests/parity_mom_heal.lua`.
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local S = require("tests.harness").suite("parity mom heal")
local check, eq = S.check, S.eq

local reds = dofile("data/scripts/reds_house.lua")
local silph = dofile("data/scripts/flavor/silph_co_9f.lua")

local function cmds(rows)
  local out = {}
  for _, row in ipairs(rows) do out[#out + 1] = row[1] end
  return out
end

local function find(rows, verb, arg)
  for i, row in ipairs(rows) do
    if row[1] == verb and (arg == nil or row[2] == arg) then
      return i, row
    end
  end
end

-- --- Mom: pre-starter branch + heal rest sequence
do
  local rows = reds.talk.TEXT_REDSHOUSE1F_MOM
  check(rows ~= nil, "Mom talk script exists")

  local iFlag = find(rows, "check_flag", "EVENT_GOT_STARTER")
  check(iFlag, "Mom checks EVENT_GOT_STARTER")
  local iWake = find(rows, "show_text", "_RedsHouse1FMomWakeUpText")
  check(iWake and iWake > iFlag, "WakeUpText follows the starter check")
  local iRest = find(rows, "show_text", "_RedsHouse1FMomYouShouldRestText")
  check(iRest and iRest > iWake, "heal path is after the wake-up branch")

  local iFadeOut = find(rows, "fade", "out")
  local iHeal = find(rows, "heal_party")
  local iJingle = find(rows, "play_once", "Music_PkmnHealed")
  local iFadeIn = find(rows, "fade", "in")
  local iGreat = find(rows, "show_text", "_RedsHouse1FMomLookingGreatText")
  check(iFadeOut and rows[iFadeOut][3] == "white",
        "Mom fades out to white after rest text")
  check(iHeal and iHeal > iFadeOut, "heal_party runs under the white fade")
  check(iJingle and iJingle > iHeal,
        "Music_PkmnHealed plays after heal_party")
  check(iFadeIn and rows[iFadeIn][3] == "white" and iFadeIn > iJingle,
        "Mom fades in from white after the jingle")
  check(iGreat and iGreat > iFadeIn,
        "LookingGreatText follows the fade-in")

  -- jump_if_true must land on the heal path (rest text), not wake-up
  local jumpRow
  for _, row in ipairs(rows) do
    if row[1] == "jump_if_true" then jumpRow = row break end
  end
  check(jumpRow, "Mom has jump_if_true after starter check")
  eq(rows[jumpRow[2]][2], "_RedsHouse1FMomYouShouldRestText",
     "EVENT_GOT_STARTER jumps to the heal rest text")
end

-- --- Silph Co. 9F nurse: white fade, no heal jingle
do
  local rows = silph.SILPH_CO_9F.talk.TEXT_SILPHCO9F_NURSE
  check(rows ~= nil, "Silph nurse talk script exists")

  local iHeal = find(rows, "heal_party")
  local iFadeOut = find(rows, "fade", "out")
  local iWait = find(rows, "wait")
  local iFadeIn = find(rows, "fade", "in")
  check(iHeal, "Silph nurse heals the party")
  check(iFadeOut and rows[iFadeOut][3] == "white" and iFadeOut > iHeal,
        "Silph nurse fades out to white after heal (pokered order)")
  check(iWait and rows[iWait][2] == 3 and iWait > iFadeOut,
        "Silph nurse Delay3 between fades")
  check(iFadeIn and rows[iFadeIn][3] == "white" and iFadeIn > iWait,
        "Silph nurse fades in from white")
  check(not find(rows, "play_once", "Music_PkmnHealed"),
        "Silph nurse does not play Music_PkmnHealed")

  local sequence = table.concat(cmds(rows), ",")
  check(sequence:find("heal_party,fade,wait,fade,show_text", 1, true),
        "Silph heal rest sequence is heal → fade out → wait → fade in → text")
end

-- --- play_once is a blocking command (Mom / captain wait loops)
do
  local Commands = require("src.script.Commands")
  check(Commands.meta.play_once and Commands.meta.play_once.blocking,
        "play_once is marked blocking so heal jingles wait to finish")
end

S.finish()
