-- Dev-mode hot reload (POKEPORT_DEV=1, F5): restore pristine base data,
-- re-run the mod loader against the current mod files, re-merge, and flush
-- every cache registered on the Assets bus.  Teardown is wholesale: the old
-- loader -- registries, event/hook subscriptions, exports -- is dropped and
-- a fresh one built, so nothing has to be un-registered piecemeal and the
-- boot-time freeze never needs an unfreeze.  Only required from the dev
-- hotkey path and the console, never on a player boot.

local HotReload = {}

-- the overworld holds a built Map object; rebuild it in place so the
-- reloaded records are what the world reads from the next step on
local function reloadMap(game)
  local ow = game.overworld
  if not (ow and ow.map and ow.setMap and ow.player and game.stack) then return end
  for _, state in ipairs(game.stack.states or {}) do
    if state == ow then
      ow:setMap(ow.map.id, ow.player.cellX, ow.player.cellY,
                ow.player.facing, { via = "boot" })
      return
    end
  end
end

-- opts.fs / opts.dev thread through to Loader.new for headless tests; the
-- in-game F5 path passes nothing and picks up love.filesystem
function HotReload.run(game, opts)
  local Loader = require("src.mods.Loader")
  local Assets = require("src.render.Assets")
  local Runtime = require("src.mods.Runtime")
  local Logger = require("src.core.Logger")
  local data = game.data
  if data and data.reloadGenerated then data:reloadGenerated() end
  local loader = Loader.new(opts and { fs = opts.fs, dev = opts.dev } or nil)
  loader.game = game
  -- mod.save keeps pointing at the live slot across the reload
  if game.save and game.save.modData then loader.modSave = game.save.modData end
  local ok, err = pcall(loader.load, loader, data)
  if not ok then
    loader.errors[#loader.errors + 1] = tostring(err)
    Logger.error("hot reload: %s", tostring(err))
  end
  game.mods = loader
  game.modStatus = loader:status()
  -- the one invalidation entry point: every downstream cache registered
  -- against Assets empties here (maps, tiles, sprites, pics, font, screens)
  Assets.flush()
  -- Theme binds Data outside the cache contract, so re-fold it by hand
  local themeOk, Theme = pcall(require, "src.ui.Theme")
  if themeOk and Theme.load then pcall(Theme.load, data) end
  -- entry chunks just re-ran and re-subscribed; hand them the Game again
  Runtime.emit("game.ready", { game = game })
  reloadMap(game)
  local summary = ("reloaded %d mods (%d errors)")
    :format(#loader.loaded, #loader.errors)
  Logger.info("%s", summary)
  return loader, summary
end

return HotReload
