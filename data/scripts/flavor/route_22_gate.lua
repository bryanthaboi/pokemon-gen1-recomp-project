-- Route 22 Gate guard (pokered scripts/Route22Gate.asm
-- Route22GateGuardText): text_asm branches on wObtainedBadges
-- BIT_BOULDERBADGE.  Without the badge he refuses (plays SFX_DENIED,
-- "no BOULDERBADGE yet" + "the rules are rules") and the original then
-- auto-walks the player back down (Route22GateMovePlayerDownScript);
-- with the badge he waves you through.  The auto-walk-back is a
-- movement/collision concern handled outside `talk` (not ported here,
-- per the task's talk-only scope) -- this only ports the guard's real
-- flavor text so the correct branch shows on repeat talks.
local M = {}

M.ROUTE_22_GATE = {
  talk = {
    TEXT_ROUTE22GATE_GUARD = {
      { "check_flag", "EVENT_BEAT_BROCK" },                          -- 1 (BIT_BOULDERBADGE)
      { "jump_if_true", 6 },                                          -- 2
      { "show_text", "_Route22GateGuardNoBoulderbadgeText" },        -- 3
      { "show_text", "_Route22GateGuardICantLetYouPassText" },       -- 4
      { "jump", 7 },                                                  -- 5 (end, skip go-right-ahead)
      { "show_text", "_Route22GateGuardGoRightAheadText" },          -- 6
    },
  },
}

return M
