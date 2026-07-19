-- Single source of truth for the registry catalog: per-registry merge
-- semantics (record | deep | compose), the Data target path each merge
-- writes, and the value schema every mod registration is checked against.
-- The loader builds its registries from this table and the reference docs
-- are generated from it, so neither can drift from the engine.
-- Pure Lua, no love.*, so the headless loader and doc generator run it.
local Merge = require("src.mods.Merge")

local Schemas = {}

-- ------- field-type combinators

local f = {}
Schemas.f = f

local function leaf(kind, desc, check)
  return { kind = kind, desc = desc, check = check }
end

f.str = leaf("str", "string", function(v) return type(v) == "string" end)
f.num = leaf("num", "number", function(v) return type(v) == "number" end)
f.bool = leaf("bool", "boolean", function(v) return type(v) == "boolean" end)
f.fn = leaf("fn", "function", function(v) return type(v) == "function" end)
f.any = leaf("any", "any value", function() return true end)
f.path = leaf("path", "file path", function(v)
  return type(v) == "string" and v ~= ""
end)
f.token = leaf("token", "text token name", function(v)
  return type(v) == "string" and v:match("^[%w_:%*]+$") ~= nil
end)

function f.int(min, max)
  local desc = "integer"
  if min and max then desc = ("integer %d..%d"):format(min, max)
  elseif min then desc = ("integer >= %d"):format(min) end
  return { kind = "int", min = min, max = max, desc = desc,
    check = function(v)
      return type(v) == "number" and v % 1 == 0
        and (min == nil or v >= min) and (max == nil or v <= max)
    end }
end

function f.enum(values)
  local set = {}
  for _, value in ipairs(values) do set[value] = true end
  local desc = 'one of "' .. table.concat(values, '" | "') .. '"'
  return { kind = "enum", set = set, values = values, desc = desc,
    check = function(v) return set[v] == true end }
end

function f.opt(inner)
  return { kind = "opt", inner = inner, desc = inner.desc }
end

function f.list(inner)
  return { kind = "list", inner = inner, desc = "list of " .. inner.desc }
end

function f.map(key, value)
  return { kind = "map", key = key, value = value,
    desc = ("map of %s -> %s"):format(key.desc, value.desc) }
end

function f.rec(fields)
  local names = {}
  for name in pairs(fields) do names[#names + 1] = name end
  table.sort(names)
  local parts = {}
  for _, name in ipairs(names) do
    local ft = fields[name]
    parts[#parts + 1] = name .. (ft.kind == "opt" and "?" or "")
  end
  return { kind = "rec", fields = fields,
    desc = "{" .. table.concat(parts, ", ") .. "}" }
end

function f.union(alts)
  local parts = {}
  for _, alt in ipairs(alts) do parts[#parts + 1] = alt.desc end
  return { kind = "union", alts = alts, desc = table.concat(parts, " | ") }
end

-- cross-registry reference; the type check at register time is string-only,
-- resolution happens in the post-merge pass so forward references work
function f.id(registry)
  return { kind = "id", registry = registry, desc = registry .. " id",
    check = function(v) return type(v) == "string" and v ~= "" end }
end

-- ------- validation

-- snake_case/camelCase typos normalize to the same key, which is how the
-- classic base_stats-for-baseStats mistake gets a suggestion
local function normalizeName(name)
  return tostring(name):lower():gsub("_", "")
end

local function suggest(fields, unknown)
  local want = normalizeName(unknown)
  for known in pairs(fields) do
    if normalizeName(known) == want then return known end
  end
  return nil
end

local function got(value)
  if type(value) == "string" then return string.format("%q", value) end
  if type(value) == "table" then return "table" end
  return tostring(value)
end

local function fail(errors, path, expected, value)
  errors[#errors + 1] = ("%s: expected %s, got %s"):format(path, expected, got(value))
end

-- top marks the outermost value of a spec.value registry; opt and union
-- re-dispatch on the same value so they carry it, descending drops it
local checkValue
checkValue = function(t, value, path, patchMode, errors, top)
  if value == Merge.DELETE then
    if not patchMode then fail(errors, path, t.desc, value) end
    return
  end
  local kind = t.kind
  if kind == "any" then return end
  if kind == "opt" then return checkValue(t.inner, value, path, patchMode, errors, top) end
  if kind == "list" then
    if type(value) ~= "table" then return fail(errors, path, t.desc, value) end
    -- lists replace wholesale, so every row is a complete value even
    -- inside a patch; an extension wrapper carries the same rows and is
    -- typed the same way instead of slipping through unseen
    if Merge.isWrapper(value) then
      for _, key in ipairs({ "__prepend", "__append" }) do
        for i, element in ipairs(value[key] or {}) do
          checkValue(t.inner, element, ("%s.%s[%d]"):format(path, key, i),
            false, errors)
        end
      end
      return
    end
    for i, element in ipairs(value) do
      checkValue(t.inner, element, path .. "[" .. i .. "]", false, errors)
    end
    return
  end
  if kind == "map" then
    if type(value) ~= "table" then return fail(errors, path, t.desc, value) end
    for k, v in pairs(value) do
      if not t.key.check(k) then
        fail(errors, path .. "." .. tostring(k), "key " .. t.key.desc, k)
      end
      checkValue(t.value, v, path .. "." .. tostring(k), patchMode, errors)
    end
    return
  end
  if kind == "rec" then
    if type(value) ~= "table" then return fail(errors, path, t.desc, value) end
    for key, sub in pairs(value) do
      local ft = t.fields[key]
      if ft == nil then
        -- the top-level record stays extensible like the spec.fields path:
        -- unknown keys are preserved unless they read as a typo of a known
        -- field.  Nested recs stay strict, that is where typos hide.
        local hint = suggest(t.fields, key)
        if hint or not top then
          errors[#errors + 1] = ("%s.%s: unknown field%s"):format(path, tostring(key),
            hint and (' (did you mean "' .. hint .. '"?)') or "")
        end
      else
        checkValue(ft, sub, path .. "." .. tostring(key), patchMode, errors)
      end
    end
    if not patchMode then
      for key, ft in pairs(t.fields) do
        if value[key] == nil and ft.kind ~= "opt" then
          errors[#errors + 1] = ("%s.%s: missing required field (%s)")
            :format(path, key, ft.desc)
        end
      end
    end
    return
  end
  if kind == "union" then
    for _, alt in ipairs(t.alts) do
      local scratch = {}
      checkValue(alt, value, path, patchMode, scratch, top)
      if #scratch == 0 then return end
    end
    return fail(errors, path, t.desc, value)
  end
  if not t.check(value) then fail(errors, path, t.desc, value) end
end

-- mode is "register" | "override" (full record: required fields enforced),
-- "patch" (only provided leaves checked, DELETE legal) or "remove" (no
-- value).  Unknown top-level fields are allowed and preserved -- extensible
-- records are a feature -- but a patch key that is only a case/underscore
-- variant of a schema field is the classic typo and gets rejected with a
-- suggestion.
function Schemas.check(spec, registryName, id, value, mode)
  if mode == "remove" or spec == nil then return true end
  -- register and patch are synonyms on a deep registry, so a partial
  -- payload is the normal case there and only override is a full value
  local patchMode = mode == "patch"
    or (spec.semantics == "deep" and mode == "register")
  local errors = {}
  local path = registryName .. "." .. tostring(id)
  if spec.keys or spec.keyValue then
    -- deep registries are open namespaces: a key the catalog does not
    -- describe is a mod's own data, not a mistake.  keyValue types every
    -- key alike, for namespaces whose keys are content (one per map).
    local keyType = (spec.keys and spec.keys[id]) or spec.keyValue
    if keyType then checkValue(keyType, value, path, patchMode, errors, true) end
  elseif spec.value then
    checkValue(spec.value, value, path, patchMode, errors, true)
    if #errors == 0 and not patchMode and spec.extra then
      local problem = spec.extra(id, value)
      if problem then errors[#errors + 1] = ("%s: %s"):format(path, problem) end
    end
  elseif spec.fields then
    if type(value) ~= "table" then
      fail(errors, path, "record table", value)
    else
      for key, sub in pairs(value) do
        local ft = spec.fields[key]
        if ft ~= nil then
          checkValue(ft, sub, path .. "." .. tostring(key), patchMode, errors)
        elseif patchMode then
          local hint = suggest(spec.fields, key)
          if hint then
            errors[#errors + 1] = ('%s.%s: unknown field (did you mean "%s"?)')
              :format(path, tostring(key), hint)
          end
        end
      end
      if not patchMode then
        for key, ft in pairs(spec.fields) do
          if value[key] == nil and ft.kind ~= "opt" then
            errors[#errors + 1] = ("%s.%s: missing required field (%s)")
              :format(path, key, ft.desc)
          end
        end
      end
      if #errors == 0 and not patchMode and spec.extra then
        local problem = spec.extra(id, value)
        if problem then
          errors[#errors + 1] = ("%s: %s"):format(path, problem)
        end
      end
    end
  end
  if #errors == 0 then return true end
  return nil, table.concat(errors, "; ")
end

-- ------- cross-reference pass

local collectRefs
collectRefs = function(t, value, path, out)
  if value == nil or value == Merge.DELETE then return end
  local kind = t.kind
  if kind == "opt" then return collectRefs(t.inner, value, path, out) end
  if kind == "id" then
    if type(value) == "string" then
      out[#out + 1] = { registry = t.registry, ref = value, path = path }
    end
    return
  end
  if kind == "list" and type(value) == "table" then
    for i, element in ipairs(value) do
      collectRefs(t.inner, element, path .. "[" .. i .. "]", out)
    end
  elseif kind == "map" and type(value) == "table" then
    for k, v in pairs(value) do
      collectRefs(t.value, v, path .. "." .. tostring(k), out)
    end
  elseif kind == "rec" and type(value) == "table" then
    for key, ft in pairs(t.fields) do
      collectRefs(ft, value[key], path .. "." .. tostring(key), out)
    end
  elseif kind == "union" then
    -- refs live in whichever alternative the value satisfies
    for _, alt in ipairs(t.alts) do
      local scratch = {}
      checkValue(alt, value, path, true, scratch)
      if #scratch == 0 then return collectRefs(alt, value, path, out) end
    end
  end
end

-- every f.id ref reachable from one record, tagged with its field path
local function refsFor(spec, name, id, value)
  local refs = {}
  if spec.keys or spec.keyValue then
    local keyType = (spec.keys and spec.keys[id]) or spec.keyValue
    if keyType then
      collectRefs(keyType, value, name .. "." .. tostring(id), refs)
    end
  elseif spec.fields and type(value) == "table" then
    for key, ft in pairs(spec.fields) do
      collectRefs(ft, value[key], name .. "." .. tostring(id) .. "." .. key, refs)
    end
  elseif spec.value then
    collectRefs(spec.value, value, name .. "." .. tostring(id), refs)
  end
  return refs
end

-- a structured target (battle_anims' per-kind subtables) hides its ids one
-- level down, so the pristine scan asks the spec instead of the raw keys
local function baseEntries(registry, base)
  local spec = registry.spec
  if not spec.baseIds then return pairs(base) end
  local ids = spec.baseIds(base)
  local i = 0
  return function()
    i = i + 1
    local id = ids[i]
    if id == nil then return nil end
    return id, spec.baseAt(base, id)
  end
end

-- runs once after the merge.  Records mods touched are scanned for dangling
-- refs (the op logs limit that, so a mod-free boot does zero work); if any
-- id folded to nil the scan widens to the untouched base records too, so a
-- remove that strands a vanilla reference is caught and attributed to the
-- removing mod instead of surfacing as an unowned crash later.  References
-- into registries the catalog does not declare yet are skipped, not guessed.
function Schemas.crossValidate(loader, data)
  local problems = {}
  local tombstoned, removed = {}, false
  for name, registry in pairs(loader.content) do
    for id in pairs(registry.ops) do
      if registry:get(id) == nil then
        tombstoned[name] = tombstoned[name] or {}
        tombstoned[name][id] = true
        removed = true
      end
    end
  end
  for name, registry in pairs(loader.content) do
    local spec = registry.spec
    for id in pairs(registry.ops) do
      local value = registry:get(id)
      if value ~= nil and registry.owners[id] ~= Schemas.ENGINE then
        for _, ref in ipairs(refsFor(spec, name, id, value)) do
          local refRegistry = Schemas.REGISTRIES[ref.registry]
            and loader.content[ref.registry]
          if refRegistry and refRegistry:get(ref.ref) == nil then
            problems[#problems + 1] = {
              owner = registry.owners[id],
              message = ("%s: unresolved reference to %s %q")
                :format(ref.path, ref.registry, ref.ref),
            }
          end
        end
      end
    end
    if removed then
      local base = registry.base and registry.base()
      if base then
        for id, value in baseEntries(registry, base) do
          if registry.ops[id] == nil then
            for _, ref in ipairs(refsFor(spec, name, id, value)) do
              local set = tombstoned[ref.registry]
              if set and set[ref.ref] then
                problems[#problems + 1] = {
                  owner = loader.content[ref.registry].owners[ref.ref],
                  message = ("%s: unresolved reference to removed %s %q")
                    :format(ref.path, ref.registry, ref.ref),
                }
              end
            end
          end
        end
      end
    end
  end
  return problems
end

-- ------- the catalog

-- v1 registry names that live on as thin views of a renamed registry; both
-- names share one op log and diagnostics report the canonical name
Schemas.ALIASES = { scripts = "map_scripts", ui = "screens" }

-- owner of the engine's own registrations (src/mods/Builtins.lua); vanilla
-- content is internally consistent by construction, so the cross-reference
-- pass skips it and stays zero-work on a mod-free boot
Schemas.ENGINE = "engine"

local R = {}
Schemas.REGISTRIES = R

R.pokemon = {
  semantics = "record", target = "pokemon",
  fields = {
    id = f.str, name = f.str, dex = f.int(1),
    index = f.opt(f.int(0, 255)),
    types = f.list(f.id("type_chart")),
    baseStats = f.rec{ hp = f.int(1, 255), attack = f.int(1, 255),
                       defense = f.int(1, 255), speed = f.int(1, 255),
                       special = f.int(1, 255) },
    catchRate = f.int(0, 255), baseExp = f.int(0, 255),
    level1Moves = f.list(f.id("moves")),
    growthRate = f.id("growth_rates"),
    tmhm = f.opt(f.list(f.id("moves"))),
    learnset = f.list(f.rec{ level = f.int(1), move = f.id("moves") }),
    evolutions = f.list(f.rec{ method = f.id("evolution_methods"),
                               level = f.opt(f.int(1)),
                               item = f.opt(f.id("items")),
                               species = f.id("pokemon") }),
    spriteFront = f.path, spriteBack = f.path, frontSize = f.int(1, 7),
    dexEntry = f.opt(f.rec{ kind = f.str, heightFt = f.int(0),
                            heightIn = f.int(0, 11), weight = f.num,
                            text = f.str }),
    icon = f.opt(f.union{ f.str, f.rec{ image = f.path,
                                        frames = f.opt(f.int(1)) } }),
    cry = f.opt(f.id("cries")), palette = f.opt(f.id("palettes")),
    trueColor = f.opt(f.bool),
  },
  example = 'mod.content.pokemon:patch("MEW", { baseStats = { attack = 120 } })',
}

R.moves = {
  semantics = "record", target = "moves",
  fields = {
    id = f.str, name = f.str,
    index = f.opt(f.int(0, 255)),
    type = f.id("type_chart"),
    power = f.int(0, 255),
    accuracy = f.int(0, 100),
    pp = f.int(0, 64),
    effect = f.id("move_effects"),
    anim = f.opt(f.any),
    category = f.opt(f.enum{ "physical", "special", "status" }),
    priority = f.opt(f.int(-7, 7)),
    highCrit = f.opt(f.bool),
    fixedDamage = f.opt(f.union{ f.int(1), f.fn }),
    chargeText = f.opt(f.str),
    semiInvulnerable = f.opt(f.bool),
    -- a fixed count or the distribution a uniform roll picks from
    multiHit = f.opt(f.union{ f.int(1), f.list(f.int(1)) }),
    counterable = f.opt(f.bool),
  },
  example = 'mod.content.moves:patch("BLIZZARD", { accuracy = 70 })',
}

R.items = {
  semantics = "record", target = "items",
  fields = {
    id = f.str, name = f.str,
    index = f.opt(f.int(0, 255)),
    price = f.int(0),
    machine = f.opt(f.rec{ kind = f.str, move = f.id("moves"),
                           number = f.int(0) }),
    effect = f.opt(f.id("item_effects")),
    ball = f.opt(f.id("balls")),
    tossable = f.opt(f.bool),
    needsTarget = f.opt(f.bool),
  },
  example = 'mod.content.items:patch("POTION", { price = 100 })',
}

R.maps = {
  semantics = "record", target = "maps",
  fields = {
    -- the byte cap is a ROM table artifact; mod maps use ids at or above
    -- 1000, and the indoor/connection range compares read the number
    id = f.str, label = f.opt(f.str), index = f.opt(f.int(0)),
    tileset = f.id("tilesets"),
    width = f.int(1), height = f.int(1),
    blocks = f.list(f.int(0, 255)),
    borderBlock = f.opt(f.int(0, 255)),
    warps = f.opt(f.list(f.rec{ x = f.int(0), y = f.int(0),
                                destMap = f.str, destWarp = f.int(0) })),
    objects = f.opt(f.list(f.any)),
    signs = f.opt(f.list(f.any)),
    connections = f.opt(f.map(f.enum{ "north", "south", "east", "west" }, f.any)),
  },
  extra = function(_, value)
    if type(value.blocks) == "table" and type(value.width) == "number"
        and type(value.height) == "number"
        and #value.blocks ~= value.width * value.height then
      return ("blocks has %d entries, expected width*height = %d")
        :format(#value.blocks, value.width * value.height)
    end
  end,
  example = 'mod.content.maps:register("MY_CAVE", { tileset = "CAVERN", ... })',
}

R.tilesets = {
  semantics = "record", target = "tilesets",
  fields = {
    id = f.opt(f.str), image = f.path,
    imageWidth = f.opt(f.int(1)), imageHeight = f.opt(f.int(1)),
    tilesPerRow = f.opt(f.int(1)),
    blocks = f.list(f.any),
    walkable = f.opt(f.any), counterTiles = f.opt(f.any),
    doorTiles = f.opt(f.any), warpTiles = f.opt(f.any),
    animation = f.opt(f.str),
    trueColor = f.opt(f.bool),
  },
  extra = function(_, value)
    if type(value.blocks) == "table" then
      for i, row in ipairs(value.blocks) do
        if type(row) ~= "table" or #row ~= 16 then
          return ("blocks[%d] must be a row of 16 tile ids"):format(i)
        end
      end
    end
  end,
  example = 'mod.content.tilesets:register("MY_TILES", { image = "...", blocks = { ... } })',
}

R.encounters = {
  semantics = "record", target = "encounters",
  fields = {
    id = f.opt(f.str),
    grass = f.opt(f.rec{ rate = f.int(0, 255),
                         slots = f.list(f.rec{ level = f.int(1),
                                               species = f.id("pokemon") }) }),
    water = f.opt(f.rec{ rate = f.int(0, 255),
                         slots = f.list(f.rec{ level = f.int(1),
                                               species = f.id("pokemon") }) }),
  },
  example = 'mod.content.encounters:patch("ROUTE_1", { grass = { rate = 30 } })',
}

R.trainers = {
  semantics = "record", target = "trainers",
  fields = {
    id = f.str, name = f.str,
    index = f.opt(f.int(0, 255)),
    -- unused vanilla classes ship without a pic, so it cannot be required
    pic = f.opt(f.path),
    baseMoney = f.opt(f.int(0)),
    parties = f.list(f.list(f.rec{ level = f.int(1),
                                   species = f.id("pokemon") })),
    aiMods = f.opt(f.any),
    aiClass = f.opt(f.id("ai_classes")),
    brain = f.opt(f.fn),
    battleTheme = f.opt(f.id("music")),
  },
  example = 'mod.content.trainers:patch("OPP_BROCK", { baseMoney = 99 })',
}

R.sprites = {
  semantics = "record", target = "sprites",
  fields = {
    id = f.opt(f.str),
    image = f.path,
    frames = f.int(1),
    walker = f.opt(f.bool),
    trueColor = f.opt(f.bool),
  },
  example = 'mod.content.sprites:register("SPRITE_HERO", { image = "...", frames = 6 })',
}

R.text = {
  semantics = "record", target = "text",
  value = f.str,
  example = 'mod.content.text:override("_PalletTownText1", "HELLO!")',
}

-- the self-contained bytecode blob ChipAsm.song/sfx emit (13.1 shape 2);
-- shared by every namespace that plays a chip program
local chipProgram = f.rec{
  blob = f.str, channels = f.any, waves = f.opt(f.any),
  drums = f.opt(f.any), engine = f.opt(f.num),
}

-- value union dispatched per def shape: rom chip ref, file-backed song, or
-- an authored chip program (ChipAsm)
R.music = {
  semantics = "record", target = "audio.songs",
  value = f.union{
    f.rec{ address = f.int(0), bank = f.int(0), engine = f.opt(f.num) },
    f.rec{ file = f.path, loopFile = f.opt(f.path), seconds = f.opt(f.num),
           loopSeconds = f.opt(f.num), intro = f.opt(f.any) },
    f.rec{ program = f.any, channels = f.any, waves = f.opt(f.any),
           drums = f.opt(f.any) },
    f.rec{ chip = chipProgram },
  },
  example = 'mod.content.music:register("MOD_SONG", { file = "song.ogg" })',
}

-- whole-key replacement of Data.audio, the v1 escape hatch.  Kept working
-- forever; the granular sfx / cries / map_songs registries supersede it and
-- whole-key swaps (programFile, bankOrder) remain its one honest use.
R.audio = {
  semantics = "record", target = "audio",
  value = f.any,
  deprecated = { useInstead = "sfx / cries / map_songs / music" },
  example = 'mod.content.audio:override("mapSongs", { ... })',
}

-- compose: registrations accumulate into per-map chains instead of
-- replacing each other.  Data.map_scripts is the interim home consumed by
-- data/scripts/init.lua until the M5 dispatcher reads chain() directly.
-- rows, a handler, or false: false is the explicit suppression that wins the
-- single-winner resolution and hides every lower-precedence entry (09 4.4)
local scriptEntry = f.union{
  f.list(f.any), f.fn,
  leaf("suppress", "false", function(v) return v == false end),
}

R.map_scripts = {
  semantics = "compose", target = "map_scripts",
  value = f.rec{
    talk = f.opt(f.map(f.str, scriptEntry)),
    scripts = f.opt(f.map(f.str, scriptEntry)),
    onEnter = f.opt(f.fn), onStep = f.opt(f.fn), onInteract = f.opt(f.fn),
    onVictory = f.opt(f.fn), onBoulderMoved = f.opt(f.fn),
    -- the flute wake sequence ItemEffects/BagMenu look up by map id; the
    -- other legacy ad-hoc keys stay unknown-but-preserved
    snorlaxWake = f.opt(f.rec{
      objName = f.opt(f.str), beatFlag = f.opt(f.str), script = f.list(f.any),
    }),
    priority = f.opt(f.num),
  },
  example = 'mod.content.map_scripts:register("PALLET_TOWN", { talk = { ... } })',
}

R.screens = {
  semantics = "record", target = "screens",
  value = f.union{ f.fn, f.rec{ new = f.fn } },
  example = 'mod.content.screens:register("QuestLog", { new = function(game) ... end })',
}

-- ------- battle

-- Two id forms share one registry: "ATTACKER>DEFENDER" matchup rows and
-- bare type ids.  Neither lives at a key of Data.type_chart (the rows are
-- an ordered array), so the registry owns the whole target: reads see only
-- registrations -- the engine makes them all -- and the merge rebuilds
-- matchups and types from the op order.
R.type_chart = {
  semantics = "record", target = "type_chart",
  value = f.union{
    f.rec{ multiplier = f.int(0) },
    f.rec{ name = f.opt(f.str), category = f.enum{ "physical", "special" },
           index = f.opt(f.int(0, 255)) },
  },
  baseAt = function() return nil end,
  baseIds = function() return {} end,
  write = function(target, registry)
    local matchups, types = {}, {}
    for _, id in ipairs(registry.order) do
      local value = registry:get(id)
      if value ~= nil then
        local attacker, defender = id:match("^([^>]+)>([^>]+)$")
        if attacker then
          local row = Merge.deepCopy(value)
          row.attacker, row.defender = attacker, defender
          matchups[#matchups + 1] = row
        else
          types[id] = value
        end
      end
    end
    target.matchups, target.types = matchups, types
  end,
  example = 'mod.content.type_chart:register("BUG>PSYCHIC_TYPE", { multiplier = 20 })',
}

R.statuses = {
  semantics = "record", target = "statuses",
  fields = {
    id = f.opt(f.str), label = f.str,
    hudLabel = f.opt(f.str),
    canInflict = f.opt(f.fn), onInflict = f.opt(f.fn),
    beforeMove = f.opt(f.fn), beforeMovePriority = f.opt(f.int(0)),
    residual = f.opt(f.fn),
    catchBonus = f.opt(f.int(0, 255)), shakeBonus = f.opt(f.int(0, 255)),
    statPenalty = f.opt(f.rec{ stat = f.str, div = f.int(1) }),
    cureOnSwitch = f.opt(f.bool),
  },
  example = 'mod.content.statuses:patch("BRN", { catchBonus = 12 })',
}

-- run is optional because the "full" effects are steered from inside the
-- damage pipeline and have no standalone handler to register yet; M7 gives
-- them the effect context that makes one possible
R.move_effects = {
  semantics = "record", target = "move_effects",
  fields = {
    kind = f.enum{ "primary", "secondary", "full" },
    accuracyChecked = f.opt(f.bool),
    run = f.opt(f.fn),
  },
  example = 'mod.content.move_effects:register("DRAIN_PP_EFFECT", { kind = "primary", run = fn })',
}

R.item_effects = {
  semantics = "record", target = "item_effects",
  fields = {
    use = f.fn,
    needsTarget = f.opt(f.bool), battle = f.opt(f.bool), field = f.opt(f.bool),
  },
  example = 'mod.content.item_effects:register("MOON_FLUTE", { use = fn, field = true })',
}

-- MASTER_BALL catches unconditionally and never rolls, so randMax 0 is a
-- legal record and hpFactor is only read on the wobble path
R.balls = {
  semantics = "record", target = "balls",
  fields = {
    randMax = f.int(0, 255),
    hpFactor = f.opt(f.int(1)), wobbleFactor = f.opt(f.int(1)),
    autoCatch = f.opt(f.bool), flicker = f.opt(f.bool),
    tossAnim = f.opt(f.str), attempt = f.opt(f.fn),
  },
  example = 'mod.content.balls:override("GREAT_BALL", { randMax = 180, hpFactor = 12 })',
}

R.rulesets = {
  semantics = "record", target = "rulesets",
  fields = { name = f.str },
  example = 'mod.content.rulesets:register("no_crits", { name = "no crits", critRate = 0 })',
}

-- three record kinds share the registry: "class" is the per-trainer
-- item/switch behavior, "layer" a move-scoring pass (the vanilla three are
-- LAYER_1..LAYER_3), "brain" a full action chooser
R.ai_classes = {
  semantics = "record", target = "ai_classes",
  fields = {
    kind = f.opt(f.enum{ "class", "layer", "brain" }),
    uses = f.opt(f.int(0)), chance = f.opt(f.int(0, 256)),
    item = f.opt(f.id("items")),
    switch = f.opt(f.bool), switchChance = f.opt(f.int(0, 256)),
    switchBelow = f.opt(f.int(1)), hpBelow = f.opt(f.int(1)),
    onStatus = f.opt(f.bool),
    score = f.opt(f.fn), choose = f.opt(f.fn), brain = f.opt(f.fn),
  },
  example = 'mod.content.ai_classes:patch("OPP_BROCK", { uses = 9 })',
}

-- ids route into the target's per-kind subtables: a bare move id is a move
-- animation, "subanim:<n>" and "tilesheet:<n>" address the shared pieces
local function animRoute(id)
  local kind, index = tostring(id):match("^(%a+):(%d+)$")
  if kind == "subanim" then return "subanims", tonumber(index) end
  if kind == "tilesheet" then return "tilesheets", tonumber(index) end
  return "moveAnims", id
end

R.battle_anims = {
  semantics = "record", target = "battle_anims",
  value = f.union{
    f.rec{ seq = f.list(f.any), source = f.opt(f.str) },
    f.rec{ blocks = f.list(f.any), type = f.opt(f.str) },
    f.rec{ path = f.path, width = f.int(1), height = f.int(1),
           tiles = f.int(1), source = f.opt(f.str) },
  },
  baseAt = function(base, id)
    local sub, key = animRoute(id)
    local table_ = base[sub]
    return table_ and table_[key] or nil
  end,
  baseIds = function(base)
    local ids = {}
    for id in pairs(base.moveAnims or {}) do ids[#ids + 1] = id end
    for index in pairs(base.subanims or {}) do ids[#ids + 1] = "subanim:" .. index end
    for index in pairs(base.tilesheets or {}) do ids[#ids + 1] = "tilesheet:" .. index end
    return ids
  end,
  write = function(target, registry)
    for _, id in ipairs(registry.order) do
      local sub, key = animRoute(id)
      local into = target[sub]
      if not into then
        into = {}
        target[sub] = into
      end
      into[key] = registry:get(id)
    end
  end,
  example = 'mod.content.battle_anims:register("SHADOW_BALL", { seq = { ... } })',
}

R.transitions = {
  semantics = "record", target = "transitions",
  fields = {
    frames = f.int(1), draw = f.opt(f.fn), sound = f.opt(f.str),
    flash = f.opt(f.bool),
  },
  example = 'mod.content.transitions:register("dissolve", { frames = 30, draw = fn })',
}

-- ------- progression

R.evolution_methods = {
  semantics = "record", target = "evolution_methods",
  fields = { check = f.fn, describe = f.opt(f.fn) },
  example = 'mod.content.evolution_methods:register("FRIENDSHIP", { check = fn })',
}

R.growth_rates = {
  semantics = "record", target = "growth_rates",
  fields = { expForLevel = f.fn },
  -- a curve that does not grow makes levelForExp loop forever
  extra = function(_, value)
    if type(value.expForLevel) == "function" then
      local ok, low, high = pcall(function()
        return value.expForLevel(1), value.expForLevel(2)
      end)
      if ok and type(low) == "number" and type(high) == "number"
          and high <= low then
        return "expForLevel must increase with level"
      end
    end
  end,
  example = 'mod.content.growth_rates:register("ERRATIC", { expForLevel = fn })',
}

-- ------- audio (per-def shapes, dispatched by the consumer)

R.sfx = {
  semantics = "record", target = "audio.sfx",
  value = f.union{
    f.str,
    f.rec{ address = f.int(0), bank = f.int(0), engine = f.opt(f.num) },
    f.rec{ file = f.path },
    f.rec{ chip = chipProgram },
  },
  example = 'mod.content.sfx:register("SFX_MOD_CHIME", { file = "chime.ogg" })',
}

-- base names the species whose header a derived cry borrows, so it resolves
-- against this same registry (13.9)
R.cries = {
  semantics = "record", target = "audio.cries",
  value = f.union{
    f.rec{ header = f.any, pitch = f.int(0, 255), length = f.int(0, 255) },
    f.rec{ file = f.path },
    f.rec{ base = f.id("cries"), pitch = f.opt(f.int(0, 255)),
           length = f.opt(f.int(0, 255)) },
    f.rec{ chip = chipProgram, pitch = f.opt(f.int(0, 255)),
           length = f.opt(f.int(0, 255)) },
  },
  example = 'mod.content.cries:patch("PIKACHU", { pitch = 200 })',
}

R.map_songs = {
  semantics = "record", target = "audio.mapSongs",
  value = f.id("music"),
  example = 'mod.content.map_songs:override("PALLET_TOWN", "Music_Routes1")',
}

-- ------- presentation

-- vanilla palettes are four raw {r,g,b} triples; the named-record form is
-- the v2 shape a mod may register instead
R.palettes = {
  semantics = "record", target = "palettes.palettes",
  value = f.union{
    f.list(f.list(f.int(0, 255))),
    f.rec{ colors = f.list(f.rec{ r = f.int(0, 255), g = f.int(0, 255),
                                  b = f.int(0, 255) }) },
  },
  extra = function(_, value)
    local colors = value.colors or value
    if type(colors) == "table" and #colors ~= 4 then
      return ("needs exactly 4 colors, got %d"):format(#colors)
    end
  end,
  example = 'mod.content.palettes:override("MEWMON", { {255,255,255}, ... })',
}

-- keyed by species id, unlike the vanilla byDex array: a species past the
-- end of the dex gets an icon without punching a hole in the list
R.icons = {
  semantics = "record", target = "icons.bySpecies",
  value = f.union{ f.str, f.rec{ image = f.path, frames = f.opt(f.int(1)) } },
  example = 'mod.content.icons:register("MISSINGNO", { image = "glitch.png" })',
}

-- glyph codes are not bytes: the vanilla pages sit at $60/$80 but a
-- registered page takes a range of its own above them (a kana block at
-- $100), so neither a base nor a charmap code is capped at one byte.
-- Two id forms share the registry (14 §registry schemas): a bare id is a
-- page, "charmap:<name>" is one sequence->code row.  A page carries its own
-- charmap only as a convenience -- replacing a sheet must not force an
-- author to restate the table.
local function fontIsCharmap(id)
  return tostring(id):match("^charmap:.+$") ~= nil
end

R.font = {
  semantics = "record", target = "font",
  value = f.union{
    f.rec{ image = f.path, base = f.int(0), glyphsPerRow = f.opt(f.int(1)),
           advance = f.opt(f.int(1)),
           charmap = f.opt(f.list(f.rec{ code = f.int(0), seq = f.str })) },
    f.rec{ seq = f.str, code = f.int(0) },
  },
  extra = function(id, value)
    if fontIsCharmap(id) then
      if type(value.seq) ~= "string" or value.seq == "" then
        return "a charmap: entry needs a non-empty seq"
      end
      if type(value.code) ~= "number" then
        return "a charmap: entry needs a code"
      end
    elseif value.image == nil or value.base == nil then
      return "a font page needs an image and a base"
    end
  end,
  baseAt = function(base, id)
    if fontIsCharmap(id) then return nil end
    return base.pages and base.pages[id] or nil
  end,
  baseIds = function(base)
    local ids = {}
    for id in pairs(base.pages or {}) do ids[#ids + 1] = id end
    return ids
  end,
  write = function(target, registry)
    local pages = target.pages or {}
    target.pages = pages
    -- the extractor's rows have no id and stay put; the registry's own are
    -- rebuilt every merge so a re-merge replaces them instead of stacking
    local rows = {}
    for _, entry in ipairs(target.charmap or {}) do
      if type(entry) ~= "table" or entry.id == nil then rows[#rows + 1] = entry end
    end
    for _, id in ipairs(registry.order) do
      local value = registry:get(id)
      if fontIsCharmap(id) then
        if value ~= nil then
          rows[#rows + 1] = { id = id, seq = value.seq, code = value.code }
        end
      else
        pages[id] = value
      end
    end
    target.charmap = rows
  end,
  example = 'mod.content.font:register("charmap:hiragana_a", { seq = "\227\129\130", code = 256 })',
}

-- ------- scripting and text plumbing

-- a record is the bare handler (the v1 shape every engine verb still uses)
-- or the flagged table Commands.resolve already unpacks (09 §4.2)
R.commands = {
  semantics = "record", target = "commands",
  value = f.union{ f.fn, f.rec{ fn = f.fn, foreground = f.opt(f.bool),
                                blocking = f.opt(f.bool) } },
  example = 'mod.content.commands:register("shake_screen", function(ctx, frames) ... end)',
}

R.tokens = {
  semantics = "record", target = "tokens",
  value = f.fn,
  example = 'mod.content.tokens:register("CLOCK", function(game) return "12" end)',
}

-- ------- deep registries: id is a top-level key of the target table

-- The rules the engine used to hard-code as Kanto/Red literals.  Keys the
-- importer does not stamp are seeded with their vanilla value at data load
-- (src/core/Data.lua) so a patch always has something to fold over.
R.constants = {
  semantics = "deep", target = "constants",
  keys = {
    bagSize = f.int(1), partyMax = f.int(1),
    boxCount = f.int(1), boxSize = f.int(1),
    moveMax = f.int(1),
    dexSize = f.int(1), dexDigits = f.int(1),
    levelCap = f.int(1), coinCap = f.int(0), moneyCap = f.int(0),
    -- ordered: list position is the badge number the trainer card draws
    badges = f.list(f.rec{ id = f.id("items"), name = f.opt(f.str),
                           icon = f.opt(f.path), item = f.opt(f.id("items")) }),
    hmMoves = f.list(f.id("moves")),
    encounterBuckets = f.list(f.int(1, 256)),
  },
  example = 'mod.content.constants:patch("levelCap", 80)',
}

-- The overworld's data grab bag.  Only the keys this milestone routes are
-- typed; the rest of the 37-subtable inventory stays open until its
-- consumers move off their literals.
R.field = {
  semantics = "deep", target = "field",
  keys = {
    ledges = f.list(f.rec{
      facing = f.enum{ "up", "down", "left", "right" },
      input = f.enum{ "up", "down", "left", "right" },
      standingTile = f.int(0), ledgeTile = f.int(0),
      tileset = f.opt(f.id("tilesets")) }),
    hiddenItems = f.map(f.str, f.list(f.rec{
      x = f.int(0), y = f.int(0), item = f.id("items") })),
    badgeGates = f.map(f.str, f.rec{
      badge = f.opt(f.id("items")), text = f.opt(f.str),
      passText = f.opt(f.str), failText = f.opt(f.str),
      -- omit it and the gate gets "PASSED_<mapId>"; Route 22 keeps its
      -- pre-v2 spelling only because saves already carry that flag
      passedFlag = f.opt(f.str),
      coords = f.opt(f.list(f.rec{ x = f.int(0), y = f.int(0) })),
      guards = f.opt(f.list(f.any)) }),
    townMap = f.rec{
      background = f.opt(f.any),
      gridPixelSize = f.opt(f.int(1)),
      cursorOrder = f.opt(f.list(f.str)),
      locations = f.opt(f.map(f.str, f.rec{ x = f.int(0), y = f.int(0),
                                            name = f.opt(f.str) })),
      nest = f.opt(f.any) },
    flyOrder = f.list(f.str),
    -- the new-game and boot config a total conversion replaces
    boot = f.rec{
      startMap = f.opt(f.str), startX = f.opt(f.int(0)), startY = f.opt(f.int(0)),
      startFacing = f.opt(f.enum{ "up", "down", "left", "right" }),
      playerName = f.opt(f.str), rivalName = f.opt(f.str),
      startMoney = f.opt(f.int(0)),
      lastHeal = f.opt(f.rec{ map = f.str, x = f.int(0), y = f.int(0) }),
      namePresets = f.opt(f.rec{ player = f.opt(f.list(f.str)),
                                 rival = f.opt(f.list(f.str)) }),
      screens = f.opt(f.rec{ splash = f.opt(f.str), title = f.opt(f.str),
                             newGame = f.opt(f.str) }),
      starterScript = f.opt(f.str),
      title = f.opt(f.any) },
  },
  example = 'mod.content.field:patch("boot", { startMap = "SABLE_COVE" })',
}

-- Every key is a map label carrying the same per-TEXT-constant shape, so
-- one keyValue types them all: a mod adds a single sign binding without
-- restating the map.  label is the extractor's field, text the authored
-- one; Data:resolveText reads text and falls back to the hand-ported
-- script when only asm is set.
R.text_pointers = {
  semantics = "deep", target = "text_pointers",
  keyValue = f.map(f.str, f.rec{
    text = f.opt(f.str), label = f.opt(f.str), asm = f.opt(f.bool),
    mart = f.opt(f.list(f.id("items"))),
    nurse = f.opt(f.bool), pc = f.opt(f.bool), cableClub = f.opt(f.bool),
  }),
  example = 'mod.content.text_pointers:patch("PalletTown", { TEXT_PALLETTOWN_SIGN = { text = "_MySign" } })',
}

-- ------- persistence

-- compose, keyed by the owning mod id: the runner walks each owner's chain
-- in semver order against the versions recorded in the save
R.migrations = {
  semantics = "compose",
  value = f.rec{ since = f.str, run = f.fn },
  example = 'mod.content.migrations:register("my_mod", { since = "1.0.0", run = fn })',
}

-- ------- link play

-- id = the extra-bag mon field a mod wants to force fingerprint agreement on.
-- Only rev reaches the digest: pack/unpack are Lua, and function bytes are not
-- portably hashable, so the author bumps rev when the codec's meaning changes
-- (the affects_link mod version is the backstop when they forget).  No engine
-- content, so the registry is empty on a mod-free boot and the fingerprint's
-- link_fields section is absent on both peers.
R.link_fields = {
  semantics = "record", target = "link_fields",
  fields = {
    rev = f.union{ f.int(0), f.str },
    pack = f.opt(f.fn), unpack = f.opt(f.fn),
  },
  example = 'mod.content.link_fields:register("held_item", { rev = 1, pack = fn, unpack = fn })',
}

return Schemas
