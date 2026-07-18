-- Silph Co. 6F worker flavor dialogue.
-- pokered/scripts/SilphCo6F.asm: SilphCo6FSilphWorkerM1Text/M2Text/M3Text/
-- F1Text/F2Text all funnel through SilphCo6FBeatGiovanniPrintDEOrPrintHLScript,
-- which checks EVENT_BEAT_SILPH_CO_GIOVANNI and prints the "before" text (hl)
-- if not yet set, or the "after" text (de) once Giovanni has been beaten.

return {
  SILPH_CO_6F = {
    talk = {
      -- SilphCo6FSilphWorkerM1Text
      TEXT_SILPHCO6F_SILPH_WORKER_M1 = {
        { "face_player" },
        { "check_flag", "EVENT_BEAT_SILPH_CO_GIOVANNI" },
        { "jump_if_true", 5 },
        { "show_text", "_SilphCo6FSilphWorkerM1TookOverTheBuildingText" },
        { "jump", 6 },
        { "show_text", "_SilphCo6FSilphWorkerM1BackToWorkText" },
      },

      -- SilphCo6FSilphWorkerM2Text
      TEXT_SILPHCO6F_SILPH_WORKER_M2 = {
        { "face_player" },
        { "check_flag", "EVENT_BEAT_SILPH_CO_GIOVANNI" },
        { "jump_if_true", 5 },
        { "show_text", "_SilphCo6FSilphWorkerMHelpMePleaseText" },
        { "jump", 6 },
        { "show_text", "_SilphCo6FSilphWorkerMWeGotEngagedText" },
      },

      -- SilphCo6FSilphWorkerF1Text
      TEXT_SILPHCO6F_SILPH_WORKER_F1 = {
        { "face_player" },
        { "check_flag", "EVENT_BEAT_SILPH_CO_GIOVANNI" },
        { "jump_if_true", 5 },
        { "show_text", "_SilphCo6FSilphWorkerF1SuchACowardText" },
        { "jump", 6 },
        { "show_text", "_SilphCo6FSilphWorkerF1HaveToMarryHimText" },
      },

      -- SilphCo6FSilphWorkerF2Text
      TEXT_SILPHCO6F_SILPH_WORKER_F2 = {
        { "face_player" },
        { "check_flag", "EVENT_BEAT_SILPH_CO_GIOVANNI" },
        { "jump_if_true", 5 },
        { "show_text", "_SilphCo6FSilphWorkerF2TeamRocketConquerWorldText" },
        { "jump", 6 },
        { "show_text", "_SilphCo6FSilphWorkerF2TeamRocketRanText" },
      },

      -- SilphCo6FSilphWorkerM3Text
      TEXT_SILPHCO6F_SILPH_WORKER_M3 = {
        { "face_player" },
        { "check_flag", "EVENT_BEAT_SILPH_CO_GIOVANNI" },
        { "jump_if_true", 5 },
        { "show_text", "_SilphCo6FSilphWorkerM3TargetedSilphText" },
        { "jump", 6 },
        { "show_text", "_SilphCo6FSilphWorkerM3WorkForSilphText" },
      },
    },
  },
}
