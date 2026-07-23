-- Silph Co. 9F (registry id: SILPH_CO_9F)
-- Source: pokered/scripts/SilphCo9F.asm, pokered/text/SilphCo9F.asm

return {
  SILPH_CO_9F = {
    talk = {
      -- SilphCo9FNurseText (pokered/scripts/SilphCo9F.asm):
      -- before EVENT_BEAT_SILPH_CO_GIOVANNI: heals the party, white fade
      -- (Delay3 between out/in; no Music_PkmnHealed), then "Don't give
      -- up!"; after the event, just says thanks. Nurse texts are not in
      -- data/generated/text.lua, so the exact pokered/text/SilphCo9F.asm
      -- strings are used as literals.
      TEXT_SILPHCO9F_NURSE = {
        { "face_player" },                                              -- 1
        { "check_flag", "EVENT_BEAT_SILPH_CO_GIOVANNI" },                -- 2
        { "jump_if_true", 11 },                                         -- 3
        { "show_text", "You look tired!\nYou should take a\nquick nap!" }, -- 4
        { "heal_party" },                                               -- 5
        { "fade", "out", "white" },                                     -- 6
        { "wait", 3 },                                                  -- 7  Delay3
        { "fade", "in", "white" },                                      -- 8
        { "show_text", "Don't give up!" },                              -- 9
        { "jump", "end" },                                              -- 10
        { "show_text", "Thank you so\nmuch!" },                         -- 11
      },
    },
  },
}
