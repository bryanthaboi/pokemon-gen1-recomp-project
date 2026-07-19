-- T3: the shipped example mod, loaded headlessly through the fs seam
-- (21-testing-and-ci acceptance: "loads mods/example_mew_starter under
-- plain Lua via the fs seam, asserts zero loader.errors, and asserts the
-- Mew override merged into Data.pokemon").
--
-- This is content-tier rather than SDK-tier because the mod overrides MEW
-- and refuses to load against a dataset that has no Mew -- it is a Red
-- content mod, so it is pinned against Red content.  What it proves is the
-- seam: discovery, topo-sort, entry chunk and merge all running with no
-- love.filesystem anywhere, which was impossible before Loader took an
-- injectable fs.

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local facts = require("tests.content_red.facts")

local Data = require("src.core.Data")
Data:load()

local example = facts.exampleMod

-- the mod is loaded off the real directory through the io-backed
-- filesystem: no love.filesystem, no in-memory synthesis
local run = T.sdk.loadMod(example.path, { data = Data })

T.eq(#run.errors, 0,
  "the example mod loads with zero errors (" .. tostring(run.errors[1]) .. ")")
T.check(run.mod ~= nil, "the loader discovered the example mod")
T.eq(run.mod and run.mod.manifest.id, example.id, "the manifest id is read off disk")
T.eq(run.mod and run.mod.state, "loaded", "the example mod reached the loaded state")

-- the override reached Data
T.check(Data.pokemon[example.species] ~= nil, "the overridden species is present")
T.eq(Data.pokemon[example.species].spriteFront, example.frontSprite,
  "the Mew front-sprite override merged into Data.pokemon")
T.eq(Data.pokemon[example.species].spriteBack, example.backSprite,
  "the Mew back-sprite override merged into Data.pokemon")

-- the sprite files the override points at actually exist, so the mod is
-- not merely registering a path into the void
for _, path in ipairs({ example.frontSprite, example.backSprite }) do
  local handle = io.open(path, "rb")
  T.check(handle ~= nil, "the overridden sprite exists on disk: " .. path)
  if handle then handle:close() end
end

-- an api=1 mod keeps working unchanged: the shipped example predates the
-- v2 manifest and must not need a rewrite
T.check(run.mod and run.mod.manifest.version ~= nil, "the manifest carries a version")

run.release()

T.finish("content_red_headless_loader")
