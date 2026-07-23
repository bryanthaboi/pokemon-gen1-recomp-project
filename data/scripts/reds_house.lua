-- Hand-ported from pret/pokered scripts/RedsHouse1F.asm.
-- Mom (RedsHouse1FMomText): pre-starter shows the wake-up / Oak tip;
-- after EVENT_GOT_STARTER, RedsHouse1FMomHealScript fades to white,
-- heals, plays MUSIC_PKMN_HEALED, fades back, then "looking great".

return {
  talk = {
    TEXT_REDSHOUSE1F_MOM = {
      { "face_player" },                                          -- 1
      { "check_flag", "EVENT_GOT_STARTER" },                      -- 2
      { "jump_if_true", 6 },                                      -- 3
      { "show_text", "_RedsHouse1FMomWakeUpText" },               -- 4
      { "jump", "end" },                                          -- 5
      -- RedsHouse1FMomHealScript
      { "show_text", "_RedsHouse1FMomYouShouldRestText" },        -- 6
      { "fade", "out", "white" },                                 -- 7  GBFadeOutToWhite
      { "heal_party" },                                           -- 8
      { "play_once", "Music_PkmnHealed" },                        -- 9  wait + restore map
      { "fade", "in", "white" },                                  -- 10 GBFadeInFromWhite
      { "show_text", "_RedsHouse1FMomLookingGreatText" },         -- 11
    },
  },
}
