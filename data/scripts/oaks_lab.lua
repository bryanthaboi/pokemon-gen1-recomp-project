-- Hand-ported from pret/pokered scripts/OaksLab.asm.  All text is real
-- extracted text.
--
-- * Starter poke balls (objects 2-4): ask, give the real species, flag,
--   then the rival's counter-pick: he steps to the countering ball,
--   takes it ("I'll take this one, then!") and both balls disappear.
--   Source: scripts/OaksLab.asm OaksLabCharmanderPokeBallText /
--   OaksLabRivalTakePokeBallScript.
-- * Rival (object 1): before starter -> "gramps isn't around"; with
--   starter -> taunt + battle OPP_RIVAL1 with the counter-pick party
--   (player Bulbasaur -> rival Charmander etc., parties 1/2/3 =
--   Squirtle/Bulbasaur/Charmander in data/trainers/parties.asm);
--   afterwards HealParty + flag always, then he gloats or sulks and
--   marches out (OaksLabRivalEndBattleScript).  A loss does not black out.

-- ball objects: CHARMANDER (6,3), SQUIRTLE (7,3), BULBASAUR (8,3);
-- rival = object 1 at (4,3).  rivalBallX is the counter-pick's column.
local function starterBall(askText, species, choseFlag, ownBall,
                           rivalBallX, rivalBall)
  return {
    { "check_flag", "EVENT_GOT_STARTER" },        -- 1
    { "jump_if_true", 20 },                       -- 2
    -- no picking until Oak has walked you in (OaksLabScript gating)
    { "check_flag", "EVENT_FOLLOWED_OAK_INTO_LAB" }, -- 3
    { "jump_if_false", 20 },                      -- 4
    -- the Pokédex "new species" entry shows before the ask (predef
    -- StarterDex ahead of OaksLabYouWant...Text).  StarterDex temporarily
    -- sets the owned bits so ShowPokedexData prints height/weight/text;
    -- forceOwned is that bypass without mutating save.pokedex.owned.
    { "push_screen", "DexEntryMenu",
      { species = species, forceOwned = true } }, -- 5
    { "ask", askText },                           -- 6
    { "jump_if_false", 21 },                      -- 7
    { "give_pokemon", species, 5 },               -- 8
    { "set_flag", "EVENT_GOT_STARTER" },          -- 9
    { "set_flag", choseFlag },                    -- 10
    -- POKé BALLs are not handed out here in the original -- Oak gives
    -- them later, at OaksLabOak1Text's .give_poke_balls beat once the
    -- player has beaten the Route 22 rival (see TEXT_OAKSLAB_OAK1 below)
    { "show_text", "_OaksLabReceivedMonText", { RAM = species } }, -- 11
    { "hide_object", "OAKS_LAB", ownBall },       -- 12
    -- the rival walks to the countering ball (around the furniture)
    { "move_npc_to", 1, rivalBallX, 4 },          -- 13
    { "face_object", 1, "up" },                   -- 14
    { "show_text", "_OaksLabRivalIllTakeThisOneText" },            -- 15
    { "hide_object", "OAKS_LAB", rivalBall },     -- 16
    { "show_text", "_OaksLabRivalReceivedMonText",
      { RAM = rivalBall == "OAKSLAB_CHARMANDER_POKE_BALL" and "CHARMANDER"
              or rivalBall == "OAKSLAB_SQUIRTLE_POKE_BALL" and "SQUIRTLE"
              or "BULBASAUR" } },                 -- 17
    { "jump", 21 },                               -- 18
    { "jump", 21 },                               -- 19 (spacer)
    { "show_text", "_OaksLabThoseArePokeBallsText" }, -- 20
  }
end

return {
  talk = {
    -- Oak: accepts the parcel and hands over the Pokédex, then (once the
    -- player has beaten the Route 22 rival) hands over the real POKé
    -- BALLs (scripts/OaksLab.asm OaksLabOak1Text, simplified: no rival
    -- recall / dex-rating / "pokemon can fight" / "around the world"
    -- branches -- see docs/known-differences.md)
    TEXT_OAKSLAB_OAK1 = {
      { "face_player" },                                          -- 1
      { "check_flag", "EVENT_GOT_OAKS_PARCEL" },                  -- 2
      { "jump_if_false", 16 },                                    -- 3
      { "check_flag", "EVENT_OAK_GOT_PARCEL" },                   -- 4
      { "jump_if_true", 16 },                                     -- 5
      { "show_text", "_OaksLabOak1DeliverParcelText" },           -- 6
      { "take_item", "OAKS_PARCEL", 1 },                          -- 7
      { "set_flag", "EVENT_OAK_GOT_PARCEL" },                     -- 8
      { "show_text", "_OaksLabOak1PokemonAroundTheWorldText" },   -- 9
      { "set_flag", "EVENT_GOT_POKEDEX" },                        -- 10
      -- OaksLab.asm OakGivesPokedex: HideObject TOGGLE_POKEDEX_1/2
      -- so the table sprites leave with the gift (#106).
      { "hide_object", "OAKS_LAB", "OAKSLAB_POKEDEX1" },          -- 11
      { "hide_object", "OAKS_LAB", "OAKSLAB_POKEDEX2" },          -- 12
      -- the Pokédex swaps Viridian's two old men (OaksLab.asm:602-606:
      -- HideObject TOGGLE_LYING_OLD_MAN / ShowObject TOGGLE_OLD_MAN).
      -- Until this ran, the walking man at (17,5) -- who owns the coffee
      -- ask and the catch tutorial -- stayed OFF for the whole game
      -- (toggleable_objects.asm seeds him OFF, the sleeper ON).
      { "hide_object", "VIRIDIAN_CITY", "VIRIDIANCITY_OLD_MAN_SLEEPY" }, -- 13
      { "show_object", "VIRIDIAN_CITY", "VIRIDIANCITY_OLD_MAN" },  -- 14
      { "jump", "end" },                                          -- 15
      { "check_flag", "EVENT_GOT_STARTER" },                      -- 16
      { "jump_if_false", 31 },                                    -- 17
      { "check_item", "POKE_BALL" },                              -- 18
      { "jump_if_true", 29 },                                     -- 19
      { "check_flag", "EVENT_BEAT_ROUTE22_RIVAL_1ST_BATTLE" },    -- 20
      { "jump_if_false", 33 },                                    -- 21
      { "check_flag", "EVENT_GOT_POKEBALLS_FROM_OAK" },           -- 22
      { "jump_if_true", 29 },                                     -- 23
      { "set_flag", "EVENT_GOT_POKEBALLS_FROM_OAK" },             -- 24
      { "give_item", "POKE_BALL", 5, false },                     -- 25
      { "show_text", "_OaksLabOak1ReceivedPokeballsText" },       -- 26
      { "show_text", "_OaksLabGivePokeballsExplanationText" },    -- 27
      { "jump", "end" },                                          -- 28
      { "show_text", "_OaksLabOak1ComeSeeMeSometimesText" },      -- 29
      { "jump", "end" },                                          -- 30
      { "show_text", "_OaksLabOak1WhichPokemonDoYouWantText" },   -- 31
      { "jump", "end" },                                          -- 32
      { "show_text", "_OaksLabOak1RaiseYourYoungPokemonText" },   -- 33
    },

    TEXT_OAKSLAB_CHARMANDER_POKE_BALL =
      starterBall("_OaksLabYouWantCharmanderText", "CHARMANDER", "EVENT_CHOSE_CHARMANDER",
                  "OAKSLAB_CHARMANDER_POKE_BALL", 7, "OAKSLAB_SQUIRTLE_POKE_BALL"),
    TEXT_OAKSLAB_SQUIRTLE_POKE_BALL =
      starterBall("_OaksLabYouWantSquirtleText", "SQUIRTLE", "EVENT_CHOSE_SQUIRTLE",
                  "OAKSLAB_SQUIRTLE_POKE_BALL", 8, "OAKSLAB_BULBASAUR_POKE_BALL"),
    TEXT_OAKSLAB_BULBASAUR_POKE_BALL =
      starterBall("_OaksLabYouWantBulbasaurText", "BULBASAUR", "EVENT_CHOSE_BULBASAUR",
                  "OAKSLAB_BULBASAUR_POKE_BALL", 6, "OAKSLAB_CHARMANDER_POKE_BALL"),

    TEXT_OAKSLAB_RIVAL = {
      { "face_player" },                                          -- 1
      { "check_flag", "EVENT_GOT_STARTER" },                      -- 2
      { "jump_if_false", 21 },                                    -- 3
      { "check_flag", "EVENT_BATTLED_RIVAL_IN_OAKS_LAB" },        -- 4
      { "jump_if_true", 19 },                                     -- 5
      { "show_text", "_OaksLabRivalMyPokemonLooksStrongerText" }, -- 6
      { "check_flag", "EVENT_CHOSE_BULBASAUR" },                  -- 7
      { "jump_if_false", 11 },                                    -- 8
      { "start_battle", "trainer", "OPP_RIVAL1", 3 },             -- 9  Charmander
      { "jump", 16 },                                             -- 10
      { "check_flag", "EVENT_CHOSE_SQUIRTLE" },                   -- 11
      { "jump_if_false", 15 },                                    -- 12
      { "start_battle", "trainer", "OPP_RIVAL1", 2 },             -- 13 Bulbasaur
      { "jump", 16 },                                             -- 14
      { "start_battle", "trainer", "OPP_RIVAL1", 1 },             -- 15 Squirtle
      -- OaksLabRivalEndBattleScript: HealParty + flag, then exit either way
      { "heal_party" },                                           -- 16
      { "set_flag", "EVENT_BATTLED_RIVAL_IN_OAKS_LAB" },          -- 17
      { "jump", 23 },                                             -- 18
      { "show_text", "_OaksLabRivalFedUpWithWaitingText" },       -- 19
      { "jump", "end" },                                          -- 20
      { "show_text", "_OaksLabRivalGrampsIsntAroundText" },       -- 21
      { "jump", "end" },                                          -- 22
      -- win: sulk text then exit; loss: Rival1WinText already played in
      -- battle (HandlePlayerBlackOut), so skip straight to the walk-out
      { "jump_if_false", 25 },                                    -- 23
      { "show_text", "_OaksLabRivalIPickedTheWrongPokemonText" }, -- 24
      { "move_npc_to", 1, 4, 11 },                                -- 25
      { "hide_object", "OAKS_LAB", "OAKSLAB_RIVAL" },             -- 26
    },
  },

  -- Saves that got the Pokédex before #106 never wrote objectToggles for
  -- the table sprites; re-entering the lab applies the same HideObject
  -- the gift script now does (OaksLab.asm OakGivesPokedex).
  onEnter = function(game, ow)
    if not (game.save.flags and game.save.flags.EVENT_GOT_POKEDEX) then
      return
    end
    local Commands = require("src.script.Commands")
    local ctx = { save = game.save, game = game, overworld = ow }
    Commands.hide_object(ctx, "OAKS_LAB", "OAKSLAB_POKEDEX1")
    Commands.hide_object(ctx, "OAKS_LAB", "OAKSLAB_POKEDEX2")
  end,

  -- Oak stops you leaving without a starter; the rival stops you on
  -- the way out for the first battle (scripts/OaksLab.asm
  -- OaksLabScript8 / OaksLabRivalChallenge)
  onStep = function(game, ow, x, y)
    local flags = game.save.flags
    -- Oak blocks the exit mats (4,11)/(5,11) until you take a starter
    if flags.EVENT_FOLLOWED_OAK_INTO_LAB and not flags.EVENT_GOT_STARTER
       and y == 11 and (x == 4 or x == 5) then
      ow.runner:run({
        { "show_text", "_OaksLabOakDontGoAwayYetText" },
        { "move_player", "up", 1 },
      }, {})
      return true
    end
    -- the challenge fires as soon as the player steps away from the
    -- table (OaksLabRivalChallengesPlayerScript: wYCoord == 6)
    if flags.EVENT_GOT_STARTER and not flags.EVENT_BATTLED_RIVAL_IN_OAKS_LAB
       and y >= 6 then
      local rival = ow:npcByIndex(1)
      if not rival then return false end
      local rows = {
        { "show_text", "_OaksLabRivalIllTakeYouOnText" },         -- 1
      }
      -- the rival routes to a free cell beside the player
      local target
      for _, c in ipairs({ { x, y - 1 }, { x - 1, y }, { x + 1, y },
                           { x, y + 1 } }) do
        if ow.map:inBounds(c[1], c[2]) and ow.map:isWalkableCell(c[1], c[2]) then
          target = c
          break
        end
      end
      if target then
        table.insert(rows, { "move_npc_to", 1, target[1], target[2] })
      end
      table.insert(rows, { "face_object", 1,
                           target and target[2] < y and "down"
                           or target and target[2] > y and "up"
                           or target and target[1] < x and "right" or "left" })
      local base = #rows
      local party = flags.EVENT_CHOSE_BULBASAUR and 3
                    or flags.EVENT_CHOSE_SQUIRTLE and 2 or 1
      table.insert(rows, { "start_battle", "trainer", "OPP_RIVAL1", party })
      -- OaksLabRivalEndBattleScript: heal + flag on win or loss; no blackout
      table.insert(rows, { "heal_party" })
      table.insert(rows, { "set_flag", "EVENT_BATTLED_RIVAL_IN_OAKS_LAB" })
      -- win: sulk text then exit; loss jumps to the walk-out (taunt was
      -- already shown in-battle via Rival1WinText)
      table.insert(rows, { "jump_if_false", base + 6 })
      table.insert(rows, { "show_text", "_OaksLabRivalIPickedTheWrongPokemonText" })
      table.insert(rows, { "move_npc_to", 1, 4, 11 })
      table.insert(rows, { "hide_object", "OAKS_LAB", "OAKSLAB_RIVAL" })
      ow.runner:run(rows, { npc = rival })
      return true
    end
    return false
  end,
}
