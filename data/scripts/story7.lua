-- Gym-guide NPCs: the helpful trainer stationed near each gym's door.
-- Each pokered <Gym>GymGuideText is a text_asm that branches on whether the
-- leader's badge has already been earned; only Pewter's guide also asks
-- a YES/NO question first (the answer only changes the transitional
-- line -- the advice text that follows is the same either way).
--
-- Row-list rows use the numeric-jump-target style from
-- data/scripts/oaks_lab.lua; see src/script/ScriptRunner.lua for how
-- jump/jump_if_true/jump_if_false select the next row (1-based index).

local M = {}

-- Common "beaten the leader? -> congratulations : champ-in-making advice"
-- shape shared by 7 of the 8 guides (CheckEvent EVENT_BEAT_<LEADER> ...).
local function badgeBranch(beatFlag, champText, beatText)
  return {
    { "check_flag", beatFlag },  -- 1
    { "jump_if_true", 5 },       -- 2
    { "show_text", champText },  -- 3
    { "jump", 6 },                -- 4 (skip the beaten-text row)
    { "show_text", beatText },   -- 5
  }
end

M.CERULEAN_GYM = {
  talk = {
    -- scripts/CeruleanGym.asm CeruleanGymGymGuideText
    TEXT_CERULEANGYM_GYM_GUIDE = badgeBranch("EVENT_BEAT_MISTY",
      "_CeruleanGymGymGuideChampInMakingText",
      "_CeruleanGymGymGuideBeatMistyText"),
  },
}

M.CINNABAR_GYM = {
  talk = {
    -- scripts/CinnabarGym.asm CinnabarGymGymGuideText
    TEXT_CINNABARGYM_GYM_GUIDE = badgeBranch("EVENT_BEAT_BLAINE",
      "_CinnabarGymGymGuideChampInMakingText",
      "_CinnabarGymGymGuideBeatBlaineText"),
  },
}

M.FUCHSIA_GYM = {
  talk = {
    -- scripts/FuchsiaGym.asm FuchsiaGymGymGuideText
    TEXT_FUCHSIAGYM_GYM_GUIDE = badgeBranch("EVENT_BEAT_KOGA",
      "_FuchsiaGymGymGuideChampInMakingText",
      "_FuchsiaGymGymGuideBeatKogaText"),
  },
}

-- TEXT_GAMECORNER_GYM_GUIDE is displayed on the GAME_CORNER map (the
-- gym guide object_event stands just inside the Game Corner door, next
-- to the stairs down to Celadon Gym) -- scripts/GameCorner.asm
-- GameCornerGymGuideText, gated on Celadon's leader ERIKA.
M.GAME_CORNER = {
  talk = {
    TEXT_GAMECORNER_GYM_GUIDE = badgeBranch("EVENT_BEAT_ERIKA",
      "_GameCornerGymGuideChampInMakingText",
      "_GameCornerGymGuideTheyOfferRarePokemonText"),
  },
}

M.SAFFRON_GYM = {
  talk = {
    -- scripts/SaffronGym.asm SaffronGymGymGuideText
    TEXT_SAFFRONGYM_GYM_GUIDE = badgeBranch("EVENT_BEAT_SABRINA",
      "_SaffronGymGuideChampInMakingText",
      "_SaffronGymGuideBeatSabrinaText"),
  },
}

M.VERMILION_GYM = {
  talk = {
    -- scripts/VermilionGym.asm VermilionGymGymGuideText
    -- (checks wBeatGymFlags BIT_THUNDERBADGE rather than CheckEvent, but
    -- it's the same underlying condition as EVENT_BEAT_LT_SURGE)
    TEXT_VERMILIONGYM_GYM_GUIDE = badgeBranch("EVENT_BEAT_LT_SURGE",
      "_VermilionGymGymGuideChampInMakingText",
      "_VermilionGymGymGuideBeatLTSurgeText"),
  },
}

M.VIRIDIAN_GYM = {
  talk = {
    -- scripts/ViridianGym.asm ViridianGymGymGuideText
    -- (checks EVENT_BEAT_VIRIDIAN_GYM_GIOVANNI in pokered; the port's
    -- equivalent flag set on winning that battle is EVENT_BEAT_GIOVANNI,
    -- see data/scripts/victories.lua OPP_GIOVANNI#3)
    TEXT_VIRIDIANGYM_GYM_GUIDE = badgeBranch("EVENT_BEAT_GIOVANNI",
      "_ViridianGymGuidePreBattleText",
      "_ViridianGymGuidePostBattleText"),
  },
}

-- Pewter's guide (scripts/PewterGym.asm PewterGymGuideText) is the one
-- with a real YES/NO branch: before the badge is earned he asks (via
-- PrintText + YesNoChoice on the "I'm no trainer, but I can tell you
-- how to win!" text), and BOTH answers lead into the same advice text --
-- only the one-line lead-in differs ("All right! Let's get happening!"
-- on YES vs. "It's a free service! Let's get happening!" on NO).  Once
-- BOULDERBADGE is set he just congratulates you.
M.PEWTER_GYM = {
  talk = {
    TEXT_PEWTERGYM_GYM_GUIDE = {
      { "check_flag", "EVENT_BEAT_BROCK" },              -- 1
      { "jump_if_true", 10 },                            -- 2
      { "ask", "_PewterGymGuidePreAdviceText" },          -- 3
      { "jump_if_false", 7 },                             -- 4
      { "show_text", "_PewterGymGuideBeginAdviceText" },  -- 5 (YES)
      { "jump", 8 },                                      -- 6
      { "show_text", "_PewterGymGuideFreeServiceText" },  -- 7 (NO)
      { "show_text", "_PewterGymGuideAdviceText" },       -- 8 (common)
      { "jump", 11 },                                     -- 9
      { "show_text", "_PewterGymGuidePostBattleText" },   -- 10 (beaten)
    },
  },
}

return M
