-- Celadon Chief House (scripts/CeladonChiefHouse.asm).  The CHIEF is a
-- talk-only NPC in the original ROM, and ChiefData (data/trainers/
-- parties.asm) is an empty, unreferenced trainer entry.  After the HALL
-- OF FAME (EVENT_BEAT_CHAMPION_RIVAL) the CHIEF puts up a fight, using a
-- reconstructed party for the otherwise-unused OPP_CHIEF class.

return {
  talk = {
    TEXT_CELADONCHIEFHOUSE_CHIEF = {
      { "face_player" },                                        -- 1
      { "check_flag", "EVENT_BEAT_CHAMPION_RIVAL" },            -- 2
      { "jump_if_false", 12 },                                  -- 3
      { "check_flag", "EVENT_BEAT_CELADON_CHIEF" },             -- 4
      { "jump_if_true", 12 },                                   -- 5
      { "show_text", "So you've come to\nshut down my\noperation?\f"
        .. "TEAM ROCKET's\nCHIEF won't go\ndown so easy!" },    -- 6
      { "start_battle", "trainer", "OPP_CHIEF", 1 },            -- 7
      { "jump_if_false", "end" },                               -- 8
      { "set_flag", "EVENT_BEAT_CELADON_CHIEF" },               -- 9
      { "show_text", "Gah! Even the\nCHIEF is no match\nfor you!\f"
        .. "TEAM ROCKET is\nfinished for\ngood!" },             -- 10
      { "jump", "end" },                                        -- 11
      { "show_text", "_CeladonChiefHouseChiefText" },           -- 12
    },
  },
}
