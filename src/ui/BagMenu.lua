-- The bag: lists inventory, uses items via ItemEffects.
-- opts.battle = BattleState when opened mid-battle (balls throwable,
-- using an item consumes the turn).

local ItemEffects = require("src.inventory.ItemEffects")
local ListMenu = require("src.ui.ListMenu")
local TextBox = require("src.render.TextBox")

local BagMenu = {}

local Bag = require("src.inventory.Bag")

-- acquisition order like wBagItems (Bag.order), not alphabetical
local function buildItems(game)
  local items = {}
  for _, id in ipairs(Bag.order(game.save)) do
    local def = game.data.items[id]
    table.insert(items, {
      value = id,
      label = def and def.name or id,
      right = "x" .. game.save.inventory[id],
    })
  end
  return items
end

local function consume(game, id)
  Bag.remove(game.save, id, 1)
end

local function save_name(game)
  return game.save.player.name
end

local function showMessages(game, msgs, onDone)
  if not msgs or #msgs == 0 then
    if onDone then onDone() end
    return
  end
  game.stack:push(TextBox.new(game, table.concat(msgs, "\f"), onDone))
end

-- run the use-flow for an item on a chosen target
local function useOn(game, battle, id, target, list, moveIndex)
  local result, payload, extra = ItemEffects.use(game.data, game.save, id, target,
                                                 battle, moveIndex, game.overworld)

  -- field POKé FLUTE: play the tune, then the no-effect text
  if result == "flute_field" then
    require("src.core.Sound").play(game.data, "Pokeflute")
    showMessages(game, payload)
    return
  end

  -- field POKé FLUTE next to a not-yet-beaten Snorlax: "had effect" text,
  -- then the woke-up/battle sequence (data/scripts/story.lua snorlaxWake)
  if result == "flute_wake" then
    list:close()
    require("src.core.Sound").play(game.data, "Pokeflute")
    showMessages(game, payload, function()
      local ow = game.overworld
      local mod = ow and require("data.scripts.init").get(extra.mapId)
      if ow and mod and mod.snorlaxWake then
        ow.runner:run(mod.snorlaxWake.script, { npc = extra.npc })
      end
    end)
    return
  end

  if result == "consumed_escape" then -- Poké Doll
    consume(game, id)
    list:close()
    showMessages(game, payload, function()
      -- ItemUsePokeDoll sets wEscapedFromBattle and never touches
      -- wBattleResult, so a script that reads the result afterwards sees
      -- 0 -- "defeated". The ghost MAROWAK's script keys on exactly that
      -- (the Poke Doll trick); the flag lets it tell this escape from an
      -- ordinary RUN, which writes $2.
      battle.pokeDollEscape = true
      battle.result = "run"
      battle.afterQueue = "finish"
      battle.phase = "messages"
    end)
    return
  end

  if result == "bicycle" then
    list:close()
    local ow = game.overworld
    local Music = require("src.core.Music")
    -- IsBikeRidingAllowed (home/overworld.asm): the tilesets of
    -- bike_riding_tilesets.asm, plus Route 23 / Indigo Plateau by
    -- map id.  Reads the extracted allowlist when present.
    local function bikeAllowed()
      if not ow then return false end
      local br = game.data.field.bikeRiding
        or { tilesets = { "OVERWORLD", "FOREST", "UNDERGROUND",
                          "SHIP_PORT", "CAVERN" },
             maps = { "ROUTE_23", "INDIGO_PLATEAU" } }
      for _, m in ipairs(br.maps or {}) do
        if ow.map.id == m then return true end
      end
      for _, t in ipairs(br.tilesets or {}) do
        if ow.map.def.tileset == t then return true end
      end
      return false
    end
    if game.save.onBike then
      game.save.onBike = false
      Music.playMap(game.data, ow and ow.map.id, false)
      showMessages(game, { save_name(game) .. " got off\nthe BICYCLE." })
    elseif bikeAllowed() then
      game.save.onBike = true
      Music.playMap(game.data, ow.map.id, true)
      showMessages(game, { save_name(game) .. " got on\nthe BICYCLE!" })
    else
      showMessages(game, { "No cycling\nallowed here." })
    end
    return
  end

  if result == "fish" then
    list:close()
    local ow = game.overworld
    local p = ow and ow.player
    if ow and p then
      local fx, fy = p:facingCell()
      if ow.map:inBounds(fx, fy) and ow.map:isWaterCell(fx, fy) then
        ow:goFishing(id)
        return
      end
    end
    showMessages(game, { "No good! It's not\neven near water." })
    return
  end

  if result == "ball" then
    if not battle then
      showMessages(game, { "OAK: " .. game.save.player.name .. "!\nThis isn't the\ntime to use that!" })
      return
    end
    consume(game, id)
    list:close()
    battle:throwBall(id)
    return
  end

  if result == "learn" or result == "learnkept" then
    local moveId = payload
    local mdef = game.data.moves[moveId]
    local function teach()
      if #target.moves < 4 then
        table.insert(target.moves, { id = moveId, pp = mdef.pp })
        showMessages(game, { ("%s learned\n%s!"):format(target.nickname or
          game.data.pokemon[target.species].name, mdef.name) })
        if result == "learn" then consume(game, id) end
      else
        require("src.ui.Screens").push(game, "MoveLearnMenu", target, moveId,
          function(learned)
            if learned and result == "learn" then consume(game, id) end
          end)
      end
    end
    list:close()
    teach()
    return
  end

  -- the TOWN MAP screen (engine/menus/town_map.asm)
  if result == "townmap" then
    local ok = pcall(function()
      require("src.ui.Screens").push(game, "TownMap")
    end)
    if not ok then
      showMessages(game, { "The TOWN MAP is\nunreadable here." })
    end
    return
  end

  -- ITEMFINDER (engine/items/itemfinder.asm): responds if the current
  -- map still has an unfound hidden item
  if result == "itemfinder" then
    local ow = game.overworld
    local t = game.data.text
    if ow and ow:hasHiddenItemLeft() then
      showMessages(game, { t._ItemfinderFoundItemText
        or "Yes! ITEMFINDER\nindicates there's\nan item nearby." })
    else
      showMessages(game, { t._ItemfinderFoundNothingText
        or "Nope! ITEMFINDER\nisn't responding." })
    end
    return
  end

  -- POKé FLUTE in battle: not consumed, but uses the turn
  if result == "flute" then
    list:close()
    require("src.core.Sound").play(game.data, "Pokeflute")
    showMessages(game, payload, function() battle:itemUsed({}) end)
    return
  end

  if result == "escape_rope" then
    -- ItemUseEscapeRope: only inside the dungeon tilesets
    -- (escape_rope_tilesets.asm), never in Agatha's room, and it sets
    -- BIT_ESCAPE_WARP so special_warps.asm warps to wLastBlackoutMap
    -- -- the last Pokémon Center town, same as Dig/Teleport (NOT the
    -- spot you entered the dungeon from)
    local ESCAPE_ROPE_TILESETS = { FOREST = true, CEMETERY = true,
                                   CAVERN = true, FACILITY = true,
                                   INTERIOR = true }
    local ow = game.overworld
    if ow and ESCAPE_ROPE_TILESETS[ow.map.def.tileset]
       and ow.map.id ~= "AGATHAS_ROOM" then
      list:close()
      consume(game, id)
      require("src.core.Sound").play(game.data, "Teleport_Exit1")
      ow.player.surfing = false
      ow:warpToHealPoint()
    else
      showMessages(game, { "OAK: " .. game.save.player.name
        .. "!\nThis isn't the\ntime to use that!" })
    end
    return
  end

  if result == "consumed" then
    consume(game, id)
    if extra and extra.evolveTo then
      list:close()
      local Evolution = require("src.pokemon.Evolution")
      Evolution.evolve(game, target, extra.evolveTo)
      return
    end
    -- RARE CANDY: after the level text, the stat window, any level-up
    -- moves and a level evolution follow (item_effects.asm .useRareCandy
    -- runs PrintStatsBox, LearnMoveFromLevelUp and TryEvolvingMon)
    if extra and extra.leveledTo and target then
      list:close()
      showMessages(game, payload, function()
        local StatBox = require("src.battle.BattleState").StatBox
        game.stack:push(StatBox.new(game, target, function()
          local Experience = require("src.battle.Experience")
          local def = game.data.pokemon[target.species]
          local moves = Experience.movesLearnedAt(def, extra.leveledTo)
          local i = 0
          local function nextStep()
            i = i + 1
            local moveId = moves[i]
            if not moveId then
              local Evolution = require("src.pokemon.Evolution")
              local evoTo, evo = Evolution.pendingFor(game, target,
                                                     { kind = "levelup" })
              if evoTo then
                Evolution.evolve(game, target, evoTo, nil, evo and evo.method)
              end
              return
            end
            for _, mv in ipairs(target.moves) do
              if mv.id == moveId then return nextStep() end
            end
            local mdef = game.data.moves[moveId]
            if #target.moves < 4 then
              table.insert(target.moves, { id = moveId, pp = mdef.pp })
              local name = target.nickname or def.name
              showMessages(game, { ("%s learned\n%s!"):format(name, mdef.name) },
                           nextStep)
            else
              require("src.ui.Screens").push(game, "MoveLearnMenu",
                                             target, moveId, nextStep)
            end
          end
          nextStep()
        end))
      end)
      return
    end
    -- refresh counts in the list
    for i, it in ipairs(list.items) do
      if it.value == id then
        local left = game.save.inventory[id]
        if left then it.right = "x" .. left else table.remove(list.items, i) end
        break
      end
    end
    list.index = math.min(list.index, math.max(1, #list.items))
    if battle then
      list:close()
      showMessages(game, payload, function() battle:itemUsed({}) end)
    else
      showMessages(game, payload)
    end
    return
  end

  showMessages(game, payload) -- failed
end

local function useItem(game, battle, id, list)
  local def = game.data.items[id]
  if ItemEffects.needsTarget(id, def) and not ItemEffects.isBall(id) then
    -- pick a target from the party
    -- the ETHERs and PP UP open the move menu after picking a mon
    -- (ItemUsePPRestore / ItemUsePPUp); the ELIXERs hit every move
    local wantsMove = id == "ETHER" or id == "MAX_ETHER" or id == "PP_UP"
    require("src.ui.Screens").push(game, "PartyMenu", {
      pickOnly = true,
      onSwitch = function(mon)
        if not wantsMove then
          useOn(game, battle, id, mon, list)
          return
        end
        local rows = {}
        for mi, mv in ipairs(mon.moves) do
          local mdef = game.data.moves[mv.id]
          table.insert(rows, {
            value = mi,
            label = mdef and mdef.name or mv.id,
            right = ("%d"):format(mv.pp),
          })
        end
        game.stack:push(ListMenu.new(game, "Which move?", rows, {
          onChoose = function(row, l)
            l:close()
            useOn(game, battle, id, mon, list, row.value)
          end,
        }))
      end,
    })
  else
    useOn(game, battle, id, nil, list)
  end
end

function BagMenu.new(game, opts)
  opts = opts or {}
  local battle = opts.battle
  local list
  list = ListMenu.new(game, "ITEMS", buildItems(game), {
    footer = ("¥%d"):format(game.save.money),
    -- SELECT reorders items like the original bag (swap_items.asm)
    onSelectKey = function(item, l)
      if not item then return end
      if not l.swapIndex then
        l.swapIndex = l.index
        return
      end
      local order = Bag.order(game.save)
      order[l.swapIndex], order[l.index] = order[l.index], order[l.swapIndex]
      l.swapIndex = nil
      require("src.core.Sound").play(game.data, "Swap")
      l.items = buildItems(game)
    end,
    onChoose = function(item)
      local id = item.value
      local def = game.data.items[id]
      if list.swapIndex then -- A also completes a pending swap
        local order = Bag.order(game.save)
        order[list.swapIndex], order[list.index] = order[list.index], order[list.swapIndex]
        list.swapIndex = nil
        require("src.core.Sound").play(game.data, "Swap")
        list.items = buildItems(game)
        return
      end
      if battle then -- no tossing mid-battle
        useItem(game, battle, id, list)
        return
      end
      -- USE / TOSS submenu (the original's item options)
      local Menu = require("src.ui.Menu")
      game.stack:push(Menu.new(game, {
        { label = "USE", onSelect = function()
            useItem(game, battle, id, list)
          end },
        { label = "TOSS", onSelect = function()
            -- KeyItemFlags + HMs decide tossability (not price:
            -- MOON STONE is price 0 but tossable)
            if not def or def.keyItem or id:find("^HM_") then
              showMessages(game, { "That's too impor-\ntant to toss!" })
              return
            end
            local QuantityBox = require("src.ui.QuantityBox")
            game.stack:push(QuantityBox.new(game, {
              max = game.save.inventory[id] or 1,
              onDone = function(qty)
                if not qty then return end
                local ChoiceBox = require("src.ui.ChoiceBox")
                game.stack:push(ChoiceBox.new(game, function(yes)
                  if not yes then return end
                  Bag.remove(game.save, id, qty)
                  list.items = buildItems(game)
                  list.index = math.min(list.index, math.max(1, #list.items))
                  showMessages(game, { ("Threw away\n%s."):format(def and def.name or id) })
                end))
              end,
            }))
          end },
      }, { tx = 12, ty = 10, tw = 8, th = 6 }))
    end,
  })
  return list
end

return BagMenu
