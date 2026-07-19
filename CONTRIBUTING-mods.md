# Contributing to the mod platform

Two routes

| You are... | Lane | Review bar |
|---|---|---|
| adding a mod to the gallery, or listing one in the showcase | [Lane A](#route-a--contributing-a-mod) | template + polish checklist + green `modkit validate` |
| changing the loader, a registry schema, an event/hook name, or a manifest field | [Lane B](#route-b--contributing-an-engine--mod-api-change) | RFC + backward-compat statement + parity test + generated docs |

If you are not sure which lane you are in, ask this: **could my change make
somebody else's existing mod behave differently?** If yes, it is Lane B.

---

## Route A — contributing a mod

### 1. Scaffold

```sh
python3 tools/modkit.py scaffold my_mod --profile content
```

`--profile` is one of `content`, `overhaul`, `total_conversion`. The
scaffold refuses to overwrite an existing directory, and prints the next
commands.

Or copy the gallery entry closest to your intent — that is what the gallery
is for:

| You want to... | Copy |
|---|---|
| change numbers | `mods/examples/example_balance_tweaks` |
| change art | `mods/examples/example_shiny_palette` |
| add music or cries | `mods/examples/example_jukebox` |
| add a quest, NPC or dialogue | `mods/examples/example_lost_parcel` |
| change how battles work | `mods/examples/example_weather` |
| add a screen or a tool | `mods/examples/example_dexnav` |
| build a whole new game | `mods/examples/example_mini_conversion` |

### 2. What the PR must contain

1. **A green `modkit validate`.** CI runs it; so should you.

   ```sh
   python3 tools/modkit.py validate mods/examples/<id> --base imported
   python3 tools/modkit.py lint mods/examples/<id>
   ```

   `validate` drives the *real* loader headlessly, so a mod that passes
   here does not surface load errors in game. `--base imported` folds
   against the full vanilla id space; without it, rules that can only be
   decided against real Red content (`MK103`, the patch-target check) are
   reported as skipped rather than guessed at.

2. **A `tests/` directory** with at least one suite that loads the mod
   through the headless loader and asserts its *stated effect* — not just
   that it loaded.

   ```lua
   package.path = "./?.lua;./?/init.lua;" .. package.path
   local T = require("tests.modkit")
   local Data = require("src.core.Data"); Data:load()
   local run = T.sdk.loadMod("mods/examples/my_mod", { data = Data })
   T.eq(#run.errors, 0, "loads clean")
   T.eq(Data.pokemon.PIKACHU.baseStats.speed, 120, "the patch landed")
   run.release()
   T.finish("my_mod")
   ```

   Add a `.modkitignore` listing the suite so it stays out of the
   distributed package — a test requiring engine modules is a
   private-require finding against the shipped archive, and `pack` treats
   warnings as fatal.

3. **A `README.md`** that opens with one sentence saying what the mod does,
   names its persona, and gives the three commands to try it. No
   prerequisites the scaffold did not already create.

4. **A `mod.card`** meeting the [§3.2 schema](#modcard):

   ```lua
   return {
     summary   = "One sentence, <=100 chars.",
     author    = "Your handle",           -- never blank; no author is anonymous by omission
     tags      = { "balance", "beginner" },
     differences = { changed = {…}, added = {…}, known = {…} },
     credits   = { { who = "…", for_ = "original chiptune arrangement" } },
     compat    = { engine = ">=1.0.0 <2.0.0", modApi = 2 },
   }
   ```

5. **A `CHANGELOG.md`** in keep-a-changelog format, with a heading matching
   `manifest.version`. `validate` warns when the version advanced without
   one.

6. **Disabled by default.** Gallery entries live in `mods/examples/`, which
   the loader's one-level discovery does not walk, so a fresh install
   discovers none of them and the vanilla game is unchanged.

7. **No ROM-derived bytes.** Art and audio ship as originals or as a
   `transforms.lua` operating on the player's own cache. `modkit lint`
   is the hard floor; see
   [the legal posture](#legal-posture-non-negotiable).

CI checks 1, 2, 6 and 7 mechanically. A reviewer checks 3, 4, 5 and the
polish checklist.

### 3. Category

`manifest.category` is a closed vocabulary. An unknown value is a warning,
not a hard error, so the list can grow without breaking old mods.

| category | Meaning | Typical profile |
|---|---|---|
| `TWEAK` | Small data edits: stats, prices, learnsets, encounter tables | content |
| `BALANCE` | Systematic rebalance across many records or a ruleset | content / overhaul |
| `CONTENT` | New species / moves / items / maps / trainers | content |
| `QUEST` | New story, NPCs, dialogue, cutscenes | content |
| `MECHANIC` | New or changed battle/field mechanics via hooks/effects | overhaul |
| `GRAPHICS` | Sprite / tileset / palette / font changes | content |
| `AUDIO` | Music, sfx, cries | content |
| `UI` | New or modified screens, menus, overlays | content / overhaul |
| `TOOL` | Dev/QoL utilities, overlays, inter-mod libraries | content |
| `TOTAL_CONVERSION` | Full re-theme; owns its own tri-ledger | total_conversion |
| `OTHER` | Fallback | any |

`GAMEPLAY` is accepted as an alias for `TWEAK`, so `example_mew_starter`
keeps validating with the value it has shipped since before the taxonomy
existed.

### 4. `mod.card`

The manifest is the *engine's* contract: identity, load order, dependencies,
permissions, profile. The card is the *human-facing* one: who made this,
what it changes, what it does not do yet. It is never read by the loader's
merge — only by tooling and the manager's detail pane — so an absent or
malformed card can never break a load.

Two fields deserve their own note:

- **`differences`** is a self-declared tri-ledger, mirroring the discipline
  the engine holds itself to. `changed` and `added` let a player see the
  blast radius before installing; `known` is where you are honest about
  what is rough. A card with an empty `known` on a complex mod reads as
  carelessness, not polish.
- **`screenshots[].transform`** describes a screenshot by the *driver
  script* that regenerates it from the player's build, rather than shipping
  the pixels. That is the legal posture extended to your marketing: a
  distributed mod never carries ROM-derived bytes, not even in its preview
  images.

### 5. Tags

Lowercase kebab strings, open vocabulary. The showcase generator
lowercases and de-dupes. A recommended starting set: `beginner`,
`data-only`, `quality-of-life`, `hardcore`, `cosmetic`, `story`, `ruleset`,
`audio`, `ui`, `total-conversion`.

---

## Route B — contributing an engine / mod-API change

Changing the loader, a registry schema, an event or hook name, or a manifest
field touches the **compatibility surface** the project promises to hold
stable. Those PRs carry five obligations.

### 1. An RFC

`docs/rfcs/NNNN-<slug>.md`, covering:

- **Motivation** — the mod that cannot be written today.
- **The decision it extends or amends** — name the D-number and the plan
  file, so the change is traceable to the design it modifies.
- **The exact API delta** — new registry names, new schema fields, new
  event/hook names and their payload shapes and call sites.
- **A migration note for existing mods** — what an author has to do, if
  anything. "Nothing" is a valid and preferred answer.

### 2. A backward-compatibility statement

Show that the v1 surface still works: `content.X:register/override/get`,
`events:on`, `hooks:wrap`, `mod.log`, `mod:read`, the manifest v1 fields,
and `pokemon.before_give`.

**A change that would break a v1 mod is rejected unless it is
additive-with-alias.** `mods/example_mew_starter` is the live proof: it is
api 1, uses `category = "GAMEPLAY"`, copies a whole species record because
`patch` did not exist yet, and it must keep loading unchanged.

### 3. A parity-guarantee test

Two tests, not one:

- **The no-mod test** — vanilla behavior is unchanged with nothing
  installed. A new hook with no subscriber must return the vanilla value;
  a new registry must be a provable no-op when empty; a new event must not
  allocate its payload when nothing wants it (`Runtime.wants(name)` /
  `Runtime.wantsHook(name)` guard the hot paths).
- **The mod-API test** — the new seam, exercised through the *public* mod
  API rather than by reaching into internals. If the test has to require a
  private module to drive your seam, the seam is not finished.

### 4. Docs with the change

The reference pages are generated from `src/mods/Schemas.lua`, so a new
registry or a new schema field lands with its catalog entry in the same PR
and the generator runs clean:

```sh
luajit tools/gen_registry_docs.lua                 # in-repo default
luajit tools/gen_registry_docs.lua ../project.wiki # the wiki checkout
```

The prose reference lives in the GitHub wiki; the generated pages are
written into a checkout of it, so they cannot drift from the engine.

### 5. Deprecation etiquette

**Nothing is removed.** A superseded seam is marked deprecated in the
generated reference with its replacement named, keeps firing and working,
and is listed in the deprecations page.

`pokemon.before_give` is the worked precedent: the `pokemon.give` hook
supersedes it, and it is grandfathered forever anyway.

### Review

PRs touching `src/mods/`, `src/mods/Schemas.lua`, or the event/hook catalog
need the RFC label and a green parity gate before merge.

---

## The polish checklist

Every gallery example and every community mod the guide recommends meets
this bar. `[auto]` items are checked by `modkit validate`; `[review]` items
by a human.

### Error messages

- `[auto]` No bare `error()` or `assert()` in mod callbacks. Every failure
  path uses `mod.log:warn` / `mod.log:error` — the loader already prefixes
  `[modid]` — **and names a remediation**:

  ```lua
  -- no
  local mew = assert(mod.content.pokemon:get("MEW"), "Mew is missing")

  -- yes
  if not mod.content.pokemon:get("MEW") then
    mod.log:warn("MEW missing from the merged view -- is a species mod "
      .. "loaded before this one? speed patch skipped")
    return
  end
  ```

- `[review]` Every registration is validated against its schema, so a typo
  is a load-time message naming the field, not a nil-index crash three
  screens later.

### Empty states

- `[review]` Every screen a mod adds renders a sentence when its data set
  is empty — "No songs registered", "Nothing seen yet" — never a blank box.
  `ListMenu` gives you this for free.

### First-run experience

- `[review]` The README opens with one sentence of what the mod does, then
  the commands to try it.
- `[auto]` The mod loads clean on a fresh install — zero `Loader.errors` —
  with only its declared dependencies.
- `[review]` Options have sane defaults, so the mod does something useful
  before the player opens its options pane.

### Credits and honoring authors

- `[review]` `mod.card.credits` names every upstream contribution — art,
  music arrangement, borrowed code — and what it was for. A mod that ports
  another community work credits it and links it.
- `[auto]` `mod.card.author` (or `authors`) is present and non-empty. The
  showcase and the manager both surface it, so no author is anonymous by
  omission.
- `[review]` Asset provenance is honest: originals declared original,
  cache-derived output produced by a declared transform, third-party assets
  credited and license-compatible.

### Legal posture (non-negotiable)

- `[auto]` **No ROM-derived bytes in the packaged mod.** `modkit pack`
  refuses otherwise, and `pack` runs `validate --strict`, so even warnings
  block the archive.
- `[review]` A total conversion carries the TC legal callout: the Red
  import still runs and supplies fallback infrastructure, the conversion
  overrides on top, and it distributes recipes rather than extracted
  content.

---

## Versioning etiquette

Three version numbers coexist.

**Engine version** — `src/core/Version.lua`. Major = a breaking change to
the mod-facing schemas or API; minor = new backward-compatible seams;
patch = bugfix.

**Mod API version** — the integer `modApi`, currently `2`. Bumped only on a
breaking change to the `mod` object surface. A manifest's `api` field pins
the surface the mod was written against, so an api-2 mod keeps working when
the engine ships api 3.

**Your mod's version** — the manifest `version`, semver:

| bump | when |
|---|---|
| patch | data fixes; no save-shape change, no new content ids |
| minor | new content ids, new options with defaults, new optional deps |
| major | removed or renamed content ids, a changed `mod.save` shape (needs a `mod.migrations:add(sinceVersion, fn)` entry), or a raised `game_version` floor |

Declare the engine range you target in `game_version` (a semver range, e.g.
`">=1.0.0 <2.0.0"`). The loader checks it on load; a mismatch is a clear,
mod-attributed manager error, never a silent partial load.

Every version change gets a `CHANGELOG.md` heading. `modkit validate` warns
when `manifest.version` advanced without one.
