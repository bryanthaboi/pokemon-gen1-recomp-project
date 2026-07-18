-- pokered/scripts/PewterNidoranHouse.asm
-- PewterNidoranHouseNidoranText: text_far _PewterNidoranHouseNidoranText, then
-- text_asm plays the NIDORAN_M cry (PlayCry/WaitForSoundToFinish) before ending.
-- No sound-effect command exists in Commands.lua, so we port the dialogue line
-- only; the cry SFX is cosmetic and has no gameplay effect.
return {
  PEWTER_NIDORAN_HOUSE = {
    talk = {
      TEXT_PEWTERNIDORANHOUSE_NIDORAN = {
        { "face_player" },
        { "show_text", "_PewterNidoranHouseNidoranText" },
      },
    },
  },
}
