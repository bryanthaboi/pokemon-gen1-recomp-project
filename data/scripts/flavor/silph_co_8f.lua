-- Flavor talk scripts for Silph Co. 8F.
-- Source: pokered/scripts/SilphCo8F.asm, pokered/text/SilphCo8F.asm

return {
  SILPH_CO_8F = {
    talk = {
      -- SilphCo8FSilphWorkerMText (scripts/SilphCo8F.asm):
      -- CheckEvent EVENT_BEAT_SILPH_CO_GIOVANNI ->
      --   not set: _SilphCo8FSilphWorkerMSilphIsFinishedText
      --   set: _SilphCo8FSilphWorkerMThanksForSavingUsText
      TEXT_SILPHCO8F_SILPH_WORKER_M = {
        { "check_flag", "EVENT_BEAT_SILPH_CO_GIOVANNI" },
        { "jump_if_true", 4 },
        { "show_text", "_SilphCo8FSilphWorkerMSilphIsFinishedText" },
        { "jump", 5 },
        { "show_text", "_SilphCo8FSilphWorkerMThanksForSavingUsText" },
      },
    },
  },
}
