-- Parity test,  Workstream A flavor backlog (data/scripts/flavor/*.lua +
-- gym guides in story7).  Asserts every ported text_asm talk script is
-- registered and reachable via the map-script registry, and that every
-- static text label it shows actually exists in the generated text,  so
-- the "uses text_asm; showing plain text" fallback no longer fires for
-- these NPCs.  Self-contained; run via `luajit tests/parity_flavor.lua`.
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end
local init = require("data.scripts.init")
local fails, total = 0, 0
local function check(c, m) total = total + 1; if c then print("ok   " .. m) else fails = fails + 1; print("FAIL " .. m) end end

-- (1) every ported (map, TEXT const) resolves via the registry
local ported = 0
for _, modname in ipairs({ "data.scripts.flavor_all", "data.scripts.story7" }) do
  for mapId, m in pairs(require(modname)) do
    if m.talk then
      for const in pairs(m.talk) do
        ported = ported + 1
        check(init.talkScript(mapId, const) ~= nil,
              "registry resolves " .. mapId .. "/" .. const)
      end
    end
  end
end
check(ported >= 100, "ported at least 100 flavor/guide talk scripts (got " .. ported .. ")")

-- (2) every static show_text/ask label in a row-list script exists in the
--     generated text (function-handler scripts resolve labels at runtime)
local labels, missing = 0, 0
for _, modname in ipairs({ "data.scripts.flavor_all", "data.scripts.story7" }) do
  for _, m in pairs(require(modname)) do
    if m.talk then
      for _, s in pairs(m.talk) do
        if type(s) == "table" then
          for _, row in ipairs(s) do
            if type(row) == "table" and (row[1] == "show_text" or row[1] == "ask")
               and type(row[2]) == "string" and row[2]:sub(1, 1) == "_" then
              labels = labels + 1
              if Data.text[row[2]] == nil then missing = missing + 1; print("FAIL missing text " .. row[2]) end
            end
          end
        end
      end
    end
  end
end
check(missing == 0, ("all %d row-list text labels exist in generated text"):format(labels))

print(("parity flavor: %d/%d passed"):format(total - fails, total))
if fails > 0 then error(fails .. " parity-flavor assertion(s) failed") end
