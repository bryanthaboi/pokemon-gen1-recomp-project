-- Route 23's badge-gate guards (pokered scripts/Route23.asm).  Each
-- guard/swimmer stands beside the staircase to Victory Road and, when
-- talked to, checks whether the player holds the badge matching that
-- step; the automatic walk-into-the-guard blocking script
-- (Route23DefaultScript / Route23CheckForBadgeScript) is not ported
-- here -- only the talk-triggered text_asm bodies, which share that
-- same subroutine (Route23CheckForBadgeScript) and text
-- (Route23YouDontHaveTheBadgeYetText / Route23OhThatIsTheBadgeText,
-- pokered/text/Route23.asm _Route23YouDontHaveTheBadgeYetText /
-- _Route23OhThatIsTheBadgeText).  Once shown the badge, pokered sets
-- EVENT_PASSED_<BADGE>_CHECK so the walk-through gate (when ported)
-- won't re-ask; we mirror that with set_flag for fidelity even though
-- no onStep gate currently reads it.

local M = {}

-- rows: check_item(badge) -> have it? show "Oh! That is the X!" and
-- set EVENT_PASSED_X_CHECK : show "You don't have the X yet!"
local function badgeGuard(badge, passFlag)
  local subs = { RAM = badge }
  return {
    { "check_item", badge },                                        -- 1
    { "jump_if_true", 5 },                                          -- 2
    { "show_text", "_Route23YouDontHaveTheBadgeYetText", subs },     -- 3
    { "jump", 7 },                                                  -- 4 (end)
    { "show_text", "_Route23OhThatIsTheBadgeText", subs },          -- 5
    { "set_flag", passFlag },                                       -- 6
  }
end

M.ROUTE_23 = {
  talk = {
    -- Route23Guard1Text: EventFlagBit ..., EVENT_PASSED_EARTHBADGE_CHECK
    -- -> wWhichBadge = EARTHBADGE
    TEXT_ROUTE23_GUARD1 = badgeGuard("EARTHBADGE", "EVENT_PASSED_EARTHBADGE_CHECK"),
    -- Route23Guard2Text: EVENT_PASSED_VOLCANOBADGE_CHECK
    TEXT_ROUTE23_GUARD2 = badgeGuard("VOLCANOBADGE", "EVENT_PASSED_VOLCANOBADGE_CHECK"),
    -- Route23Guard3Text: EVENT_PASSED_RAINBOWBADGE_CHECK
    TEXT_ROUTE23_GUARD3 = badgeGuard("RAINBOWBADGE", "EVENT_PASSED_RAINBOWBADGE_CHECK"),
    -- Route23Guard4Text: EVENT_PASSED_THUNDERBADGE_CHECK
    TEXT_ROUTE23_GUARD4 = badgeGuard("THUNDERBADGE", "EVENT_PASSED_THUNDERBADGE_CHECK"),
    -- Route23Guard5Text: EVENT_PASSED_CASCADEBADGE_CHECK
    TEXT_ROUTE23_GUARD5 = badgeGuard("CASCADEBADGE", "EVENT_PASSED_CASCADEBADGE_CHECK"),
    -- Route23Swimmer1Text: EVENT_PASSED_MARSHBADGE_CHECK
    TEXT_ROUTE23_SWIMMER1 = badgeGuard("MARSHBADGE", "EVENT_PASSED_MARSHBADGE_CHECK"),
    -- Route23Swimmer2Text: EVENT_PASSED_SOULBADGE_CHECK
    TEXT_ROUTE23_SWIMMER2 = badgeGuard("SOULBADGE", "EVENT_PASSED_SOULBADGE_CHECK"),
  },
}

return M
