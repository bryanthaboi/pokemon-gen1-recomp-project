-- Driver: the options screen with the port's audio rows (MUSIC VOL /
-- SFX VOL / MUSIC FILTER) to prove the 4-box viewport, the ▼ scroll
-- marker, and CANCEL fixed on the bottom line.  The menu is pushed
-- directly (title-menu row order shifts when a save file exists, so
-- blind taps are unreliable).
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local DIR = os.getenv("SHOT_DIR") or "/tmp/shots"
  U.teleport(game, "PALLET_TOWN", 10, 8, "down")
  local OptionsMenu = require("src.ui.OptionsMenu")
  game.stack:push(OptionsMenu.new(game))
  U.wait(5)
  U.shot(game, DIR .. "/options_0_top.png")
  for _ = 1, 4 do U.tap(game, "down"); U.wait(2) end
  U.shot(game, DIR .. "/options_1_musicvol.png") -- scrolled, ▼ visible
  U.tap(game, "left"); U.wait(2)
  U.tap(game, "left"); U.wait(2)
  U.shot(game, DIR .. "/options_2_musicvol_5.png")
  U.tap(game, "down"); U.wait(2)
  U.tap(game, "down"); U.wait(2)
  U.tap(game, "right"); U.wait(2) -- MUSIC FILTER -> 1X
  U.shot(game, DIR .. "/options_3_filter_1x.png")
  U.tap(game, "down"); U.wait(2) -- CANCEL, tail rows behind it
  U.shot(game, DIR .. "/options_4_cancel.png")
end
