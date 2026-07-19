-- The map_scripts compose store (09 §4.4).  The engine's hand-ported
-- data/scripts/* modules are the base contribution -- attachBase folds
-- them with the v1 merge rules (talk per TEXT constant, other keys
-- replaced by later files), so a mod-free boot dispatches the exact
-- table it always did.  Mod contributions arrive through the merged
-- registry (Data.map_scripts, one ordered chain per map id) and compose:
--
--   talk / scripts / legacy keys  single winner, false suppresses
--   onEnter / onVictory / onBoulderMoved  all-run, pcall-guarded
--   onStep / onInteract  first truthy return consumes
--
-- Precedence is priority descending, later registration first at equal
-- priority; base sits at priority 0 behind every default-priority mod.

local Data = require("src.core.Data")
local Logger = require("src.core.Logger")
local Runtime = require("src.mods.Runtime")

local MapScripts = {}

local base = {}   -- mapId -> merged engine contribution
local views = {}  -- mapId -> { chain = chainRef, value = merged view, sources }

local HOOK_RULES = {
  onEnter = "all", onVictory = "all", onBoulderMoved = "all",
  onStep = "first", onInteract = "first",
}

-- the v1 merge, verbatim: later base files override earlier ones
function MapScripts.attachBase(mapId, contribution)
  local existing = base[mapId]
  if not existing then
    base[mapId] = contribution
  else
    for k, v in pairs(contribution) do
      if k == "talk" and existing.talk then
        for textConst, script in pairs(v) do
          existing.talk[textConst] = script
        end
      else
        existing[k] = v
      end
    end
  end
  views[mapId] = nil
end

function MapScripts.invalidate(mapId)
  if mapId then
    views[mapId] = nil
  else
    views = {}
  end
end

-- Registry:chain hands the mod contributions priority-descending with
-- earlier registrations first; re-rank each equal-priority run so a
-- later registration outranks an earlier one, then slot base in at
-- priority 0 behind the mods that tie it.  chain.owners -- stamped by the
-- loader merge, index-aligned with the values -- rides along so every
-- contribution keeps its attribution.
local function contributions(chain, baseEntry)
  local owners = chain.owners or {}
  local ordered, run, runPriority = {}, {}, nil
  local function flush()
    for i = #run, 1, -1 do ordered[#ordered + 1] = run[i] end
    run = {}
  end
  for i, entry in ipairs(chain) do
    local p = type(entry) == "table" and entry.priority or 0
    if p ~= runPriority then
      flush()
      runPriority = p
    end
    run[#run + 1] = { value = entry, owner = owners[i] }
  end
  flush()
  if baseEntry then
    local at = #ordered + 1
    for i, entry in ipairs(ordered) do
      local p = type(entry.value) == "table" and entry.value.priority or 0
      if (p or 0) < 0 then
        at = i
        break
      end
    end
    table.insert(ordered, at, { value = baseEntry })
  end
  return ordered
end

-- the runner's ctx.source for one contribution's rows (09 §4.4): errors,
-- mod: field routing and the script events name the owning mod.  Base
-- contributions stay unattributed, so a mod-free dispatch hands the runner
-- the exact extra it always did.
local function sourceFor(owner, mapId, hook)
  if not (owner and owner.modId) then return nil end
  return { modId = owner.modId, strict = owner.strict,
           mapId = mapId, hook = hook }
end

local function blame(mapId, hookName, owner, err)
  local modId = owner and owner.modId
  Logger.error("map script %s.%s [%s]: %s", mapId, hookName,
    tostring(modId or "engine"), tostring(err))
  if modId then Runtime.reportError(modId, tostring(err)) end
end

local function chainAll(mapId, hookName, handlers)
  return function(...)
    for _, handler in ipairs(handlers) do
      local ok, err = pcall(handler.fn, ...)
      if not ok then blame(mapId, hookName, handler.owner, err) end
    end
  end
end

local function chainFirst(mapId, hookName, handlers)
  return function(...)
    local result
    for _, handler in ipairs(handlers) do
      local ok, value = pcall(handler.fn, ...)
      if not ok then
        blame(mapId, hookName, handler.owner, value)
      elseif value then
        return value
      else
        result = value
      end
    end
    return result
  end
end

local function buildView(mapId, ordered)
  local view = { talk = {} }
  local sources = { talk = {}, scripts = {} }
  local talkDefined, scriptsDefined, otherDefined = {}, {}, {}
  local hooks = {}
  for _, entry in ipairs(ordered) do
    local contribution, owner = entry.value, entry.owner
    for key, value in pairs(contribution) do
      if key == "talk" then
        for textConst, script in pairs(value) do
          if not talkDefined[textConst] then
            talkDefined[textConst] = true
            -- false is explicit suppression: talkTo falls through to its
            -- item-ball/trainer/mart branches
            if script ~= false then
              view.talk[textConst] = script
              sources.talk[textConst] = sourceFor(owner, mapId, "talk")
            end
          end
        end
      elseif key == "scripts" then
        view.scripts = view.scripts or {}
        for name, rows in pairs(value) do
          if not scriptsDefined[name] then
            scriptsDefined[name] = true
            if rows ~= false then
              view.scripts[name] = rows
              sources.scripts[name] = sourceFor(owner, mapId, "scripts." .. name)
            end
          end
        end
      elseif HOOK_RULES[key] then
        local list = hooks[key]
        if not list then
          list = {}
          hooks[key] = list
        end
        list[#list + 1] = { fn = value, owner = owner }
      elseif key ~= "priority" then
        -- legacy ad-hoc keys (snorlaxWake, escort, ...): talk's rule
        if not otherDefined[key] then
          otherDefined[key] = true
          if value ~= false then view[key] = value end
        end
      end
    end
  end
  for hookName, handlers in pairs(hooks) do
    if #handlers == 1 and not (handlers[1].owner and handlers[1].owner.modId) then
      -- a lone base handler dispatches bare, exactly as the v1 merge did
      view[hookName] = handlers[1].fn
    elseif HOOK_RULES[hookName] == "all" then
      view[hookName] = chainAll(mapId, hookName, handlers)
    else
      view[hookName] = chainFirst(mapId, hookName, handlers)
    end
  end
  return view, sources
end

function MapScripts.get(mapId)
  local chains = Data.map_scripts
  local chain = chains and chains[mapId]
  local baseEntry = base[mapId]
  -- map_scripts:override or :remove cleared the chain for this map
  -- (09 4.4), so the engine's own contribution is excluded too -- otherwise
  -- a total conversion still gets the vanilla onEnter and every TEXT
  -- constant it did not redefine, and a removed map is not actually gone.
  -- A tombstone arrives as an empty chain and falls through to nil below
  if chain and chain.replacesBase then baseEntry = nil end
  if not chain or #chain == 0 then return baseEntry end
  local hit = views[mapId]
  if hit and hit.chain == chain then return hit.value end
  local view, sources = buildView(mapId, contributions(chain, baseEntry))
  views[mapId] = { chain = chain, value = view, sources = sources }
  return view
end

-- the cached sources beside a map's merged view; nil when the map has no
-- chain (base fast path) and for base-owned winners
local function viewSources(mapId)
  local chains = Data.map_scripts
  local chain = chains and chains[mapId]
  if not chain or #chain == 0 then return nil end
  MapScripts.get(mapId)
  local hit = views[mapId]
  return hit and hit.sources
end

-- ctx.source for a talk dispatch, handed to ScriptRunner:run by
-- showMapText so the winning contribution's rows run as their owner
function MapScripts.talkSource(mapId, textConst)
  local sources = viewSources(mapId)
  return sources and sources.talk[textConst] or nil
end

-- ctx.source for a named `scripts` entry (run_parallel / queueScript refs)
function MapScripts.namedSource(mapId, name)
  local sources = viewSources(mapId)
  return sources and sources.scripts[name] or nil
end

-- script to run when the player talks to an object with this TEXT_ constant
function MapScripts.talkScript(mapId, textConst)
  local view = MapScripts.get(mapId)
  return view and view.talk and view.talk[textConst] or nil
end

-- the base (engine) talk handler behind any mod override -- the supported
-- replacement for the old re-wrap idiom
function MapScripts.baseTalk(mapId, textConst)
  local entry = base[mapId]
  return entry and entry.talk and entry.talk[textConst] or nil
end

-- "MAP_ID/name" refs used by run_parallel and queueScript
function MapScripts.namedScript(mapId, name)
  local view = MapScripts.get(mapId)
  return view and view.scripts and view.scripts[name] or nil
end

-- ------- load-time validation (09 §4.9)

-- every row list reachable from one contribution; findings name the key
-- they were found under.  lookup is the verb resolver handed to
-- ScriptRunner.validate; the loader and modkit share this pass.
function MapScripts.validateContribution(contribution, lookup)
  local ScriptRunner = require("src.script.ScriptRunner")
  local problems = {}
  local function collect(where, rows)
    if type(rows) ~= "table" then return end
    for _, finding in ipairs(ScriptRunner.validate(rows, lookup)) do
      problems[#problems + 1] = where .. ": " .. finding
    end
  end
  if type(contribution) ~= "table" then
    return { "contribution is not a table" }
  end
  for textConst, script in pairs(contribution.talk or {}) do
    if type(script) == "table" then collect("talk." .. textConst, script) end
  end
  for name, rows in pairs(contribution.scripts or {}) do
    if type(rows) == "table" then collect("scripts." .. name, rows) end
  end
  if type(contribution.snorlaxWake) == "table" then
    collect("snorlaxWake", contribution.snorlaxWake.script)
  end
  return problems
end

return MapScripts
