-- Regression: a plan must never be blocked by another map's NPCs.
--
-- The route driver's BFS treats every entity as a wall, keyed by a folded
-- cell id (`y * width + x`). A warp swaps the map id before the entity list
-- is rebuilt, so a plan made in that window sees the PREVIOUS map's NPCs --
-- and folding hides how wrong that is. On an 8-wide gate, a forest NPC at
-- (16,43) folds to 43*8+16 = 360, which is a perfectly ordinary cell of the
-- gate; the wall lands somewhere innocent and nothing looks amiss.
--
-- Observed as: "goto (4,1) unreachable on VIRIDIAN_FOREST_NORTH_GATE; from
-- (2,1); npcs: SPRITE_YOUNGSTER@(16,43) SPRITE_YOUNGSTER@(30,33)
-- SPRITE_POKE_BALL@(12,29)" -- Viridian Forest coordinates listed against a
-- gate the size of a room. Every following segment skipped and the attempt
-- was lost.
--
-- The fix is to ignore any entity outside the current map's bounds. This
-- pins the folding arithmetic that makes the bug invisible, so a future
-- reader can see why the bounds check is not merely defensive.
--
-- Self-contained; run via `luajit tests/parity_stale_npc.lua`.
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local S = require("tests.harness").suite("parity stale npc")
local check, eq = S.check, S.eq

-- the driver's blocking rule, isolated: fold a cell, wall it, but only for
-- entities that are actually on this map
local function blockedCells(npcs, w, h)
  local blocked = {}
  for _, npc in ipairs(npcs) do
    if npc.x >= 0 and npc.y >= 0 and npc.x < w and npc.y < h then
      blocked[npc.y * w + npc.x] = true
    end
  end
  return blocked
end

-- VIRIDIAN_FOREST_NORTH_GATE is 8 cells wide; the forest is far larger.
local GATE_W, GATE_H = 8, 8

-- The arithmetic that made this invisible: a foreign NPC folds onto a real
-- cell of the small map rather than into obvious nonsense.
eq(43 * GATE_W + 16, 360, "forest (16,43) folds onto a plain integer id")
eq(1 * GATE_W + 4, 12, "the gate's own (4,1) folds to 12")

-- Without the bounds check, foreign NPCs wall off cells of the gate.
do
  local naive = {}
  for _, n in ipairs({ { x = 16, y = 43 }, { x = 30, y = 33 }, { x = 12, y = 29 } }) do
    naive[n.y * GATE_W + n.x] = true
  end
  check(next(naive) ~= nil,
        "unguarded, off-map NPCs still produce blocked cell ids")
end

-- With it, they are ignored entirely.
do
  local blocked = blockedCells({
    { x = 16, y = 43 }, { x = 30, y = 33 }, { x = 12, y = 29 },
    { x = 2, y = 18 }, { x = 27, y = 40 },
  }, GATE_W, GATE_H)
  check(next(blocked) == nil,
        "every off-map NPC is ignored on the gate")
end

-- ...while the map's own NPCs still block, which is the whole point.
do
  local blocked = blockedCells({
    { x = 3, y = 2 },  -- SPRITE_SUPER_NERD, really in the gate
    { x = 2, y = 5 },  -- SPRITE_GRAMPS
    { x = 16, y = 43 }, -- stale, from the forest
  }, GATE_W, GATE_H)
  check(blocked[2 * GATE_W + 3], "an NPC inside the gate still blocks its cell")
  check(blocked[5 * GATE_W + 2], "and so does the second one")
  local n = 0
  for _ in pairs(blocked) do n = n + 1 end
  eq(n, 2, "exactly the two real NPCs block -- the stale one does not")
end

-- Edge cases of the bound itself.
do
  local blocked = blockedCells({
    { x = GATE_W - 1, y = GATE_H - 1 }, -- last legal cell
    { x = GATE_W, y = 0 },              -- one past the right edge
    { x = 0, y = GATE_H },              -- one past the bottom
    { x = -1, y = 0 },                  -- negative
  }, GATE_W, GATE_H)
  check(blocked[(GATE_H - 1) * GATE_W + (GATE_W - 1)],
        "the far corner is in bounds and blocks")
  local n = 0
  for _ in pairs(blocked) do n = n + 1 end
  eq(n, 1, "off-by-one and negative coordinates are all rejected")
end

S.finish()
