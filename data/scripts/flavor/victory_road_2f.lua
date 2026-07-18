-- Moltres (scripts/VictoryRoad2F.asm VictoryRoad2FMoltresText +
-- home/trainers.asm TalkToTrainer; MOLTRES 50 from
-- data/maps/objects/VictoryRoad2F.asm).
--
-- The text_asm loads MoltresTrainerHeader and calls TalkToTrainer:
-- VictoryRoad2FMoltresBattleText is text_far "Gyaoo!" + text_asm
-- PlayCry MOLTRES + WaitForSoundToFinish, then the wild battle starts --
-- or, when EVENT_BEAT_MOLTRES is already set, the (identical)
-- after-battle text prints and nothing else happens.  EndTrainerBattle
-- sets EVENT_BEAT_MOLTRES and hides the object on any non-blackout
-- result (win, catch or flee) -- static_battle mirrors that.

local M = {}

M.VICTORY_ROAD_2F = {
  talk = {
    TEXT_VICTORYROAD2F_MOLTRES = {
      { "play_cry", "MOLTRES" },                                -- 1 text_asm PlayCry
      { "show_text", "_VictoryRoad2FMoltresBattleText" },       -- 2 "Gyaoo!"
      { "check_flag", "EVENT_BEAT_MOLTRES" },                   -- 3
      { "jump_if_true", 6 },                                    -- 4 already beaten: text only
      { "static_battle", "MOLTRES", 50, "EVENT_BEAT_MOLTRES" }, -- 5
    },
  },
}

return M
