-- Silph Co. 10F flavor dialogue.
-- Registered standalone (not via init.lua by this agent); returns the
-- talk table for SILPH_CO_10F.

return {
  SILPH_CO_10F = {
    talk = {
      -- pokered/scripts/SilphCo10F.asm SilphCo10FSilphWorkerFText:
      -- CheckEvent EVENT_BEAT_SILPH_CO_GIOVANNI branches between the
      -- "I'm scared" line (Giovanni not yet beaten) and the "please
      -- keep quiet about my crying" line (after Giovanni is beaten).
      TEXT_SILPHCO10F_SILPH_WORKER_F = {
        { "face_player" },
        { "check_flag", "EVENT_BEAT_SILPH_CO_GIOVANNI" },
        { "jump_if_true", 5 },
        { "show_text", "_SilphCo10FSilphWorkerFImScaredText" },
        { "jump", 6 },
        { "show_text", "_SilphCo10FSilphWorkerFQuietAboutMyCryingText" },
      },
    },
  },
}
