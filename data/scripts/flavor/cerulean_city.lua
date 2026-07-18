-- Cerulean City flavor dialogue (pokered/scripts/CeruleanCity.asm)
--
-- Both NPCs use text_asm with an hRandomAdd roll to pick one of several
-- flavor lines (no flags, no branching outcome) -- ported as a weighted
-- math.random pick each time the NPC is talked to.

local M = {}

local function push(game, ow, npc, done, text)
  local TextBox = require("src.render.TextBox")
  npc:facePlayer(ow.player)
  game.stack:push(TextBox.new(game, text, done))
end

M.CERULEAN_CITY = {
  talk = {
    -- CeruleanCityCooltrainerF1Text (scripts/CeruleanCity.asm:362-393)
    -- cp 180 -> 76/256 chance of 1st; cp 100 -> 80/256 chance of 2nd;
    -- else 100/256 chance of 3rd.
    TEXT_CERULEANCITY_COOLTRAINER_F1 = function(game, ow, npc, done)
      local t = game.data.text
      local roll = math.random(0, 255)
      local text
      if roll >= 180 then
        text = t._CeruleanCityCooltrainerF1SlowbroUseSonicboomText
      elseif roll >= 100 then
        text = t._CeruleanCityCooltrainerF1SlowbroPunchText
      else
        text = t._CeruleanCityCooltrainerF1SlowbroWithdrawText
      end
      push(game, ow, npc, done, text)
    end,

    -- CeruleanCitySlowbroText (scripts/CeruleanCity.asm:395-436)
    -- cp 180 -> 76/256 chance of 1st; cp 120 -> 60/256 chance of 2nd;
    -- cp 60 -> 60/256 chance of 3rd; else 60/256 chance of 4th.
    TEXT_CERULEANCITY_SLOWBRO = function(game, ow, npc, done)
      local t = game.data.text
      local roll = math.random(0, 255)
      local text
      if roll >= 180 then
        text = t._CeruleanCitySlowbroTookASnoozeText
      elseif roll >= 120 then
        text = t._CeruleanCitySlowbroIsLoafingAroundText
      elseif roll >= 60 then
        text = t._CeruleanCitySlowbroTurnedAwayText
      else
        text = t._CeruleanCitySlowbroIgnoredOrdersText
      end
      push(game, ow, npc, done, text)
    end,
  },
}

return M
