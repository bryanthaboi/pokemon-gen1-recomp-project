-- The evolution movie (engine/movie/evolution.asm): the mon's pic
-- flashes back and forth with the evolved form, speeding up, then the
-- new form appears with its cry and the congratulations text.
-- B during the flash cancels ("Huh? ... stopped evolving!"? -- Gen 1
-- has no cancel; the flash always completes).

local Font = require("src.render.Font")
local Music = require("src.core.Music")

local EvolutionState = {}
EvolutionState.__index = EvolutionState
EvolutionState.isOpaque = true

-- SGB: SetPal_PokemonWholeScreen for the mon on display
function EvolutionState:sgbPalettes(game)
  local P = require("src.render.PaletteFX")
  local species = self.done and self.newSpecies or self.mon.species
  local c = P.monPal(game.data, species)
  if c then return { P.whole(c) } end
  return P.wholeNamed(game.data, "MEWMON")
end

local FLASH_FRAMES = 220

local function frontSprite(game, species)
  local def = game.data.pokemon[species]
  if not (def and def.spriteFront) then return nil end
  local ok, img = pcall(love.graphics.newImage, def.spriteFront)
  return ok and img or nil
end

function EvolutionState.new(game, mon, newSpecies, onDone)
  local self = setmetatable({}, EvolutionState)
  self.game = game
  self.mon = mon
  self.newSpecies = newSpecies
  self.onDone = onDone
  self.oldName = mon.nickname or game.data.pokemon[mon.species].name
  self.oldSprite = frontSprite(game, mon.species)
  self.newSprite = frontSprite(game, newSpecies)
  self.t = 0
  self.done = false
  Music.play(game.data, Music.special(game.data, "evolution"))
  return self
end

function EvolutionState:update(dt)
  self.t = self.t + 1
  if self.done then return end
  if self.t >= FLASH_FRAMES then
    self.done = true
    local game = self.game
    local Evolution = require("src.pokemon.Evolution")
    Evolution.apply(game, self.mon, self.newSpecies)
    require("src.core.Sound").playCry(game.data, self.newSpecies)
    local TextBox = require("src.render.TextBox")
    local newName = game.data.pokemon[self.newSpecies].name
    game.stack:push(TextBox.new(game,
      ("Congratulations!\nYour %s\nevolved into\n%s!")
        :format(self.oldName, newName),
      function()
        Music.restoreMap(game.data)
        game.stack:pop() -- the evolution screen itself
        if self.onDone then self.onDone() end
      end))
  end
end

function EvolutionState:draw()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)

  -- accelerating flash between the two forms
  local sprite
  if self.done then
    sprite = self.newSprite
  else
    local period = math.max(4, 28 - math.floor(self.t / 40) * 6)
    local showNew = math.floor(self.t / period) % 2 == 1
    sprite = showNew and self.newSprite or self.oldSprite
  end
  if sprite then
    love.graphics.draw(sprite, math.floor((160 - sprite:getWidth()) / 2),
                       math.max(8, 64 - sprite:getHeight()))
  end

  love.graphics.setColor(0, 0, 0, 1)
  if not self.done then
    Font.draw("What?", 8, 104)
    Font.draw(self.oldName .. " is", 8, 114)
    Font.draw("evolving!", 8, 124)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

return EvolutionState
