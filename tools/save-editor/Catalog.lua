local Catalog = {}

local function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do
    table.insert(keys, k)
  end
  table.sort(keys)
  return keys
end

function Catalog.build(data)
  return {
    species = sortedKeys(data.pokemon),
    items = sortedKeys(data.items),
    moves = sortedKeys(data.moves),
  }
end

-- extraDirs: loaded mods' roots, so MOD_-prefixed flags defined in mod
-- scripts show up beside the vanilla EVENT_ ones
function Catalog.scrapeEvents(scriptDir, headerPath, listFiles, extraDirs)
  listFiles = listFiles or function(dir)
    local out = {}
    local p = io.popen(string.format('ls "%s"/*.lua 2>/dev/null', dir))
    if p then
      for line in p:lines() do
        table.insert(out, line)
      end
      p:close()
    end
    return out
  end

  local found = {}
  local function eat(text)
    for name in text:gmatch("EVENT_[A-Z0-9_]+") do
      found[name] = true
    end
    for name in text:gmatch("MOD_[A-Z0-9_]+") do
      found[name] = true
    end
  end

  local dirs = { scriptDir }
  for _, dir in ipairs(extraDirs or {}) do
    dirs[#dirs + 1] = dir
  end
  for _, dir in ipairs(dirs) do
    for _, path in ipairs(listFiles(dir)) do
      local f = io.open(path, "r")
      if f then
        eat(f:read("*a"))
        f:close()
      end
    end
  end

  if headerPath then
    local f = io.open(headerPath, "r")
    if f then
      eat(f:read("*a"))
      f:close()
    end
  end

  return sortedKeys(found)
end

return Catalog
