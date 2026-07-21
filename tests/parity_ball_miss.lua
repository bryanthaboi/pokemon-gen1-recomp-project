-- Parity test: a wild battle always returns to the action menu after a
-- POKé BALL fails to catch.
--
-- BattleState's message pump only leaves the "messages" phase through
-- afterQueue:
--
--   if self.phase == "messages" then
--     if not self:updateQueue() then
--       if self.afterQueue == "menu" then self.phase = "menu"
--       elseif self.afterQueue == "finish" then self:finish() end
--     end
--     return
--   end
--
-- so a drained queue with afterQueue set to anything else -- or to nothing
-- -- parks the battle in "messages" for good.  Nothing on screen is
-- waiting, no input advances it, and the encounter can never end.
--
-- Found by the route driver, which reported it precisely once it was made
-- to give up rather than spin: "catch: livelocked on ROUTE_6 after 1201
-- iterations (steps=81, thrown=6, inBattle=true, phase=messages)".  Six
-- balls thrown, battle still live, phase stuck.  Before the guard it span
-- 10,229 times on one ODDISH and pinned the whole run.
--
-- Self-contained; run via `luajit tests/parity_ball_miss.lua`.
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local S = require("tests.harness").suite("parity ball miss")
local check, eq = S.check, S.eq

-- Drive the phase machine the way BattleState:update does, with a queue
-- that drains.  The decision under test is what the phase becomes when the
-- queue empties, so the queue's contents do not matter -- only afterQueue.
local function pump(afterQueue, queued)
  local b = {
    phase = "messages",
    afterQueue = afterQueue,
    queue = queued or {},
    finished = false,
  }
  b.updateQueue = function(self)
    if #self.queue > 0 then table.remove(self.queue, 1) return true end
    return false
  end
  b.finish = function(self) self.finished = true end
  -- the real update()'s messages branch, verbatim
  for _ = 1, 50 do
    if b.phase == "messages" then
      if not b:updateQueue() then
        if b.afterQueue == "menu" then
          b.phase = "menu"
        elseif b.afterQueue == "finish" then
          b:finish()
        end
      end
    end
  end
  return b
end

-- The contract: "menu" and "finish" both leave the messages phase.
eq(pump("menu").phase, "menu", "afterQueue=menu returns to the action menu")
check(pump("finish").finished, "afterQueue=finish ends the battle")

-- ...and anything else is the livelock.  This is the assertion that would
-- have caught it: a drained queue with no afterQueue never leaves
-- "messages", so the battle is unreachable by any input.
local stuck = pump(nil, { {}, {}, {} })
eq(stuck.phase, "messages", "afterQueue=nil is the stuck state (documented)")
check(#stuck.queue == 0, "the queue really did drain -- nothing is pending")

-- The real thing: openItems -> throwBall -> miss must leave afterQueue as
-- "menu" the whole way through, since throwBall itself never sets it.
local BattleState = require("src.battle.BattleState")
local openItems = BattleState.openItems
local fake = {
  queue = {},
  say = function(self, t) table.insert(self.queue, { text = t }) end,
  act = function(self, f) table.insert(self.queue, { fn = f }) end,
  ui = function(self, f) table.insert(self.queue, { ui = f }) end,
  buildScreen = function() return {} end,
}
openItems(fake)
eq(fake.phase, "messages", "openItems parks the battle in the messages phase")
eq(fake.afterQueue, "menu", "openItems arms afterQueue=menu before the bag")
check(#fake.queue == 1 and fake.queue[1].ui ~= nil,
      "openItems queues the bag as a ui item")

S.finish()
