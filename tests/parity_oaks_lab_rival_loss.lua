-- Parity: losing the Oak's Lab starter rival must not black out.
-- pret HandlePlayerBlackOut special-cases OPP_RIVAL1 on OAKS_LAB:
-- Rival1WinText only, no PlayerBlackedOutText, no warp / half-money.
-- OaksLabRivalEndBattleScript then HealParty and continues either way.
-- Self-contained; run via `luajit tests/parity_oaks_lab_rival_loss.lua`.
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local BattleState = require("src.battle.BattleState")
local S = require("tests.harness").suite("parity oaks lab rival loss")
local check, eq = S.check, S.eq

local function saidBlackout(b)
  for _, m in ipairs(b.said) do
    if tostring(m):find("blacked") then return true end
  end
  return false
end

local function saidRivalTaunt(b)
  for _, m in ipairs(b.said) do
    if tostring(m):find("great or what") then return true end
  end
  return false
end

local function rivalBattle(mapId)
  return {
    kind = "trainer",
    oppClass = "OPP_RIVAL1",
    result = nil,
    afterQueue = nil,
    said = {},
    data = {
      text = { _Rival1WinText = "{RIVAL}: Yeah! Am\nI great or what?" },
    },
    game = {
      save = {
        party = { { species = "SQUIRTLE", hp = 0, stats = { hp = 20 } } },
        player = { name = "RED", rival = "BLUE", map = mapId },
      },
      overworld = { map = { id = mapId } },
    },
    sayNext = function(self, m) self.said[#self.said + 1] = m end,
    say = function(self, m) self.said[#self.said + 1] = m end,
  }
end

do
  local b = rivalBattle("OAKS_LAB")
  BattleState.playerMonFainted(b)
  eq(b.result, "lose", "lab rival wipe is still a loss")
  check(saidRivalTaunt(b), "lab rival wipe shows Rival1WinText")
  check(not saidBlackout(b), "lab rival wipe does not say blacked out")
  check(BattleState.isOaksLabStarterRival(b), "oaks-lab starter-rival detector")
end

do
  local b = rivalBattle("ROUTE_22")
  BattleState.playerMonFainted(b)
  eq(b.result, "lose", "route-22 rival wipe is a loss")
  check(saidRivalTaunt(b), "route-22 rival still shows Rival1WinText")
  check(saidBlackout(b), "route-22 rival still blacks out")
  check(not BattleState.isOaksLabStarterRival(b),
        "route-22 is not the oaks-lab special case")
end

S.finish()
