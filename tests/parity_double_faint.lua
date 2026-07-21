-- Parity test: losing your last POKéMON always blacks you out, even when
-- the battle was already decided in your favour.
--
-- A double faint -- the lead dying to residual damage on the same turn it
-- lands the KO -- used to leave BattleState:playerMonFainted at its
-- "the battle is decided" guard, so it returned with result = "win" still
-- set.  OverworldState:afterBattle only revives the party and warps to the
-- heal point on "lose" (src/world/OverworldController.lua), so the player
-- was handed back to the overworld standing on the map with every POKéMON
-- at 0 HP.  Nothing recovers from that: BattleState refuses to start an
-- encounter with no healthy party ("wild battle with no healthy party;
-- skipping"), so the save is bricked in place.
--
-- pokered cannot reach that state -- HandlePlayerMonFainted runs the
-- player-side check on its own account, so being out of useable POKéMON
-- blacks you out whatever happened to the enemy.
--
-- Found by the automated route driver: an attempt spent its whole length
-- "wiping" on VIRIDIAN_FOREST fourteen times without ever moving, because
-- the party was dead but the game had never blacked out.
-- Self-contained; run via `luajit tests/parity_double_faint.lua`.
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local BattleState = require("src.battle.BattleState")
local S = require("tests.harness").suite("parity double faint")
local check, eq = S.check, S.eq

-- A stand-in carrying only what playerMonFainted touches.  Deliberately not
-- a real battle: the point is the decision, and a full encounter would need
-- a loaded Data, an RNG and a queue to say nothing more than this does.
local function battleWith(partyHP, result)
  local party = {}
  for i, hp in ipairs(partyHP) do
    party[i] = { species = "SQUIRTLE", hp = hp, stats = { hp = 20 } }
  end
  return {
    kind = "wild",
    result = result,
    afterQueue = nil,
    said = {},
    -- the reserves-left path reads the "Use next POKéMON?" prompt off Data
    data = { text = { _UseNextMonText = "Use next POKéMON?" } },
    game = { save = { party = party, player = { name = "RED" } } },
    sayNext = function(self, m) self.said[#self.said + 1] = m end,
    say = function(self, m) self.said[#self.said + 1] = m end,
    ui = function() end,
  }
end

local function saidBlackout(b)
  for _, m in ipairs(b.said) do
    if tostring(m):find("blacked") then return true end
  end
  return false
end

-- The regression itself: a won battle whose last mon died with it.
do
  local b = battleWith({ 0 }, "win")
  BattleState.playerMonFainted(b)
  eq(b.result, "lose", "a win with the last mon dead becomes a blackout")
  eq(b.afterQueue, "finish", "the blackout ends the battle")
  check(saidBlackout(b), "the blackout text still prints on a double faint")
end

-- Same for the other non-lose results, so no path can strand the party.
for _, result in ipairs({ "run", "caught" }) do
  local b = battleWith({ 0 }, result)
  BattleState.playerMonFainted(b)
  eq(b.result, "lose", ("a %q result with no healthy party becomes a blackout")
                       :format(result))
end

-- An undecided battle keeps behaving exactly as before.
do
  local b = battleWith({ 0 }, nil)
  BattleState.playerMonFainted(b)
  eq(b.result, "lose", "the ordinary last-mon faint still blacks out")
  check(saidBlackout(b), "and still prints the blackout text")
end

-- The guard must not fire while something is still standing: a won battle
-- with a healthy reserve stays won, and the fainted-mon flow is untouched.
do
  local b = battleWith({ 0, 15 }, "win")
  BattleState.playerMonFainted(b)
  eq(b.result, "win", "a win with a healthy reserve is still a win")
  check(not saidBlackout(b), "and prints no blackout text")
end

-- Already lost: no second helping of the blackout text.
do
  local b = battleWith({ 0 }, "lose")
  BattleState.playerMonFainted(b)
  eq(b.result, "lose", "an already-lost battle stays lost")
  eq(#b.said, 0, "and does not re-announce the blackout")
end

-- A mid-battle faint with reserves left is the wild "Use next POKéMON?"
-- prompt (DoUseNextMonDialogue), not a blackout -- the path the guard
-- sits in front of, so prove it still runs.
do
  local b = battleWith({ 0, 15 }, nil)
  BattleState.playerMonFainted(b)
  eq(b.result, nil, "a faint with reserves left does not decide the battle")
  check(not saidBlackout(b), "and does not black out")
end

S.finish()
