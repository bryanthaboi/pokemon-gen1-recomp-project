-- "Which move should be forgotten?",  replaces a move when a Pokémon with
-- four moves learns a new one (engine/pokemon/learn_move.asm).  Opens
-- with the TryingToLearnText "Delete an older move...?" YES/NO; HM moves
-- can't be forgotten; B / CANCEL gives up on the new move.

local Font = require("src.render.Font")

local MoveLearnMenu = {}
MoveLearnMenu.__index = MoveLearnMenu

local CURSOR = 0xED

-- data/moves/hm_moves.asm (IsMoveHM)
local HM_MOVES = {
  CUT = true, FLY = true, SURF = true, STRENGTH = true, FLASH = true,
}

function MoveLearnMenu.new(game, mon, newMoveId, onDone)
  local self = setmetatable({}, MoveLearnMenu)
  self.game = game
  self.mon = mon
  self.newMoveId = newMoveId
  self.onDone = onDone
  self.index = 1
  return self
end

function MoveLearnMenu:monName()
  return self.mon.nickname or self.game.data.pokemon[self.mon.species].name
end

-- TryingToLearnText + yes/no (learn_move.asm TryingToLearn): NO offers
-- AbandonLearning, whose own NO loops back here (DontAbandonLearning).
function MoveLearnMenu:enter()
  local TextBox = require("src.render.TextBox")
  local ChoiceBox = require("src.ui.ChoiceBox")
  local game = self.game
  local mdef = game.data.moves[self.newMoveId]
  local name = self:monName()
  game.stack:push(TextBox.new(game,
    ("%s is\ntrying to learn\v%s!\fBut, %s\ncan't learn more\vthan 4 moves!\f")
      :format(name, mdef.name, name) ..
    ("Delete an older\nmove to make room\vfor %s?"):format(mdef.name),
    function()
      game.stack:push(ChoiceBox.new(game, function(yes)
        if not yes then self:confirmAbandon() end
      end))
    end))
end

function MoveLearnMenu:update(dt)
  local input = self.game.input
  local n = #self.mon.moves + 1 -- moves + CANCEL
  if input:wasPressed("up") then
    self.index = self.index > 1 and self.index - 1 or n
  elseif input:wasPressed("down") then
    self.index = self.index < n and self.index + 1 or 1
  elseif input:wasPressed("b") then
    self:confirmAbandon()
  elseif input:wasPressed("a") then
    if self.index > #self.mon.moves then
      self:confirmAbandon()
    else
      local old = self.mon.moves[self.index]
      if HM_MOVES[old.id] then
        -- HMCantDeleteText, then back to the forget list
        local TextBox = require("src.render.TextBox")
        self.game.stack:push(TextBox.new(self.game,
          "HM techniques\ncan't be deleted!"))
        return
      end
      local mdef = self.game.data.moves[self.newMoveId]
      self.mon.moves[self.index] = { id = self.newMoveId, pp = mdef.pp }
      self.forgot = self.game.data.moves[old.id].name
      self:finish(true)
    end
  end
end

-- AbandonLearning (learn_move.asm): "Abandon learning MOVE?" YES/NO
-- before giving up; NO returns to the TryingToLearn prompt
-- (DontAbandonLearning)
function MoveLearnMenu:confirmAbandon()
  local TextBox = require("src.render.TextBox")
  local ChoiceBox = require("src.ui.ChoiceBox")
  local game = self.game
  local mdef = game.data.moves[self.newMoveId]
  game.stack:push(TextBox.new(game,
    ("Abandon learning\n%s?"):format(mdef.name), function()
    game.stack:push(ChoiceBox.new(game, function(yes)
      if yes then self:finish(false) else self:enter() end
    end))
  end))
end

function MoveLearnMenu:finish(learned)
  local TextBox = require("src.render.TextBox")
  local game = self.game
  local name = self:monName()
  local mdef = game.data.moves[self.newMoveId]
  game.stack:pop()
  local msg
  if learned then
    -- OneTwoAndText/PoofText/ForgotAndText
    msg = ("1, 2 and... Poof!\f%s forgot\n%s!\fAnd...\f%s learned\n%s!")
          :format(name, self.forgot, name, mdef.name)
  else
    -- DidNotLearnText
    msg = ("%s\ndid not learn\v%s!"):format(name, mdef.name)
  end
  game.stack:push(TextBox.new(game, msg, function()
    if self.onDone then self.onDone(learned) end
  end))
end

function MoveLearnMenu:draw()
  -- single-spaced move list box (TryingToLearn: TextBoxBorder at 4,7)
  -- plus the port's extra CANCEL row
  Font.drawBox(4, 5, 16, 7)
  love.graphics.setColor(0, 0, 0, 1)
  for i, mv in ipairs(self.mon.moves) do
    Font.draw(self.game.data.moves[mv.id].name, 48, (5 + i) * 8)
  end
  Font.draw("CANCEL", 48, (6 + #self.mon.moves) * 8)
  Font.drawCode(CURSOR, 40, (5 + self.index) * 8)
  -- WhichMoveToForgetText in the bottom dialogue box
  Font.drawBox(0, 12, 20, 6)
  Font.draw("Which move should", 8, 14 * 8)
  Font.draw("be forgotten?", 8, 16 * 8)
  love.graphics.setColor(1, 1, 1, 1)
end

return MoveLearnMenu
