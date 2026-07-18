-- Party menu: list the party, choose a member.
-- Modes:
--   default: A -> submenu (STATS / SWITCH order / CANCEL)
--   opts.onSwitch: A -> hand the chosen mon to the callback (battle
--                  switch, item targeting via opts.pickOnly)
--   opts.onCancel: fired when the menu closes without a pick (B)
-- Pops itself on B.

local Font = require("src.render.Font")

local PartyMenu = {}
PartyMenu.__index = PartyMenu
PartyMenu.isOpaque = true

-- SGB: generic whole-screen palette (SET_PAL_GENERIC)
function PartyMenu:sgbPalettes(game)
  return require("src.render.PaletteFX").wholeNamed(game.data, "MEWMON")
end

local CURSOR = 0xED

-- where DIG escapes work: escape_rope_tilesets.asm (Agatha's room is
-- excluded by map id in ItemUseEscapeRope)
local DIG_TILESETS = { FOREST = true, CEMETERY = true, CAVERN = true,
                       FACILITY = true, INTERIOR = true }

-- Party mon icons (engine/gfx/mon_icons.asm AnimatePartyMon): only the
-- SELECTED mon's icon animates, at a speed set by its HP bar color --
-- 5 / 16 / 32 frames per phase for green / yellow / red (the famous
-- health-speed detail).  BALL and HELIX icons nudge one pixel down
-- instead of switching frames; every other icon swaps to a real second
-- frame (+ICONOFFSET).

-- Rest/alt frame per icon (data/icon_pointers.asm
-- MonPartySpritePointers): the base entries are the RESTING frame,
-- the +ICONOFFSET entries the animated alternate.  The 16x32 icon
-- sheets stack Frame1 (index 0) over Frame2 (index 1, INC_FRAME_2):
-- BUG/GRASS rest on BugIconFrame2/PlantIconFrame2 and animate to
-- Frame1; SNAKE/QUADRUPED are the reverse.  Sprite-reused icons draw
-- from 16x16x6 overworld sheets where index 3 is walk-down (tile 12):
-- MON/FAIRY/BIRD rest on the walk frame and animate to standing
-- (tile 0); WATER (Seel) is the reverse.
PartyMenu.iconFrames = {
  BUG       = { rest = 1, alt = 0 }, -- BugIconFrame2 <-> BugIconFrame1
  GRASS     = { rest = 1, alt = 0 }, -- PlantIconFrame2 <-> PlantIconFrame1
  SNAKE     = { rest = 0, alt = 1 }, -- SnakeIconFrame1 <-> SnakeIconFrame2
  QUADRUPED = { rest = 0, alt = 1 }, -- QuadrupedIconFrame1 <-> Frame2
  MON       = { rest = 3, alt = 0 }, -- MonsterSprite tile 12 <-> tile 0
  FAIRY     = { rest = 3, alt = 0 }, -- FairySprite tile 12 <-> tile 0
  BIRD      = { rest = 3, alt = 0 }, -- BirdSprite tile 12 <-> tile 0
  WATER     = { rest = 0, alt = 3 }, -- SeelSprite tile 0 <-> tile 12
}

-- Which 16x16 frame of `name`'s sheet to draw; `ih` (sheet pixel
-- height) only matters for the fallback, which keeps the old uniform
-- behavior for icons outside the table (BALL/HELIX y-bob instead).
function PartyMenu.frameFor(name, alt, ih)
  local m = PartyMenu.iconFrames[name]
  if m then return alt and m.alt or m.rest end
  return alt and ((ih or 0) >= 64 and 3 or 1) or 0
end

local iconImages = {}
local function drawIcon(game, mon, x, y, selected, counter)
  local icons = game.data.icons
  if not icons then return end
  local def = game.data.pokemon[mon.species]
  local name = def and def.dex and icons.byDex[def.dex]
  local path = name and icons.icons[name]
  if not path then return end
  if iconImages[path] == nil then
    local ok, img = pcall(love.graphics.newImage, path)
    iconImages[path] = ok and img or false
  end
  local img = iconImages[path]
  if not img then return end
  local alt = false
  if selected then
    local px = math.floor(mon.hp * 48 / math.max(1, mon.stats.hp))
    local speed = px >= 27 and 5 or px >= 10 and 16 or 32
    alt = math.floor(counter / speed) % 2 == 1
  end
  if alt and (name == "BALL" or name == "HELIX") then
    y = y + 1
    alt = false
  end
  local iw, ih = img:getDimensions()
  if ih > 16 then
    local frame = PartyMenu.frameFor(name, alt, ih)
    love.graphics.draw(img, love.graphics.newQuad(0, frame * 16, 16, 16, iw, ih), x, y)
  else
    love.graphics.draw(img, x, y)
  end
end

function PartyMenu.new(game, opts)
  opts = opts or {}
  local self = setmetatable({}, PartyMenu)
  self.game = game
  self.index = 1
  self.onSwitch = opts.onSwitch
  self.onCancel = opts.onCancel
  self.pickOnly = opts.pickOnly
  self.battle = opts.battle
  self.party = opts.party -- link battles pass their clamped copies
  self.swapFrom = nil
  self.submenu = nil
  self.subIndex = 1
  self.blink = 0
  return self
end

function PartyMenu:update(dt)
  -- icon animation counter; 320 = a whole cycle at every HP speed
  self.blink = ((self.blink or 0) + 1) % 320
  local input = self.game.input
  local party = self.party or self.game.save.party

  if self.submenu then
    local n = #self.subItems
    if input:wasPressed("up") then
      self.subIndex = self.subIndex > 1 and self.subIndex - 1 or n
    elseif input:wasPressed("down") then
      self.subIndex = self.subIndex < n and self.subIndex + 1 or 1
    elseif input:wasPressed("b") then
      self.submenu = nil
    elseif input:wasPressed("a") then
      local mon = party[self.index]
      local action = self.subItems[self.subIndex].action
      if action == "stats" then
        local SummaryMenu = require("src.ui.SummaryMenu")
        self.game.stack:push(SummaryMenu.new(self.game, mon))
      elseif action == "switch" then
        self.swapFrom = self.index
      elseif action == "fly" then
        local FlyMenu = require("src.ui.FlyMenu")
        self.game.stack:pop() -- close the party menu
        self.game.stack:push(FlyMenu.new(self.game))
        return
      elseif action == "flash" then -- FLASH lights dark tunnels
        -- start_sub_menus.asm .flash: PrintText _FlashLightsAreaText, then
        -- GBPalWhiteOutWithDelay3 + jp .goBackToMap
        local ow = self.game.overworld
        local TextBox = require("src.render.TextBox")
        local Transition = require("src.render.Transition")
        self.game.stack:pop()
        ow.dark = false
        self.game.save.flashLit = true
        self.game.stack:push(TextBox.new(self.game,
          self.game.data.text._FlashLightsAreaText
          or "A blinding FLASH\nlights the area!", function()
            self.game.stack:push(Transition.whiteFlash(self.game))
          end))
        return
      elseif action == "surf" then
        -- start_sub_menus.asm .surf: SOULBADGE-gated (checked at list time
        -- above), then IsSurfingAllowed (the Cycling Road / Seafoam B4F
        -- current refusals, both of which loop back to the submenu), then
        -- ItemUseSurfboard: while surfing it tries to dismount instead;
        -- otherwise it mounts only if the FACING tile is water, else
        -- SurfingAttemptFailed (_NoSurfingHereText) loops back to the
        -- submenu.  useSurfFieldMove reports which; trySurf does the mount.
        local ow = self.game.overworld
        local reason = ow:useSurfFieldMove()
        local Transition = require("src.render.Transition")
        if reason == "ok" then
          self.game.stack:pop() -- close the party menu (jp .goBackToMap)
          local fx, fy = ow.player:facingCell()
          ow:trySurf(fx, fy)
          return
        end
        if reason == "dismount" then
          -- ItemUseSurfboard .stopSurfing: no text -- the walking state
          -- and music return first (PlayDefaultMusic +
          -- LoadWalkingPlayerSpriteGraphics), the menu closes with the
          -- GBPalWhiteOutWithDelay3 blink, and the simulated pad press
          -- steps the player forward onto land
          self.game.stack:pop()
          ow.player.surfing = false
          require("src.core.Music").setSurfing(self.game.data, false)
          self.game.stack:push(Transition.whiteFlash(self.game, nil, function()
            ow:scriptMove(ow.player, ow.player.facing, 1)
          end))
          return
        end
        local TextBox = require("src.render.TextBox")
        local def = self.game.data.pokemon[mon.species]
        local key = ({ no_badge = "_NewBadgeRequiredText",
                       forced_bike = "_CyclingIsFunText",
                       current = "_CurrentTooFastText",
                       no_place = "_SurfingNoPlaceToGetOffText" })[reason]
                    or "_NoSurfingHereText"
        local txt = (self.game.data.text[key] or "No SURFing here!")
                    :gsub("{RAM:wNameBuffer}", mon.nickname or def.name)
        if reason == "no_place" then
          -- .cannotStopSurfing prints _SurfingNoPlaceToGetOffText but
          -- never zeroes wActionResultOrTookBattleTurn, so unlike the
          -- other refusals the menu still closes afterwards
          -- (GBPalWhiteOutWithDelay3 + .goBackToMap)
          self.game.stack:pop()
          self.game.stack:push(TextBox.new(self.game, txt, function()
            self.game.stack:push(Transition.whiteFlash(self.game))
          end))
          return
        end
        self.game.stack:push(TextBox.new(self.game, txt))
        return -- .loop: submenu stays open behind the message
      elseif action == "cut" then
        -- start_sub_menus.asm .cut -> predef UsedCut (engine/overworld/cut.asm):
        -- CASCADEBADGE-gated (list time); _NothingToCutText loops back to the
        -- submenu when the FACING tile isn't a cuttable tree.
        local ow = self.game.overworld
        local reason = ow:useCutFieldMove()
        if reason == "ok" then
          self.game.stack:pop() -- close the party menu (CloseTextDisplay)
          local fx, fy = ow.player:facingCell()
          ow:tryCut(fx, fy)
          return
        end
        local TextBox = require("src.render.TextBox")
        local def = self.game.data.pokemon[mon.species]
        local key = (reason == "no_badge") and "_NewBadgeRequiredText"
                                            or "_NothingToCutText"
        local txt = (self.game.data.text[key] or "Nothing to CUT!")
                    :gsub("{RAM:wNameBuffer}", mon.nickname or def.name)
        self.game.stack:push(TextBox.new(self.game, txt))
        return -- .loop: submenu stays open behind the message
      elseif action == "strength" then
        -- start_sub_menus.asm .strength: RAINBOWBADGE-gated (list time);
        -- predef PrintStrengthText (field_move_messages.asm) sets
        -- BIT_STRENGTH_ACTIVE of wStatusFlags1 -- the sole gate
        -- push_boulder.asm reads -- then prints _UsedStrengthText (no
        -- prompt: after the text, the text_asm tail plays the chosen
        -- mon's cry, Delay3, and it auto-advances) and
        -- _CanMoveBouldersText (`prompt`: waits for A/B).  Back in
        -- .strength, GBPalWhiteOutWithDelay3 blinks the screen white
        -- before CloseTextDisplay returns to the map.
        local ow = self.game.overworld
        local TextBox = require("src.render.TextBox")
        local Transition = require("src.render.Transition")
        local def = self.game.data.pokemon[mon.species]
        local name = mon.nickname or def.name
        self.game.stack:pop() -- close the party menu (jp .goBackToMap)
        ow.strengthActive = true
        local t1 = (self.game.data.text._UsedStrengthText
          or "{RAM:wNameBuffer} used\nSTRENGTH."):gsub("{RAM:wNameBuffer}", name)
        local t2 = (self.game.data.text._CanMoveBouldersText
          or "{RAM:wNameBuffer} can\nmove boulders."):gsub("{RAM:wNameBuffer}", name)
        self.game.stack:push(TextBox.new(self.game, t1, function()
          self.game.stack:push(TextBox.new(self.game, t2, function()
            self.game.stack:push(Transition.whiteFlash(self.game))
          end))
        end, { auto = { sound = function()
          return require("src.core.Sound").playCry(self.game.data, mon.species)
        end } }))
        return
      elseif action == "softboiled" then
        -- field SOFTBOILED (StartMenu_Pokemon .softboiled): transfer
        -- 1/5 of the user's max HP to a chosen teammate
        self.softboiledFrom = self.index
      elseif action == "escape" then
        -- DIG / TELEPORT both warp to the last Pokémon Center town
        -- (wLastBlackoutMap, special_warps.asm escape warp); .dig/.teleport
        -- end with GBPalWhiteOutWithDelay3 + jp .goBackToMap
        local ow = self.game.overworld
        local heal = self.game.save.lastHeal
        local Transition = require("src.render.Transition")
        self.game.stack:pop()
        if ow and heal then
          self.game.stack:push(Transition.whiteFlash(self.game, nil, function()
            require("src.core.Sound").play(self.game.data, "Teleport_Exit1")
            ow:warpToHealPoint()
          end))
        end
        return
      end
      self.submenu = nil
    end
    return
  end

  if input:wasPressed("up") then
    self.index = self.index > 1 and self.index - 1 or math.max(1, #party)
  elseif input:wasPressed("down") then
    self.index = self.index < #party and self.index + 1 or 1
  elseif input:wasPressed("b") then
    self.game.stack:pop()
    if self.onCancel then self.onCancel() end
  elseif input:wasPressed("a") and #party > 0 then
    local mon = party[self.index]
    if self.softboiledFrom then
      local user = party[self.softboiledFrom]
      local heal = math.floor(user.stats.hp / 5)
      if mon == user or mon.hp <= 0 or mon.hp >= mon.stats.hp
         or user.hp <= heal then
        self.softboiledFrom = nil
        local TextBox = require("src.render.TextBox")
        self.game.stack:push(TextBox.new(self.game, "It won't have\nany effect."))
      else
        user.hp = user.hp - heal
        mon.hp = math.min(mon.stats.hp, mon.hp + heal)
        self.softboiledFrom = nil
        require("src.core.Sound").play(self.game.data, "Heal_HP")
        local def = self.game.data.pokemon[mon.species]
        local TextBox = require("src.render.TextBox")
        self.game.stack:push(TextBox.new(self.game,
          ("%s's HP\nwas restored!"):format(mon.nickname or def.name)))
      end
    elseif self.swapFrom then
      if self.swapFrom ~= self.index then
        party[self.swapFrom], party[self.index] = party[self.index], party[self.swapFrom]
        require("src.core.Sound").play(self.game.data, "Swap")
      end
      self.swapFrom = nil
    elseif self.onSwitch then
      self.game.stack:pop()
      self.onSwitch(mon)
    else
      self.submenu = true
      self.subIndex = 1
      -- STATS/SWITCH plus this mon's field moves (start_sub_menus.asm
      -- builds the same dynamic list)
      self.subItems = { { label = "STATS", action = "stats" },
                        { label = "SWITCH", action = "switch" } }
      local ow = self.game.overworld
      if not self.battle and ow and mon.hp > 0 then
        for _, mv in ipairs(mon.moves) do
          if mv.id == "FLY" and ow.map.def.tileset == "OVERWORLD"
             and self.game.save.inventory.THUNDERBADGE then
            table.insert(self.subItems, { label = "FLY", action = "fly" })
          elseif mv.id == "FLASH" and ow.dark
             and self.game.save.inventory.BOULDERBADGE then
            table.insert(self.subItems, { label = "FLASH", action = "flash" })
          elseif mv.id == "CUT" and self.game.save.inventory.CASCADEBADGE then
            -- CUT/SURF/STRENGTH are party-menu field moves too
            -- (start_sub_menus.asm .outOfBattleMovePointers); listed here
            -- with the same list-time badge filter this file already uses
            -- for FLY/FLASH.  The facing-tile/activation check happens on
            -- selection (useCutFieldMove/useSurfFieldMove).
            table.insert(self.subItems, { label = "CUT", action = "cut" })
          elseif mv.id == "SURF" and self.game.save.inventory.SOULBADGE then
            table.insert(self.subItems, { label = "SURF", action = "surf" })
          elseif mv.id == "STRENGTH" and self.game.save.inventory.RAINBOWBADGE then
            table.insert(self.subItems, { label = "STRENGTH", action = "strength" })
          elseif mv.id == "SOFTBOILED" then
            table.insert(self.subItems, { label = "SOFTBOILED", action = "softboiled" })
          elseif mv.id == "TELEPORT" and ow.map.def.tileset == "OVERWORLD" then
            -- TELEPORT works only OUTDOORS (start_sub_menus.asm
            -- .teleport -> CheckIfInOutsideMap); dark maps don't
            -- block it
            table.insert(self.subItems, { label = "TELEPORT", action = "escape" })
          elseif mv.id == "DIG" and DIG_TILESETS[ow.map.def.tileset]
             and ow.map.id ~= "AGATHAS_ROOM" then
            -- DIG runs ItemUseEscapeRope (.dig sets wCurItem =
            -- ESCAPE_ROPE): usable in the dungeon tilesets of
            -- escape_rope_tilesets.asm minus Agatha's room, even in
            -- the dark (Rock Tunnel)
            table.insert(self.subItems, { label = "DIG", action = "escape" })
          end
        end
      end
    end
  end
end

function PartyMenu:draw()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  love.graphics.setColor(0, 0, 0, 1)
  local party = self.party or self.game.save.party
  if #party == 0 then
    Font.draw("No POKéMON!", 16, 64)
  end
  local HudTiles = require("src.render.HudTiles")
  for i, mon in ipairs(party) do
    local def = self.game.data.pokemon[mon.species]
    local y = (i - 1) * 16 + 12
    love.graphics.setColor(1, 1, 1, 1)
    drawIcon(self.game, mon, 8, y - 2, i == self.index, self.blink or 0)
    love.graphics.setColor(0, 0, 0, 1)
    Font.draw(mon.nickname or def.name, 24, y)
    -- level at column 13 (<LV> tile + digits, PrintLevel) AND the
    -- status/FNT text at column 17 (PrintStatusCondition), like the
    -- original rows -- statused mons keep their level display
    if mon.level < 100 then
      HudTiles.tile(0x6E, 104, y) -- <LV>
      Font.draw(tostring(mon.level), 112, y)
    else
      -- PrintLevel overwrites the <LV> tile with the third digit
      Font.draw(tostring(mon.level), 104, y)
    end
    if mon.hp <= 0 then
      Font.draw("FNT", 136, y)
    elseif mon.status then
      Font.draw(mon.status, 136, y)
    end
    -- the colored tile HP bar (DrawHP2 + SetPartyMenuHPBarColor)
    love.graphics.setColor(1, 1, 1, 1)
    HudTiles.drawHPBar(self.game.data, 5, (y + 8) / 8, mon)
    love.graphics.setColor(0, 0, 0, 1)
    Font.draw(("%3d/%3d"):format(mon.hp, mon.stats.hp), 104, y + 8)
    if i == self.index then
      Font.drawCode(CURSOR, 0, y)
    end
    if i == self.swapFrom or i == self.softboiledFrom then
      Font.drawCode(0xEC, 0, y) -- the unfilled swap arrow
    end
  end
  if self.swapFrom then
    Font.draw("Move to where?", 8, 136)
  elseif self.softboiledFrom then
    Font.draw("Use on which one?", 8, 136)
  elseif self.pickOnly then
    Font.draw("Use on which one?", 8, 136)
  end
  if self.submenu then
    local n = #self.subItems
    Font.drawBox(9, 17 - n * 2 - 1, 11, n * 2 + 1)
    local y0 = (17 - n * 2) * 8
    for si, entry in ipairs(self.subItems) do
      Font.draw(entry.label, 88, y0 + (si - 1) * 16)
    end
    Font.drawCode(CURSOR, 80, y0 + (self.subIndex - 1) * 16)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

return PartyMenu
