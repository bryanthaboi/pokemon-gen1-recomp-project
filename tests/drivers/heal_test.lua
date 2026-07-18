-- Driver: Pokémon Center nurse heal,  welcome/choice dialogue, the
-- machine monitor + per-mon balls, the jingle flash, and the farewell.
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local DIR = os.getenv("SHOT_DIR") or "/tmp/shots"
  local Pokemon = require("src.pokemon.Pokemon")
  local ChoiceBox = require("src.ui.ChoiceBox")
  local mon = Pokemon.new(game.data, "CHARMANDER", 12)
  mon.hp = 3
  table.insert(game.save.party, mon)
  local mon2 = Pokemon.new(game.data, "PIDGEY", 8)
  mon2.hp = 1
  table.insert(game.save.party, mon2)
  U.teleport(game, "VIRIDIAN_POKECENTER", 3, 3, "up")
  local ow = game.overworld

  -- mash A until a condition holds
  local function mashUntil(cond)
    for _ = 1, 400 do
      if cond() then return true end
      U.tap(game, "a")
      U.wait(3)
    end
    return false
  end

  U.tap(game, "a") -- talk to the nurse
  U.wait(30)
  U.shot(game, DIR .. "/heal_00_welcome.png")
  U.log("choice reached:", mashUntil(function()
    return getmetatable(game.stack:top()) == ChoiceBox
  end))
  U.shot(game, DIR .. "/heal_01_choice.png")
  U.tap(game, "a") -- YES
  U.log("machine started:", mashUntil(function()
    return ow.healAnim ~= nil
  end))
  U.shot(game, DIR .. "/heal_02_ball1.png")
  U.wait(28)
  U.shot(game, DIR .. "/heal_03_ball2.png")
  -- overlay must stay glued to the machine under survey zoom
  game:zoomStep(-1); game:zoomStep(-1)
  U.wait(3)
  U.shot(game, DIR .. "/heal_03z_zoomed.png")
  local Zoom = require("src.render.Zoom")
  Zoom.reset()
  U.wait(3)
  U.wait(35)
  U.shot(game, DIR .. "/heal_04_flash_a.png")
  U.wait(10)
  U.shot(game, DIR .. "/heal_05_flash_b.png")
  U.wait(10)
  U.shot(game, DIR .. "/heal_06_flash_c.png")
  -- wait out the jingle + 32-frame beat
  for _ = 1, 40 do
    if not ow.healAnim then break end
    U.wait(10)
  end
  U.shot(game, DIR .. "/heal_07_fit.png")
  U.log("farewell reached:", mashUntil(function()
    return game.stack:top() == ow
  end))
  U.shot(game, DIR .. "/heal_08_end.png")
end
