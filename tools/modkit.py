#!/usr/bin/env python3
"""modkit: the mod-author CLI (20-developer-tooling.md, D12).

    python3 tools/modkit.py <subcommand> [args]

Subcommands:
    scaffold  <id> [--profile content|overhaul|total_conversion] [--api 2]
              [--dest DIR] [--force]
    validate  <id|path> [--strict] [--base auto|fixture|imported]
    lint      <id|path>
    pack      <mod-dir> [-o out.modpkg]
    bounce    <song-id|--all> [--seconds N] [--out DIR]
    docs      [--out DIR]

Global flags: --repo PATH, --json, --quiet.
Exit codes: 0 success, 1 validation/lint failure, 2 usage error.

validate drives the real engine loader headlessly (luajit, injected fs) so
a mod that passes here will not surface load errors in-game.  --base auto
folds over the player's imported dataset when there is one and falls back
to the ROM-free fixture in tests/fixture_data/ otherwise, which is what
keeps the tool runnable on a CI box with no ROM.  Which base ran matters to
MK103: only the imported dataset owns the real vanilla id space, so over the
fixture that rule is reported as skipped rather than guessed at.

lint is the no-ROM-content distribution gate (MK3xx); pack runs both at
--strict, so any finding -- warning included -- refuses the package.
"""

import argparse
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import zipfile
from datetime import datetime, timezone

MODKIT_VERSION = "1.0.0"

LUAJIT = os.environ.get("MODKIT_LUAJIT", "luajit")

IMAGE_EXTS = {".png"}
ASSET_EXTS = {".png", ".wav", ".bin"}
ROM_PATCH_EXTS = {".gb", ".gbc", ".ips", ".bps"}
SKIP_DIRS = {".git", ".modkit", "__pycache__", ".vscode"}

GENERATED_MODULES = [
    "constants", "maps", "tilesets", "text", "text_pointers",
    "trainer_headers", "font", "sprites", "pokemon", "moves", "items",
    "type_chart", "trainers", "encounters", "field", "battle_anims",
    "audio", "palettes", "icons",
]


# ---------------------------------------------------------------- findings

class Finding:
    def __init__(self, rule, severity, message, path=None):
        self.rule = rule
        self.severity = severity  # "error" | "warn"
        self.message = message
        self.path = path

    def as_dict(self):
        return {"rule": self.rule, "severity": self.severity,
                "message": self.message, "path": self.path}

    def line(self):
        where = f"{self.path}: " if self.path else ""
        return f"{self.rule} {self.severity.upper():5} {where}{self.message}"


def report(findings, args, summary_ok, summary_fail, notes=None):
    """notes are rules that could not run, not findings against the mod, so
    --strict never promotes them and they never change the exit code."""
    notes = notes or []
    errors = [f for f in findings if f.severity == "error"]
    warns = [f for f in findings if f.severity == "warn"]
    if getattr(args, "strict", False):
        errors, warns = errors + warns, []
    if args.json:
        print(json.dumps({"ok": not errors,
                          "findings": [f.as_dict() for f in findings],
                          "notes": notes}))
    else:
        for f in findings:
            print(f.line())
        if not args.quiet:
            for note in notes:
                print(f"modkit: {note}")
            print(summary_fail if errors else summary_ok)
    return 1 if errors else 0


# ---------------------------------------------------------------- repo/root

def find_repo(start):
    node = os.path.abspath(start)
    while True:
        if os.path.isfile(os.path.join(node, "tools", "rom_manifest.json")):
            return node
        parent = os.path.dirname(node)
        if parent == node:
            return None
        node = parent


def engine_version(repo):
    src = open(os.path.join(repo, "src", "core", "Version.lua"),
               encoding="utf-8").read()
    match = re.search(r'engine\s*=\s*"([^"]+)"', src)
    return match.group(1) if match else "1.0.0"


def known_permissions(repo):
    """The vocabulary the engine itself enforces (Manifest.PERMISSIONS), read
    from the source so a lint rule can never disagree with the loader."""
    try:
        src = open(os.path.join(repo, "src", "mods", "Manifest.lua"),
                   encoding="utf-8").read()
    except OSError:
        return {"network", "filesystem", "engine_internals"}
    block = re.search(r"Manifest\.PERMISSIONS\s*=\s*\{([^}]*)\}", src)
    names = set(re.findall(r"(\w+)\s*=\s*true", block.group(1))) \
        if block else set()
    return names or {"network", "filesystem", "engine_internals"}


def supported_requires(repo):
    """The src.* modules the mod surface points authors at; requiring one of
    these is not reaching past the API (Loader.lua SUPPORTED_REQUIRES)."""
    try:
        src = open(os.path.join(repo, "src", "mods", "Loader.lua"),
                   encoding="utf-8").read()
    except OSError:
        return {"src.mods.Semver", "src.audio.ChipAsm"}
    block = re.search(r"SUPPORTED_REQUIRES\s*=\s*\{(.*?)\}", src, re.S)
    names = set(re.findall(r'\["([^"]+)"\]', block.group(1))) \
        if block else set()
    return names or {"src.mods.Semver", "src.audio.ChipAsm"}


def resolve_mod_dir(repo, arg):
    if os.path.isdir(arg):
        return os.path.abspath(arg)
    candidate = os.path.join(repo, "mods", arg)
    if os.path.isdir(candidate):
        return candidate
    return None


def mod_files(mod_dir):
    """Sorted relative paths of everything a package would carry."""
    ignored = set()
    ignore_file = os.path.join(mod_dir, ".modkitignore")
    if os.path.isfile(ignore_file):
        for line in open(ignore_file, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#"):
                ignored.add(line)
    out = []
    for base, dirs, files in os.walk(mod_dir):
        dirs[:] = [d for d in dirs
                   if d not in SKIP_DIRS and not d.startswith(".")]
        for name in files:
            if name.startswith(".") and name != ".luarc.json":
                continue
            rel = os.path.relpath(os.path.join(base, name), mod_dir)
            rel = rel.replace(os.sep, "/")
            if rel in ignored or rel == ".modkitignore":
                continue
            out.append(rel)
    return sorted(out)


def read_manifest(mod_dir):
    path = os.path.join(mod_dir, "manifest.json")
    if not os.path.isfile(path):
        return None, Finding("MK001", "error", "manifest.json missing",
                             "manifest.json")
    try:
        manifest = json.load(open(path, encoding="utf-8"))
    except ValueError as err:
        return None, Finding("MK001", "error",
                             f"manifest.json unparseable: {err}",
                             "manifest.json")
    mod_id = manifest.get("id")
    if not isinstance(mod_id, str) or not re.fullmatch(r"[\w\-]+", mod_id):
        return None, Finding("MK001", "error",
                             "manifest id must match ^[%w_-]+$",
                             "manifest.json")
    return manifest, None


# ------------------------------------------------- permissions (MK005/MK006)

def check_permissions(repo, manifest):
    """MK005: every declared permission is from the engine's known set.  The
    loader turns this into a hard load failure for api 2 and a warning for
    api 1, so naming it here is what makes the finding readable either way."""
    findings = []
    declared = manifest.get("permissions", [])
    if declared is None:
        return findings
    if not isinstance(declared, list):
        return [Finding("MK005", "error",
                        "permissions must be an array of strings",
                        "manifest.json")]
    known = known_permissions(repo)
    for name in declared:
        if not isinstance(name, str) or name not in known:
            findings.append(Finding(
                "MK005", "error",
                f"unknown permission {name!r}; the known set is "
                + ", ".join(sorted(known)), "manifest.json"))
    return findings


def strip_lua(body):
    """Blanks comments so a commented-out example never trips a scan, keeping
    line numbers intact.  A string literal is stepped over rather than blanked
    -- the module name a require scan is after IS a string -- so a `--` inside
    a path is not read as a comment; the keyword itself is masked inside the
    literal so prose quoting a require call cannot look like one."""
    out, index, size = [], 0, len(body)
    long_open = re.compile(r"\[(=*)\[")

    def literal(text):
        return text.replace("require", " " * len("require"))

    while index < size:
        char = body[index]
        if char in "\"'":
            quote = char
            start = index
            index += 1
            while index < size:
                if body[index] == "\\" and index + 1 < size:
                    index += 2
                    continue
                index += 1
                if body[index - 1] == quote:
                    break
            out.append(literal(body[start:index]))
            continue
        comment = body.startswith("--", index)
        opener = long_open.match(body, index + 2 if comment else index)
        if comment:
            if opener:
                close = "]" + opener.group(1) + "]"
                end = body.find(close, opener.end())
                chunk = (body[index:] if end < 0
                         else body[index:end + len(close)])
            else:
                end = body.find("\n", index)
                chunk = body[index:] if end < 0 else body[index:end]
            out.append("\n" * chunk.count("\n"))
            index += len(chunk)
            continue
        if opener and opener.start() == index:
            close = "]" + opener.group(1) + "]"
            end = body.find(close, opener.end())
            chunk = body[index:] if end < 0 else body[index:end + len(close)]
            out.append(literal(chunk))
            index += len(chunk)
            continue
        out.append(char)
        index += 1
    return "".join(out)


REQUIRE_CALL = re.compile(r"""\brequire\s*\(?\s*["']([^"']+)["']""")


def check_requires(repo, mod_dir, manifest):
    """MK006: a private require of an engine module the mod has no permission
    for.  Static rather than runtime because the loader's dev tripwire only
    sees the requires that actually execute during the entry chunk, and a
    require sitting inside a function body is the same reach past the API."""
    declared = manifest.get("permissions") or []
    granted = set(name for name in declared if isinstance(name, str)) \
        if isinstance(declared, list) else set()
    supported = supported_requires(repo)
    findings = []
    for rel in mod_files(mod_dir):
        if os.path.splitext(rel)[1].lower() != ".lua":
            continue
        body = strip_lua(open(os.path.join(mod_dir, rel), encoding="utf-8",
                              errors="replace").read())
        for match in REQUIRE_CALL.finditer(body):
            name = match.group(1).replace("/", ".")
            # the link modules are the one place a mod reaches the wire, so
            # network governs them; everything else under src. is internals
            if name.startswith("src.link."):
                needed = "network"
            elif name.startswith("src.") and name not in supported:
                needed = "engine_internals"
            else:
                continue
            if needed in granted:
                continue
            line = body.count("\n", 0, match.start()) + 1
            findings.append(Finding(
                "MK006", "warn",
                f"private require of {name} without the {needed} permission; "
                f"declare it in manifest.json or use the mod API instead",
                f"{rel}:{line}"))
    return findings


# ---------------------------------------------------------------- scaffold

MANIFEST_TEMPLATE = """{
  "id": "{{id}}",
  "name": "{{name}}",
  "version": "0.1.0",
  "api": 2,
  "entry": "main.lua",
  "profile": "{{profile}}",
  "game_version": ">={{game_version}} <{{next_major}}.0.0",
  "category": "GAMEPLAY",
  "priority": 100,
  "dependencies": [],
  "optional_dependencies": [],
  "conflicts": [],
  "description": "TODO: one line about {{id}}"{{extra}}
}
"""

MAIN_CONTENT = """-- {{id}}: a content-profile mod (api 2).
-- The 10-minute loop: edit, save, F5 in a POKEPORT_DEV=1 game, repeat.
return function(mod)
  -- patch, not override: every field you do not name keeps its base value
  -- (learnset, sprites, evolutions all survive this speed change)
  mod.content.pokemon:patch("MEW", { baseStats = { speed = 110 } })

  -- mod.events:on("pokemon.caught", function(e)
  --   mod.log:info("caught %s at L%d", e.species, e.level)
  -- end)
end
"""

MAIN_OVERHAUL = """-- {{id}}: an overhaul-profile mod (api 2).
return function(mod)
  mod.options:define({
    { key = "difficulty", label = "DIFFICULTY", kind = "choice",
      choices = { "normal", "hard" }, default = "normal" },
  })

  -- register into content registries here; patch beats override for
  -- anything you want to coexist with other mods
  -- mod.content.moves:patch("BLIZZARD", { accuracy = 70 })

  -- mod.hooks:wrap("battle.damage", function(next, ctx, damage)
  --   return next(ctx, damage)
  -- end)
  -- mod.hooks:wrap("catch.rate", function(next, ctx, rate)
  --   return next(ctx, rate)
  -- end)
end
"""

MAIN_TC = """-- {{id}}: a total-conversion-profile mod (api 2).
return function(mod)
  -- the new game itself: spawn, names, money (field.boot, D11)
  -- mod.content.field:patch("boot", {
  --   startMap = "MY_TOWN", startX = 5, startY = 6,
  --   playerName = "HERO", rivalName = "FOE", startMoney = 5000,
  -- })

  -- own the boot screens (Title/Intro) through the screens registry
  -- mod.content.screens:register("MyTitle", { new = function(game) ... end })
end
"""

TRANSFORMS_TEMPLATE = """-- Asset transforms ({{id}}): derive art from the PLAYER'S own imported
-- cache at install time.  Ship the recipe, never ROM-derived pixels --
-- this file is the only sanctioned way to base art on vanilla assets.
return function(ctx)
  -- local img = ctx.readImage("battle/front/mew.png")
  -- ctx.recolor(img, { [2] = 3, [3] = 2 })
  -- ctx.writeImage(img, "battle/front/mew.png")
end
"""

LUARC_TEMPLATE = """{
  "runtime.version": "LuaJIT",
  "diagnostics.globals": ["love"]
}
"""

README_TEMPLATE = """# {{name}}

A `{{profile}}` mod for the LOVE2D Pokemon Red engine (mod api 2).

## Layout

- `manifest.json` - identity, version range, load order
- `main.lua` - the entry chunk; receives the `mod` object
{{layout_extra}}
## Loop

1. `POKEPORT_DEV=1 love .` once, leave it running
2. edit, press F5 to hot-reload, backtick for the dev console
3. `python3 tools/modkit.py validate {{id}}` before sharing
4. `python3 tools/modkit.py pack mods/{{id}}` to ship
"""


def cmd_scaffold(args, repo):
    profile = args.profile
    dest_root = args.dest or os.path.join(repo, "mods")
    dest = os.path.join(dest_root, args.id)
    if not re.fullmatch(r"[\w\-]+", args.id):
        print(f"modkit: bad id {args.id!r} (letters, numbers, _ or -)")
        return 2
    if os.path.exists(dest) and not args.force:
        print(f"modkit: {dest} exists (use --force to overwrite)")
        return 2
    engine = engine_version(repo)
    next_major = int(engine.split(".")[0]) + 1
    name = args.id.replace("_", " ").replace("-", " ").title()

    extra = ""
    if profile == "total_conversion":
        extra = ',\n  "assets_transforms": "transforms.lua"'
    subst = {
        "{{id}}": args.id, "{{name}}": name, "{{profile}}": profile,
        "{{game_version}}": engine, "{{next_major}}": str(next_major),
        "{{extra}}": extra,
    }

    def emit(rel, template):
        path = os.path.join(dest, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        body = template
        for key, value in subst.items():
            body = body.replace(key, value)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(body)

    main = {"content": MAIN_CONTENT, "overhaul": MAIN_OVERHAUL,
            "total_conversion": MAIN_TC}[profile]
    layout_extra = ""
    if profile == "total_conversion":
        layout_extra = "- `transforms.lua` - asset transforms over the player's cache\n"
    subst["{{layout_extra}}"] = layout_extra

    emit("manifest.json", MANIFEST_TEMPLATE)
    emit("main.lua", main)
    emit("README.md", README_TEMPLATE)
    emit(".luarc.json", LUARC_TEMPLATE)
    os.makedirs(os.path.join(dest, "assets"), exist_ok=True)
    open(os.path.join(dest, "assets", ".gitkeep"), "w").close()
    if profile == "total_conversion":
        emit("transforms.lua", TRANSFORMS_TEMPLATE)

    if not args.quiet:
        print(f"created {dest} ({profile} profile, api 2)")
        print(f"next: python3 tools/modkit.py validate {args.id}")
    return 0


# ---------------------------------------------------------------- validate

DRIVER_TEMPLATE = """-- generated by tools/modkit.py; drives the real loader headlessly
package.path = "./?.lua;./?/init.lua;" .. package.path
local data = %s
local FILES = %s
local overlay = {}
local function readDisk(path)
  local disk = FILES[path]
  if not disk then return nil end
  local handle = io.open(disk, "rb")
  if not handle then return nil end
  local body = handle:read("*a")
  handle:close()
  return body
end
local fs = {
  read = function(path) return overlay[path] or readDisk(path) end,
  write = function(path, body) overlay[path] = body return true end,
  createDirectory = function() return true end,
  getInfo = function(path)
    if overlay[path] or FILES[path] then return { type = "file" } end
    local prefix = path .. "/"
    for key in pairs(FILES) do
      if key:sub(1, #prefix) == prefix then return { type = "directory" } end
    end
    return nil
  end,
  load = function(path)
    local body = overlay[path] or readDisk(path)
    if not body then return nil, "no file: " .. path end
    return loadstring(body, path)
  end,
  getDirectoryItems = function(path)
    local seen, items = {}, {}
    local prefix = path .. "/"
    for key in pairs(FILES) do
      if key:sub(1, #prefix) == prefix then
        local child = key:sub(#prefix + 1):match("^[^/]+")
        if child and not seen[child] then
          seen[child] = true
          items[#items + 1] = child
        end
      end
    end
    table.sort(items)
    return items
  end,
}
local Loader = require("src.mods.Loader")
local Schemas = require("src.mods.Schemas")
-- MK103 needs the id space as it stood BEFORE the merge: a patch against a
-- missing id still folds to a value and lands in the target, so the merged
-- view cannot tell an orphan from a real record
local function resolvePath(root, path)
  local node = root
  for key in path:gmatch("[^%%.]+") do
    if type(node) ~= "table" then return nil end
    node = node[key]
  end
  return node
end
local baseIds = {}
for name, spec in pairs(Schemas.REGISTRIES) do
  local set = {}
  local target = spec.target and resolvePath(data, spec.target)
  if type(target) == "table" then
    if spec.baseIds then
      for _, id in ipairs(spec.baseIds(target)) do set[id] = true end
    else
      for id in pairs(target) do set[id] = true end
    end
  end
  baseIds[name] = set
end
local loader = Loader.new({ fs = fs })
local ok, err = pcall(loader.load, loader, data)
-- one tab-separated record per finding; each field is scrubbed on its own so
-- the separators survive (a field that carried its own tab used to collapse
-- the whole row into one column)
local function row(kind, ...)
  local parts = { kind }
  for index = 1, select("#", ...) do
    local field = tostring((select(index, ...)))
    parts[#parts + 1] = (field:gsub("[\\t\\r\\n]", " "))
  end
  print(table.concat(parts, "\\t"))
end
if not ok then row("ERR", err) end
-- record registries only: deep ones treat patch as register (a new key is
-- the point) and compose ones reject patch outright
for name, registry in pairs(loader.content) do
  if registry.spec.semantics == "record" then
    local known = baseIds[name] or {}
    for id, list in pairs(registry.ops) do
      local defined, patcher = known[id], nil
      for _, entry in ipairs(list) do
        if entry.op == "register" or entry.op == "override" then
          defined = true
        elseif entry.op == "patch" and entry.owner ~= Schemas.ENGINE then
          patcher = patcher or entry.owner
        end
      end
      if patcher and not defined then
        row("ORPHAN", name, id, patcher)
      end
    end
  end
end
local Logger = require("src.core.Logger")
for _, line in ipairs(Logger.history or {}) do
  if line:find("ignored:", 1, true) then
    row("IGN", line)
  elseif line:find("^%%[warn%%]") then
    row("WARN", line)
  end
end
local status = loader:status()
for _, mod in ipairs(status.available) do
  row("MOD", mod.id, mod.version, mod.state, mod.error or "")
end
for _, message in ipairs(status.errors) do
  row("ERR", message)
end
"""


def classify_error(message, fallback="MK100"):
    msg = message.lower()
    # a reference stranded by a tombstone is its own rule; the generic
    # dangling-ref test below would otherwise swallow it as MK102
    if "unresolved reference to removed" in msg:
        return "MK104"
    if "unresolved reference" in msg:
        return "MK102"
    if "unknown permission" in msg:
        return "MK005"
    if ("unknown field" in msg or "missing required field" in msg
            or "expected" in msg):
        return "MK101"
    if "game version" in msg:
        return "MK002"
    if ("dependency" in msg or "circular" in msg):
        return "MK003"
    if "conflicts with" in msg:
        return "MK004"
    if "map_scripts" in msg:
        return "MK201"
    return fallback


FIXTURE_BASE = 'require("tests.fixture_data").load()'
IMPORTED_BASE = ('(function() local D = require("src.core.Data") '
                 'D:load() return D end)()')


def resolve_base(repo, choice):
    """--base auto prefers the player's imported dataset and falls back to the
    ROM-free fixture.  Which one ran matters to MK103: the fixture is a
    three-species stand-in, so a missing id there proves nothing and the rule
    is skipped instead of reported."""
    if choice != "auto":
        return choice
    imported = os.path.join(repo, "data", "generated", "pokemon.lua")
    return "imported" if os.path.isfile(imported) else "fixture"


def run_loader(repo, mod_dir, findings, base="fixture", notes=None):
    """Drive the engine loader headlessly with the mod mounted; the base
    dataset is the ROM-free fixture, or the imported cache with
    --base imported (for mods that reference vanilla Red content).

    Rules that only the imported dataset can decide are skipped rather than
    downgraded when the fixture stands in, and each one names itself in
    notes so a skip is visible instead of silent."""
    mount = "mods/" + os.path.basename(mod_dir)
    files = {}
    for rel in mod_files(mod_dir):
        files[f"{mount}/{rel}"] = os.path.join(mod_dir, rel)
    entries = "".join(
        "  [%s] = %s,\n" % (lua_quote(k), lua_quote(v))
        for k, v in sorted(files.items()))
    base = resolve_base(repo, base)
    source = IMPORTED_BASE if base == "imported" else FIXTURE_BASE
    driver = DRIVER_TEMPLATE % (source, "{\n" + entries + "}")
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False,
                                     encoding="utf-8") as handle:
        handle.write(driver)
        driver_path = handle.name
    try:
        proc = subprocess.run([LUAJIT, driver_path], cwd=repo,
                              capture_output=True, text=True, timeout=120)
    except FileNotFoundError:
        findings.append(Finding("MK100", "error",
                                f"cannot run {LUAJIT} (install luajit or "
                                "set MODKIT_LUAJIT)"))
        return
    finally:
        os.unlink(driver_path)
    if proc.returncode != 0:
        findings.append(Finding("MK100", "error",
                                "loader driver crashed: "
                                + (proc.stderr or proc.stdout).strip()[-400:]))
        return
    # a failed mod reports the same message twice -- once in the error feed and
    # once as its own state -- so the same rule/text pair is emitted once
    seen = set()
    skipped = set()

    def add(finding):
        key = (finding.rule, finding.severity, finding.message)
        if key in seen:
            return
        seen.add(key)
        findings.append(finding)

    for line in proc.stdout.splitlines():
        parts = line.split("\t")
        kind = parts[0]
        if kind == "ERR" and len(parts) > 1:
            message = parts[1]
            # check_permissions already named this one against manifest.json,
            # with the known set spelled out; the loader's echo adds nothing
            if "unknown permission" in message:
                continue
            add(Finding(classify_error(message), "error", message))
        elif kind == "IGN" and len(parts) > 1:
            if "unknown permission" in parts[1]:
                continue
            add(Finding(classify_error(parts[1], "MK001"), "error", parts[1]))
        elif kind == "ORPHAN" and len(parts) >= 4:
            registry, target, owner = parts[1], parts[2], parts[3]
            # only the imported dataset owns the real vanilla id space.  The
            # fixture stands in for three species, so "not in base data" there
            # is a fact about the fixture, not about the mod -- MK103 has no
            # evidence either way and does not get to speak.  Emitting it as a
            # warning instead would still refuse the package, because pack and
            # --strict promote every warning to fatal.
            if base != "imported":
                skipped.add("MK103")
                continue
            add(Finding(
                "MK103", "error",
                f"{owner}: patch target {target!r} exists in neither "
                f"{registry} base data nor a dependency's registrations; "
                f"check the id spelling or depend on the mod that "
                f"registers it"))
        elif kind == "WARN" and len(parts) > 1:
            message = parts[1]
            if "unresolved reference" in message:
                # api 1 keeps cross-ref breakage at warning level; the rule id
                # still has to distinguish a tombstone from a plain typo
                add(Finding(classify_error(message), "warn", message))
            elif "did you mean" in message or "schema" in message:
                add(Finding("MK101", "warn", message))
        elif kind == "MOD" and len(parts) >= 4:
            mod_id, _version, state, error = (parts[1], parts[2], parts[3],
                                              "\t".join(parts[4:]))
            if state not in ("loaded", "disabled") and error:
                add(Finding(classify_error(error), "error",
                            f"{mod_id}: {error}"))
    if skipped and notes is not None:
        notes.append(
            "%s not checked: the ROM-free fixture base only stands in for "
            "vanilla content, so it cannot tell a typo from a real id -- "
            "re-run with --base imported to check %s"
            % (", ".join(sorted(skipped)),
               "them" if len(skipped) > 1 else "it"))


def lua_quote(text):
    return '"' + (text.replace("\\", "\\\\").replace('"', '\\"')) + '"'


def cmd_validate(args, repo):
    mod_dir = resolve_mod_dir(repo, args.mod)
    if not mod_dir:
        print(f"modkit: no mod at {args.mod!r}")
        return 2
    findings = []
    notes = []
    manifest, problem = read_manifest(mod_dir)
    if problem:
        findings.append(problem)
    else:
        findings.extend(check_permissions(repo, manifest))
        run_loader(repo, mod_dir, findings, args.base, notes)
        findings.extend(check_requires(repo, mod_dir, manifest))
        findings.extend(lint_dir(repo, mod_dir, manifest))
    name = manifest.get("id") if manifest else os.path.basename(mod_dir)
    return report(findings, args, f"ok {name} valid", f"FAIL {name} invalid",
                  notes)


# ---------------------------------------------------------------- lint

def ahash(image):
    """Ink-mask hash over the 8x8 downscale: background (the lightest GB
    shade) vs ink.  Swapping the three ink shades -- the classic recolor --
    leaves the mask intact, which is exactly what MK302 wants to catch."""
    from PIL import Image
    small = image.convert("L").resize((8, 8), Image.LANCZOS)
    raw = (small.get_flattened_data() if hasattr(small, "get_flattened_data")
           else small.getdata())
    return sum((1 << i) for i, p in enumerate(raw) if p <= 200)


def hamming(a, b):
    return bin(a ^ b).count("1")


class CacheIndex:
    """Hashes of the player's ROM-derived cache (assets/generated)."""

    def __init__(self, repo):
        self.sha = {}
        self.perceptual = []
        root = os.path.join(repo, "assets", "generated")
        if not os.path.isdir(root):
            return
        try:
            from PIL import Image
        except ImportError:
            Image = None
        for base, _dirs, files in os.walk(root):
            for name in files:
                path = os.path.join(base, name)
                rel = os.path.relpath(path, repo).replace(os.sep, "/")
                body = open(path, "rb").read()
                self.sha[hashlib.sha256(body).hexdigest()] = rel
                if Image and os.path.splitext(name)[1].lower() in IMAGE_EXTS:
                    try:
                        with Image.open(io.BytesIO(body)) as img:
                            self.perceptual.append(
                                (rel, img.size, ahash(img)))
                    except Exception:
                        pass


def lint_dir(repo, mod_dir, manifest):
    """MK3xx: the no-ROM-content gate (22-distribution-and-packaging.md)."""
    findings = []
    manifest = manifest or {}
    transforms_rel = manifest.get("assets_transforms")
    has_transforms = bool(transforms_rel)
    cache = CacheIndex(repo)
    try:
        from PIL import Image
    except ImportError:
        Image = None

    for rel in mod_files(mod_dir):
        path = os.path.join(mod_dir, rel)
        ext = os.path.splitext(rel)[1].lower()
        # MK301: nothing may live in (or point into) the generated trees
        if rel.startswith(("data/generated/", "assets/generated/")):
            findings.append(Finding(
                "MK301", "error",
                "path shadows the player's ROM-derived cache", rel))
            continue
        if ext in (".lua", ".json") and rel != transforms_rel:
            body = open(path, encoding="utf-8", errors="replace").read()
            if "assets/generated/" in body or "data/generated/" in body:
                findings.append(Finding(
                    "MK301", "error",
                    "references the ROM-derived cache; ship your own asset "
                    "under assets/ or derive it via assets_transforms", rel))
        # MK303: ROM images and ROM-hack patch formats never ship
        if ext in ROM_PATCH_EXTS:
            findings.append(Finding(
                "MK303", "error", "ROM/ROM-hack patch file", rel))
            continue
        # MK304: raw chip-audio banks are ROM-derived
        base = os.path.basename(rel)
        if base == "programs.bin":
            findings.append(Finding(
                "MK304", "error",
                "raw audio bank blob (author chip programs instead)", rel))
            continue
        if ext == ".bin":
            size = os.path.getsize(path)
            if size >= 0x4000 and size % 0x4000 == 0:
                findings.append(Finding(
                    "MK304", "error",
                    "bank-sized binary blob looks ROM-derived", rel))
                continue
        # MK302: byte-identity and perceptual near-duplicates vs the cache
        if ext in ASSET_EXTS:
            body = open(path, "rb").read()
            digest = hashlib.sha256(body).hexdigest()
            twin = cache.sha.get(digest)
            if twin:
                findings.append(Finding(
                    "MK302", "error",
                    f"byte-identical to ROM-derived {twin}", rel))
                continue
            if Image and ext in IMAGE_EXTS and cache.perceptual:
                try:
                    with Image.open(io.BytesIO(body)) as img:
                        size, digest = img.size, ahash(img)
                except Exception:
                    continue
                for twin_rel, twin_size, twin_hash in cache.perceptual:
                    if size == twin_size and hamming(digest, twin_hash) <= 4:
                        severity = "warn" if has_transforms else "error"
                        remedy = ("allowed (ships assets_transforms)"
                                  if has_transforms else
                                  "ship it as an assets_transforms step "
                                  "instead of a file")
                        findings.append(Finding(
                            "MK302", severity,
                            f"near-duplicate of ROM-derived {twin_rel} -- "
                            f"{remedy}", rel))
                        break
        # MK305: bulk dump of an imported data table
        if (ext == ".lua"
                and os.path.splitext(base)[0] in GENERATED_MODULES
                and rel != transforms_rel and rel != "main.lua"):
            finding = check_data_dump(repo, path, base, rel)
            if finding:
                findings.append(finding)
    return findings


DUMP_DRIVER = """local function keysOf(path)
  local handle = io.open(path, "rb")
  if not handle then return nil end
  local body = handle:read("*a")
  handle:close()
  local chunk = loadstring(body, path)
  if not chunk then return nil end
  setfenv(chunk, {})
  local ok, result = pcall(chunk)
  if not ok or type(result) ~= "table" then return nil end
  local keys = {}
  for key in pairs(result) do
    if type(key) == "string" then keys[#keys + 1] = key end
  end
  return keys
end
local shipped = keysOf(%s)
local vanilla = keysOf(%s)
if not shipped or not vanilla or #vanilla < 10 then return print("SKIP") end
local set = {}
for _, key in ipairs(shipped) do set[key] = true end
local hits = 0
for _, key in ipairs(vanilla) do
  if set[key] then hits = hits + 1 end
end
print(hits >= #vanilla * 0.8 and "DUMP" or "OK")
"""


def check_data_dump(repo, path, base, rel):
    vanilla = os.path.join(repo, "data", "generated", base)
    if not os.path.isfile(vanilla):
        # no imported dataset to diff against; say so rather than pass
        # silently, so a green run never implies this rule actually ran
        return Finding("MK305", "warn",
                       f"dump check skipped: no imported data/generated/{base} "
                       "to diff against", rel)
    driver = DUMP_DRIVER % (lua_quote(path), lua_quote(vanilla))
    try:
        proc = subprocess.run([LUAJIT, "-e", driver], cwd=repo,
                              capture_output=True, text=True, timeout=60)
    except FileNotFoundError:
        # the gate must fail closed: a missing interpreter is a broken
        # environment, not a clean mod
        return Finding("MK100", "error",
                       f"cannot run {LUAJIT} for the dump check (install "
                       "luajit or set MODKIT_LUAJIT)", rel)
    if proc.stdout.strip() == "DUMP":
        return Finding("MK305", "error",
                       "bulk dump of an imported data table; register "
                       "individual records through the mod API", rel)
    return None


def cmd_lint(args, repo):
    mod_dir = resolve_mod_dir(repo, args.mod)
    if not mod_dir:
        print(f"modkit: no mod at {args.mod!r}")
        return 2
    manifest, problem = read_manifest(mod_dir)
    findings = [problem] if problem else []
    findings.extend(lint_dir(repo, mod_dir, manifest))
    name = os.path.basename(mod_dir)
    return report(findings, args, f"ok {name}: no ROM-derived content",
                  f"FAIL {name}: ROM-content gate")


# ---------------------------------------------------------------- pack

def cmd_pack(args, repo):
    mod_dir = resolve_mod_dir(repo, args.mod)
    if not mod_dir:
        print(f"modkit: no mod at {args.mod!r}")
        return 2
    manifest, problem = read_manifest(mod_dir)
    if problem:
        print(problem.line())
        return 1
    findings = list(check_permissions(repo, manifest))
    notes = []
    run_loader(repo, mod_dir, findings, args.base, notes)
    findings.extend(check_requires(repo, mod_dir, manifest))
    findings.extend(lint_dir(repo, mod_dir, manifest))
    # pack runs validate --strict (20-developer-tooling.md 5), so a warning
    # blocks distribution too: MK006 and the MK3xx gate are documented as
    # unbypassable by the packaging path, which only holds if warnings bite
    # here even though they are advisory under a bare validate.  Notes are not
    # findings -- a rule the fixture base could not run has nothing to say
    # about the mod, so packing ROM-free stays possible (M13 criterion 4)
    for f in findings:
        print(f.line())
    if not args.quiet:
        for note in notes:
            print(f"modkit: {note}")
    if findings:
        if not args.quiet:
            print("modkit: pack refused (pack runs validate --strict, so the "
                  "warnings above are fatal too)")
        return 1

    mod_id = manifest["id"]
    version = manifest.get("version", "0.0.0")
    out = args.output or f"{mod_id}-{version}.modpkg"
    files = mod_files(mod_dir)
    records = []
    for rel in files:
        body = open(os.path.join(mod_dir, rel), "rb").read()
        records.append({"path": rel, "bytes": len(body),
                        "sha256": hashlib.sha256(body).hexdigest()})
    pack_meta = {
        "modkit": MODKIT_VERSION,
        "packed_at": datetime.now(timezone.utc)
        .strftime("%Y-%m-%dT%H:%M:%SZ"),
        "id": mod_id,
        "version": version,
        "api": manifest.get("api", 1),
        "engine_range": manifest.get("game_version", ""),
        "files": records,
        "lint": {"no_rom_content": "pass", "schema": "pass",
                 "cross_refs": "pass"},
    }
    # normalized entry order + a fixed timestamp = reproducible archives
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as archive:
        for rel in files:
            info = zipfile.ZipInfo(rel, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info,
                             open(os.path.join(mod_dir, rel), "rb").read())
        info = zipfile.ZipInfo(".modkit/pack.json",
                               date_time=(1980, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        archive.writestr(info, json.dumps(pack_meta, indent=2))
    if not args.quiet:
        print(f"wrote {out} (reproducible, {len(files)} files "
              "+ .modkit/pack.json)")
    return 0


# ---------------------------------------------------------------- bounce

BOUNCE_DRIVER = """-- generated by tools/modkit.py bounce
package.path = "./?.lua;./?/init.lua;" .. package.path
love = require("tests.love_stub")
-- the render seam reads programs.bin through love.filesystem; back it
-- with the real disk for this offline run
love.filesystem.read = function(path)
  local handle = io.open(path, "rb")
  if not handle then return nil, "no file: " .. path end
  local body = handle:read("*a")
  handle:close()
  return body
end
love.filesystem.getInfo = function(path)
  local handle = io.open(path, "rb")
  if handle then handle:close() return { type = "file" } end
  return nil
end
local Data = require("src.core.Data")
local ok, err = pcall(Data.load, Data)
if not ok then
  io.stderr:write("bounce needs an imported dataset: " .. tostring(err) .. "\\n")
  os.exit(3)
end
local ChipAudio = require("src.core.ChipAudio")
local songs = Data.audio and Data.audio.songs or {}
local WANTED = %s
local SECONDS = %d
local OUT = %s
local function isChip(def)
  return type(def) == "table"
    and (def.chip ~= nil or (def.address and def.bank) or def.program)
end
local function writeWav(path, sd)
  local samples = sd:getSampleCount()
  local channels = sd:getChannelCount()
  local rate = sd:getSampleRate()
  local dataBytes = samples * channels * 2
  local function u32(n)
    return string.char(n %% 256, math.floor(n / 256) %% 256,
      math.floor(n / 65536) %% 256, math.floor(n / 16777216) %% 256)
  end
  local function u16(n)
    return string.char(n %% 256, math.floor(n / 256) %% 256)
  end
  local handle = assert(io.open(path, "wb"))
  handle:write("RIFF", u32(36 + dataBytes), "WAVE")
  handle:write("fmt ", u32(16), u16(1), u16(channels), u32(rate),
    u32(rate * channels * 2), u16(channels * 2), u16(16))
  handle:write("data", u32(dataBytes))
  local chunk = {}
  for index = 0, samples - 1 do
    for channel = 1, channels do
      local value = sd:getSample(index, channel)
      local int = math.floor(value * 32767 + 0.5)
      if int < -32768 then int = -32768 end
      if int > 32767 then int = 32767 end
      if int < 0 then int = int + 65536 end
      chunk[#chunk + 1] = u16(int)
    end
    if #chunk >= 8192 then
      handle:write(table.concat(chunk))
      chunk = {}
    end
  end
  handle:write(table.concat(chunk))
  handle:close()
end
local ids = {}
if WANTED then
  ids[1] = WANTED
else
  for id in pairs(songs) do ids[#ids + 1] = id end
  table.sort(ids)
end
local rendered, skipped = 0, 0
for _, id in ipairs(ids) do
  local def = songs[id]
  if not def then
    io.stderr:write("no such song: " .. id .. "\\n")
    os.exit(1)
  end
  if isChip(def) then
    local okRender, sd = pcall(ChipAudio._renderMusicForTest, Data, def, SECONDS)
    if okRender and sd then
      writeWav(OUT .. "/" .. id .. ".wav", sd)
      print("wrote " .. OUT .. "/" .. id .. ".wav")
      rendered = rendered + 1
    else
      io.stderr:write("render failed for " .. id .. ": " .. tostring(sd) .. "\\n")
    end
  else
    skipped = skipped + 1
  end
end
print(("bounced %%d songs (%%d file-based skipped)"):format(rendered, skipped))
"""


def cmd_bounce(args, repo):
    out_dir = args.out or os.path.join(repo, "bounce")
    os.makedirs(out_dir, exist_ok=True)
    wanted = "nil" if args.all else lua_quote(args.song)
    driver = BOUNCE_DRIVER % (wanted, args.seconds, lua_quote(out_dir))
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False,
                                     encoding="utf-8") as handle:
        handle.write(driver)
        driver_path = handle.name
    try:
        proc = subprocess.run([LUAJIT, driver_path], cwd=repo)
    finally:
        os.unlink(driver_path)
    return 0 if proc.returncode == 0 else 1


# ---------------------------------------------------------------- docs

def cmd_docs(args, repo):
    """Regenerates the registry reference by driving the Schemas-backed
    generator, so the docs cannot drift from the engine."""
    proc = subprocess.run(
        [LUAJIT, os.path.join("tools", "gen_registry_docs.lua")], cwd=repo)
    if proc.returncode != 0:
        return 1
    generated = os.path.join(repo, "docs", "modding", "reference",
                             "registries.md")
    if args.out:
        os.makedirs(args.out, exist_ok=True)
        target = os.path.join(args.out, "registries.md")
        with open(generated, encoding="utf-8") as src_handle, \
                open(target, "w", encoding="utf-8") as dst_handle:
            dst_handle.write(src_handle.read())
        if not args.quiet:
            print(f"copied to {target}")
    return 0


# ---------------------------------------------------------------- main

def main(argv):
    # global flags ride a parent parser so they work on either side of the
    # subcommand (modkit --json validate x / modkit validate x --json);
    # SUPPRESS keeps the subparser pass from clobbering a value the main
    # parser already set (set_defaults would write the fallback back onto
    # the shared actions and re-clobber, so absentees are filled post-parse)
    shared = argparse.ArgumentParser(add_help=False)
    shared.add_argument("--repo", default=argparse.SUPPRESS,
                        help="repo root override")
    shared.add_argument("--json", action="store_true",
                        default=argparse.SUPPRESS)
    shared.add_argument("--quiet", action="store_true",
                        default=argparse.SUPPRESS)

    parser = argparse.ArgumentParser(prog="modkit", parents=[shared])
    sub = parser.add_subparsers(dest="command")

    p = sub.add_parser("scaffold", parents=[shared])
    p.add_argument("id")
    p.add_argument("--profile", default="content",
                   choices=["content", "overhaul", "total_conversion"])
    p.add_argument("--api", type=int, default=2)
    p.add_argument("--dest")
    p.add_argument("--force", action="store_true")

    p = sub.add_parser("validate", parents=[shared])
    p.add_argument("mod")
    p.add_argument("--strict", action="store_true")
    p.add_argument("--base", default="auto",
                   choices=["auto", "fixture", "imported"])

    p = sub.add_parser("lint", parents=[shared])
    p.add_argument("mod")

    p = sub.add_parser("pack", parents=[shared])
    p.add_argument("mod")
    p.add_argument("-o", "--output")
    p.add_argument("--base", default="auto",
                   choices=["auto", "fixture", "imported"])

    p = sub.add_parser("bounce", parents=[shared])
    p.add_argument("song", nargs="?")
    p.add_argument("--all", action="store_true")
    p.add_argument("--seconds", type=int, default=10)
    p.add_argument("--out")

    p = sub.add_parser("docs", parents=[shared])
    p.add_argument("--out")

    args = parser.parse_args(argv)
    for dest, fallback in (("repo", None), ("json", False),
                           ("quiet", False)):
        if not hasattr(args, dest):
            setattr(args, dest, fallback)
    if not args.command:
        parser.print_help()
        return 2
    if args.command == "bounce" and not (args.song or args.all):
        print("modkit: bounce needs a song id or --all")
        return 2

    repo = args.repo or find_repo(os.getcwd()) or find_repo(
        os.path.dirname(os.path.abspath(__file__)))
    if not repo:
        print("modkit: cannot find the repo root "
              "(looked for tools/rom_manifest.json)")
        return 2
    repo = os.path.abspath(repo)

    handler = {
        "scaffold": cmd_scaffold,
        "validate": cmd_validate,
        "lint": cmd_lint,
        "pack": cmd_pack,
        "bounce": cmd_bounce,
        "docs": cmd_docs,
    }[args.command]
    return handler(args, repo)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
