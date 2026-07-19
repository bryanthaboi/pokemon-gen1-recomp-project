-- Gallery #3 (Musician): one authored chip song, one hook that swaps the
-- Pallet Town theme, one derived cry, and a jukebox screen that lists the
-- merged music registry.
local SONG_ID = "Music_ExamplePalletRain"

return function(mod)
  -- the song lives in its own file; mod:read + load keeps it addressable
  -- through the loader's filesystem instead of the host package.path, so
  -- the mod works the same installed as it does in the repo
  local source = mod:read("song.lua")
  if not source then
    mod.log:error("song.lua missing from %s -- reinstall the mod", mod.path)
    return
  end
  local chunk, compileErr = load(source, "@" .. mod.path .. "/song.lua")
  if not chunk then
    mod.log:error("song.lua did not compile: %s", tostring(compileErr))
    return
  end
  -- a malformed note table raises inside ChipAsm; catching it here turns
  -- the whole mod into a mod-attributed load error instead of latching the
  -- music system at playback time
  local ok, song = pcall(chunk)
  if not ok then
    mod.log:error("song.lua failed to assemble: %s", tostring(song))
    return
  end

  mod.content.music:register(SONG_ID, song)

  -- a derived cry: the ChipAsm effect command set (channels 5-8), keyed by
  -- species exactly like the vanilla cry table
  mod.content.cries:override("MEW", {
    -- .chip, not the whole return: ChipAsm hands back { chip = program }
    -- and a cry record carries the program under its own chip key
    chip = require("src.audio.ChipAsm").sfx{
      channels = {
        { hw = 1, program = {
          { pitchSweep = { pace = 3, subtract = false, shift = 2 } },
          { squareNote = { len = 6, volume = 14, fade = 2, frequency = 0x5C0 } },
          { squareNote = { len = 8, volume = 12, fade = 3, frequency = 0x680 } },
        } },
      },
    }.chip,
    pitch = 128, length = 128,
  })

  -- music.select is the single choke point every song choice passes
  -- through.  Defer to next() for everything that is not the case this mod
  -- cares about: with the mod installed but off the map, playback is
  -- byte-for-byte what it was.
  mod.hooks:wrap("music.select", function(next, chosen, ctx)
    if ctx and ctx.reason == "map" and ctx.mapId == "PALLET_TOWN" then
      return next(SONG_ID, ctx)
    end
    return next(chosen, ctx)
  end)

  -- the jukebox itself: a screen factory in the screens registry
  mod.content.screens:register("ExampleJukebox", {
    new = function(game)
      local ids = {}
      for id in mod.content.music:each() do ids[#ids + 1] = id end
      table.sort(ids)
      local items = {}
      for _, id in ipairs(ids) do
        items[#items + 1] = { label = id:gsub("^Music_", ""), value = id }
      end
      -- ListMenu draws "Nothing here." on an empty set, so the empty state
      -- is a sentence rather than a blank box
      return mod.ui.ListMenu.new(game, "JUKEBOX", items, {
        onChoose = function(item)
          require("src.core.Music").play(game.data, item.value, true,
            { reason = "direct" })
        end,
        onCancel = function()
          require("src.core.Music").stop()
        end,
      })
    end,
  })

  -- reachable from OPTIONS; call next() first and decorate what comes back,
  -- so every other mod's rows survive this one
  mod.hooks:wrap("ui.options.rows", function(next, game, rows)
    local out = next(game, rows)
    if type(out) ~= "table" then return out end
    out[#out + 1] = {
      id = "example_jukebox",
      label = "JUKEBOX",
      value = function() return "OPEN" end,
      activate = function(g) mod.ui.push(g, "ExampleJukebox") end,
    }
    return out
  end)
end
