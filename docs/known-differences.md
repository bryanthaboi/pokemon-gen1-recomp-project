# Known differences from the original game

Only genuine remaining divergences live here: behavior that is still
**missing, wrong, or approximated for convenience** and would need more
work for true parity. Faithfully-ported behavior is documented in
docs/behavior-porting-notes.md; deliberate additions beyond the original
are in docs/new-features.md.

## Reimplemented unused Prof. Oak and Rocket Chief battles

The original ROM defines trainer data for `PROF_OAK` and `CHIEF`
(`data/trainers/parties.asm`) but never attaches either to an NPC, so
both battles are unreachable in the real game. This project makes them
fightable after the Hall of Fame:

- Prof. Oak battles you in Pallet Town once `EVENT_BEAT_CHAMPION_RIVAL`
  is set, using `ProfOakData`'s three starter-matched teams (the team is
  picked by the type that counters your starter, mirroring the rival).
- The Celadon Game Corner Chief battles you in his house post-game.
  `ChiefData` is empty in the ROM, so `OPP_CHIEF` is given a
  reconstructed party.

This is an intentional divergence: neither battle can be triggered in the
original game.

## Reimplemented unused Silph Co. card-key doors

`engine/events/card_key.asm` and the unused `CardKeyTable1/2/3` coordinate
lists (`data/events/card_key_coords.asm`) describe locked doors for Silph
Co. floors 2F-11F, but no retail `.blk` map layout ever places the closed
door block at those coordinates, so the card key check is dead code in
the original game. This project stamps the closed door block (`$54`/`$5f`
on floors 2F-10F, `$20` on 11F) over each of the 20 door coordinates on
map load, and swaps it for the open block once that door's
`EVENT_SILPH_CO_n_UNLOCKED_DOORn` flag is set (using the key from a Team
Rocket grunt, as in the original's unused design).

This is an intentional divergence: the doors are not visible or
functional in the original game. The door layout lives in
`tools/rom_manifest.json` (`field.cardKeyDoors.closedDoors`), hand-ported
since no retail ROM data encodes it; `src/import/RomExtractor.lua` copies
it straight through on ROM import.
