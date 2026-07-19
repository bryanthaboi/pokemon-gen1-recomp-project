-- ROM-free base dataset (21-testing-and-ci): a tiny hand-written stand-in
-- for data/generated/* so the mod loader, the modkit SDK tests and CI run
-- with no ROM present.  load() assembles a fresh Data-shaped table each
-- call -- modules are re-required so one test's merge never leaks into the
-- next.  Test-only: nothing in a shipped build ever reads this tree.

local M = {}

M.MODULES = {
  "constants", "maps", "tilesets", "text", "text_pointers",
  "trainer_headers", "font", "sprites", "pokemon", "moves", "items",
  "type_chart", "trainers", "encounters", "field", "battle_anims",
}

function M.load()
  local data = {}
  for _, name in ipairs(M.MODULES) do
    local key = "tests.fixture_data." .. name
    package.loaded[key] = nil
    data[name] = require(key)
  end
  return data
end

return M
