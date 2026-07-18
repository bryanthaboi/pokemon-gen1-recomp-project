-- Gym metadata for the statue hidden events (data/maps/badge_maps.asm
-- gives map -> badge; each gym's script carries its .CityName /
-- .LeaderName strings, e.g. scripts/VermilionGym.asm
-- LoadGymLeaderAndCityName).
--
-- The module is also merged into the map-script registry (see
-- data/scripts/init.lua), so gym maps can carry hand-ported `talk`
-- scripts alongside the statue metadata.

local M = {
  PEWTER_GYM    = { city = "PEWTER CITY",    leader = "BROCK",    badge = "BOULDERBADGE" },
  CERULEAN_GYM  = { city = "CERULEAN CITY",  leader = "MISTY",    badge = "CASCADEBADGE" },
  VERMILION_GYM = { city = "VERMILION CITY", leader = "LT.SURGE", badge = "THUNDERBADGE" },
  CELADON_GYM   = { city = "CELADON CITY",   leader = "ERIKA",    badge = "RAINBOWBADGE" },
  FUCHSIA_GYM   = { city = "FUCHSIA CITY",   leader = "KOGA",     badge = "SOULBADGE" },
  SAFFRON_GYM   = { city = "SAFFRON CITY",   leader = "SABRINA",  badge = "MARSHBADGE" },
  CINNABAR_GYM  = { city = "CINNABAR ISLAND", leader = "BLAINE",  badge = "VOLCANOBADGE" },
  VIRIDIAN_GYM  = { city = "VIRIDIAN CITY",  leader = "GIOVANNI", badge = "EARTHBADGE" },
}

-- scripts/PewterGym.asm PewterGymBrockText (text_asm): CheckEvent
-- EVENT_BEAT_BROCK branches his dialogue.  Before the badge he prints
-- _PewterGymBrockPreBattleText and engages the leader battle
-- (engageTrainer shows that same pre-battle text via resolveText; the
-- badge/TM34 rewards and EVENT_BEAT_BROCK come from
-- data/scripts/victories.lua OPP_BROCK#1).  After the badge his
-- .afterBeat branch prints _PewterGymBrockPostBattleAdviceText ("Go to
-- the GYM in CERULEAN...").  The original's middle branch (beat but
-- TM34 not yet handed over, CheckEventReuseA EVENT_GOT_TM34) is
-- unreachable in the port: the TM is granted with the victory.
M.PEWTER_GYM.talk = {
  TEXT_PEWTERGYM_BROCK = function(game, ow, npc, done)
    if game.save.flags.EVENT_BEAT_BROCK then
      local TextBox = require("src.render.TextBox")
      game.stack:push(TextBox.new(game,
        game.data.text._PewterGymBrockPostBattleAdviceText
        or "Go to the GYM in\nCERULEAN and test\nyour abilities!", done))
    else
      ow:engageTrainer(npc, done)
    end
  end,
}

-- The other leaders' text_asm bodies all follow Brock's shape
-- (scripts/CeruleanGym.asm CeruleanGymMistyText ... scripts/ViridianGym.asm
-- ViridianGymGiovanniText): CheckEvent EVENT_BEAT_<LEADER> -- before the
-- badge print the pre-battle text and engage the leader battle
-- (engageTrainer shows that same pre-battle text via resolveText; the
-- badge/TM rewards and the beat flag come from data/scripts/victories.lua)
-- -- and once beaten print the post-battle advice text.  As with Brock,
-- the originals' middle branch (beaten but the TM not yet handed over,
-- CheckEventReuseA EVENT_GOT_TM*) is unreachable in the port: the TM is
-- granted with the victory.
-- afterAdvice, when given, takes over `done`: it is handed (game, ow, npc,
-- done) and must call done() itself once whatever it's doing (e.g. a fade
-- around a HideObject) finishes, rather than having it invoked
-- automatically. Only Giovanni's farewell uses this.
local function leaderTalk(beatFlag, adviceLabel, fallback, afterAdvice)
  return function(game, ow, npc, done)
    if game.save.flags[beatFlag] then
      local TextBox = require("src.render.TextBox")
      local finish = done
      if afterAdvice then
        finish = function()
          afterAdvice(game, ow, npc, done)
        end
      end
      game.stack:push(TextBox.new(game,
        game.data.text[adviceLabel] or fallback, finish))
    else
      ow:engageTrainer(npc, done)
    end
  end
end

-- scripts/CeruleanGym.asm CeruleanGymMistyText .afterBeat: Misty has no
-- separate advice label -- her repeat dialogue is the TM11 explanation
-- (.TM11ExplanationText).
M.CERULEAN_GYM.talk = {
  TEXT_CERULEANGYM_MISTY = leaderTalk("EVENT_BEAT_MISTY",
    "_CeruleanGymMistyTM11ExplanationText",
    "TM11 teaches\nBUBBLEBEAM!"),
}

-- scripts/VermilionGym.asm VermilionGymLTSurgeText .got_tm24_already
M.VERMILION_GYM.talk = {
  TEXT_VERMILIONGYM_LT_SURGE = leaderTalk("EVENT_BEAT_LT_SURGE",
    "_VermilionGymLTSurgePostBattleAdviceText",
    "A little word of\nadvice, kid!"),
}

-- scripts/CeladonGym.asm CeladonGymErikaText .afterBeat
M.CELADON_GYM.talk = {
  TEXT_CELADONGYM_ERIKA = leaderTalk("EVENT_BEAT_ERIKA",
    "_CeladonGymErikaPostBattleAdviceText",
    "You are cataloging\nPOKéMON? I must\nsay I'm impressed."),
}

-- scripts/FuchsiaGym.asm FuchsiaGymKogaText .afterBeat
M.FUCHSIA_GYM.talk = {
  TEXT_FUCHSIAGYM_KOGA = leaderTalk("EVENT_BEAT_KOGA",
    "_FuchsiaGymKogaPostBattleAdviceText",
    "When afflicted by\nTOXIC, POKéMON\nsuffer more and\nmore as battle\nprogresses!"),
}

-- scripts/SaffronGym.asm SaffronGymSabrinaText .afterBeat
M.SAFFRON_GYM.talk = {
  TEXT_SAFFRONGYM_SABRINA = leaderTalk("EVENT_BEAT_SABRINA",
    "_SaffronGymSabrinaPostBattleAdviceText",
    "Everyone has\npsychic power!\nPeople just don't\nrealize it!"),
}

-- scripts/CinnabarGym.asm CinnabarGymBlaineText .afterBeat
M.CINNABAR_GYM.talk = {
  TEXT_CINNABARGYM_BLAINE = leaderTalk("EVENT_BEAT_BLAINE",
    "_CinnabarGymBlainePostBattleAdviceText",
    "FIRE BLAST is the\nultimate fire\ntechnique!"),
}

-- scripts/ViridianGym.asm ViridianGymGiovanniText .afterBeat: after the
-- farewell speech Giovanni leaves for good -- the original fades to
-- black (GBFadeOutToBlack), HideObject TOGGLE_VIRIDIAN_GYM_GIOVANNI while
-- the screen is black, then fades back in (GBFadeInFromBlack). The port
-- reuses src/render/Transition.lua (the same fade-out/callback/fade-in
-- primitive warps and PartyMenu field moves push) so HideObject fires at
-- its onMidpoint, between the two fades, instead of as a bare disappearance
-- when the text box closes. The objectToggles entry persists in the save,
-- so he stays gone on re-entry.  pokered's beat flag is
-- EVENT_BEAT_VIRIDIAN_GYM_GIOVANNI; the port's equivalent set on winning
-- that battle is EVENT_BEAT_GIOVANNI (data/scripts/victories.lua
-- OPP_GIOVANNI#3).
M.VIRIDIAN_GYM.talk = {
  TEXT_VIRIDIANGYM_GIOVANNI = leaderTalk("EVENT_BEAT_GIOVANNI",
    "_ViridianGymGiovanniPostBattleAdviceText",
    "Let us meet again\nsome day!\nFarewell!",
    function(game, ow, npc, done)
      local Transition = require("src.render.Transition")
      game.stack:push(Transition.new(game, function()
        local ok, Commands = pcall(require, "src.script.Commands")
        if ok and Commands.hide_object then
          Commands.hide_object({ game = game, save = game.save, overworld = ow },
            "VIRIDIAN_GYM", "VIRIDIANGYM_GIOVANNI")
        end
      end, done))
    end),
}

return M
