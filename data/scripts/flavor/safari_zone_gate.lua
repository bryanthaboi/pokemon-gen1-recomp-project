-- pokered/scripts/SafariZoneGate.asm SafariZoneGateSafariZoneWorker2Text:
-- the second worker at the gate always asks "Is it your first time
-- here?"; YES prints the SAFARI ZONE rules, NO prints "Sorry, you're a
-- regular here!". No event flag is checked or set -- the answer is
-- purely session (it's a fresh YesNoChoice every time you talk to him).
--
-- worker1's talk/onStep/onEnter handling already lives in
-- data/scripts/safari.lua; this file only adds worker2's flavor text.

return {
  SAFARI_ZONE_GATE = {
    talk = {
      TEXT_SAFARIZONEGATE_SAFARI_ZONE_WORKER2 = {
        {"face_player"},
        {"ask", "_SafariZoneGateSafariZoneWorker2FirstTimeHereText"},
        {"jump_if_true", 6},
        {"show_text", "_SafariZoneGateSafariZoneWorker2YoureARegularHereText"},
        {"jump", 7},
        {"show_text", "_SafariZoneGateSafariZoneWorker2SafariZoneExplanationText"},
      },
    },
  },
}
