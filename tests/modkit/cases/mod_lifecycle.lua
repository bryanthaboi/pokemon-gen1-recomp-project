-- T4: the mod lifecycle through the public API only
-- (21-testing-and-ci "the modkit test harness").
--
-- This is the case a mod author copies: synthesize (or point at) a mod,
-- load it headlessly against the fixture dataset, and assert on what
-- reached Data and the buses.  Nothing here reaches into loader internals
-- that a mod could not reach itself.

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")

-- ------- a mod that exercises content, events, hooks, save and exports

local GOOD = {
  ["mods/fix_kitchen_sink/manifest.json"] = [[{
    "id": "fix_kitchen_sink",
    "name": "Fixture Kitchen Sink",
    "version": "2.1.0",
    "entry": "main.lua",
    "api": 2,
    "description": "Exercises the public mod surface."
  }]],
  ["mods/fix_kitchen_sink/main.lua"] = [[
    local mod = ...
    mod.content.items:register("FIX_SODA", {
      id = "FIX_SODA", index = 90, name = "FIX SODA", price = 400,
      tossable = true,
    })
    -- patch an existing record instead of replacing it
    mod.content.items:patch("FIX_POTION", { price = 250 })
    mod.events:on("game.ready", function(ev) mod.exports.sawReady = ev ~= nil end)
    mod.hooks:wrap("catch.rate", function(nextFn, ctx)
      local base = nextFn(ctx)
      return base
    end)
    mod.save:set("charge", 3)
    mod.exports.marker = "kitchen-sink"
  ]],
}

do
  local data = T.fixtures.fresh()
  local run = T.sdk.loadMods({ "mods/fix_kitchen_sink" },
    { data = data, fs = T.sdk.memfs(GOOD) })

  T.eq(#run.errors, 0, "the mod loads with no errors (" .. tostring(run.errors[1]) .. ")")
  local mod = run.mods.fix_kitchen_sink
  T.check(mod ~= nil, "the loader discovered the mod by its manifest id")
  T.eq(mod and mod.state, "loaded", "the mod reached the loaded state")
  T.eq(mod and mod.manifest.version, "2.1.0", "the manifest version is read")

  -- content reached Data through the merge
  T.check(data.items.FIX_SODA ~= nil, "a registered item merged into Data")
  T.eq(data.items.FIX_SODA.price, 400, "the registered item kept its fields")
  T.eq(data.items.FIX_SODA.tossable, true, "record fields survive the merge")

  -- patch is a deep merge over the base record, not a replacement
  T.eq(data.items.FIX_POTION.price, 250, "patch overwrote the field it named")
  T.eq(data.items.FIX_POTION.tossable, true,
    "patch left the fields it did not name alone")
  T.eq(data.items.FIX_POTION.name, "FIX POTION", "patch left the record's name alone")

  -- the hook is wrapped, and with exactly one link
  local hooks = T.record.hooks(run.loader)
  T.eq(hooks:depth("catch.rate"), 1, "the mod's hook is wrapped once")
  T.eq(hooks:owners("catch.rate")[1], "fix_kitchen_sink", "the hook link is attributed to the mod")

  -- the event recorder sees what the engine emits
  local rec = T.record.events(run.loader)
  run.loader.events:emit("game.ready", { game = { marker = true } })
  T.eq(rec:count("game.ready"), 1, "the recorder captured the emit")
  T.check(rec:first("game.ready").game ~= nil, "game.ready carries { game = Game }")
  rec:stop()

  run.release()
end

-- ------- a mod that throws in its entry chunk rolls back completely

local BAD = {
  ["mods/fix_broken/manifest.json"] = [[{
    "id": "fix_broken",
    "name": "Fixture Broken",
    "version": "1.0.0",
    "entry": "main.lua",
    "api": 2
  }]],
  ["mods/fix_broken/main.lua"] = [[
    local mod = ...
    mod.content.items:register("FIX_GHOST", {
      id = "FIX_GHOST", index = 91, name = "FIX GHOST", price = 1,
    })
    mod.events:on("game.ready", function() end)
    error("entry chunk exploded")
  ]],
}

do
  local data = T.fixtures.fresh()
  local run = T.sdk.loadMods({ "mods/fix_broken" },
    { data = data, fs = T.sdk.memfs(BAD) })

  T.check(#run.errors > 0, "a throwing entry chunk is reported as an error")
  T.check(tostring(run.errors[1]):find("exploded", 1, true) ~= nil,
    "the error names the failure (" .. tostring(run.errors[1]) .. ")")
  T.eq(run.mods.fix_broken and run.mods.fix_broken.state, "failed",
    "the mod is marked failed")

  -- rollback: neither its content nor its subscription survived
  T.eq(data.items.FIX_GHOST, nil, "a failed mod's content is rolled back out of Data")
  local hooks = T.record.hooks(run.loader)
  T.eq(hooks:depth("catch.rate"), 0, "a failed mod leaves no hook links")
  local listeners = run.loader.events.listeners["game.ready"]
  T.eq(#(listeners or {}), 0, "a failed mod leaves no event listeners")

  -- and the engine still works: a failed mod is "not installed", not fatal
  T.check(data.items.FIX_POTION ~= nil, "base content survives a failed mod")

  run.release()
end

-- ------- the no-mod parity baseline for this same path

do
  local data = T.fixtures.fresh()
  local run = T.sdk.loadNone({ data = data })
  T.eq(#run.errors, 0, "loading no mods produces no errors")
  T.eq(next(run.mods), nil, "loading no mods discovers no mods")
  T.eq(data.items.FIX_SODA, nil, "no mod means no mod content in Data")
  T.eq(data.items.FIX_POTION.price, 300, "the base item keeps its unpatched price")

  local hooks = T.record.hooks(run.loader)
  for _, name in ipairs(T.catalog.hooks()) do
    T.eq(hooks:depth(name), 0, "no mod means an empty chain: " .. name)
  end
  run.release()
end

T.finish("mod_lifecycle")
