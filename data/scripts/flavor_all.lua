-- Auto-generated index of the ported text_asm flavor talk scripts
-- (Workstream A backlog).  Each data/scripts/flavor/<map>.lua returns
-- { MAP_ID = { talk = {...} } } for one map; this combines them into a
-- single table that data/scripts/init.lua merges into the registry
-- (talk tables merge per TEXT constant, like the story files).
local files = {
  "data.scripts.flavor.bike_shop",
  "data.scripts.flavor.celadon_city",
  "data.scripts.flavor.celadon_mansion_1f",
  "data.scripts.flavor.celadon_mansion_3f",
  "data.scripts.flavor.cerulean_badge_house",
  "data.scripts.flavor.cerulean_cave_b1f",
  "data.scripts.flavor.cerulean_city",
  "data.scripts.flavor.cerulean_trade_house",
  "data.scripts.flavor.cerulean_trashed_house",
  "data.scripts.flavor.copycats_house_1f",
  "data.scripts.flavor.copycats_house_2f",
  "data.scripts.flavor.game_corner",
  "data.scripts.flavor.lavender_cubone_house",
  "data.scripts.flavor.lavender_mart",
  "data.scripts.flavor.lavender_town",
  "data.scripts.flavor.mr_fujis_house",
  "data.scripts.flavor.museum_1f",
  "data.scripts.flavor.oaks_lab",
  "data.scripts.flavor.pewter_city",
  "data.scripts.flavor.pewter_mart",
  "data.scripts.flavor.pewter_nidoran_house",
  "data.scripts.flavor.pokemon_fan_club",
  "data.scripts.flavor.power_plant",
  "data.scripts.flavor.reds_house_1f",
  "data.scripts.flavor.route11_gate_2f",
  "data.scripts.flavor.route18_gate_2f",
  "data.scripts.flavor.route_12_gate_2f",
  "data.scripts.flavor.route_15_gate_2f",
  "data.scripts.flavor.route_16_fly_house",
  "data.scripts.flavor.route_16_gate_1f",
  "data.scripts.flavor.route_16_gate_2f",
  "data.scripts.flavor.route_18_gate_1f",
  "data.scripts.flavor.route_22_gate",
  "data.scripts.flavor.route_23",
  "data.scripts.flavor.route_2_trade_house",
  "data.scripts.flavor.safari_zone_gate",
  "data.scripts.flavor.saffron_pidgey_house",
  "data.scripts.flavor.seafoam_islands_b4f",
  "data.scripts.flavor.silph_co_10f",
  "data.scripts.flavor.silph_co_3f",
  "data.scripts.flavor.silph_co_4f",
  "data.scripts.flavor.silph_co_5f",
  "data.scripts.flavor.silph_co_6f",
  "data.scripts.flavor.silph_co_7f",
  "data.scripts.flavor.silph_co_8f",
  "data.scripts.flavor.silph_co_9f",
  "data.scripts.flavor.ss_anne_1f_rooms",
  "data.scripts.flavor.ss_anne_2f_rooms",
  "data.scripts.flavor.ss_anne_b1f_rooms",
  "data.scripts.flavor.ss_anne_kitchen",
  "data.scripts.flavor.vermilion_city",
  "data.scripts.flavor.vermilion_pidgey_house",
  "data.scripts.flavor.victory_road_2f",
  "data.scripts.flavor.viridian_city",
  "data.scripts.flavor.viridian_nickname_house",
  "data.scripts.flavor.wardens_house",
}

local M = {}
for _, f in ipairs(files) do
  for mapId, mod in pairs(require(f)) do
    if M[mapId] and M[mapId].talk and mod.talk then
      for k, v in pairs(mod.talk) do M[mapId].talk[k] = v end
    else
      M[mapId] = mod
    end
  end
end
return M
