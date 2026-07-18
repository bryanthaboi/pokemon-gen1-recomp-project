-- Flavor talk scripts for Silph Co. 7F.
-- Source: pokered/scripts/SilphCo7F.asm, pokered/text/SilphCo7F.asm

return {
  SILPH_CO_7F = {
    talk = {
      -- SilphCo7FSilphWorkerM2Text (scripts/SilphCo7F.asm):
      -- CheckEvent EVENT_BEAT_SILPH_CO_GIOVANNI ->
      --   not set: _SilphCo7FSilphWorkerM2AfterTheMasterBallText
      --   set: _SilphCo7FSilphWorkerM2CancelledMasterBallText
      TEXT_SILPHCO7F_SILPH_WORKER_M2 = {
        { "check_flag", "EVENT_BEAT_SILPH_CO_GIOVANNI" },
        { "jump_if_true", 4 },
        { "show_text", "_SilphCo7FSilphWorkerM2AfterTheMasterBallText" },
        { "jump", 5 },
        { "show_text", "_SilphCo7FSilphWorkerM2CancelledMasterBallText" },
      },

      -- SilphCo7FSilphWorkerM3Text (scripts/SilphCo7F.asm):
      -- CheckEvent EVENT_BEAT_SILPH_CO_GIOVANNI ->
      --   not set: _SilphCo7FSilphWorkerM3ItWouldBeBadText
      --   set: _SilphCo7FSilphWorkerM3YouChasedOffTeamRocketText
      TEXT_SILPHCO7F_SILPH_WORKER_M3 = {
        { "check_flag", "EVENT_BEAT_SILPH_CO_GIOVANNI" },
        { "jump_if_true", 4 },
        { "show_text", "_SilphCo7FSilphWorkerM3ItWouldBeBadText" },
        { "jump", 5 },
        { "show_text", "_SilphCo7FSilphWorkerM3YouChasedOffTeamRocketText" },
      },

      -- SilphCo7FSilphWorkerM4Text (scripts/SilphCo7F.asm):
      -- CheckEvent EVENT_BEAT_SILPH_CO_GIOVANNI ->
      --   not set: _SilphCo7FSilphWorkerM4ItsReallyDangerousHereText
      --   set: _SilphCo7FSilphWorkerM4SafeAtLastText
      TEXT_SILPHCO7F_SILPH_WORKER_M4 = {
        { "check_flag", "EVENT_BEAT_SILPH_CO_GIOVANNI" },
        { "jump_if_true", 4 },
        { "show_text", "_SilphCo7FSilphWorkerM4ItsReallyDangerousHereText" },
        { "jump", 5 },
        { "show_text", "_SilphCo7FSilphWorkerM4SafeAtLastText" },
      },
    },
  },
}
