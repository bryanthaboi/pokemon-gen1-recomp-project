-- Hand-ported from pret/pokered scripts/CeladonMansionRoofHouse.asm
-- (CeladonMansionRoofHouseEeveePokeballText): the poke ball on the table
-- holds an Eevee (level 25).  The text_asm calls GivePokemon immediately
-- (no confirm prompt) and, on success, hides the ball object
-- (TOGGLE_CELADON_MANSION_EEVEE_GIFT predef HideObject, persisted in
-- wToggleableObjectFlags) -- the hidden ball is the original's whole
-- re-gift guard.  If the party AND box are full GivePokemon fails
-- (BoxIsFullText, .party_full) and the ball stays for later.
--
-- EVENT_GOT_EEVEE is port-internal bookkeeping with no pokered
-- equivalent, kept for save compatibility: rows 1-4 also self-heal
-- older saves (flag set before the port hid the ball) by hiding the
-- leftover ball on the next interaction.

return {
  talk = {
    TEXT_CELADONMANSION_ROOF_HOUSE_EEVEE_POKEBALL = {
      { "check_flag", "EVENT_GOT_EEVEE" },                     -- 1
      { "jump_if_false", 5 },                                  -- 2
      { "hide_object", "CELADON_MANSION_ROOF_HOUSE",
        "CELADONMANSION_ROOF_HOUSE_EEVEE_POKEBALL" },          -- 3 (old saves)
      { "jump", 13 },                                          -- 4
      { "give_pokemon", "EEVEE", 25 },                         -- 5
      { "jump_if_false", 12 },                                 -- 6 (party+box full)
      { "play_sound", "Get_Item1" },                           -- 7 (GotMonText jingle)
      { "show_text", "_GotMonText", { RAM = "EEVEE" } },       -- 8
      { "set_flag", "EVENT_GOT_EEVEE" },                       -- 9
      { "hide_object", "CELADON_MANSION_ROOF_HOUSE",
        "CELADONMANSION_ROOF_HOUSE_EEVEE_POKEBALL" },          -- 10
      { "jump", 13 },                                          -- 11
      { "show_text", "_BoxIsFullText" },                       -- 12
    },
  },
}
