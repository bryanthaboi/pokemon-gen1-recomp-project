-- SaffronPidgeyHouse (pokered/scripts/SaffronPidgeyHouse.asm)
--
-- TEXT_SAFFRONPIDGEYHOUSE_PIDGEY: SaffronPidgeyHousePidgeyText plays the
-- PIDGEY cry after showing its "Kurukkoo!" line (text_asm: ld a, PIDGEY /
-- call PlayCry / jp TextScriptEnd). The command vocabulary has no cry/SFX
-- command, so only the flavor text is ported here; the cry itself has no
-- equivalent to hook into.

return {
  SAFFRON_PIDGEY_HOUSE = {
    talk = {
      TEXT_SAFFRONPIDGEYHOUSE_PIDGEY = {
        { "face_player" },
        { "show_text", "_SaffronPidgeyHousePidgeyText" },
      },
    },
  },
}
