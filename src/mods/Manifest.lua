local Manifest = {}

local function array(value)
  if value == nil then return {} end
  assert(type(value) == "table", "manifest arrays must be tables")
  return value
end

function Manifest.validate(raw, path)
  assert(type(raw) == "table", "manifest must be an object")
  assert(type(raw.id) == "string" and raw.id:match("^[%w_%-]+$"),
    "manifest id must contain only letters, numbers, _ or -")
  assert(type(raw.name) == "string" and raw.name ~= "", "manifest name is required")
  assert(type(raw.version) == "string" and raw.version ~= "", "manifest version is required")
  assert(type(raw.entry) == "string" and raw.entry ~= "", "manifest entry is required")
  return {
    id = raw.id,
    name = raw.name,
    version = raw.version,
    entry = raw.entry,
    priority = tonumber(raw.priority) or 0,
    dependencies = array(raw.dependencies),
    optional_dependencies = array(raw.optional_dependencies),
    conflicts = array(raw.conflicts),
    category = raw.category or "OTHER",
    game_version = raw.game_version,
    description = raw.description or "",
    path = path,
    raw = raw,
  }
end

return Manifest
