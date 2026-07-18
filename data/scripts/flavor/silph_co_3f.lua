-- Flavor talk scripts for Silph Co. 3F.
-- Source: pokered/scripts/SilphCo3F.asm, pokered/text/SilphCo3F.asm

return {
  SILPH_CO_3F = {
    talk = {
      -- SilphCo3FSilphWorkerMText (scripts/SilphCo3F.asm):
      -- CheckEvent EVENT_BEAT_SILPH_CO_GIOVANNI ->
      --   set: _SilphCo3FSilphWorkerMYouSavedUsText
      --   not set: _SilphCo3FSilphWorkerMWhatShouldIDoText
      TEXT_SILPHCO3F_SILPH_WORKER_M = {
        { "check_flag", "EVENT_BEAT_SILPH_CO_GIOVANNI" },
        { "jump_if_true", 4 },
        { "show_text", "_SilphCo3FSilphWorkerMWhatShouldIDoText" },
        { "jump", 5 },
        { "show_text", "_SilphCo3FSilphWorkerMYouSavedUsText" },
      },
    },
  },
}
