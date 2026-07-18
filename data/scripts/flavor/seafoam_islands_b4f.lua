-- Articuno (scripts/SeafoamIslandsB4F.asm SeafoamIslandsB4FArticunoText +
-- home/trainers.asm TalkToTrainer; ARTICUNO 50 from
-- data/maps/objects/SeafoamIslandsB4F.asm).
--
-- The text_asm loads ArticunoTrainerHeader and calls TalkToTrainer:
-- SeafoamIslandsB4FArticunoBattleText is text_far "Gyaoo!" + text_asm
-- PlayCry ARTICUNO + WaitForSoundToFinish, then the wild battle starts --
-- or, when EVENT_BEAT_ARTICUNO is already set, the (identical)
-- after-battle text prints and nothing else happens.  The script also
-- switches to SCRIPT_SEAFOAMISLANDSB4F_OBJECT_MOVING3, which just routes
-- the battle end through EndTrainerBattle (set EVENT_BEAT_ARTICUNO + hide
-- the object on any non-blackout result) -- static_battle covers that.
-- The B4F current/boulder puzzle itself is data-driven via field.seafoam.

local M = {}

M.SEAFOAM_ISLANDS_B4F = {
  talk = {
    TEXT_SEAFOAMISLANDSB4F_ARTICUNO = {
      { "play_cry", "ARTICUNO" },                                 -- 1 text_asm PlayCry
      { "show_text", "_SeafoamIslandsB4FArticunoBattleText" },    -- 2 "Gyaoo!"
      { "check_flag", "EVENT_BEAT_ARTICUNO" },                    -- 3
      { "jump_if_true", 6 },                                      -- 4 already beaten: text only
      { "static_battle", "ARTICUNO", 50, "EVENT_BEAT_ARTICUNO" }, -- 5
    },
  },
}

return M
