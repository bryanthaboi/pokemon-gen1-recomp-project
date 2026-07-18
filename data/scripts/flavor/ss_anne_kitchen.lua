-- SS Anne kitchen cook flavor dialogue.
-- pokered/scripts/SSAnneKitchen.asm SSAnneKitchenCook7Text

local function push(game, s, done)
  local TextBox = require("src.render.TextBox")
  game.stack:push(TextBox.new(game, s, done))
end

return {
  SS_ANNE_KITCHEN = {
    talk = {
      -- pokered/scripts/SSAnneKitchen.asm SSAnneKitchenCook7Text (text_asm):
      -- always shows the "main course is" lead-in
      -- (_SSAnneKitchenCook7MainCourseIsText), then rolls hRandomAdd to
      -- pick the dish: bit 7 set (~50%) -> Salmon du Salad, else bit 4
      -- set (~25%) -> Eels au Barbecue, else (~25%) -> Prime Beef Steak.
      -- The three dish texts (SSAnneKitchenCook7SalmonDuSaladText /
      -- ...EelsAuBarbecueText / ...PrimeBeefSteakText) aren't extracted
      -- into data/generated/text.lua (no leading underscore in
      -- pokered/text/SSAnneKitchen.asm), so their literal strings are
      -- ported here verbatim.
      TEXT_SSANNEKITCHEN_COOK7 = function(game, ow, npc, done)
        local t = game.data.text
        push(game, t._SSAnneKitchenCook7MainCourseIsText
          or "Er-hem! Indeed I\nam le CHEF!\fLe main course is", function()
          local roll = math.random(1, 4)
          local dish
          if roll <= 2 then
            -- bit 7 of hRandomAdd set (~50%)
            dish = "Salmon du Salad!\fLes guests may\ngripe it's fish\vagain, however!"
          elseif roll == 3 then
            -- bit 4 set, bit 7 clear (~25%)
            dish = "Eels au Barbecue!\fLes guests will\nmutiny, I fear."
          else
            -- neither bit set (~25%)
            dish = "Prime Beef Steak!\fBut, have I enough\nfillets du beef?"
          end
          push(game, dish, done)
        end)
      end,
    },
  },
}
