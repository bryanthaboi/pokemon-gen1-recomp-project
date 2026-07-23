-- Hand-ported story-critical scripts, one table per map, all using real
-- extracted text.  Each cites its pokered source.  Registered in
-- data/scripts/init.lua.

local M = {}

-- -------------------------------------------------------------------
-- Oak's Parcel chain (scripts/ViridianMart.asm, OaksLab.asm,
-- ViridianCity.asm)
-- -------------------------------------------------------------------

M.VIRIDIAN_MART = {
  -- scripts/ViridianMart.asm: the parcel hand-off is the map's DEFAULT
  -- script, not a talk.  Entering with a starter and no parcel runs
  -- ViridianMartDefaultScript -- the clerk calls out, then
  -- StartSimulatingJoypadStates walks the player to the counter
  -- (.PlayerMovement: PAD_LEFT 1, PAD_UP 2, door (3,7) -> counter (2,5))
  -- and ViridianMartOaksParcelScript hands the parcel over.  The player
  -- never presses A.  This matters beyond convenience: the parcel gates
  -- Oak's Pokedex and the old man clearing Route 2, so vanilla guarantees
  -- it on entry rather than letting you walk out without it.
  --
  -- The talk branch below is kept as the fallback for a save that reaches
  -- the counter without this having fired.
  onEnter = function(game, ow)
    local f = game.save.flags
    if f.EVENT_OAK_GOT_PARCEL or f.EVENT_GOT_OAKS_PARCEL then return end
    if not f.EVENT_GOT_STARTER then return end
    ow:queueScript({
      { "show_text", "_ViridianMartClerkYouCameFromPalletTownText" },
      { "move_player", "left", 1 },
      { "move_player", "up", 2 },
      -- the quest text's last page is "{PLAYER} got\nOAK's PARCEL!"
      { "give_item", "OAKS_PARCEL", 1, "_ViridianMartClerkParcelQuestText" },
      { "set_flag", "EVENT_GOT_OAKS_PARCEL" },
    })
  end,
  talk = {
    TEXT_VIRIDIANMART_CLERK = {
      { "check_flag", "EVENT_OAK_GOT_PARCEL" },                       -- 1
      { "jump_if_true", 11 },                                         -- 2
      { "check_flag", "EVENT_GOT_OAKS_PARCEL" },                      -- 3
      { "jump_if_true", 13 },                                         -- 4
      { "check_flag", "EVENT_GOT_STARTER" },                          -- 5
      { "jump_if_false", 11 },                                        -- 6
      { "show_text", "_ViridianMartClerkYouCameFromPalletTownText" }, -- 7
      -- the parcel-quest text's last page is "{PLAYER} got\nOAK's
      -- PARCEL!" (scripts/ViridianMart.asm, sound_get_key_item)
      { "give_item", "OAKS_PARCEL", 1, "_ViridianMartClerkParcelQuestText" }, -- 8
      { "set_flag", "EVENT_GOT_OAKS_PARCEL" },                        -- 9
      { "jump", 14 },                                                 -- 10
      { "open_mart", "TEXT_VIRIDIANMART_CLERK" },                     -- 11
      { "jump", 14 },                                                 -- 12
      { "show_text", "_ViridianMartClerkSayHiToOakText" },            -- 13
    },
  },
}

M.VIRIDIAN_CITY = {
  talk = {
    -- The GAMBLER_ASLEEP at (18,9) (ViridianCityOldManSleepyText): he
    -- only ever grumbles and shoves you back down -- he never wakes,
    -- moves or hides.  The coffee ask and the catch tutorial belong to
    -- the *other* old man, the walking SPRITE_GAMBLER at (17,5)
    -- (TEXT_VIRIDIANCITY_OLD_MAN, below).  The two are swapped by the
    -- Pokédex in data/scripts/oaks_lab.lua, not by talking to either.
    TEXT_VIRIDIANCITY_OLD_MAN_SLEEPY = {
      { "show_text", "_ViridianCityOldManSleepyPrivatePropertyText" },   -- 1
      { "move_player", "down", 1 },                                     -- 2
    },

    -- The walking old man at (17,5), shown once the Pokédex swaps him in
    -- (ViridianCityOldManText).  "Are you in a hurry?" -- YES brushes you
    -- off, NO leads into the catch tutorial: he explains, demos a catch
    -- on a wild WEEDLE (BATTLE_TYPE_OLD_MAN), then comments afterwards.
    -- pokered prints YouNeedToWeakenTheTarget *after* the demo battle
    -- (ViridianCityOldManEndCatchTrainingScript), not before it.
    TEXT_VIRIDIANCITY_OLD_MAN = {
      { "face_player" },                                                 -- 1
      { "ask", "_ViridianCityOldManHadMyCoffeeNowText" },                -- 2
      { "jump_if_true", 8 },                                             -- 3 (yes = in a hurry)
      { "show_text", "_ViridianCityOldManKnowHowToCatchPokemonText" },   -- 4
      { "old_man_demo" },                                                -- 5
      { "show_text", "_ViridianCityOldManYouNeedToWeakenTheTargetText" },-- 6
      { "jump", 9 },                                                     -- 7
      { "show_text", "_ViridianCityOldManTimeIsMoneyText" },             -- 8 (9 = end)
    },
  },
  -- ViridianCityCheckGotPokedexScript: the north corridor is gated on
  -- EVENT_GOT_POKEDEX, NOT on the sleeper being hidden, and it triggers
  -- on exactly one cell -- (19,9), the gap east of the sleeper (18,9)
  -- and the girl (17,9).  With the Pokédex the check returns immediately
  -- and you simply walk past at x=19.
  onStep = function(game, ow, x, y)
    if game.save.flags and game.save.flags.EVENT_GOT_POKEDEX then return false end
    if x ~= 19 or y ~= 9 then return false end
    local TextBox = require("src.render.TextBox")
    game.stack:push(TextBox.new(game,
      game.data.text._ViridianCityOldManSleepyPrivatePropertyText
      or "You can't go\nthrough here!\fThis is private\nproperty!",
      function() ow:scriptMove(ow.player, "down", 1) end))
    return true
  end,
}

-- -------------------------------------------------------------------
-- Bill's SS ticket (scripts/BillsHouse.asm; the cell-separation cutscene
-- is compressed into the dialogue)
-- -------------------------------------------------------------------

-- Daisy hands over the TOWN MAP once Oak's errand is under way
-- (scripts/BluesHouse.asm BluesHouseDaisySittingText)
M.BLUES_HOUSE = {
  talk = {
    TEXT_BLUESHOUSE_DAISY_SITTING = {
      { "face_player" },                                     -- 1
      { "check_flag", "EVENT_GOT_TOWN_MAP" },                -- 2
      { "jump_if_true", 10 },                                -- 3
      { "check_flag", "EVENT_GOT_STARTER" },                 -- 4
      { "jump_if_false", 12 },                               -- 5
      { "show_text", "_BluesHouseDaisyOfferMapText" },       -- 6
      -- _GotMapText: "{PLAYER} got a\n{RAM:wStringBuffer}!" -- the
      -- buffer supplies "TOWN MAP" (scripts/BluesHouse.asm GotMapText)
      { "give_item", "TOWN_MAP", 1, "_GotMapText" },         -- 7
      { "set_flag", "EVENT_GOT_TOWN_MAP" },                  -- 8
      { "jump", 13 },                                        -- 9
      { "show_text", "_BluesHouseDaisyUseMapText" },         -- 10
      { "jump", 13 },                                        -- 11
      { "show_text", "_BluesHouseDaisyRivalAtLabText" },     -- 12
    },
  },
}

M.BILLS_HOUSE = {
  talk = {
    -- BillsHouseBillPokemonText: "I'm not a POKéMON!", a YES/NO choice
    -- (NO only adds "No, you gotta help!" before rejoining the YES
    -- path), then the "get in the TELEPORTER" line and the monster
    -- walking into the cell-separator machine
    -- (BillsHousePokemonWalkToMachineScript: up 3, or around the player
    -- when they stand in the way facing down), where it is hidden and
    -- EVENT_BILL_SAID_USE_CELL_SEPARATOR arms the PC at (1,4) -- see
    -- OverworldState.billsHousePC for the separator itself.
    TEXT_BILLSHOUSE_BILL_POKEMON = function(game, ow, npc, done)
      local TextBox = require("src.render.TextBox")
      local t = game.data.text
      local function toMachine()
        game.stack:push(TextBox.new(game,
          t._BillsHouseBillUseSeparationSystemText
          or "When I'm in the\nTELEPORTER, run\nthe Cell\nSeparation System!", function()
          local function entered()
            local Commands = require("src.script.Commands")
            Commands.hide_object({ game = game, save = game.save,
                                   overworld = ow },
                                 "BILLS_HOUSE", "BILLSHOUSE_BILL_POKEMON")
            game.save.flags.EVENT_BILL_SAID_USE_CELL_SEPARATOR = true
            done()
          end
          if ow.player.facing == "down" then
            -- the player is standing on his straight path: walk around
            -- (.PokemonWalkAroundPlayerMovement)
            ow:scriptMove(npc, "right", 1, function()
              ow:scriptMove(npc, "up", 2, function()
                ow:scriptMove(npc, "left", 1, function()
                  ow:scriptMove(npc, "up", 1, entered)
                end)
              end)
            end)
          else
            ow:scriptMove(npc, "up", 3, entered)
          end
        end))
      end
      game.stack:push(TextBox.new(game,
        t._BillsHouseBillImNotAPokemonText or "Hey! I'm not a\nPOKéMON!",
        nil, { choice = function(yes)
          if yes then
            toMachine()
          else
            game.stack:push(TextBox.new(game,
              t._BillsHouseBillNoYouGottaHelpText
              or "No! You gotta\nhelp me!", toMachine))
          end
        end }))
    end,

    -- BillsHouseBillSSTicketText (human Bill after the separation)
    TEXT_BILLSHOUSE_BILL_SS_TICKET = {
      { "face_player" },                                           -- 1
      { "check_flag", "EVENT_GOT_SS_TICKET" },                     -- 2
      { "jump_if_true", 12 },                                      -- 3
      { "show_text", "_BillsHouseBillThankYouText" },              -- 4
      -- pokered gives first (GiveItem fills wStringBuffer), then prints
      -- the received text that reads it (scripts/BillsHouse.asm; the
      -- item id is S_S_TICKET in generated items.lua -- keyItem, so the
      -- sound_get_key_item jingle plays like BillsHouse.asm:196)
      { "give_item", "S_S_TICKET", 1, false },                     -- 5
      { "show_text", "_SSTicketReceivedText" },                    -- 6
      { "set_flag", "EVENT_GOT_SS_TICKET" },                       -- 7
      -- The two Cerulean guards are a SWAP PAIR, not scenery
      -- (BillsHouse.asm:174-178): handing over the ticket shows GUARD1 at
      -- (28,12) and hides GUARD2 at (27,12).  This matters far more than it
      -- looks: (27,12) is the ONLY walkable neighbour of the trashed
      -- house's south door at (27,11), and that house is one of the two
      -- ways through the fence that splits Cerulean in half (the badge
      -- house is the other).  Leaving GUARD2 up forever severs the city --
      -- the gym/mart half can never reach the Route 5 exit.
      -- Same swap fires after the TM28 Rocket (CeruleanCity_2.asm
      -- CeruleanHideRocket), so either route opens the path.
      { "show_object", "CERULEAN_CITY", "CERULEANCITY_GUARD1" },   -- 8
      { "hide_object", "CERULEAN_CITY", "CERULEANCITY_GUARD2" },   -- 9
      { "show_text", "_BillsHouseBillWhyDontYouGoInsteadOfMeText" }, -- 10
      { "jump", 13 },                                              -- 11
      { "show_text", "_BillsHouseBillWhyDontYouGoInsteadOfMeText" }, -- 12
    },

    TEXT_BILLSHOUSE_BILL_CHECK_OUT_MY_RARE_POKEMON = {
      { "face_player" },                                           -- 1
      { "show_text", "_BillsHouseBillCheckOutMyRarePokemonText" }, -- 2
    },
  },
  -- repair saves that already got the ticket under the old collapsed
  -- script (the monster never hidden, human Bill never shown)
  onEnter = function(game, ow)
    if game.save.flags.EVENT_GOT_SS_TICKET
       and not game.save.flags.EVENT_USED_CELL_SEPARATOR_ON_BILL then
      local Commands = require("src.script.Commands")
      local ctx = { game = game, save = game.save, overworld = ow }
      Commands.hide_object(ctx, "BILLS_HOUSE", "BILLSHOUSE_BILL_POKEMON")
      Commands.show_object(ctx, "BILLS_HOUSE", "BILLSHOUSE_BILL1")
      game.save.flags.EVENT_BILL_SAID_USE_CELL_SEPARATOR = true
      game.save.flags.EVENT_USED_CELL_SEPARATOR_ON_BILL = true
      game.save.flags.EVENT_MET_BILL = true
      game.save.flags.EVENT_MET_BILL_2 = true
    end
  end,
}

-- -------------------------------------------------------------------
-- SS Anne (scripts/VermilionCity.asm, SSAnne2F.asm,
-- SSAnneCaptainsRoom.asm)
-- -------------------------------------------------------------------

M.VERMILION_CITY = {
  -- VermilionCity_Script .setFirstLockTrashCanIndex (scripts/
  -- VermilionCity.asm): every load of this map re-rolls which Vermilion
  -- Gym trash can hides the first-lock switch (Random & $0e: a random
  -- EVEN can, 0-14).  The roll is unconditional -- pokered does not
  -- care whether the first lock is already open, because the index is
  -- only read while EVENT_1ST_LOCK_OPENED is unset (the gym is only
  -- reachable through this map, so a fresh visit always re-rolls).
  onEnter = function(game, ow)
    local puz = game.save.trashPuzzle or {}
    game.save.trashPuzzle = puz
    puz.first = love.math.random(0, 7) * 2
  end,
  -- VermilionCityDefaultScript's per-frame SSAnneTicketCheckCoords check:
  -- the unguarded cell (18,30) just west of the sailor leads straight
  -- onto the dock warp, so stepping onto it heading for the dock gets
  -- ticket-checked (and turned back once the ship has sailed) without
  -- the player ever pressing A.  The sailor himself never disappears.
  onStep = function(game, ow, x, y)
    if x ~= 18 or y ~= 30 then return false end
    if ow.player.facing ~= "down" then return false end
    local f = game.save.flags
    local t = game.data.text
    local TextBox = require("src.render.TextBox")
    if f.EVENT_SS_ANNE_LEFT then
      game.stack:push(TextBox.new(game,
        t._VermilionCitySailor1ShipSetSailText or "The ship set sail.",
        function() ow:scriptMove(ow.player, "up", 1) end))
      return true
    end
    if (game.save.inventory.S_S_TICKET or 0) > 0 then return false end
    game.stack:push(TextBox.new(game,
      (t._VermilionCitySailor1WelcomeToSSAnneText or "Welcome to S.S.\nANNE!")
      .. "\f"
      .. (t._VermilionCitySailor1YouNeedATicketText
          or "You need a ticket\nto get aboard."),
      function() ow:scriptMove(ow.player, "up", 1) end))
    return true
  end,
  talk = {
    -- the sailor guarding the dock gangway (VermilionCitySailor1Text):
    -- flashing the ticket just lets you through -- he never hides, and
    -- once the ship has sailed he only reports it gone
    TEXT_VERMILIONCITY_SAILOR1 = {
      { "face_player" },                                             -- 1
      { "check_flag", "EVENT_SS_ANNE_LEFT" },                        -- 2
      { "jump_if_true", 11 },                                        -- 3
      { "show_text", "_VermilionCitySailor1WelcomeToSSAnneText" },   -- 4
      { "check_item", "S_S_TICKET" },                                -- 5
      { "jump_if_false", 9 },                                        -- 6
      { "show_text", "_VermilionCitySailor1FlashedTicketText" },     -- 7
      { "jump", 12 },                                                -- 8
      { "show_text", "_VermilionCitySailor1YouNeedATicketText" },    -- 9
      { "jump", 12 },                                                -- 10
      { "show_text", "_VermilionCitySailor1ShipSetSailText" },       -- 11
    },
  },
}

M.SS_ANNE_2F = {
  talk = {
    TEXT_SSANNE2F_RIVAL = {
      { "face_player" },                                  -- 1
      { "check_flag", "EVENT_BEAT_SS_ANNE_RIVAL" },       -- 2
      { "jump_if_true", 9 },                              -- 3
      { "show_text", "_SSAnne2FRivalText" },              -- 4
      { "rival_battle", "OPP_RIVAL2", 1 },                -- 5
      { "jump_if_false", 10 },                            -- 6
      { "set_flag", "EVENT_BEAT_SS_ANNE_RIVAL" },         -- 7
      { "show_text", "_SSAnne2FRivalDefeatedText" },      -- 8
      { "jump", 10 },                                     -- 9 (already beaten: silent)
    },
  },
}

M.SS_ANNE_CAPTAINS_ROOM = {
  talk = {
    TEXT_SSANNECAPTAINSROOM_CAPTAIN = {
      { "check_flag", "EVENT_GOT_HM01" },                                 -- 1
      { "jump_if_true", 9 },                                              -- 2
      { "show_text", "_SSAnneCaptainsRoomRubCaptainsBackText" },          -- 3
      { "show_text", "_SSAnneCaptainsRoomCaptainIFeelMuchBetterText" },   -- 4
      -- give-then-print like scripts/SSAnneCaptainsRoom.asm (GiveItem
      -- fills wStringBuffer; the received text reads it)
      { "give_item", "HM_CUT", 1, false },                                -- 5
      { "show_text", "_SSAnneCaptainsRoomCaptainReceivedHM01Text" },      -- 6
      { "set_flag", "EVENT_GOT_HM01" },                                   -- 7
      { "jump", 10 },                                                     -- 8
      { "show_text", "_SSAnneCaptainsRoomCaptainNotSickAnymoreText" },    -- 9
    },
  },
}

-- -------------------------------------------------------------------
-- Pokémon Tower / Poké Flute (scripts/PokemonTower7F.asm,
-- MrFujisHouse.asm; the teleport back to his house is a warp)
-- -------------------------------------------------------------------

M.POKEMON_TOWER_7F = {
  talk = {
    TEXT_POKEMONTOWER7F_MR_FUJI = {
      { "face_player" },                                  -- 1
      { "show_text", "_PokemonTower7FMrFujiRescueText" }, -- 2
      { "set_flag", "EVENT_RESCUED_MR_FUJI" },            -- 3
      { "set_flag", "EVENT_RESCUED_MR_FUJI_2" },          -- 4
      -- pokered shows Fuji at home and swaps the Silph Co door
      -- guard (ROCKET8 on the door tile -> ROCKET9 beside it)
      { "show_object", "MR_FUJIS_HOUSE", "MRFUJISHOUSE_MR_FUJI" },   -- 5
      { "hide_object", "SAFFRON_CITY", "SAFFRONCITY_ROCKET8" },      -- 6
      { "show_object", "SAFFRON_CITY", "SAFFRONCITY_ROCKET9" },      -- 7
      -- pokered warps to wDestinationWarpID $1 (0-based) -- the house's
      -- SECOND warp, the door mat at (3,7) -- facing UP
      -- (PokemonTower7FWarpToMrFujiHouseScript: SPRITE_FACING_UP +
      -- hWarpDestinationMap MR_FUJIS_HOUSE). Landing (3,3) instead put
      -- the player at the Pokédex table, and the route's first waypoint
      -- (3,7) then stepped onto a LIVE door mat and exited the house
      -- before ever talking to Fuji -- so the POKE_FLUTE was never
      -- collected and the Route 16 SNORLAX sealed the map. The arrival
      -- mat itself is inert until stepped off (warpEntryCell), which is
      -- what makes the vanilla coordinates safe.
      { "warp", "MR_FUJIS_HOUSE", 3, 7, "up" },           -- 8
    },
  },
}

M.MR_FUJIS_HOUSE = {
  -- repair saves from before the rescue toggled him visible
  onEnter = function(game, ow)
    if game.save.flags.EVENT_RESCUED_MR_FUJI then
      local Commands = require("src.script.Commands")
      Commands.show_object({ game = game, save = game.save, overworld = ow },
                           "MR_FUJIS_HOUSE", "MRFUJISHOUSE_MR_FUJI")
    end
  end,
  talk = {
    TEXT_MRFUJISHOUSE_MR_FUJI = {
      { "face_player" },                                                -- 1
      { "check_flag", "EVENT_GOT_POKE_FLUTE" },                         -- 2
      { "jump_if_true", 12 },                                           -- 3
      { "check_flag", "EVENT_RESCUED_MR_FUJI" },                        -- 4
      { "jump_if_false", 14 },                                          -- 5
      { "show_text", "_MrFujisHouseMrFujiIThinkThisMayHelpYourQuestText" }, -- 6
      -- give-then-print like scripts/MrFujisHouse.asm
      { "give_item", "POKE_FLUTE", 1, false },                          -- 7
      { "show_text", "_MrFujisHouseMrFujiReceivedPokeFluteText" },      -- 8
      { "set_flag", "EVENT_GOT_POKE_FLUTE" },                           -- 9
      { "show_text", "_MrFujisHouseMrFujiPokeFluteExplanationText" },   -- 10
      { "jump", 15 },                                                   -- 11
      { "show_text", "_MrFujisHouseMrFujiHasMyFluteHelpedYouText" },    -- 12
      { "jump", 15 },                                                   -- 13
      { "show_text", "_MrFujisHouseMrFujiPokedexText" },                -- 14
    },
  },
}

-- -------------------------------------------------------------------
-- Snorlax (scripts/Route12.asm, Route16.asm)
-- -------------------------------------------------------------------

-- each route has its own strings (text/Route12.asm, text/Route16.asm;
-- Route 16's sleeping line is the unnamed _Route16Text7).  Talking to
-- Snorlax before it's beaten always just shows the sleeping line --
-- Route12DefaultScript/Route16DefaultScript only special-case
-- EVENT_FIGHT_ROUTEnn_SNORLAX, which ItemUsePokeFlute sets when the
-- player USES the POKé FLUTE from the item-use menu while standing next
-- to Snorlax (see ItemEffects.lua's POKE_FLUTE branch); merely talking
-- to it with the flute in the bag does nothing.  From the woke-up text
-- on, snorlaxWake below mirrors Route12DefaultScript's fight branch /
-- Route12SnorlaxPostBattleScript (scripts/Route12.asm, Route16.asm):
-- HideObject runs BEFORE the battle (so Snorlax is gone even after a
-- blackout), then the battle, then the calmed-down/returned line only
-- when it was NOT caught (`ld a, [wBattleResult] / cp $2` skips it),
-- and EVENT_BEAT_ROUTEnn_SNORLAX on any non-blackout result.
local function snorlaxWake(mapId, objName, beatFlag, wokeUpText, calmedText)
  return {
    { "show_text", wokeUpText },                    -- 1
    { "hide_object", mapId, objName },              -- 2 HideObject pre-battle
    { "static_battle", "SNORLAX", 30, beatFlag },   -- 3
    { "check_battle_result", "win", "run" },        -- 4 not caught, not blackout
    { "jump_if_false", 7 },                         -- 5 end (skip calmed-down)
    { "show_text", calmedText },                    -- 6
  }
end

-- snorlaxWake is looked up by ItemEffects.lua/BagMenu.lua (via
-- data/scripts/init.lua's M.get) and run when the flute wakes Snorlax;
-- objName/beatFlag let ItemEffects find the NPC and check whether it's
-- already been beaten before allowing the wake.
M.ROUTE_12 = {
  talk = { TEXT_ROUTE12_SNORLAX = { { "show_text", "_Route12SnorlaxText" } } },
  snorlaxWake = {
    objName = "ROUTE12_SNORLAX", beatFlag = "EVENT_BEAT_ROUTE12_SNORLAX",
    script = snorlaxWake("ROUTE_12", "ROUTE12_SNORLAX", "EVENT_BEAT_ROUTE12_SNORLAX",
                         "_Route12SnorlaxWokeUpText", "_Route12SnorlaxCalmedDownText"),
  },
}
M.ROUTE_16 = {
  talk = { TEXT_ROUTE16_SNORLAX = { { "show_text", "_Route16Text7" } } },
  snorlaxWake = {
    objName = "ROUTE16_SNORLAX", beatFlag = "EVENT_BEAT_ROUTE16_SNORLAX",
    script = snorlaxWake("ROUTE_16", "ROUTE16_SNORLAX", "EVENT_BEAT_ROUTE16_SNORLAX",
                         "_Route16SnorlaxWokeUpText", "_Route16SnorlaxReturnedToMountainsText"),
  },
}

-- -------------------------------------------------------------------
-- Safari Zone HMs (scripts/SafariZoneSecretHouse.asm, WardensHouse.asm)
-- -------------------------------------------------------------------

M.SAFARI_ZONE_SECRET_HOUSE = {
  talk = {
    TEXT_SAFARIZONESECRETHOUSE_FISHING_GURU = {
      { "face_player" },                                                     -- 1
      { "check_flag", "EVENT_GOT_HM03" },                                    -- 2
      { "jump_if_true", 9 },                                                 -- 3
      { "show_text", "_SafariZoneSecretHouseFishingGuruYouHaveWonText" },    -- 4
      -- give-then-print like scripts/SafariZoneSecretHouse.asm
      { "give_item", "HM_SURF", 1, false },                                  -- 5
      { "show_text", "_SafariZoneSecretHouseFishingGuruReceivedHM03Text" },  -- 6
      { "set_flag", "EVENT_GOT_HM03" },                                      -- 7
      { "jump", 10 },                                                        -- 8
      { "show_text", "_SafariZoneSecretHouseFishingGuruHM03ExplanationText" }, -- 9
    },
  },
}

M.WARDENS_HOUSE = {
  talk = {
    TEXT_WARDENSHOUSE_WARDEN = {
      { "face_player" },                                             -- 1
      { "check_flag", "EVENT_GOT_HM04" },                            -- 2
      { "jump_if_true", 13 },                                        -- 3
      { "check_item", "GOLD_TEETH" },                                -- 4
      { "jump_if_false", 15 },                                       -- 5
      { "show_text", "_WardensHouseWardenGaveTheGoldTeethText" },    -- 6
      { "take_item", "GOLD_TEETH", 1 },                              -- 7
      { "set_flag", "EVENT_GAVE_GOLD_TEETH" },                       -- 8
      { "show_text", "_WardensHouseWardenThanksText" },              -- 9
      -- give-then-print like scripts/WardensHouse.asm
      { "give_item", "HM_STRENGTH", 1, false },                      -- 10
      { "show_text", "_WardensHouseWardenReceivedHM04Text" },        -- 11
      { "set_flag", "EVENT_GOT_HM04" },                              -- 12
      { "jump", 16 },                                                -- 13 (already got it)
      { "jump", 16 },                                                -- 14 (unused)
      { "show_text", "_WardensHouseWardenGibberish1Text" },          -- 15
    },
  },
}

-- -------------------------------------------------------------------
-- Silph Co. president (scripts/SilphCo11F.asm; Giovanni there is the
-- generic OPP_GIOVANNI#2 battle)
-- -------------------------------------------------------------------

M.SILPH_CO_11F = {
  -- Giovanni's battle is a COORDINATE TRIGGER, not a talk.
  -- SilphCo11FDefaultScript (scripts/SilphCo11F.asm) checks
  -- .PlayerCoordsArray -- (6,13) and (7,12) -- every frame while
  -- EVENT_BEAT_SILPH_CO_GIOVANNI is unset: standing there shows his text,
  -- walks him three tiles down (.GiovanniMovement), and starts the fight.
  -- He also has no trainer-header entry, so sight engagement never fires
  -- either. Without this hook he was a talk-only statue four tiles away
  -- from anything the route (or a vanilla-faithful player walking the same
  -- line) would touch, and the whole Silph ending -- the flag, the Master
  -- Ball, the Saffron streets clearing -- silently never happened.
  --
  -- engageTrainer shows TEXT_SILPHCO11F_GIOVANNI as the battle text and,
  -- via victories.lua OPP_GIOVANNI#2, sets the event on a win; a loss
  -- sets nothing, so the trigger re-arms exactly as vanilla does.
  onStep = function(game, ow, x, y)
    if game.save.flags.EVENT_BEAT_SILPH_CO_GIOVANNI then return false end
    if not ((x == 6 and y == 13) or (x == 7 and y == 12)) then return false end
    local gio
    for _, npc in ipairs(ow.npcs) do
      if npc.def and npc.def.name == "SILPHCO11F_GIOVANNI" then gio = npc break end
    end
    if not gio or ow:trainerDefeated(gio) then return false end
    ow:scriptMove(gio, "down", 3, function()
      gio:facePlayer(ow.player)
      ow:engageTrainer(gio, function()
        -- SilphCo11FTeamRocketLeavesScript: Giovanni leaves the floor
        -- after the loss (the street rockets are handled by
        -- M.SAFFRON_CITY.onEnter in story4.lua).
        if game.save.flags.EVENT_BEAT_SILPH_CO_GIOVANNI then
          local Commands = require("src.script.Commands")
          local ctx = { game = game, save = game.save, overworld = ow }
          Commands.hide_object(ctx, "SILPH_CO_11F", "SILPHCO11F_GIOVANNI")
        end
      end)
    end)
    return true
  end,
  onEnter = function(game, ow)
    if game.save.flags.EVENT_BEAT_SILPH_CO_GIOVANNI then
      local Commands = require("src.script.Commands")
      local ctx = { game = game, save = game.save, overworld = ow }
      Commands.hide_object(ctx, "SILPH_CO_11F", "SILPHCO11F_GIOVANNI")
    end
  end,
  talk = {
    TEXT_SILPHCO11F_SILPH_PRESIDENT = {
      { "face_player" },                                                     -- 1
      { "check_flag", "EVENT_BEAT_SILPH_CO_GIOVANNI" },                      -- 2
      { "jump_if_false", 10 },                                               -- 3
      { "check_flag", "EVENT_GOT_MASTER_BALL" },                             -- 4
      { "jump_if_true", 10 },                                                -- 5
      { "show_text", "_SilphCo11FSilphPresidentText" },                      -- 6
      -- give-then-print like scripts/SilphCo11F.asm
      { "give_item", "MASTER_BALL", 1, false },                              -- 7
      { "show_text", "_SilphCo11FSilphPresidentReceivedMasterBallText" },    -- 8
      { "set_flag", "EVENT_GOT_MASTER_BALL" },                               -- 9
      { "jump", 11 },                                                        -- 10
    },
  },
}

-- -------------------------------------------------------------------
-- Victory Road boulder switches (scripts/VictoryRoad1F/2F/3F.asm):
-- a boulder resting on a switch removes a barrier block; the 3F hole
-- drops a boulder down to the 2F switch.
-- -------------------------------------------------------------------

local function boulderAt(ow, x, y)
  local npc = ow:npcAtCell(x, y)
  return npc and npc.def.sprite == "SPRITE_BOULDER" and npc or nil
end

M.VICTORY_ROAD_1F = {
  onEnter = function(game, ow)
    if game.save.flags.EVENT_VICTORY_ROAD_1_BOULDER_ON_SWITCH then
      ow:replaceBlock(4, 6, 0x1D)
    end
  end,
  onBoulderMoved = function(game, ow, npc)
    if npc.cellX == 17 and npc.cellY == 13
       and not game.save.flags.EVENT_VICTORY_ROAD_1_BOULDER_ON_SWITCH then
      game.save.flags.EVENT_VICTORY_ROAD_1_BOULDER_ON_SWITCH = true
      ow:replaceBlock(4, 6, 0x1D)
    end
  end,
}

M.VICTORY_ROAD_2F = {
  onEnter = function(game, ow)
    if game.save.flags.EVENT_VICTORY_ROAD_2_BOULDER_ON_SWITCH1 then
      ow:replaceBlock(3, 4, 0x15)
    end
    if game.save.flags.EVENT_VICTORY_ROAD_2_BOULDER_ON_SWITCH2 then
      ow:replaceBlock(11, 7, 0x1D)
    end
  end,
  onBoulderMoved = function(game, ow, npc)
    if npc.cellX == 1 and npc.cellY == 16
       and not game.save.flags.EVENT_VICTORY_ROAD_2_BOULDER_ON_SWITCH1 then
      game.save.flags.EVENT_VICTORY_ROAD_2_BOULDER_ON_SWITCH1 = true
      ow:replaceBlock(3, 4, 0x15)
    end
    if npc.cellX == 9 and npc.cellY == 16
       and not game.save.flags.EVENT_VICTORY_ROAD_2_BOULDER_ON_SWITCH2 then
      game.save.flags.EVENT_VICTORY_ROAD_2_BOULDER_ON_SWITCH2 = true
      ow:replaceBlock(11, 7, 0x1D)
    end
  end,
}

M.VICTORY_ROAD_3F = {
  onEnter = function(game, ow)
    if game.save.flags.EVENT_VICTORY_ROAD_3_BOULDER_ON_SWITCH1 then
      ow:replaceBlock(3, 5, 0x1D)
    end
  end,
  onBoulderMoved = function(game, ow, npc)
    if npc.cellX == 3 and npc.cellY == 5
       and not game.save.flags.EVENT_VICTORY_ROAD_3_BOULDER_ON_SWITCH1 then
      game.save.flags.EVENT_VICTORY_ROAD_3_BOULDER_ON_SWITCH1 = true
      ow:replaceBlock(3, 5, 0x1D)
    end
    -- the hole at (23,15): the boulder drops to 2F next to switch 2
    if npc.cellX == 23 and npc.cellY == 15 then
      local Commands = require("src.script.Commands")
      local ctx = { save = game.save, overworld = ow, game = game }
      Commands.hide_object(ctx, "VICTORY_ROAD_3F", npc.def.name)
      Commands.show_object(ctx, "VICTORY_ROAD_2F", "VICTORYROAD2F_BOULDER")
    end
  end,
}

-- -------------------------------------------------------------------
-- Champion (scripts/ChampionsRoom.asm): rival with the Rival3 party for
-- your starter, then Oak's congratulations (Hall of Fame-lite).
-- -------------------------------------------------------------------

-- The battle gate is the run-scoped EVENT_BEAT_CHAMPION_RIVAL_THIS_RUN,
-- cleared by the Indigo lobby's Elite Four reset (scripts/
-- IndigoPlateauLobby.asm) so the champion is re-fightable on rematches,
-- like pokered's re-entry cutscene.  EVENT_BEAT_CHAMPION_RIVAL stays set
-- forever (postgame gates like the Cerulean cave guard read it).
-- scripts/ChampionsRoom.asm ChampionsRoomRivalDefeatedScript ->
-- OakArrivesScript -> OakCongratulatesPlayerScript ->
-- OakDisappointedWithRivalScript -> OakComeWithMeScript -> OakExitsScript,
-- then the simulated walk up-and-left into the HALL_OF_FAME warp
-- (PlayerFollowsOakScript / WalkToHallOfFame_RLEMovement).  The induction
-- itself is NOT run here: it belongs to the HALL_OF_FAME room script
-- (scripts/HallOfFame.asm), so we set a one-shot marker and warp; the room
-- onEnter (M.HALL_OF_FAME below) drives the HoF Oak speech + record.
M.CHAMPIONS_ROOM = {
  talk = {
    TEXT_CHAMPIONSROOM_RIVAL = {
      { "face_player" },                                        -- 1
      { "check_flag", "EVENT_BEAT_CHAMPION_RIVAL_THIS_RUN" },   -- 2
      { "jump_if_true", 24 },                                   -- 3
      { "show_text", "_ChampionsRoomRivalIntroText" },          -- 4
      { "rival_battle", "OPP_RIVAL3", 1 },                      -- 5
      { "jump_if_false", 24 },                                  -- 6
      { "set_flag", "EVENT_BEAT_CHAMPION_RIVAL_THIS_RUN" },     -- 7
      { "set_flag", "EVENT_BEAT_CHAMPION_RIVAL" },              -- 8
      -- ChampionsRoomRivalDefeatedScript re-displays TEXT_CHAMPIONSROOM_RIVAL,
      -- whose text_asm takes the EVENT_BEAT_CHAMPION_RIVAL branch =
      -- _ChampionsRoomRivalAfterBattleText (the in-battle _RivalDefeatedText
      -- is the port's generic "<PLAYER> defeated BLUE!" engine line instead).
      { "show_text", "_ChampionsRoomRivalAfterBattleText" },    -- 9
      -- ChampionsRoomOakArrivesScript: Oak's "{PLAYER}!" then reveal + walk in
      { "show_text", "_ChampionsRoomOakText" },                 -- 10
      { "show_object", "CHAMPIONS_ROOM", "CHAMPIONSROOM_OAK" },  -- 11
      { "move_npc", 2, "up", 5 },                               -- 12 OakEntranceAfterVictoryMovement (3,7)->(3,2)
      -- OakCongratulatesPlayerScript: rival faces left, Oak faces down
      { "face_object", 1, "left" },                             -- 13
      { "face_object", 2, "down" },                             -- 14
      { "show_text", "_ChampionsRoomOakCongratulatesPlayerText" }, -- 15
      -- OakDisappointedWithRivalScript: Oak turns to the rival (right)
      { "face_object", 2, "right" },                            -- 16
      { "show_text", "_ChampionsRoomOakDisappointedWithRivalText" }, -- 17
      -- OakComeWithMeScript: Oak faces down again, then exits up
      { "face_object", 2, "down" },                             -- 18
      { "show_text", "_ChampionsRoomOakComeWithMeText" },       -- 19
      { "move_npc", 2, "up", 2 },                               -- 20 OakExitChampionsRoomMovement (3,2)->(3,0)
      { "hide_object", "CHAMPIONS_ROOM", "CHAMPIONSROOM_OAK" },  -- 21
      -- hand the induction off to the HALL_OF_FAME room (consumed by its
      -- onEnter), then warp up into it (destWarp 1 lands at (4,7) facing up)
      { "set_field", "pendingHallOfFame", true },               -- 22
      { "warp", "HALL_OF_FAME", 4, 7, "up" },                   -- 23
    },
  },
}

-- -------------------------------------------------------------------
-- Hall of Fame (scripts/HallOfFame.asm): the induction's entry point is
-- the ROOM, not the Champions Room script.  HallOfFameDefaultScript walks
-- the player up 5 into Oak (HallOfFameEntryMovement), then
-- HallOfFameOakCongratulationsScript turns them face-to-face, shows
-- _HallOfFameOakText, hides Oak (predef HideObject) and runs
-- HallOfFameResetEventsAndSaveScript's predef HallOfFamePC (the induction +
-- credits, here Commands.record_hall_of_fame).
--
-- onEnter fires DURING the Champions Room warp's setMap, while that warp
-- command's runner is still suspended-alive (yielded at the warp), so we
-- cannot start a runner here directly (ScriptRunner:run asserts the runner
-- is idle).  Instead we QUEUE the cutscene: OverworldState:update drains
-- self.pendingScript once the warp's transition has finished and its runner
-- has gone dead, so the room cutscene begins a frame after the warp fully
-- completes.  The one-shot save.pendingHallOfFame marker (set by the
-- Champions Room script) is consumed here so re-entering the room later
-- does not replay the induction.
M.HALL_OF_FAME = {
  onEnter = function(game, ow)
    -- self-heal saves poisoned by a prior version of this script, which
    -- wrongly hid Oak here instead of the Cerulean Cave guard (see
    -- CERULEAN_CITY onEnter, which handles the real HideObject target)
    local toggles = game.save.objectToggles and game.save.objectToggles.HALL_OF_FAME
    if toggles then toggles.HALLOFFAME_OAK = nil end

    -- Make the Hall of Fame recording machine interactable.  The console
    -- juts from the north wall as the two solid cells (4,1) and (5,1); a
    -- sign on each lets the player face the machine (from below, or from
    -- either side) and press A to run the TEXT_HALLOFFAME_PC talk script.
    -- maps.lua is generated from the ROM and gitignored, so the sign is
    -- injected here (a tracked script) rather than baked into map data.
    local def = ow.map.def
    def.signs = def.signs or {}
    local present = false
    for _, s in ipairs(def.signs) do
      if s.text == "TEXT_HALLOFFAME_PC" then present = true break end
    end
    if not present then
      table.insert(def.signs, { text = "TEXT_HALLOFFAME_PC", x = 4, y = 1 })
      table.insert(def.signs, { text = "TEXT_HALLOFFAME_PC", x = 5, y = 1 })
    end
    -- the live Map instance built its signAt lookup from def.signs before
    -- this hook ran, so rebuild it (idempotent) to pick up the injection
    ow.map.signAt = {}
    for _, s in ipairs(def.signs) do
      ow.map.signAt[s.y * ow.map.widthCells + s.x] = s
    end

    if not game.save.pendingHallOfFame then return end
    game.save.pendingHallOfFame = false
    ow:queueScript({
      { "move_player", "up", 5 },                      -- (4,7)->(4,2) beside Oak (5,2)
      { "face_object", 1, "left" },                    -- HALLOFFAME_OAK faces the player
      { "face_player_dir", "right" },                  -- player faces Oak (PLAYER_DIR_RIGHT)
      { "show_text", "_HallOfFameOakText" },           -- TEXT_HALLOFFAME_OAK
      -- HallOfFameOakCongratulationsScript hides TOGGLE_CERULEAN_CAVE_GUY
      -- here, not Oak; that's handled separately by CERULEAN_CITY onEnter
      -- gating on EVENT_BEAT_CHAMPION_RIVAL
      { "record_hall_of_fame" },                       -- predef HallOfFamePC: induction + credits
    })
  end,
  talk = {
    -- The recording machine doubles as a "warp home" PC: a YES/NO prompt
    -- that teleports back to the new-game bedroom spawn (special_warps.asm
    -- NewGameWarp: REDS_HOUSE_2F, 3, 6, facing down).  Fabricated
    -- convenience -- there is no such prompt in the original ROM.
    TEXT_HALLOFFAME_PC = {
      { "ask", "Return to\nPALLET TOWN?" },             -- 1  YES/NO -> lastCheck
      { "jump_if_false", "end" },                       -- 2  NO: back away
      { "warp", "REDS_HOUSE_2F", 3, 6, "down" },        -- 3  YES: home to your room
    },
  },
}

-- -------------------------------------------------------------------
-- Mid-game rival battles (scripts/CeruleanCity.asm, PokemonTower2F.asm);
-- Rival1 parties 7-9 are the Cerulean set, Rival2 parties 4-6 the Tower
-- set (data/trainers/parties.asm)
-- -------------------------------------------------------------------

M.CERULEAN_CITY = {
  talk = {
    TEXT_CERULEANCITY_RIVAL = {
      { "face_player" },                                    -- 1
      { "check_flag", "EVENT_BEAT_CERULEAN_RIVAL" },        -- 2
      { "jump_if_true", 9 },                                -- 3
      { "show_text", "_CeruleanCityRivalPreBattleText" },   -- 4
      { "rival_battle", "OPP_RIVAL1", 7 },                  -- 5
      { "jump_if_false", 10 },                              -- 6
      { "set_flag", "EVENT_BEAT_CERULEAN_RIVAL" },          -- 7
      { "show_text", "_CeruleanCityRivalDefeatedText" },    -- 8
      { "jump", 10 },                                       -- 9
    },
  },
}

M.POKEMON_TOWER_2F = {
  talk = {
    TEXT_POKEMONTOWER2F_RIVAL = {
      { "face_player" },                                            -- 1
      { "check_flag", "EVENT_BEAT_POKEMON_TOWER_RIVAL" },           -- 2
      { "jump_if_true", 10 },                                       -- 3
      { "show_text", "_PokemonTower2FRivalWhatBringsYouHereText" }, -- 4
      { "rival_battle", "OPP_RIVAL2", 4 },                          -- 5
      { "jump_if_false", 11 },                                      -- 6
      { "set_flag", "EVENT_BEAT_POKEMON_TOWER_RIVAL" },             -- 7
      { "show_text", "_PokemonTower2FRivalDefeatedText" },          -- 8
      { "jump", 11 },                                               -- 9
      { "show_text", "_PokemonTower2FRivalHowsYourDexText" },       -- 10
    },
  },
  -- PokemonTower2FDefaultScript: walking past the rival's tile forces
  -- the encounter (ArePlayerCoordsInArray on (15,5)/(14,6)) -- he never
  -- waits to be talked to
  onStep = function(game, ow, x, y)
    if game.save.flags.EVENT_BEAT_POKEMON_TOWER_RIVAL then return false end
    if not ((x == 15 and y == 5) or (x == 14 and y == 6)) then return false end
    if ow.runner:isRunning() then return false end
    local rival = ow:npcByIndex(1)
    if not rival then return false end
    ow.player.facing = (x == 15) and "left" or "up"
    require("src.core.Music").play(game.data, "Music_MeetRival")
    ow.runner:run(M.POKEMON_TOWER_2F.talk.TEXT_POKEMONTOWER2F_RIVAL,
                  { npc = rival })
    return true
  end,
}

-- -------------------------------------------------------------------
-- In-game trades (data/events/trades.asm; the NPC<->trade mapping is
-- from each map's DoInGameTradeDialogue call)
-- -------------------------------------------------------------------

M.ROUTE_2_TRADE_HOUSE = {
  talk = {
    -- The Scientist is plain flavor; the Game Boy Kid holds the trade
    -- (data/scripts/flavor/route_2_trade_house.lua), per Route2TradeHouse.asm.
    TEXT_ROUTE2TRADEHOUSE_SCIENTIST = {
      { "face_player" },
      { "show_text", "_Route2TradeHouseScientistText" },
    },
  },
}

M.CERULEAN_TRADE_HOUSE = {
  talk = {
    -- The Granny is plain flavor (points you to her husband); the Gambler
    -- holds the trade (data/scripts/flavor/cerulean_trade_house.lua), per
    -- CeruleanTradeHouse.asm.
    TEXT_CERULEANTRADEHOUSE_GRANNY = {
      { "face_player" },
      { "show_text", "_CeruleanTradeHouseGrannyText" },
    },
  },
}

M.VERMILION_TRADE_HOUSE = {
  talk = {
    TEXT_VERMILIONTRADEHOUSE_LITTLE_GIRL = {
      { "face_player" },
      { "trade", 5, "EVENT_TRADED_SPEAROW_FOR_FARFETCHD" }, -- DUX
    },
  },
}

return M
