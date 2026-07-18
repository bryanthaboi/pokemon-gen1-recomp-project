-- pokered/scripts/SSAnneB1FRooms.asm: SSAnneB1FRoomsMachokeText
-- text_far _SSAnneB1FRoomsMachokeText, then `ld a, MACHOKE / call PlayCry`
-- (cry playback has no equivalent Commands.lua verb in this port, so only
-- the flavor text is ported).
return {
    SS_ANNE_B1F_ROOMS = {
        talk = {
            TEXT_SSANNEB1FROOMS_MACHOKE = {
                { "face_player" },
                { "show_text", "_SSAnneB1FRoomsMachokeText" },
            },
        },
    },
}
