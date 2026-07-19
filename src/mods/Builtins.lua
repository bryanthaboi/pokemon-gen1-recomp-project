-- The engine's own content, registered into the catalog under owner
-- "engine" before any mod runs.  Overriding a vanilla record and overriding
-- a mod's record are then the same verb, each() always yields the whole
-- world, and a mod's cross-references resolve against real ids.
-- Every registrant hands over the table its module already reads, and
-- install deep-copies it on the way in: two loads must not share record
-- tables, or an edit through one dataset (hot reload, a test loading
-- twice) reaches the other and the module's own statics.  Functions ride
-- the copy by reference, so handlers keep their identity and the merged
-- value stays equal to the vanilla one -- the mod-free merge is a no-op.
-- Modules are required lazily -- the loader must not drag the battle and
-- script stacks in with it at require time.
local Logger = require("src.core.Logger")
local Merge = require("src.mods.Merge")
local Schemas = require("src.mods.Schemas")

local Builtins = {}

Builtins.OWNER = Schemas.ENGINE

-- registry name -> the module that owns its vanilla records.  Each exposes
-- registerInto(registry, data, owner).
local REGISTRANTS = {
  { name = "type_chart", from = "src.battle.TypeChart" },
  { name = "statuses", from = "src.battle.Status" },
  { name = "move_effects", from = "src.battle.MoveEffects" },
  { name = "balls", from = "src.battle.Catching" },
  { name = "transitions", from = "src.render.BattleTransition" },
  { name = "growth_rates", from = "src.pokemon.Growth" },
  { name = "evolution_methods", from = "src.pokemon.Evolution" },
  { name = "commands", from = "src.script.Commands" },
  { name = "tokens", from = "src.render.TextBox" },
  -- plain data files with no owning module: registered from here
  { name = "rulesets", modules = { "src.battle.rulesets.gen1_faithful",
                                   "src.battle.rulesets.modern_clean" },
    install = function(registry, modules, owner)
      for _, ruleset in ipairs(modules) do
        registry:register(ruleset.name, ruleset, owner)
      end
    end },
  -- the per-trainer class records plus the three vanilla move-scoring
  -- layers, which share the registry under LAYER_1..LAYER_3
  { name = "ai_classes", modules = { "data.scripts.ai_classes",
                                     "src.battle.TrainerAI" },
    install = function(registry, modules, owner)
      for id, record in pairs(modules[1]) do
        registry:register(id, record, owner)
      end
      modules[2].registerInto(registry, nil, owner)
    end },
}

-- the registries the engine seeds, in registration order; the parity tests
-- read this to tell an engine-owned namespace from a stray one
function Builtins.registries()
  local names = {}
  for i, entry in ipairs(REGISTRANTS) do names[i] = entry.name end
  return names
end

-- the top-level Data keys those registrations bring into existence: the
-- only namespaces a mod-free boot is allowed to add
function Builtins.namespaceRoots()
  local roots = {}
  for _, name in ipairs(Builtins.registries()) do
    local target = Schemas.REGISTRIES[name] and Schemas.REGISTRIES[name].target
    if target then roots[target:match("^[^%.]+")] = true end
  end
  return roots
end

-- a module the build dropped disables its registry rather than the game:
-- the consumer still reads its own table, so vanilla keeps working
local function load(path)
  local ok, module = pcall(require, path)
  if ok then return module end
  Logger.warn("builtin registrations skipped for %s (%s)", path, tostring(module))
  return nil
end

-- the write verbs copy their payload before it lands; centralized here so
-- the isolation holds for every registrant instead of leaning on each
-- module to hand over fresh tables
local function isolate(registry)
  return setmetatable({
    register = function(_, id, value, owner)
      return registry:register(id, Merge.deepCopy(value), owner)
    end,
    override = function(_, id, value, owner)
      return registry:override(id, Merge.deepCopy(value), owner)
    end,
    patch = function(_, id, partial, owner)
      return registry:patch(id, Merge.deepCopy(partial), owner)
    end,
  }, { __index = registry })
end

function Builtins.install(content, data)
  for _, entry in ipairs(REGISTRANTS) do
    local registry = content[entry.name] and isolate(content[entry.name])
    if registry then
      if entry.install then
        local modules, complete = {}, true
        for i, path in ipairs(entry.modules) do
          modules[i] = load(path)
          if modules[i] == nil then complete = false end
        end
        if complete then entry.install(registry, modules, Builtins.OWNER) end
      else
        local module = load(entry.from)
        if module and module.registerInto then
          module.registerInto(registry, data, Builtins.OWNER)
        end
      end
    end
  end
end

return Builtins
