-- SS Anne, 2F rooms (pokered/scripts/SSAnne2FRooms.asm)
--
-- All ported constants below are plain text_asm bodies: PrintText of a
-- single text_far, no CheckEvent branching, no YES/NO menu.  The
-- trainers (Gentleman1/2, Fisher, CooltrainerF) and the PickUpItem
-- rows (MAX_ETHER, RARE_CANDY) are skipped -- trainers are handled by
-- CheckFightingMapTrainers/TalkToTrainer via the existing trainer
-- system, and the item pickups carry no talk text of their own here.
--
-- TEXT_SSANNE2FROOMS_GENTLEMAN3 also opens the POKéDEX entry for
-- SNORLAX after the text box (DisplayPokedex in the original), which
-- has no equivalent talk-script hook in this port (DexEntryMenu has
-- no done-callback the way other pushed UI states do) -- only the
-- flavor line is ported here.
return {
  SS_ANNE_2F_ROOMS = {
    talk = {
      -- SSAnne2FRoomsGentleman3Text: PrintText(_SSAnne2FRoomsGentleman3Text)
      -- (then DisplayPokedex SNORLAX -- not ported, see note above)
      TEXT_SSANNE2FROOMS_GENTLEMAN3 = {
        { "face_player" },
        { "show_text", "_SSAnne2FRoomsGentleman3Text" },
      },

      -- SSAnne2FRoomsGentleman4Text: PrintText(_SSAnne2FRoomsGentleman4Text)
      TEXT_SSANNE2FROOMS_GENTLEMAN4 = {
        { "face_player" },
        { "show_text", "_SSAnne2FRoomsGentleman4Text" },
      },

      -- SSAnne2FRoomsGentleman5Text: PrintText(_SSAnne2FRoomsGentleman5Text)
      TEXT_SSANNE2FROOMS_GENTLEMAN5 = {
        { "face_player" },
        { "show_text", "_SSAnne2FRoomsGentleman5Text" },
      },

      -- SSAnne2FRoomsGrampsText: PrintText(_SSAnne2FRoomsGrampsText)
      TEXT_SSANNE2FROOMS_GRAMPS = {
        { "face_player" },
        { "show_text", "_SSAnne2FRoomsGrampsText" },
      },

      -- SSAnne2FRoomsLittleBoyText: PrintText(_SSAnne2FRoomsLittleBoyText)
      TEXT_SSANNE2FROOMS_LITTLE_BOY = {
        { "face_player" },
        { "show_text", "_SSAnne2FRoomsLittleBoyText" },
      },

      -- SSAnne2FRoomsBrunetteGirlText: PrintText(_SSAnne2FRoomsBrunetteGirlText)
      TEXT_SSANNE2FROOMS_BRUNETTE_GIRL = {
        { "face_player" },
        { "show_text", "_SSAnne2FRoomsBrunetteGirlText" },
      },

      -- SSAnne2FRoomsBeautyText: PrintText(_SSAnne2FRoomsBeautyText)
      TEXT_SSANNE2FROOMS_BEAUTY = {
        { "face_player" },
        { "show_text", "_SSAnne2FRoomsBeautyText" },
      },
    },
  },
}
