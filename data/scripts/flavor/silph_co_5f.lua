-- pokered/scripts/SilphCo5F.asm: SilphCo5FSilphWorkerMText
-- Uses SilphCo6FBeatGiovanniPrintDEOrPrintHLScript: if EVENT_BEAT_SILPH_CO_GIOVANNI
-- is set, show the "You're our hero" line; otherwise show the "That's you right?" line.
return {
  SILPH_CO_5F = {
    talk = {
      TEXT_SILPHCO5F_SILPH_WORKER_M = {
        {"face_player"},
        {"check_flag", "EVENT_BEAT_SILPH_CO_GIOVANNI"},
        {"jump_if_true", 5},
        {"show_text", "_SilphCo5FSilphWorkerMThatsYouRightText"},
        {"jump", 6},
        {"show_text", "_SilphCo5FSilphWorkerMYoureOurHeroText"},
      },
    },
  },
}
