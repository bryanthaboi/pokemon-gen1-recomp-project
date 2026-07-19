-- Game state stack.  The top state updates; all states draw bottom-up
-- (so a text box can overlay the overworld, a battle replaces it, etc).
-- States are tables with optional enter/exit/update/draw/isOpaque.

local Runtime = require("src.mods.Runtime")

local StateStack = {}

function StateStack:init()
  self.states = {}
end

-- screen.pushed/popped fire after enter/exit so listeners observe the
-- settled state; the wants guard keeps the no-listener path allocation-free

function StateStack:push(state, ...)
  table.insert(self.states, state)
  if state.enter then state:enter(...) end
  if Runtime.wants("screen.pushed") then
    Runtime.emit("screen.pushed", { state = state })
  end
end

function StateStack:pop()
  local state = table.remove(self.states)
  if state and state.exit then state:exit() end
  if state and Runtime.wants("screen.popped") then
    Runtime.emit("screen.popped", { state = state })
  end
  return state
end

function StateStack:top()
  return self.states[#self.states]
end

function StateStack:update(dt)
  local top = self:top()
  if top and top.update then top:update(dt) end
end

-- index of the lowest state drawn this frame (highest opaque, else 1)
function StateStack:visibleBase()
  for i = #self.states, 1, -1 do
    if self.states[i].isOpaque then return i end
  end
  return 1
end

function StateStack:draw()
  for i = self:visibleBase(), #self.states do
    if self.states[i].draw then self.states[i]:draw() end
  end
end

return StateStack
