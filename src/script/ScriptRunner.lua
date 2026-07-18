-- Executes map scripts: lists of { "command", args... } rows (see
-- src/script/Commands.lua and data/scripts/).  Runs as a coroutine so
-- commands like show_text and wait can block on UI.
--
-- Map-specific behavior lives in data/scripts/<map>.lua modules, never in
-- engine code.  Each hand-ported script references its asm source.

local Commands = require("src.script.Commands")
local Logger = require("src.core.Logger")

local unpack = table.unpack or unpack -- LuaJIT (LÖVE) compatibility

local ScriptRunner = {}
ScriptRunner.__index = ScriptRunner

function ScriptRunner.new(game, overworld)
  local self = setmetatable({}, ScriptRunner)
  self.game = game
  self.overworld = overworld
  self.co = nil
  return self
end

function ScriptRunner:isRunning()
  return self.co ~= nil and coroutine.status(self.co) ~= "dead"
end

-- ctx passed to commands: engine services plus per-run info (npc, map)
function ScriptRunner:makeContext(extra)
  local ctx = {
    game = self.game,
    overworld = self.overworld,
    save = self.game.save,
    runner = self,
  }
  for k, v in pairs(extra or {}) do ctx[k] = v end
  return ctx
end

function ScriptRunner:run(script, extra)
  assert(not self:isRunning(), "script already running")
  local ctx = self:makeContext(extra)
  self.co = coroutine.create(function()
    self:exec(script, ctx)
    if ctx.onDone then ctx.onDone() end
  end)
  self:resume()
end

-- Execute a command list.  Supports labels via jump commands: a script is
-- an array of rows; control commands return a new program counter.
function ScriptRunner:exec(script, ctx)
  local pc = 1
  while pc <= #script do
    local row = script[pc]
    local name = row[1]
    local fn = Commands[name]
    if not fn then
      Logger.warn("script: unknown command '%s' (skipped)", tostring(name))
      pc = pc + 1
    else
      local jump = fn(ctx, select(2, unpack(row)))
      if type(jump) == "number" then
        pc = jump
      else
        pc = pc + 1
      end
    end
  end
end

-- Called by blocking commands from inside the coroutine.
function ScriptRunner:yield()
  coroutine.yield()
end

function ScriptRunner:resume(...)
  if not self.co then return end
  local ok, err = coroutine.resume(self.co, ...)
  if not ok then
    Logger.error("script error: %s", tostring(err))
    self.co = nil
  elseif coroutine.status(self.co) == "dead" then
    self.co = nil
  end
end

function ScriptRunner:update()
  -- commands that wait on frames re-resume every step while running
  if self:isRunning() and self.waitingFrames then
    self.waitingFrames = self.waitingFrames - 1
    if self.waitingFrames <= 0 then
      self.waitingFrames = nil
      self:resume()
    end
  end
end

return ScriptRunner
