-- Mr. Fuji's House flavor NPCs (pokered/scripts/MrFujisHouse.asm).
-- TEXT_MRFUJISHOUSE_MR_FUJI and TEXT_MRFUJISHOUSE_POKEDEX are already
-- ported in data/scripts/story.lua (M.MR_FUJIS_HOUSE.talk) alongside the
-- EVENT_RESCUED_MR_FUJI onEnter repair, so they're skipped here.

local M = {}

M.MR_FUJIS_HOUSE = {
  talk = {
    -- scripts/MrFujisHouse.asm MrFujisHouseSuperNerdText: CheckEvent
    -- EVENT_RESCUED_MR_FUJI branches between "he's not here" and
    -- "he had been praying".
    TEXT_MRFUJISHOUSE_SUPER_NERD = {
      { "face_player" },                                                    -- 1
      { "check_flag", "EVENT_RESCUED_MR_FUJI" },                            -- 2
      { "jump_if_true", 5 },                                                -- 3
      { "show_text", "_MrFujisHouseSuperNerdMrFujiIsntHereText" },          -- 4
      { "jump", 6 },                                                        -- 5
      { "show_text", "_MrFujisHouseSuperNerdMrFujiHadBeenPrayingText" },    -- 6
    },

    -- scripts/MrFujisHouse.asm MrFujisHouseLittleGirlText: CheckEvent
    -- EVENT_RESCUED_MR_FUJI branches between "this is Mr. Fuji's house"
    -- and "Pokemon are nice to hug".
    TEXT_MRFUJISHOUSE_LITTLE_GIRL = {
      { "face_player" },                                                    -- 1
      { "check_flag", "EVENT_RESCUED_MR_FUJI" },                            -- 2
      { "jump_if_true", 5 },                                                -- 3
      { "show_text", "_MrFujisHouseLittleGirlThisIsMrFujisHouseText" },     -- 4
      { "jump", 6 },                                                        -- 5
      { "show_text", "_MrFujisHouseLittleGirlPokemonAreNiceToHugText" },    -- 6
    },

    -- scripts/MrFujisHouse.asm MrFujisHousePsyduckText: text_far then
    -- PlayCry(PSYDUCK). Cry playback isn't modeled by Commands, so just
    -- show the flavor text.
    TEXT_MRFUJISHOUSE_PSYDUCK = {
      { "show_text", "_MrFujisHousePsyduckText" },
    },

    -- scripts/MrFujisHouse.asm MrFujisHouseNidorinoText: text_far then
    -- PlayCry(NIDORINO).
    TEXT_MRFUJISHOUSE_NIDORINO = {
      { "show_text", "_MrFujisHouseNidorinoText" },
    },
  },
}

return M
