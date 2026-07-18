-- Driver: the Oak speech from NEW GAME through the shrink-away beat
-- (engine/movie/oak_speech/oak_speech.asm .next): RedPicFront ->
-- ShrinkPic1 -> ShrinkPic2 -> walking sprite -> fade to white ->
-- Pallet Town.
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local DIR = os.getenv("SHOT_DIR") or "/tmp/shots"

  U.wait(5)
  U.tap(game, "start") -- skip intro movie
  U.wait(10)
  U.tap(game, "a") -- title -> menu
  U.wait(5)
  -- with an existing save the menu is CONTINUE / NEW GAME / OPTION
  local ok, saved = pcall(function()
    return require("src.core.SaveData").load() ~= nil
  end)
  if ok and saved then U.tap(game, "down") U.wait(3) end
  U.tap(game, "a") -- NEW GAME
  U.wait(10)

  -- mash through the speech + both naming screens (preset 1)
  local function top() return game.stack:top() end
  local function speechState()
    for _, s in ipairs(game.stack.states or {}) do
      if s.shrink ~= nil or s.oakPic ~= nil then return s end
    end
  end
  for _ = 1, 400 do
    local s = speechState()
    if s and s.step and s.step >= 9 then break end
    U.tap(game, "a")
    U.wait(2)
  end

  -- the shrink beat: captures aimed at each timeline window, with the
  -- exact frame logged so the windows can be verified
  local s = speechState()
  local function frameNow()
    return (s and s.shrink and s.shrink.frame) or -1
  end
  U.log("shrink beat entered:", tostring(s ~= nil and s.shrink ~= nil),
        "frame:", frameNow())
  U.shot(game, DIR .. "/shrink_1_redpic.png")   -- frames 1-4: RedPicFront
  U.log("shot1 frame:", frameNow())
  U.wait(3)
  U.shot(game, DIR .. "/shrink_2_pic1.png")     -- frames 5-8: ShrinkPic1
  U.log("shot2 frame:", frameNow())
  U.wait(8)
  U.shot(game, DIR .. "/shrink_3_pic2.png")     -- frames 9-28: ShrinkPic2
  U.log("shot3 frame:", frameNow())
  U.wait(25)
  U.shot(game, DIR .. "/shrink_4_sprite.png")   -- frames 29-78: walk sprite
  U.log("shot4 frame:", frameNow())
  U.wait(43)
  U.shot(game, DIR .. "/shrink_5_fade.png")     -- frames 79-102: fade
  U.log("shot5 frame:", frameNow())
  U.wait(15)
  U.wait(30)
  U.shot(game, DIR .. "/shrink_6_overworld.png")
  U.log("after speech: top==overworld:", tostring(top() == game.overworld),
        "map:", game.overworld and game.overworld.map
                and game.overworld.map.id or "?")
end
