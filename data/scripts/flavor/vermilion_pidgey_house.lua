-- pokered/scripts/VermilionPidgeyHouse.asm: VermilionPidgeyHousePidgeyText
-- text_far _VermilionPidgeyHousePidgeyText, then text_asm plays the PIDGEY
-- cry (ld a, PIDGEY / call PlayCry / call WaitForSoundToFinish) before
-- TextScriptEnd. This port has no cry-playback command, so only the
-- flavor line is ported.

return {
  VERMILION_PIDGEY_HOUSE = {
    talk = {
      TEXT_VERMILIONPIDGEYHOUSE_PIDGEY = {
        {"face_player"},
        {"show_text", "_VermilionPidgeyHousePidgeyText"},
      },
    },
  },
}
