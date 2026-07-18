-- Hand-ported flavor text for OaksLab (registry id OAKS_LAB).
-- Source: pokered/scripts/OaksLab.asm.  These five text_asm bodies are
-- all simple "PrintText; jp TextScriptEnd" -- no flag branches, no
-- YES/NO menu -- so a one-row talk script showing the real extracted
-- text is a faithful port.  (The rest of OaksLab.asm's TEXT_OAKSLAB_*
-- constants -- OAK1, the three starter poke balls, RIVAL -- are already
-- ported with full branching logic in data/scripts/oaks_lab.lua.)

return {
  OAKS_LAB = {
    talk = {
      -- OaksLabGirlText (scripts/OaksLab.asm)
      TEXT_OAKSLAB_GIRL = {
        { "face_player" },
        { "show_text", "_OaksLabGirlText" },
      },

      -- OaksLabPokedexText, used for both the POKEDEX1 and POKEDEX2
      -- table objects (scripts/OaksLab.asm OaksLab_TextPointers)
      TEXT_OAKSLAB_POKEDEX1 = {
        { "face_player" },
        { "show_text", "_OaksLabPokedexText" },
      },
      TEXT_OAKSLAB_POKEDEX2 = {
        { "face_player" },
        { "show_text", "_OaksLabPokedexText" },
      },

      -- OaksLabScientistText, used for both SCIENTIST1 and SCIENTIST2
      -- (scripts/OaksLab.asm OaksLab_TextPointers)
      TEXT_OAKSLAB_SCIENTIST1 = {
        { "face_player" },
        { "show_text", "_OaksLabScientistText" },
      },
      TEXT_OAKSLAB_SCIENTIST2 = {
        { "face_player" },
        { "show_text", "_OaksLabScientistText" },
      },
    },
  },
}
