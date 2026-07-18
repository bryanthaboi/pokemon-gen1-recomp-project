-- pokered/scripts/SilphCo4F.asm: SilphCo4FSilphWorkerMText
-- Uses SilphCo6FBeatGiovanniPrintDEOrPrintHLScript: if EVENT_BEAT_SILPH_CO_GIOVANNI
-- is set, show the "Team Rocket is gone?" line; otherwise show the "hiding" line.
return {
  SILPH_CO_4F = {
    talk = {
      TEXT_SILPHCO4F_SILPH_WORKER_M = {
        {"face_player"},
        {"check_flag", "EVENT_BEAT_SILPH_CO_GIOVANNI"},
        {"jump_if_true", 5},
        {"show_text", "_SilphCo4FSilphWorkerMImHidingText"},
        {"jump", 6},
        {"show_text", "_SilphCo4FSilphWorkerMTeamRocketIsGoneText"},
      },
    },
  },
}
