# New features (deliberate additions beyond the original)

Intentional enhancements this port adds on top of faithful Pokémon Red
behavior. They have no Game Boy equivalent and are kept by design.
Genuine divergences from the original (things still missing, wrong, or
approximated) live in docs/known-differences.md; faithfully-ported
behavior is in docs/behavior-porting-notes.md.

## Survey zoom

The mouse wheel (or `-`/`=`) zooms the overworld between 1 pixel per world
pixel (full survey) and 2× the window fit scale (close-up), in crisp
integer steps. This has no Game Boy equivalent:

- Connected maps render their full bodies, and their NPCs appear as
  visual-only "ghosts",  they wander but have no sight lines, triggers,
  dialogue, or collision until the map is actually entered.
- Menus, text boxes, and battles draw at normal scale on top of the
  zoomed world. Zoom input is ignored while a script, menu, or battle is
  active; the zoom level persists across warps and is never saved.
- Beyond the border ring the border block repeats indefinitely (interiors
  stay black, seaside towns stay water,  except OVERWORLD-tileset maps,
  whose beyond-edge space fills with the solid tree wall instead of the
  per-map border block), and each visible map area is colorized with its
  own SGB palette (the original recolored the whole screen per map).
- Neighbor maps load two connection hops out so corner-adjacent maps
  don't pop in and out, and ghost NPCs share instances with the real ones
  so their wander positions persist across seamless connection crossings
  (a warp or fresh map entry still respawns everything at its script
  position, like the original's per-entry sprite init).

## Tilt mode

The `3` key (and the Options menu TILT row) cycles a visual-only perspective
tilt of the overworld through **OFF → 15° → 35° → 50° → OFF** for an HD-2D /
diorama look. Like survey zoom this is purely presentational and has no
Game Boy equivalent:

- The entire map tilts as one rigid ground plane,  paths, grass, water,
  floors, and every background-tile structure (buildings, trees, fences,
  signs; in Gen 1 these are baked into the tile layer, not sprites),  so
  rows above the player recede and rows below come toward the viewer. Only
  things that actually *stand* on the ground draw as upright billboards,
  unscaled and pixel-identical to flat mode: the player, NPCs, item balls,
  and the standing FX attached to them (emote bubbles, the fishing rod,
  the FLY bird). The Poké Center heal-machine overlay stays on the ground
  plane with the machine tiles (it is OAM glued to a BG graphic, not a
  standing sprite). An earlier revision tried
  billboarding buildings/trees/signs too (cutting them out of the ground
  per hand-curated per-tileset tables); that chased an endless tail of
  special cases,  dense tree canopy, fences fused into grass, building
  facades with their own baked-in fake perspective,  because Gen 1's art
  was never drawn with a clean seam between ground and standing scenery. It
  wasn't merged; tilting everything but the characters as one plane is the
  simpler, shipped tradeoff (buildings recede/foreshorten with the ground
  like a photo of a diorama, rather than standing fully upright next to
  a full-height character).
- Cycling tweens the angle between levels over ~0.25s rather than snapping;
  with tilt fully off the world pass drops back onto the flat blit path, so
  flat rendering stays pixel-identical to tilt-off and off costs nothing.
- Tilt input is gated exactly like survey zoom,  honored only while
  free-roaming, ignored while a script, menu, or battle is active,  and it
  composes with survey zoom (the zoom scale feeds the projection). The tilt
  level is persisted in `save.options.tilt` (default OFF).
- It applies everywhere the overworld draws, interiors and caves included.
  Menus, text boxes, and battles render flat on top, unaffected, and the
  infinite beyond-the-border-ring fill stays flat by design.
- Collision, movement, sight lines, triggers, encounters, and scripts are
  untouched; nothing about the tilt reaches gameplay.

## Colors mode

The `2` key (and the Options menu COLORS row) cycles the display mode
through **OG RED → SGB → RED++ → OG → OG INV → SGB INV → CLASSIC → OG RED**.
The first three are the real colorizations; the rest are DMG-shade novelties:

- **OG RED**: the Game Boy Color boot-ROM look for Pokemon Red -- one global
  red BG palette + one green OBJ palette, every map, no per-map variation
  (Pokemon Red has no CGB code, so on a GBC the boot ROM colors it globally).
  The player/NPCs stay green over the red terrain via the OBP bake +
  post-zone redraw (`PaletteFX.GBC_BG` / `GBC_OBJ`).
- **SGB** (default): the per-map Super Game Boy region palettes
  (`data/sgb/sgb_palettes.asm`). Sprites tint with the region palette, as on
  real SGB. (This is the mode formerly mislabeled "GBC".)
- **RED++**: pokered-gbc SuperPalettes -- real per-tile GBC coloring plus
  per-species mon colors (`data/palettes_gbc.lua`).
- **OG**: force the four DMG grays (colorization off).
- **OG INV**: inverted DMG grays.
- **SGB INV**: each SGB zone palette with shade order reversed.
- **CLASSIC**: original Game Boy pea-soup greens
  (`#9BBC0F` / `#8BAC0F` / `#306230` / `#0F380F`).

The shade-remap transform is applied centrally in `PaletteFX.sendColors`, so
it covers overworld, menus, battles, and tilt upright billboards. OG RED's
global BG palette is supplied by `OverworldState:overworldBgColors` (per-map
override in the overworld pass). Persisted as `save.options.colors`; the
`gbc` / `gbc_inv` save ids are kept for back-compat under the new labels.

## GBC FX

The `5` key (and the Options menu GBC FX row) cycles a "played on real
unlit-GBC hardware" post-process through **OFF → 1 → 2 → 3 → 4**. The
levels are a cumulative ladder:

- **1**: reflective-screen backing transparency.
- **2**: + LCD pixel grid.
- **3**: + pixel drop shadows.
- **4**: + sunlight glare and rainbow shimmer with a drifting light.

It runs as a final present pass after world + UI composite in
`Renderer:endFrame`, inspired by the Pixel Transparency RetroArch shader
([github.com/mattakins/Pixel_Transparency](https://github.com/mattakins/Pixel_Transparency)).
Default OFF; persisted as `save.options.gbcfx`.

## Peer-to-peer link play (lua-enet)

Trades and link battles connect two copies of the game directly over
lua-enet (ENet ships inside LÖVE,  nothing to install, no server to run)
on a reliable-ordered channel, replacing the original standalone Python
room-code relay (`tools/relay_server.py`, deleted). HOST A GAME shows the
host's LAN address (UDP 7777; `POKEPORT_LINK_PORT` overrides); JOIN A
GAME enters it. Closing performs a graceful ENet disconnect so the final
confirm/bye always lands; a vanished peer exits with "The link was
broken." Internet play needs a forwarded UDP port or a VPN (deliberate
tradeoff vs. the relay). Headless tests drive the protocol over an
in-memory loopback (`Net.loopbackPair`); under LÖVE the same test file
also exercises real UDP pairing.

## Custom boot text

The boot sequence replaces the Nintendo / GAME FREAK identifiers with
"bois club" / "bryanthaboi",  a deliberate branding customization. The
rest of the boot beats (copyright splash, "presents" shooting-star, the
Nidorino-vs-Gengar attract scene) mirror the original.


## Custom Options

Options persist in a standalone `options.lua` (separate from the game
progress `save.lua`), so audio/display/battle preferences survive New Game
and aren't wiped when a save slot is cleared. Changing a row in the Options
menu or cycling hotkeys `2`/`3`/`5` writes immediately; an in-game save also
flushes the live options. Old saves that still embed an `options` table are
migrated once into `options.lua` on load.

- Music / SFX volume
- Music Filter
- OG GLITCHES on / off (Gen 1 quirks vs. modern-clean battle rules)
- COLORS (OG RED / SGB / RED++ / OG / OG INV / SGB INV / CLASSIC),  also
  hotkey `2` (OG RED = GBC boot-ROM look; RED++ uses pokered-gbc
  SuperPalettes + per-species mon colors)
- TILT (OFF / 15 / 35 / 50),  also hotkey `3` while free-roaming
- GBC FX (OFF / 1 / 2 / 3 / 4),  also hotkey `5`
- MAX FPS (30 / 40 / 50 / 60 / 75 / 90 / 100 / 120 / 144 / 160, default 60),
  a hard render frame-rate cap (`save.options.fpsCap`).