-- Silph Co. 9F (registry id: SILPH_CO_9F)
-- Source: pokered/scripts/SilphCo9F.asm, pokered/text/SilphCo9F.asm

return {
  SILPH_CO_9F = {
    talk = {
      -- SilphCo9FNurseText (pokered/scripts/SilphCo9F.asm):
      -- before EVENT_BEAT_SILPH_CO_GIOVANNI: heals the party and shows
      -- "You look tired..." then "Don't give up!"; after the event, just
      -- says thanks. Nurse texts are not in data/generated/text.lua, so
      -- the exact pokered/text/SilphCo9F.asm strings are used as literals.
      TEXT_SILPHCO9F_NURSE = {
        { "face_player" },
        { "check_flag", "EVENT_BEAT_SILPH_CO_GIOVANNI" },
        { "jump_if_true", 8 },
        { "show_text", "You look tired!\nYou should take a\nquick nap!" },
        { "heal_party" },
        { "show_text", "Don't give up!" },
        { "jump", 9 },
        { "show_text", "Thank you so\nmuch!" },
      },
    },
  },
}
