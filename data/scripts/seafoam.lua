-- Seafoam Islands boulder/current puzzle wiring + the Vermilion Gym
-- locked door (map-enter hooks; the mechanics themselves live in
-- src/world/OverworldController.lua driven by field.seafoam and the
-- trash can data).
--
-- Sources: scripts/SeafoamIslands1F.asm / B1F.asm / B3F.asm / B4F.asm
-- (currents, holes), scripts/VermilionGym.asm (VermilionGymSetDoorTile:
-- the door block at (2,2) is $24 until EVENT_2ND_LOCK_OPENED, then $5).
--
-- The 1F->B1F->B2F->B3F->B4F boulder cascade is fully data-driven via
-- field.seafoam (SEAFOAM_ISLANDS_1F/B1F/B3F holes+holeDestination and
-- B3F's pluggedByHolesOn) plus the generic
-- OverworldState:boulderIntoHole in src/world/OverworldController.lua;
-- no per-map onEnter hook is needed here.

local M = {}

M.VERMILION_GYM = {
  onEnter = function(game, ow)
    if not game.save.flags.EVENT_2ND_LOCK_OPENED then
      ow:replaceBlock(2, 2, 36) -- $24: the closed double door
    end
  end,
}

return M
