-- Rewards for winning specific trainer battles, keyed by
-- "OPP_CLASS#partyIndex" (the object_event trainer args).  Hand-ported
-- from the leaders'/bosses' text_asm victory scripts:
--   gym badges: scripts/PewterGym.asm ... ViridianGym.asm
--   Rocket Hideout Giovanni: his Silph Scope is an item ball next to him
--   (data/maps/objects/RocketHideoutB4F.asm), so no reward entry needed.
-- The TM each gym leader hands out afterwards is also ported.

return {
  ["OPP_BROCK#1"] = { badge = "BOULDERBADGE", flag = "EVENT_BEAT_BROCK",
                      item = "TM_BIDE" },
  ["OPP_MISTY#1"] = { badge = "CASCADEBADGE", flag = "EVENT_BEAT_MISTY",
                      item = "TM_BUBBLEBEAM" },
  ["OPP_LT_SURGE#1"] = { badge = "THUNDERBADGE", flag = "EVENT_BEAT_LT_SURGE",
                         item = "TM_THUNDERBOLT" },
  ["OPP_ERIKA#1"] = { badge = "RAINBOWBADGE", flag = "EVENT_BEAT_ERIKA",
                      item = "TM_MEGA_DRAIN" },
  ["OPP_KOGA#1"] = { badge = "SOULBADGE", flag = "EVENT_BEAT_KOGA",
                     item = "TM_TOXIC" },
  ["OPP_SABRINA#1"] = { badge = "MARSHBADGE", flag = "EVENT_BEAT_SABRINA",
                        item = "TM_PSYWAVE" },
  ["OPP_BLAINE#1"] = { badge = "VOLCANOBADGE", flag = "EVENT_BEAT_BLAINE",
                       item = "TM_FIRE_BLAST" },
  ["OPP_GIOVANNI#3"] = { badge = "EARTHBADGE", flag = "EVENT_BEAT_GIOVANNI",
                         item = "TM_FISSURE" },

  -- Silph Co. Giovanni: unlocks the president's Master Ball gift
  ["OPP_GIOVANNI#2"] = { flag = "EVENT_BEAT_SILPH_CO_GIOVANNI" },

  -- Fighting Dojo Karate Master (scripts/FightingDojo.asm
  -- FightingDojoKarateMasterPostBattleScript sets EVENT_BEAT_KARATE_MASTER,
  -- which gates the HITMONLEE/HITMONCHAN gift).  OPP_BLACKBELT party 1 is
  -- only him (data/maps/objects/FightingDojo.asm).
  ["OPP_BLACKBELT#1"] = { flag = "EVENT_BEAT_KARATE_MASTER" },

  -- Elite Four progress flags (their rooms' door logic isn't ported, but
  -- the flags make the Hall of Fame checkable)
  ["OPP_LORELEI#1"] = { flag = "EVENT_BEAT_LORELEIS_ROOM_TRAINER_0" },
  ["OPP_BRUNO#1"] = { flag = "EVENT_BEAT_BRUNOS_ROOM_TRAINER_0" },
  ["OPP_AGATHA#1"] = { flag = "EVENT_BEAT_AGATHAS_ROOM_TRAINER_0" },
  ["OPP_LANCE#1"] = { flag = "EVENT_BEAT_LANCE" },
}
