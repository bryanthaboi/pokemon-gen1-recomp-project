-- Gallery #6 (Tool builder): a read-mostly overlay.  Everything it knows
-- comes from the merged view through the public mod API -- no private
-- require, no engine table reached behind the loader's back -- and what it
-- knows is published as a stable export other mods can call.
local SCREEN = "ExampleDexNav"

return function(mod)
  mod.options:define({
    { key = "sort", label = "SORT BY", type = "choice", default = "dex",
      choices = { { "DEX NO.", "dex" }, { "NAME", "name" } } },
    { key = "unseen", label = "SHOW UNSEEN", type = "toggle", default = true },
  })

  -- ------- the merged view, read once per open

  -- content.pokemon:each() yields the engine's species AND every mod's,
  -- which is the whole point: a tool that hard-codes 151 breaks the moment
  -- someone adds a species.
  local function species()
    local rows = {}
    for id, mon in mod.content.pokemon:each() do
      rows[#rows + 1] = { id = id, name = mon.name or id, dex = mon.dex or 9999 }
    end
    return rows
  end

  local function dexOf(game)
    return (game and game.save and game.save.pokedex) or { seen = {}, owned = {} }
  end

  local function counts(game)
    local dex = dexOf(game)
    local seen, owned = 0, 0
    for _, row in ipairs(species()) do
      if dex.seen[row.id] then seen = seen + 1 end
      if dex.owned[row.id] then owned = owned + 1 end
    end
    return seen, owned
  end

  -- ------- the inter-mod API
  -- Another mod reads this with mod.find("example_dexnav").exports; it is
  -- the supported way to depend on this one, and the reason nothing here
  -- reaches into a private module.

  mod.exports.countSeen = function(game) return (counts(game)) end
  mod.exports.countOwned = function(game) return select(2, counts(game)) end
  mod.exports.species = species

  -- ------- the screen

  mod.content.screens:register(SCREEN, {
    new = function(game)
      local dex = dexOf(game)
      local showUnseen = mod.options:get("unseen")
      local rows = species()
      if mod.options:get("sort") == "name" then
        table.sort(rows, function(a, b) return a.name < b.name end)
      else
        table.sort(rows, function(a, b)
          if a.dex ~= b.dex then return a.dex < b.dex end
          return a.id < b.id
        end)
      end

      local items = {}
      for _, row in ipairs(rows) do
        local state = dex.owned[row.id] and "OWN"
          or (dex.seen[row.id] and "SEEN" or "----")
        if showUnseen or state ~= "----" then
          items[#items + 1] = { label = row.name, right = state, value = row.id }
        end
      end

      local seen, owned = counts(game)
      -- ListMenu draws "Nothing here." for an empty set, so a brand new
      -- save with SHOW UNSEEN off reads as a sentence, not a blank frame
      return mod.ui.ListMenu.new(game,
        ("DEXNAV %d/%d"):format(owned, seen), items, {
          pageJump = true,
          onChoose = function(_, menu) menu:close() end,
        })
    end,
  })

  -- ------- reaching it
  -- Call next() first, then decorate the list it returns: another mod's
  -- row survives, and the vanilla rows are never rebuilt by hand.

  mod.hooks:wrap("ui.start_menu.items", function(next, game, items)
    local out = next(game, items)
    if type(out) ~= "table" then return out end
    return mod.ui.insertBefore(out, "SAVE", {
      label = "DEXNAV",
      onSelect = function() mod.ui.push(game, SCREEN) end,
    })
  end)
end
