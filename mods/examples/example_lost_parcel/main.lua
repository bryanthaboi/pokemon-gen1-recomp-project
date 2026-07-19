-- Gallery #4 (Quest author): the worked multi-map fetch quest from
-- 09-scripting-and-quests.md 6.  A courier in Viridian City lost a parcel
-- in Pewter City; the player retrieves it for a NUGGET.
--
-- No map is edited and no engine file is touched.  Both NPCs are vanilla
-- objects addressed by their real TEXT_ constants, and the base
-- conversation is still reachable on every branch the quest does not own.
local MapScripts = require("src.script.MapScripts")

local PARCEL = "EXAMPLE_LOST_PARCEL_PARCEL"
local REWARD = "NUGGET"

-- flags a mod writes are MOD_-prefixed by convention, so a save never
-- confuses them with the pokered event namespace
local STARTED = "MOD_EXAMPLE_LOST_PARCEL_STARTED"
local TAKEN = "MOD_EXAMPLE_LOST_PARCEL_TAKEN"
local DONE = "MOD_EXAMPLE_LOST_PARCEL_DONE"

-- the Pewter super nerd's object index on PEWTER_CITY; the ambient script
-- makes this one fidget while the parcel is still lying around
local NERD_INDEX = 3

return function(mod)
  -- ------- the reward item

  mod.content.items:register(PARCEL, {
    id = PARCEL,
    name = "PARCEL?",
    price = 0,
    keyItem = true,
    tossable = false,
  })

  -- ------- a text token, so the reward name is written once

  mod.content.tokens:register("EXAMPLE_PARCEL_REWARD", function(game)
    local item = game and game.data and game.data.items[REWARD]
    return item and item.name or REWARD
  end)

  -- ------- a script verb of this mod's own
  -- The table form carries dispatch metadata: foreground marks it illegal
  -- inside a parallel script, which is what keeps the ambient runner from
  -- ever touching quest state.
  mod.content.commands:register("example_lost_parcel:count_ask", {
    foreground = true,
    fn = function(ctx)
      -- mod: fields route into save.modData[owner], so quest scratch state
      -- is attributable and two quests never collide on one key
      local base = ctx.save.modData and ctx.save.modData[mod.id]
      local asked = (base and base.asked_count or 0) + 1
      ctx.save.modData = ctx.save.modData or {}
      ctx.save.modData[mod.id] = ctx.save.modData[mod.id] or {}
      ctx.save.modData[mod.id].asked_count = asked
      -- the same number through the loader-side namespace, which is what a
      -- screen or another mod would read
      mod.save:set("asked_count", asked)
    end,
  })

  -- ------- handing a branch back to the base conversation
  -- talk dispatch is single-winner, so the Pewter rows below replace the
  -- engine's handler outright.  Re-running the TEXT_ constant with
  -- show_text would only replay its opening line: the base handler is a
  -- Lua function that asks YES/NO and answers with one of two follow-ups,
  -- and none of that survives a text lookup.  baseTalk reaches the handler
  -- still sitting behind the override (09 6), so the branches the quest
  -- does not own play the whole vanilla conversation.
  mod.content.commands:register("example_lost_parcel:base_nerd_chat", {
    foreground = true,
    fn = function(ctx)
      local base = MapScripts.baseTalk("PEWTER_CITY", "TEXT_PEWTERCITY_SUPER_NERD1")
      if not base then return end
      local runner = ctx.runner
      base(ctx.game, ctx.overworld, ctx.npc, function() runner:resume() end)
      runner:yield()
    end,
  })

  -- ------- Viridian City: the quest giver

  mod.content.map_scripts:register("VIRIDIAN_CITY", {
    talk = {
      TEXT_VIRIDIANCITY_GAMBLER1 = {
        { "check_flag", DONE },
        { "jump_if_true", "after" },
        { "check_flag", STARTED },
        { "jump_if_true", "pending" },
        { "show_text", "I dropped a parcel\nsomewhere in\nPEWTER CITY..." },
        { "choice", { "SURE", "NO WAY" } },
        { "jump_if_false", "refused" },
        { "set_flag", STARTED },
        { "set_field", "mod:asked_count", 0 },
        { "show_text", "Thanks! A {EXAMPLE_PARCEL_REWARD}\nawaits you!" },
        { "jump", "end" },

        { "label", "pending" },
        { "example_lost_parcel:count_ask" },
        { "check_item", PARCEL },
        { "jump_if_false", "remind" },
        { "take_item", PARCEL },
        { "give_item", REWARD },
        { "set_flag", DONE },
        { "emote", "player", "happy", 45 },
        { "show_text", "You found it!\nHere, as promised!" },
        { "jump", "end" },

        { "label", "remind" },
        { "show_text", "It's a small brown\nparcel. PEWTER CITY!" },
        { "jump", "end" },

        { "label", "refused" },
        { "show_text", "Aww. GYMs are\nclosed anyway..." },
        { "jump", "end" },

        { "label", "after" },
        { "show_text", "Thanks again,\n{PLAYER}!" },
      },
    },
  })

  -- ------- Pewter City: the parcel, and some ambience while it is lost

  mod.content.map_scripts:register("PEWTER_CITY", {
    talk = {
      TEXT_PEWTERCITY_SUPER_NERD1 = {
        { "check_flag", STARTED },
        { "jump_if_false", "vanilla" },
        { "check_flag", TAKEN },
        { "jump_if_true", "vanilla" },
        { "show_text", "Someone dropped\nthis parcel by the\nMUSEUM." },
        { "give_item", PARCEL, 1, false },
        { "set_flag", TAKEN },
        { "show_text", "{PLAYER} got the\nparcel back!" },
        { "jump", "end" },

        -- every branch the quest does not own replays the base handler, so
        -- the vanilla conversation is never lost to the override
        { "label", "vanilla" },
        { "example_lost_parcel:base_nerd_chat" },
      },
    },

    -- all-run: this composes with the engine's own onEnter for the map
    -- instead of replacing it
    onEnter = function(game, ow)
      local flags = game.save and game.save.flags or {}
      if flags[STARTED] and not flags[TAKEN] then
        ow:queueScript({ { "run_parallel", "PEWTER_CITY/example_nerd_pace" } })
      end
    end,

    scripts = {
      -- background-legal verbs only; the runner rejects foreground rows in
      -- a parallel slot, and the script dies on map exit
      example_nerd_pace = {
        { "label", "top" },
        { "march_in_place", NERD_INDEX, true }, { "wait", 90 },
        { "march_in_place", NERD_INDEX, false }, { "wait", 150 },
        { "jump", "top" },
      },
    },
  })

  -- quest completion is worth announcing to other mods; a mod may only
  -- broadcast under its own prefix
  mod.events:on("flag.changed", function(ev)
    if ev.name == DONE and ev.value then
      mod.events:emit("mod.example_lost_parcel.completed", { reward = REWARD })
    end
  end)
end
