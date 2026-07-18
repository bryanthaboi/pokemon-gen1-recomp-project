-- pokered/scripts/SSAnne1FRooms.asm: SSAnne1FRoomsWigglytuffText
-- text_far _SSAnne1FRoomsWigglytuffText; then ld a, WIGGLYTUFF / call PlayCry (cosmetic cry sound, not ported)
return {
  SS_ANNE_1F_ROOMS = {
    talk = {
      TEXT_SSANNE1FROOMS_WIGGLYTUFF = {
        {"face_player"},
        {"show_text", "_SSAnne1FRoomsWigglytuffText"},
      },
    },
  },
}
