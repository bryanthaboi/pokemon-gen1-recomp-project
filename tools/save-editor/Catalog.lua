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

function Catalog.scrapeEvents(scriptDir, headerPath, listFiles)
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
  end

  for _, path in ipairs(listFiles(scriptDir)) do
    local f = io.open(path, "r")
    if f then
      eat(f:read("*a"))
      f:close()
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
