-- Driver: Hall of Fame end credits (engine/movie/credits.asm),  the
-- screen-by-screen fades, mon silhouette wipes, copyright block, THE END,
-- the autosave while THE END is up, and the post-credits soft reset
-- (`jp Init`) back to the boot sequence.  Fast-forwards the credits state
-- directly (a real-time run is ~95s) and screenshots the key beats.

return function(game)
  local U = dofile("tests/drivers/util.lua")
  local DIR = os.getenv("SHOT_DIR") or "/tmp/shots"

  -- don't clobber a real save: restore (or remove) save.lua afterwards
  local prevSave = love.filesystem.read("save.lua")

  U.teleport(game, "HALL_OF_FAME", 4, 2, "right")
  local ow = game.overworld
  game.save.party = { { species = "PIKACHU", level = 81 } }
  -- run the tail of the room script directly (the walk + Oak speech is
  -- story.lua's queued cutscene in normal play)
  ow.runner:run({ { "record_hall_of_fame" } })
  U.wait(2)
  U.shot(game, DIR .. "/credits_0_induction.png")

  -- A through the induction until the credits state is on top
  local Credits = require("src.ui.Credits")
  local credits
  for _ = 1, 60 do
    local top = game.stack:top()
    if getmetatable(top) == Credits then credits = top break end
    U.tap(game, "a")
    U.wait(2)
  end
  if not credits then
    U.log("FAIL: credits state never appeared")
    return
  end

  -- fast-forward helper: step the credits state without waiting realtime
  local function ffUntil(cond, cap)
    for _ = 1, cap or 20000 do
      if cond() then break end
      credits:update(1 / 60)
    end
    U.wait(1) -- render one real frame for the screenshot
  end

  ffUntil(function() return credits.phase == "intro" end)
  U.shot(game, DIR .. "/credits_1_bars.png")

  ffUntil(function() return credits.phase == "fade" end)
  for _ = 1, 8 do credits:update(1 / 60) end -- mid-fade (shade 1/3)
  U.wait(1)
  U.shot(game, DIR .. "/credits_2_fade_in.png")

  ffUntil(function() return credits.phase == "hold" end)
  U.shot(game, DIR .. "/credits_3_page1.png")

  ffUntil(function() return credits.phase == "wipe" end)
  for _ = 1, 12 do credits:update(1 / 60) end -- silhouette mid-screen
  U.wait(1)
  U.shot(game, DIR .. "/credits_4_mon_wipe.png")

  ffUntil(function() return credits.index == 4 and credits.phase == "hold" end)
  U.shot(game, DIR .. "/credits_5_plain_page.png")

  ffUntil(function() return credits.index == 35 and credits.phase == "hold" end)
  U.shot(game, DIR .. "/credits_6_copyright.png")

  ffUntil(function() return credits.phase == "end_hold" end)
  U.shot(game, DIR .. "/credits_7_the_end.png")
  U.log("save written:", love.filesystem.getInfo("save.lua") ~= nil,
        "lastHeal:", game.save.lastHeal and game.save.lastHeal.map)

  ffUntil(function() return credits.phase == "end_wait" end)
  U.tap(game, "a")
  U.wait(5)
  local top = game.stack:top()
  U.log("post-credits top state:",
        top == game.overworld and "overworld" or tostring(top and "boot" or "none"),
        "stack depth:", #game.stack.states)
  U.shot(game, DIR .. "/credits_8_soft_reset.png")

  if prevSave then
    love.filesystem.write("save.lua", prevSave)
  else
    love.filesystem.remove("save.lua")
  end
  U.log("done")
end
