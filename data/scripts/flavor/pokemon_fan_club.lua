-- Flavor talk scripts for POKEMON_FAN_CLUB (pokered/scripts/PokemonFanClub.asm)
--
-- TEXT_POKEMONFANCLUB_CHAIRMAN is already ported in data/scripts/story2.lua
-- (the bike voucher chain), so it is intentionally omitted here.

local M = {}

M.POKEMON_FAN_CLUB = {
  talk = {
    -- PokemonFanClubPikachuFanText (scripts/PokemonFanClub.asm): brags
    -- about her PIKACHU unless she's already "won" the boast war against
    -- the SEEL fan (EVENT_PIKACHU_FAN_BOAST set), in which case she gets
    -- huffy and resets it. Either way she sets the other fan's boast flag
    -- so their next line is the "mine is better" retort.
    TEXT_POKEMONFANCLUB_PIKACHU_FAN = {
      { "face_player" },                                              -- 1
      { "check_flag", "EVENT_PIKACHU_FAN_BOAST" },                    -- 2
      { "jump_if_true", 7 },                                          -- 3
      { "show_text", "_PokemonFanClubPikachuFanNormalText" },         -- 4
      { "set_flag", "EVENT_SEEL_FAN_BOAST" },                         -- 5
      { "jump", 9 },                                                  -- 6 (skip the "mineisbetter" branch)
      { "show_text", "_PokemonFanClubPikachuFanBetterText" },         -- 7
      { "clear_flag", "EVENT_PIKACHU_FAN_BOAST" },                    -- 8
    },

    -- PokemonFanClubSeelFanText (scripts/PokemonFanClub.asm): mirror of
    -- the PIKACHU fan above, keyed off EVENT_SEEL_FAN_BOAST.
    TEXT_POKEMONFANCLUB_SEEL_FAN = {
      { "face_player" },                                              -- 1
      { "check_flag", "EVENT_SEEL_FAN_BOAST" },                       -- 2
      { "jump_if_true", 7 },                                          -- 3
      { "show_text", "_PokemonFanClubSeelFanNormalText" },            -- 4
      { "set_flag", "EVENT_PIKACHU_FAN_BOAST" },                      -- 5
      { "jump", 9 },                                                  -- 6 (skip the "mineisbetter" branch)
      { "show_text", "_PokemonFanClubSeelFanBetterText" },            -- 7
      { "clear_flag", "EVENT_SEEL_FAN_BOAST" },                       -- 8
    },

    -- PokemonFanClubPikachuText (scripts/PokemonFanClub.asm): the
    -- PIKACHU itself, just a flavor line (its cry isn't playable in the
    -- port's talk pipeline, so it's dropped like other cry-only lines).
    TEXT_POKEMONFANCLUB_PIKACHU = {
      { "show_text", "_PokemonFanClubPikachuText" },
    },

    -- PokemonFanClubSeelText (scripts/PokemonFanClub.asm): the SEEL
    -- itself, flavor line only.
    TEXT_POKEMONFANCLUB_SEEL = {
      { "show_text", "_PokemonFanClubSeelText" },
    },
  },
}

return M
