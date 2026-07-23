-- Side events that were missing from the port (found by auditing
-- against pokered): Oak's aides, the Magikarp salesman, the Fighting
-- Dojo prize, the Silph LAPRAS, Copycat, Mr. Psychic, the Route 16
-- FLY house, the Celadon rooftop vending machines + thirsty girl, and
-- the Name Rater.  Each cites its pokered source.

local M = {}

local function text(game) return game.data.text end

local function push(game, s, done)
  local TextBox = require("src.render.TextBox")
  game.stack:push(TextBox.new(game, s, done))
end

local function ask(game, s, cb)
  local ChoiceBox = require("src.ui.ChoiceBox")
  push(game, s, function() game.stack:push(ChoiceBox.new(game, cb)) end)
end

-- fill the extracted text placeholders ({NUM:...}, {RAM:...}, {PLAYER})
local function fill(s, subs)
  s = s:gsub("{PLAYER}", subs.player or "")
  s = s:gsub("{NUM:[^}]*}", function() return tostring(subs.num or "") end)
  s = s:gsub("{RAM:[^}]*}", function() return subs.ram or "" end)
  return s
end

-- -------------------------------------------------------------------
-- Oak's aides (engine/events/oaks_aide.asm; Route2Gate / Route11Gate2F
-- / Route15Gate2F pass the requirement + reward)
-- -------------------------------------------------------------------

local function countOwned(save)
  local n = 0
  for _ in pairs(save.pokedex and save.pokedex.owned or {}) do n = n + 1 end
  return n
end

local function oaksAide(threshold, itemId)
  return function(game, ow, npc, done)
    local t = text(game)
    local flags = game.save.flags
    local itemName = game.data.items[itemId].name
    local flag = "EVENT_GOT_" .. itemId
    if flags[flag] then
      push(game, fill(t._OaksAideComeBackText or
        "I already gave\nyou the {RAM:}!",
        { num = threshold, ram = itemName }), done)
      return
    end
    ask(game, fill(t._OaksAideHiText or
      "Have you caught\n{NUM:} kinds of\nPOKéMON?",
      { num = threshold, ram = itemName, player = game.save.player.name }),
      function(yes)
        if not yes then
          push(game, fill(t._OaksAideComeBackText or "Come back later!",
            { num = threshold, ram = itemName }), done)
          return
        end
        local owned = countOwned(game.save)
        if owned >= threshold then
          if not require("src.inventory.Bag").add(game.save, itemId, 1) then
            push(game, fill(t._OaksAideNoRoomText or
              "No room for the\n{RAM:}!", { ram = itemName }), done)
            return
          end
          flags[flag] = true
          push(game, fill(t._OaksAideHereYouGoText or "Here you go!",
              { num = owned, ram = itemName }),
            function()
              push(game, fill(t._OaksAideGotItemText or
                "{PLAYER} got the\n{RAM:}!",
                { ram = itemName, player = game.save.player.name }), done)
            end)
        else
          push(game, fill(t._OaksAideUhOhText or
            "You have only\ncaught {NUM:}!",
            { num = owned, ram = itemName }), done)
        end
      end)
  end
end

M.ROUTE_2_GATE = {
  talk = { TEXT_ROUTE2GATE_OAKS_AIDE = oaksAide(10, "HM_FLASH") },
}
M.ROUTE_11_GATE_2F = {
  talk = { TEXT_ROUTE11GATE2F_OAKS_AIDE = oaksAide(30, "ITEMFINDER") },
}
M.ROUTE_15_GATE_2F = {
  talk = { TEXT_ROUTE15GATE2F_OAKS_AIDE = oaksAide(50, "EXP_ALL") },
}

-- -------------------------------------------------------------------
-- Magikarp salesman (scripts/MtMoonPokecenter.asm): ¥500 for a L5
-- MAGIKARP, once
-- -------------------------------------------------------------------

M.MT_MOON_POKECENTER = {
  talk = {
    TEXT_MTMOONPOKECENTER_MAGIKARP_SALESMAN = function(game, ow, npc, done)
      local t = text(game)
      if game.save.flags.EVENT_BOUGHT_MAGIKARP then
        push(game, t._MtMoonPokecenterMagikarpSalesmanNoRefundsText
          or "Well, I don't\ngive refunds!", done)
        return
      end
      ask(game, t._MtMoonPokecenterMagikarpSalesmanOfferText
        or "MAGIKARP! A\nsteal at ¥500!\nWant one?", function(yes)
        if not yes then
          push(game, t._MtMoonPokecenterMagikarpSalesmanNoText
            or "No? I'm only\nselling today!", done)
          return
        end
        if game.save.money < 500 then
          push(game, t._MtMoonPokecenterMagikarpSalesmanNoMoneyText
            or "You'll need more\nmoney than that!", done)
          return
        end
        game.save.money = game.save.money - 500
        game.save.flags.EVENT_BOUGHT_MAGIKARP = true
        local Commands = require("src.script.Commands")
        Commands.give_pokemon({ save = game.save, game = game, overworld = ow },
                              "MAGIKARP", 5)
        push(game, ("%s got a\nMAGIKARP!"):format(game.save.player.name), done)
      end)
    end,
  },
}

-- -------------------------------------------------------------------
-- Fighting Dojo prize (scripts/FightingDojo.asm): after beating the
-- Karate Master, take HITMONLEE or HITMONCHAN (the other disappears)
-- -------------------------------------------------------------------

local function dojoBall(species, ownBall, otherBall, askKey)
  return function(game, ow, npc, done)
    local t = text(game)
    local flags = game.save.flags
    if flags.EVENT_GOT_HITMONLEE or flags.EVENT_GOT_HITMONCHAN then
      done()
      return
    end
    if not flags.EVENT_BEAT_KARATE_MASTER then
      push(game, "You'll have to\nbeat the master\nfirst!", done)
      return
    end
    ask(game, t[askKey] or ("You want\n" .. species .. "?"), function(yes)
      if not yes then done() return end
      flags["EVENT_GOT_" .. species] = true
      flags.EVENT_DEFEATED_FIGHTING_DOJO = true
      local Commands = require("src.script.Commands")
      local ctx = { save = game.save, game = game, overworld = ow }
      Commands.give_pokemon(ctx, species, 30)
      Commands.hide_object(ctx, "FIGHTING_DOJO", ownBall)
      Commands.hide_object(ctx, "FIGHTING_DOJO", otherBall)
      push(game, ("%s got\n%s!"):format(game.save.player.name, species), done)
    end)
  end
end

M.FIGHTING_DOJO = {
  talk = {
    TEXT_FIGHTINGDOJO_HITMONLEE_POKE_BALL =
      dojoBall("HITMONLEE", "FIGHTINGDOJO_HITMONLEE_POKE_BALL",
               "FIGHTINGDOJO_HITMONCHAN_POKE_BALL",
               "_FightingDojoHitmonleePokeBallText"),
    TEXT_FIGHTINGDOJO_HITMONCHAN_POKE_BALL =
      dojoBall("HITMONCHAN", "FIGHTINGDOJO_HITMONCHAN_POKE_BALL",
               "FIGHTINGDOJO_HITMONLEE_POKE_BALL",
               "_FightingDojoHitmonchanPokeBallText"),
  },
}

-- -------------------------------------------------------------------
-- Silph Co. 7F worker's LAPRAS (scripts/SilphCo7F.asm: L15, once,
-- after the rival fight area is reached; gift is unconditional here)
-- -------------------------------------------------------------------

M.SILPH_CO_7F = {
  talk = {
    TEXT_SILPHCO7F_SILPH_WORKER_M1 = function(game, ow, npc, done)
      local t = text(game)
      if game.save.flags.EVENT_GOT_LAPRAS then
        push(game, t._SilphCo7FSilphWorkerM1LaprasDescriptionText
          or "How is LAPRAS\ndoing?", done)
        return
      end
      push(game, t._SilphCo7FSilphWorkerM1ThankYouText
        or "Thank you for\nsaving us!\fI want you to\nhave this LAPRAS!",
        function()
          game.save.flags.EVENT_GOT_LAPRAS = true
          local Commands = require("src.script.Commands")
          Commands.give_pokemon({ save = game.save, game = game, overworld = ow },
                                "LAPRAS", 15)
          push(game, ("%s got\nLAPRAS!"):format(game.save.player.name),
            function()
              push(game, t._SilphCo7FSilphWorkerM1LaprasDescriptionText
                or "It's a good\nswimmer!", done)
            end)
        end)
    end,
  },
}

-- -------------------------------------------------------------------
-- Copycat (scripts/CopycatsHouse2F.asm): a POKE DOLL buys TM31 MIMIC
-- -------------------------------------------------------------------

M.COPYCATS_HOUSE_2F = {
  talk = {
    TEXT_COPYCATSHOUSE2F_COPYCAT = function(game, ow, npc, done)
      local t = text(game)
      if game.save.flags.EVENT_GOT_TM31 then
        push(game, t._CopycatsHouse2FCopycatWhirlingText
          or "Huh? Huh? Huh?", done)
        return
      end
      if (game.save.inventory.POKE_DOLL or 0) > 0 then
        ask(game, t._CopycatsHouse2FCopycatPokeDollText
          or "Oh wow!\nA POKé DOLL!\fFor me?\nCan I have it?", function(yes)
          if not yes then done() return end
          game.save.inventory.POKE_DOLL = game.save.inventory.POKE_DOLL - 1
          if game.save.inventory.POKE_DOLL == 0 then
            game.save.inventory.POKE_DOLL = nil
          end
          if not require("src.inventory.Bag").add(game.save, "TM_MIMIC", 1) then
            push(game, "You don't have\nroom for TM31!", done)
            return
          end
          game.save.flags.EVENT_GOT_TM31 = true
          push(game, ("%s got\nTM31!"):format(game.save.player.name), done)
        end)
        return
      end
      push(game, t._CopycatsHouse2FCopycatText
        or "I like to mimic\npeople!", done)
    end,
  },
}

-- -------------------------------------------------------------------
-- Mr. Psychic (scripts/MrPsychicsHouse.asm): TM29 PSYCHIC, once
-- -------------------------------------------------------------------

M.MR_PSYCHICS_HOUSE = {
  talk = {
    TEXT_MRPSYCHICSHOUSE_MR_PSYCHIC = function(game, ow, npc, done)
      local t = text(game)
      if game.save.flags.EVENT_GOT_TM29 then
        push(game, t._MrPsychicsHouseMrPsychicNoMoreText
          or "...Hmm...", done)
        return
      end
      push(game, t._MrPsychicsHouseMrPsychicText
        or "...Wait!\nDon't say a word!\fYou came to get\nTM29!", function()
        if not require("src.inventory.Bag").add(game.save, "TM_PSYCHIC_M", 1) then
          push(game, "You don't have\nroom for TM29!", done)
          return
        end
        game.save.flags.EVENT_GOT_TM29 = true
        push(game, ("%s got\nTM29!"):format(game.save.player.name), done)
      end)
    end,
  },
}

-- -------------------------------------------------------------------
-- Route 16 hidden house (scripts/Route16FlyHouse.asm): HM02 FLY, once
-- -------------------------------------------------------------------

M.ROUTE_16_FLY_HOUSE = {
  talk = {
    TEXT_ROUTE16FLYHOUSE_BRUNETTE_GIRL = function(game, ow, npc, done)
      local t = text(game)
      if game.save.flags.EVENT_GOT_HM02 then
        push(game, t._Route16FlyHouseBrunetteGirlHm02ExplanationText
          or "HM02 is FLY!\fIt will whisk you\nback to any town!", done)
        return
      end
      push(game, t._Route16FlyHouseBrunetteGirlText
        or "Shh! It's a\nsecret!\fMy POKéMON's\nHM02, take it!", function()
        if not require("src.inventory.Bag").add(game.save, "HM_FLY", 1) then
          push(game, "You don't have\nroom for HM02!", done)
          return
        end
        game.save.flags.EVENT_GOT_HM02 = true
        push(game, ("%s got\nHM02!"):format(game.save.player.name), done)
      end)
    end,
  },
}

-- -------------------------------------------------------------------
-- Celadon rooftop (scripts/CeladonMartRoof.asm): vending machines sell
-- the three drinks; the thirsty girl trades drinks for TM13/48/49
-- -------------------------------------------------------------------

local DRINK_PRICES = {
  { id = "FRESH_WATER", price = 200 },
  { id = "SODA_POP", price = 300 },
  { id = "LEMONADE", price = 350 },
}

local function vendingMachine(game, ow, npc, done)
  local ListMenu = require("src.ui.ListMenu")
  local items = {}
  for _, d in ipairs(DRINK_PRICES) do
    table.insert(items, {
      value = d, label = ("%s ¥%d"):format(game.data.items[d.id].name, d.price),
    })
  end
  game.stack:push(ListMenu.new(game, "VENDING MACHINE", items, {
    onChoose = function(item, list)
      local d = item.value
      if game.save.money < d.price then
        push(game, "Not enough\nmoney.")
        return
      end
      if not require("src.inventory.Bag").add(game.save, d.id, 1) then
        push(game, "You have no room\nfor it!")
        return
      end
      game.save.money = game.save.money - d.price
      push(game, ("%s\npopped out!"):format(game.data.items[d.id].name))
    end,
    onCancel = done,
  }))
end

-- drink -> TM (CeladonMartRoof.asm .gaveFreshWater/.gaveSodaPop/
-- .gaveLemonade branches of CeladonMartRoofScript_GiveDrinkToGirl)
local GIRL_TMS = {
  { drink = "FRESH_WATER", tm = "TM_ICE_BEAM", flag = "EVENT_GOT_TM13",
    yay = "_CeladonMartRoofLittleGirlYayFreshWaterText",
    received = "_CeladonMartRoofLittleGirlReceivedTM13Text",
    explain = "_CeladonMartRoofLittleGirlTM13ExplanationText" },
  { drink = "SODA_POP", tm = "TM_ROCK_SLIDE", flag = "EVENT_GOT_TM48",
    yay = "_CeladonMartRoofLittleGirlYaySodaPopText",
    received = "_CeladonMartRoofLittleGirlReceivedTM48Text",
    explain = "_CeladonMartRoofLittleGirlTM48ExplanationText" },
  { drink = "LEMONADE", tm = "TM_TRI_ATTACK", flag = "EVENT_GOT_TM49",
    yay = "_CeladonMartRoofLittleGirlYayLemonadeText",
    received = "_CeladonMartRoofLittleGirlReceivedTM49Text",
    explain = "_CeladonMartRoofLittleGirlTM49ExplanationText" },
}

M.CELADON_MART_ROOF = {
  talk = {
    TEXT_CELADONMARTROOF_VENDING_MACHINE1 = vendingMachine,
    TEXT_CELADONMARTROOF_VENDING_MACHINE2 = vendingMachine,
    TEXT_CELADONMARTROOF_VENDING_MACHINE3 = vendingMachine,
    -- CeladonMartRoofLittleGirlText + Script_GiveDrinkToGirl: a menu
    -- of the drinks in the bag; the chosen one earns its TM (once per
    -- drink kind, EVENT_GOT_TM13/48/49)
    TEXT_CELADONMARTROOF_LITTLE_GIRL = function(game, ow, npc, done)
      local t = text(game)
      local have = {}
      for _, g in ipairs(GIRL_TMS) do
        if (game.save.inventory[g.drink] or 0) > 0 then
          table.insert(have, g)
        end
      end
      if #have == 0 then
        push(game, t._CeladonMartRoofLittleGirlImThirstyText
          or "I'm thirsty!\nI want something\nto drink!", done)
        return
      end
      ask(game, t._CeladonMartRoofLittleGirlGiveHerADrinkText
        or "I'm thirsty!\nI want something\nto drink!\fGive her a drink?",
        function(yes)
          if not yes then done() return end
          push(game, t._CeladonMartRoofLittleGirlGiveHerWhichDrinkText
            or "Give her which\ndrink?", function()
            local items = {}
            for _, g in ipairs(have) do
              table.insert(items, {
                label = game.data.items[g.drink].name, value = g,
              })
            end
            local ListMenu = require("src.ui.ListMenu")
            game.stack:push(ListMenu.new(game, "DRINKS", items, {
              onChoose = function(item, list)
                list:close()
                local g = item.value
                if game.save.flags[g.flag] then
                  push(game, t._CeladonMartRoofLittleGirlImNotThirstyText
                    or "No thank you!\nI'm not thirsty\nafter all!", done)
                  return
                end
                push(game, t[g.yay]
                  or "Yay!\fThank you!\fYou can have this\nfrom me!", function()
                  local Bag = require("src.inventory.Bag")
                  Bag.remove(game.save, g.drink, 1)
                  if not Bag.add(game.save, g.tm, 1) then
                    push(game, t._CeladonMartRoofLittleGirlNoRoomText
                      or "You don't have\nspace for this!", done)
                    return
                  end
                  game.save.flags[g.flag] = true
                  require("src.core.Sound").play(game.data, "Get_Item1")
                  local subs = { player = game.save.player.name,
                                 ram = game.data.items[g.tm].name }
                  local explain = fill(t[g.explain] or "", subs)
                    :gsub("^\f", "")
                  push(game, fill(t[g.received]
                    or "{PLAYER} received\n{RAM:}!", subs), function()
                    if #explain > 0 then
                      push(game, explain, done)
                    else
                      done()
                    end
                  end)
                end)
              end,
              onCancel = done,
            }))
          end)
        end)
    end,
  },
}

-- -------------------------------------------------------------------
-- Nugget Bridge recruiter (scripts/Route24.asm): the champ prize
-- NUGGET, the TEAM ROCKET pitch, then the battle
-- -------------------------------------------------------------------

M.ROUTE_24 = {
  talk = {
    TEXT_ROUTE24_COOLTRAINER_M1 = function(game, ow, npc, done)
      local flags = game.save.flags
      local function battleOrDone()
        if ow:trainerDefeated(npc) then
          push(game, "I hate this!\nMy dreams of\nTEAM ROCKET...", done)
        else
          ow:engageTrainer(npc, done)
        end
      end
      if not flags.EVENT_GOT_NUGGET then
        push(game, "Congratulations!\nYou beat our 5\ncontest trainers!\f"
          .. "You just earned a\nfabulous prize!", function()
          flags.EVENT_GOT_NUGGET = true
          require("src.inventory.Bag").add(game.save, "NUGGET", 1)
          push(game, ("%s received\na NUGGET!"):format(game.save.player.name),
            function()
              ask(game, "By the way, would\nyou like to join\nTEAM ROCKET?",
                function()
                  push(game, "Arrgh! You are\nnot convinced?\fThen I'll show\n"
                    .. "you my power!", battleOrDone)
                end)
            end)
        end)
        return
      end
      battleOrDone()
    end,
  },
  -- Route24DefaultScript forces TEXT_ROUTE24_COOLTRAINER_M1 whenever the
  -- player stands on (10,15) in front of the recruiter while
  -- EVENT_GOT_NUGGET is unset (dbmapcoord 10,15), independent of facing
  -- or input -- he has no trainer header, so sight never engages him.
  onStep = function(game, ow, x, y)
    if game.save.flags.EVENT_GOT_NUGGET then return false end
    if not (x == 10 and y == 15) then return false end
    if ow.runner:isRunning() or ow.engaging then return false end
    local recruiter
    for _, npc in ipairs(ow.npcs) do
      if npc.def and npc.def.name == "ROUTE24_COOLTRAINER_M1" then
        recruiter = npc
        break
      end
    end
    if not recruiter then return false end
    ow:showMapText("TEXT_ROUTE24_COOLTRAINER_M1", recruiter)
    return true
  end,
}

-- -------------------------------------------------------------------
-- Cinnabar Lab trade room (scripts/CinnabarLabTradeRoom.asm):
-- Gramps trades DORIS (Raichu -> Electrode), the Beauty CRINKLES
-- (Venonat -> Tangela); indexes into data/events/trades.asm
-- -------------------------------------------------------------------

M.CINNABAR_LAB_TRADE_ROOM = {
  talk = {
    TEXT_CINNABARLABTRADEROOM_GRAMPS = {
      { "face_player" },
      { "trade", 8, "EVENT_TRADED_RAICHU_FOR_ELECTRODE" }, -- DORIS
    },
    TEXT_CINNABARLABTRADEROOM_BEAUTY = {
      { "face_player" },
      { "trade", 9, "EVENT_TRADED_VENONAT_FOR_TANGELA" }, -- CRINKLES
    },
  },
}

-- -------------------------------------------------------------------
-- Name Rater (scripts/NameRatersHouse.asm): rename a party member
-- -------------------------------------------------------------------

M.NAME_RATERS_HOUSE = {
  talk = {
    TEXT_NAMERATERSHOUSE_NAME_RATER = function(game, ow, npc, done)
      local t = text(game)
      local function bye()
        push(game, t._NameRatersHouseNameRaterComeAnyTimeYouLikeText
          or "Fine! Come any\ntime you like!", done)
      end
      ask(game, t._NameRatersHouseNameRaterWantMeToRateText
        or "Hello, hello!\nI am the official\nNAME RATER!\fWant me to rate\nthe nicknames of\nyour POKéMON?",
        function(yes)
          if not yes then bye() return end
          push(game, t._NameRatersHouseNameRaterWhichPokemonText
            or "Which POKéMON\nshould I look at?", function()
            local PartyMenu = require("src.ui.PartyMenu")
            game.stack:push(PartyMenu.new(game, {
              pickOnly = true,
              -- backing out of the party menu is .did_not_rename:
              -- "Fine! Come any time you like!" (NameRatersHouse.asm)
              onCancel = bye,
              onSwitch = function(mon)
                local def = game.data.pokemon[mon.species]
                local curName = mon.nickname or def.name or mon.species
                -- NameRatersHouseCheckMonOTScript: a mon whose OT name
                -- or OT ID isn't the player's can't be renamed
                local player = game.save.player
                local foreign = mon.traded
                  or (mon.ot ~= nil and mon.ot ~= player.name)
                  or (mon.otId ~= nil and player.id ~= nil
                      and mon.otId ~= player.id)
                if foreign then
                  push(game, fill(t._NameRatersHouseNameRaterATrulyImpeccableNameText
                    or "{RAM:}, is it?\nThat is a truly\nimpeccable name!\fTake good care of\n{RAM:}!",
                    { ram = curName }), done)
                  return
                end
                ask(game, fill(t._NameRatersHouseNameRaterGiveItANiceNameText
                  or "{RAM:}, is it?\nThat is a decent\nnickname!\fBut, would you\nlike me to give\nit a nicer name?\fHow about it?",
                  { ram = curName }), function(rename)
                  if not rename then bye() return end
                  push(game, t._NameRatersHouseNameRaterWhatShouldWeNameItText
                    or "Fine! What should\nwe name it?", function()
                    local NamingScreen = require("src.ui.NamingScreen")
                    game.stack:push(NamingScreen.new(game, {
                      title = (def.name or mon.species) .. "'s name?",
                      maxLen = 10,
                      default = mon.nickname,
                      onDone = function(name)
                        if name and #name > 0 and name ~= def.name then
                          mon.nickname = name
                        else
                          mon.nickname = nil
                        end
                        push(game, fill(t._NameRatersHouseNameRaterPokemonHasBeenRenamedText
                          or "OK! This POKéMON\nhas been renamed\n{RAM:}!\fThat's a better\nname than before!",
                          { ram = mon.nickname or def.name }), done)
                      end,
                    }))
                  end)
                end)
              end,
            }))
          end)
        end)
    end,
  },
}

-- -------------------------------------------------------------------
-- Saffron City occupation / liberation (scripts/SaffronCity.asm object
-- defaults + scripts/SilphCo11F.asm SilphCo11FTeamRocketLeavesScript +
-- scripts/PokemonTower7F.asm Fuji rescue).  The street ROCKETs guard
-- the gym and Silph Co doors; rescuing Mr. Fuji swaps the Silph door
-- guard (ROCKET8 -> ROCKET9), and beating Silph Giovanni clears every
-- rocket and shows the liberated-city NPCs.  Synced on map enter so it
-- also repairs saves made before this script existed.
-- -------------------------------------------------------------------

local SAFFRON_ROCKETS = {
  "SAFFRONCITY_ROCKET1", "SAFFRONCITY_ROCKET2", "SAFFRONCITY_ROCKET3",
  "SAFFRONCITY_ROCKET4", "SAFFRONCITY_ROCKET5", "SAFFRONCITY_ROCKET6",
  "SAFFRONCITY_ROCKET7", "SAFFRONCITY_ROCKET8", "SAFFRONCITY_ROCKET9",
}
local SAFFRON_CIVILIANS = {
  "SAFFRONCITY_SCIENTIST", "SAFFRONCITY_SILPH_WORKER_M",
  "SAFFRONCITY_SILPH_WORKER_F", "SAFFRONCITY_GENTLEMAN",
  "SAFFRONCITY_PIDGEOT", "SAFFRONCITY_ROCKER",
}

M.SAFFRON_CITY = {
  onEnter = function(game, ow)
    local Commands = require("src.script.Commands")
    local ctx = { game = game, save = game.save, overworld = ow }
    if game.save.flags.EVENT_BEAT_SILPH_CO_GIOVANNI then
      for _, name in ipairs(SAFFRON_ROCKETS) do
        Commands.hide_object(ctx, "SAFFRON_CITY", name)
      end
      for _, name in ipairs(SAFFRON_CIVILIANS) do
        Commands.show_object(ctx, "SAFFRON_CITY", name)
      end
    elseif game.save.flags.EVENT_RESCUED_MR_FUJI then
      Commands.hide_object(ctx, "SAFFRON_CITY", "SAFFRONCITY_ROCKET8")
      Commands.show_object(ctx, "SAFFRON_CITY", "SAFFRONCITY_ROCKET9")
    end
  end,
}

-- -------------------------------------------------------------------
-- Elite Four room exit doors (scripts/LoreleisRoom.asm
-- LoreleiShowOrHideExitBlock and the Bruno/Agatha equivalents): the
-- block above the exit warp stays solid until the room's trainer is
-- beaten.  LORELEIS_ROOM ships closed in the extracted .blk, so
-- without this the league was a dead end after Lorelei.
-- -------------------------------------------------------------------

local function e4ExitSeal(flag, closedBlock, openBlock, dontRunText, autoFlag)
  local seal = function(game, ow)
    local open = game.save.flags[flag]
    ow:replaceBlock(2, 0, open and openBlock or closedBlock)
    -- the auto walk-in on first (south) entry (LoreleiScriptWalkIntoRoom)
    if autoFlag and not game.save.flags[autoFlag] and ow.player.cellY >= 10 then
      game.save.flags[autoFlag] = true
      ow:scriptMove(ow.player, "up", 6)
    end
  end
  -- onVictory re-runs the seal so the door opens right after the
  -- battle, like pokered's post-battle map reload
  return {
    onEnter = seal,
    onVictory = seal,
    -- retreating toward the entrance gets "Don't run away!" and a
    -- shove back up (the entrance coords rows in each room script)
    onStep = function(game, ow, x, y)
      if y < 10 or x < 4 or x > 5 then return false end
      local TextBox = require("src.render.TextBox")
      game.stack:push(TextBox.new(game,
        game.data.text[dontRunText] or "Don't run away!", function()
        ow:scriptMove(ow.player, "up", 1)
      end))
      return true
    end,
  }
end

M.LORELEIS_ROOM = e4ExitSeal("EVENT_BEAT_LORELEIS_ROOM_TRAINER_0", 0x24, 0x05,
  "_LoreleisRoomLoreleiDontRunAwayText", "EVENT_AUTOWALKED_INTO_LORELEIS_ROOM")
M.BRUNOS_ROOM = e4ExitSeal("EVENT_BEAT_BRUNOS_ROOM_TRAINER_0", 0x24, 0x05,
  "_BrunosRoomBrunoDontRunAwayText", "EVENT_AUTOWALKED_INTO_BRUNOS_ROOM")
M.AGATHAS_ROOM = e4ExitSeal("EVENT_BEAT_AGATHAS_ROOM_TRAINER_0", 0x3b, 0x0e,
  "_AgathasRoomAgathaDontRunAwayText", "EVENT_AUTOWALKED_INTO_AGATHAS_ROOM")

-- -------------------------------------------------------------------
-- Lance's room (scripts/LancesRoom.asm). Unlike the other three E4
-- rooms this one gates its ENTRANCE, not its exit: the .blk ships with
-- the arena doorway CLOSED (blocks $72/$73 at block (2,6)/(3,6), cells
-- (4-7,12-13)), and LanceShowOrHideEntranceBlocks OPENS it ($31/$32)
-- on every map load while EVENT_LANCES_ROOM_LOCK_DOOR is unset.
-- Without this script the doorway never opened, so the whole arena --
-- Lance AND both CHAMPIONS_ROOM warps at (5,0)/(6,0) -- was sealed off
-- from the entrance hall and the league dead-ended here ("goto (6,11)
-- unreachable on LANCES_ROOM").
--
-- LancesRoomDefaultScript's coordinate triggers, all inert once
-- EVENT_BEAT_LANCE is set:
--   (5,1)/(6,2)   beside Lance -> his battle starts (a coordinate
--                 trigger, not a talk; victories.lua OPP_LANCE#1 sets
--                 EVENT_BEAT_LANCE on the win, so a loss re-arms)
--   (5,11)/(6,11) the doorway -> CheckAndSetEvent
--                 EVENT_LANCES_ROOM_LOCK_DOOR: first crossing seals
--                 the door behind the player with SFX_GO_INSIDE
--   (24,16)       the entrance staircase -> WalkToLance: an auto-walk
--                 (up 12, left 12, down 7, left 6) landing on (6,11).
--                 It marches straight across the room's water decor:
--                 pokered's CollisionCheckOnLand skips collision
--                 entirely while simulated joypad states run, and our
--                 scriptMove is collision-free the same way.
-- -------------------------------------------------------------------

local function lanceEntranceBlocks(game, ow)
  local locked = game.save.flags.EVENT_LANCES_ROOM_LOCK_DOOR
  ow:replaceBlock(2, 6, locked and 0x72 or 0x31)
  ow:replaceBlock(3, 6, locked and 0x73 or 0x32)
end

local function lanceLockDoor(game, ow)
  if game.save.flags.EVENT_LANCES_ROOM_LOCK_DOOR then return end
  game.save.flags.EVENT_LANCES_ROOM_LOCK_DOOR = true
  require("src.core.Sound").play(game.data, "Go_Inside")
  lanceEntranceBlocks(game, ow)
end

local function lanceWalkIn(game, ow)
  ow:scriptMove(ow.player, "up", 12, function()
    ow:scriptMove(ow.player, "left", 12, function()
      ow:scriptMove(ow.player, "down", 7, function()
        ow:scriptMove(ow.player, "left", 6, function()
          -- the walk lands on (6,11); vanilla's per-frame coord poll
          -- then locks the door at once. scriptMove landings do not
          -- fire onStep, so lock here.
          lanceLockDoor(game, ow)
        end)
      end)
    end)
  end)
end

M.LANCES_ROOM = {
  onEnter = function(game, ow)
    lanceEntranceBlocks(game, ow)
    -- the warp arrival lands ON the staircase trigger, and onStep only
    -- fires for completed steps -- start the walk-in here, the same
    -- way Lorelei's auto walk-in runs from its onEnter
    if not game.save.flags.EVENT_BEAT_LANCE
       and ow.player.cellX == 24 and ow.player.cellY == 16 then
      lanceWalkIn(game, ow)
    end
  end,
  onStep = function(game, ow, x, y)
    if game.save.flags.EVENT_BEAT_LANCE then return false end
    if (x == 5 and y == 1) or (x == 6 and y == 2) then
      local lance
      for _, npc in ipairs(ow.npcs) do
        if npc.def and npc.def.name == "LANCESROOM_LANCE" then lance = npc break end
      end
      if not lance or ow:trainerDefeated(lance) then return false end
      lance:facePlayer(ow.player)
      ow:engageTrainer(lance, function() end)
      return true
    end
    if (x == 5 or x == 6) and y == 11 then
      lanceLockDoor(game, ow)
      return false
    end
    if x == 24 and y == 16 then
      lanceWalkIn(game, ow)
      return true
    end
    return false
  end,
}

M.CELADON_CHIEF_HOUSE = require("data.scripts.celadon_chief_house")

return M
