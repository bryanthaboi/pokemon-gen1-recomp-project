-- Executes map scripts: lists of { "command", args... } rows (see
-- src/script/Commands.lua and data/scripts/).  Runs as a coroutine so
-- commands like show_text and wait can block on UI.
--
-- Map-specific behavior lives in data/scripts/<map>.lua modules, never in
-- engine code.  Each hand-ported script references its asm source.
--
-- Script v2: { "label", "name" } rows are jump targets; jump/jump_if_*
-- may return a label name and exec resolves it through a pre-scanned
-- label map.  "end" is reserved shorthand for halt.  Numeric targets are
-- untouched, so hand-numbered vanilla ports keep working row for row.

local Commands = require("src.script.Commands")
local Logger = require("src.core.Logger")
local Runtime = require("src.mods.Runtime")

local unpack = table.unpack or unpack -- LuaJIT (LÖVE) compatibility

local ScriptRunner = {}
ScriptRunner.__index = ScriptRunner

-- weak-keyed so a hot-reloaded script table drops its stale scan
local labelCache = setmetatable({}, { __mode = "k" })

function ScriptRunner.scanLabels(script)
  local hit = labelCache[script]
  if hit then return hit end
  local labels = {}
  for index, row in ipairs(script) do
    if type(row) == "table" and row[1] == "label" and type(row[2]) == "string"
        and labels[row[2]] == nil then
      labels[row[2]] = index
    end
  end
  labelCache[script] = labels
  return labels
end

-- Load-time validation (09 §4.9): every finding names its row.  lookup
-- is fn(verb) -> true when the verb resolves; nil uses the built-in set,
-- so the offline validator and the loader share this code path.
function ScriptRunner.validate(script, lookup)
  local problems = {}
  local function bad(fmt, ...)
    problems[#problems + 1] = fmt:format(...)
  end
  if type(script) ~= "table" then
    bad("script is not a row list")
    return problems
  end
  lookup = lookup or function(verb) return Commands[verb] ~= nil end
  local labels = {}
  for index, row in ipairs(script) do
    if type(row) ~= "table" or type(row[1]) ~= "string" then
      bad("row %d is not a { \"command\", ... } row", index)
    elseif row[1] == "label" then
      local name = row[2]
      if type(name) ~= "string" then
        bad("row %d: label needs a string name", index)
      elseif labels[name] then
        bad("row %d: duplicate label '%s' (first at row %d)",
          index, name, labels[name])
      else
        labels[name] = index
      end
    elseif not lookup(row[1]) then
      bad("row %d: unknown command '%s'", index, row[1])
    end
  end
  for index, row in ipairs(script) do
    if type(row) == "table" and (row[1] == "jump" or row[1] == "jump_if_true"
        or row[1] == "jump_if_false") then
      local target = row[2]
      if type(target) == "string" then
        if target ~= "end" and not labels[target] then
          bad("row %d: jump to missing label '%s'", index, target)
        end
      elseif type(target) == "number" then
        if target ~= math.huge and (target < 1 or target > #script
            or target % 1 ~= 0) then
          bad("row %d: jump target %s out of range 1..%d",
            index, tostring(target), #script)
        end
      else
        bad("row %d: jump needs a label or row number", index)
      end
    end
  end
  return problems
end

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

-- ctx passed to commands: engine services plus per-run info (npc, map).
-- extra.source = { modId, mapId, hook } attributes errors and the mod:
-- field route to the contribution's owner.
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
  self.ctx = ctx
  if Runtime.wants("script.started") then
    Runtime.emit("script.started", { ctx = ctx })
  end
  self.co = coroutine.create(function()
    self:exec(script, ctx)
    if ctx.onDone then ctx.onDone() end
    if Runtime.wants("script.ended") then
      Runtime.emit("script.ended", { ctx = ctx, completed = true })
    end
  end)
  self:resume()
end

-- Execute a command list.  Supports labels via jump commands: a script is
-- an array of rows; control commands return a new program counter, as a
-- row number or a label name.
function ScriptRunner:exec(script, ctx)
  local labels = ScriptRunner.scanLabels(script)
  local data = self.game and self.game.data
  local pc = 1
  while pc <= #script do
    local row = script[pc]
    local name = row[1]
    local fn, meta = Commands.resolve(data, name)
    if not fn then
      -- api 2 owned scripts fail loudly; everything else keeps the v1
      -- skip so old content degrades instead of dying
      if ctx.source and ctx.source.strict then
        error(("unknown command '%s' at row %d"):format(tostring(name), pc), 0)
      end
      Logger.warn("script: unknown command '%s' (skipped)", tostring(name))
      pc = pc + 1
    else
      if self.parallel and meta and meta.foreground then
        error(("'%s' is a foreground command; illegal in a parallel script")
          :format(name), 0)
      end
      local jump
      if Runtime.wantsHook("script.command") then
        local args = { select(2, unpack(row)) }
        jump = Runtime.call("script.command", function(hctx, _, hargs)
          return fn(hctx, unpack(hargs))
        end, ctx, name, args)
      else
        jump = fn(ctx, select(2, unpack(row)))
      end
      if type(jump) == "string" then
        if jump == "end" then
          pc = math.huge
        else
          local target = labels[jump]
          if not target then
            error(("jump to missing label '%s' at row %d"):format(jump, pc), 0)
          end
          pc = target
        end
      elseif type(jump) == "number" then
        pc = jump
      else
        pc = pc + 1
      end
    end
  end
end

-- Called by blocking commands from inside the coroutine.
function ScriptRunner:yield()
  return coroutine.yield()
end

function ScriptRunner:resume(...)
  if not self.co then return end
  local ok, err = coroutine.resume(self.co, ...)
  if not ok then
    local source = self.ctx and self.ctx.source
    local where = source
      and (" [%s %s.%s]"):format(tostring(source.modId or "engine"),
        tostring(source.mapId or "?"), tostring(source.hook or "?"))
      or ""
    Logger.error("script error%s: %s", where, tostring(err))
    if source and source.modId then
      Runtime.reportError(source.modId, tostring(err))
    end
    if Runtime.wants("script.ended") then
      Runtime.emit("script.ended", { ctx = self.ctx, completed = false })
    end
    self.co = nil
    self.waitingFrames = nil
    self.waitingCheck = nil
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
  -- per-frame condition polls (wait_flag, push_screen): the check returns
  -- done plus the value the yield should hand back
  if self:isRunning() and self.waitingCheck then
    local done, result = self.waitingCheck()
    if done then
      self.waitingCheck = nil
      self:resume(result)
    end
  end
end

return ScriptRunner
