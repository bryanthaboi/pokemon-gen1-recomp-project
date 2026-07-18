-- Driver: trainer sight-line walk-up timing (home/trainers.asm
-- CheckFightingMapTrainers).  Teleports to Route 3 one tile outside the
-- range-2 sight line of the Youngster at (10,6) (faces right), then walks
-- left INTO the line while keeping the d-pad held.  The player must
-- freeze on the detection tile (12,6): the "!" shows, the trainer walks
-- exactly one step to (11,6) and the battle text opens -- the held
-- direction must never buy another step.

return function(game)
  local U = dofile("tests/drivers/util.lua")
  local DIR = os.getenv("SHOT_DIR") or "/tmp/shots"
  U.teleport(game, "ROUTE_3", 13, 6, "left")
  local ow = game.overworld
  U.shot(game, DIR .. "/sight_0_before.png")

  -- hold left well past detection (step 16f + detect 1f + bubble 60f)
  U.hold(game, "left", 30)
  U.log("at-detect pos:", ow.player.cellX, ow.player.cellY,
        "engaging:", tostring(ow.engaging),
        "emote:", tostring(ow.emote and ow.emote.frames))
  U.shot(game, DIR .. "/sight_1_exclaim.png")
  U.hold(game, "left", 60)
  U.log("post-bubble pos:", ow.player.cellX, ow.player.cellY,
        "moving:", tostring(ow.player.moving))
  U.shot(game, DIR .. "/sight_2_walkup.png")

  -- let the walk-up finish and the pre-battle text open
  U.wait(40)
  U.shot(game, DIR .. "/sight_3_text.png")
  local trainer
  for _, npc in ipairs(ow.npcs) do
    if npc.def.index == 2 then trainer = npc end
  end
  U.log("final player:", ow.player.cellX, ow.player.cellY,
        "trainer:", trainer and trainer.cellX, trainer and trainer.cellY,
        "facing:", trainer and trainer.facing,
        "top-is-overworld:", tostring(game.stack:top() == ow))
end
