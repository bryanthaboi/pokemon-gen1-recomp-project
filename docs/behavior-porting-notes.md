# Behavior porting notes

What was ported from pokered's engine code and where it came from.

## Overworld

- **Collision rule** (`home/overworld.asm` tile-in-front checks): a 16x16
  cell is passable when its bottom-left 8x8 tile is in the tileset's
  `coll_tiles` list. Verified against Pallet Town's fences/houses/water
  and Oak's Lab furniture.
- **Warp activation** (`home/overworld.asm` CheckWarpsNoCollision /
  ExtraWarpCheck): a warp fires when arriving on a warp whose standing
  tile is in the tileset's door or warp tile list, or when standing on a
  warp and walking off the map edge (interior exit mats). Both paths are
  data-driven from `door_tile_ids.asm` / `warp_tile_ids.asm`.
- **LAST_MAP warps** return to the remembered outdoor map/position, like
  `wLastMap`.
- **Connections** (`map_header` connection directives): crossing an edge
  places the player at `destCoord = curCoord - offset*2` cells on the
  destination's opposite edge.
- **Movement**: tile-by-tile, 1 px/frame at 60 fps (16 frames per step),
  tap-to-turn without stepping, hold-to-walk, input locked mid-step.
- **Wild encounters** (`engine/battle/wild_encounters.asm`): per grass
  step, encounter iff `rand(0..255) < rate`; slot picked via the
  cumulative buckets 51/102/141/166/191/216/229/242/253/256.
- **Initial object visibility** from `toggleable_objects.asm` (e.g. Oak
  hidden in his lab), with `show_object`/`hide_object` script commands
  persisting to the save like the missable-object bits.

## Pokémon math (`engine/pokemon/calc_stats.asm`, `experience.asm`)

- `stat = floor(((base + DV)*2 + floor(sqrt(statExp)/4)) * L / 100) + 5`
  (HP: `+ L + 10`); HP DV from the low bits of the other four DVs.
- Growth curves use the exact cubic coefficients (MEDIUM_SLOW =
  1.2n^3 - 15n^2 + 100n - 140, etc).
- Exp gain = `floor(baseExp * level / 7)` (x1.5 for trainer battles);
  defeated species' base stats accumulate as stat experience.

## Battle core (`engine/battle/core.asm`)

- Damage: `floor(floor(2L(x2 crit)/5 + 2) * power * atk / def / 50)`
  capped at 997, `+2`, STAB x1.5, per-matchup type multipliers applied
  sequentially (x10 fixed point), then `rand(217..255)/255` when
  damage > 1.
- Critical hits: `rand(0..255) < baseSpeed/2` (x4 for Karate Chop, Razor
  Leaf, Crabhammer, Slash, capped 255); crits double level and ignore
  stat stages (gen1_faithful ruleset).
- Accuracy: `rand(0..255) < floor(acc*255/100)` after accuracy/evasion
  stages,  including the 1/256 miss at 100% accuracy (toggleable via the
  `modern_clean` ruleset).
- Stat stages use the 25/28/33/40/50/66/100/150/.../400 multiplier table
  (`data/battle/stat_modifiers.asm`).
- Physical/special split by type (special = Water/Grass/Fire/Ice/
  Electric/Psychic/Dragon).
- Status: paralysis speed/4 and 25% full para, burn halves physical
  attack, poison/burn residual = maxHP/16, sleep 1-7 turns waking on the
  lost turn, freeze permanent (as in Gen 1).
- Turn order: effective speed, coin-flip ties; Quick Attack first,
  Counter last (Gen 1's only priorities).
- Run formula (`TryRunningFromBattle`): always escape if faster,
  otherwise `floor(pSpd*32 / (eSpd/4)) + 30*attempts` vs `rand(0..255)`.
- Catching (`ItemUseBall`): ball-specific rand ranges (255/200/150),
  status bonus 25/12, second roll `floor(maxHP*255/ballFactor) /
  floor(HP/4)` capped 255.
- Prize money: class base money x last defeated mon's level
  (`pic_pointers_money.asm`).

## Battle move effects (engine/battle/core.asm, move_effects/*)

- Mimic via Metronome (effects.asm:1203-1273): MimicEffect's
  .letPlayerChooseMove branch snapshots wCurrentMenuItem before the
  copy-picker menu opens and restores it afterward as the write index
  into wBattleMonMoves. Since SelectMenuItem always writes
  wCurrentMenuItem/wPlayerMoveListIndex together at the FIGHT-menu
  confirm and nothing (including MetronomePickMove) touches either
  variable during mid-move resolution, the reused value is always the
  calling move's own slot,  BattleState.lua's applyMimic fallback uses
  self.moveIndex, frozen the same way, so a called Mimic (e.g. from
  METRONOME in slot 3) overwrites the calling move's own slot, keeping
  its PP, matching the Gen 1 quirk exactly.
- Multi-hit distribution 2/2/2/3/3/3/4/5 over rand(0..7); all hits reuse
  the first damage roll (faithful).
- Recoil = damage/4 (Struggle /2); drain/Dream Eater heal = damage/2;
  Dream Eater requires sleep.
- Fixed damage: SonicBoom 20, Dragon Rage 40, Seismic Toss/Night Shade =
  level, Psywave rand(1 .. 1.5xlevel-1).
- OHKO deals 65535, fails against faster targets; Swift skips accuracy;
  Jump Kick crash = 1 damage on miss; Explosion halves defense and
  faints the user even on a miss; Hyper Beam skips recharge if it KOs.
- Charge moves (incl. Fly's invulnerable turn), trapping moves locking
  the victim out of its turns, Thrash's 3-4 turn lock ending in
  confusion, Bide's 2-3 turn store-and-double, Rage's permanent lock
  with attack-up on being hit, Counter/Quick Attack priority.
- Side-effect chances: 26/256 (10%), 77/256 (30%), stat-down side
  effects 85/256; Twineedle 20% poison.
- Substitute costs 1/4 max HP, absorbs damage, blocks status/stat/side
  effects; screens double effective defense (bypassed by crits); Focus
  Energy keeps the Gen 1 quarter-rate bug under gen1_faithful.
- Status: sleep 1-7 turns (wake turn is lost), freeze permanent, burn
  halves physical attack, paralysis speed/4 + 25% full para, Toxic's
  rising counter, Leech Seed transfer, confusion 2-5 turns with 50%
  40-power typeless self-hit.
- Trainer Pokémon use fixed DVs 9/8/8/8 (TrainerAI.asm convention).

## Items (engine/items/item_effects.asm)

- Potion family 20/50/200/full; drinks 50/60/80; status heals per item;
  Revive half HP; Rare Candy = exact next-level exp with HP delta kept;
  evolution stones use the extracted evos data; TMs single-use / HMs
  reusable, gated by the species' real tmhm list; Repel 100/200/250
  steps blocking wilds below the lead's level; Escape Rope returns to
  the last heal point.
- Snorlax (Route 12/16) only wakes via `ItemUsePokeFlute` (item-use
  menu, adjacent to it, not yet beaten),  talking to it with the POKé
  FLUTE merely in the bag has no effect (`engine/items/item_effects.asm`,
  `scripts/Route12.asm`/`Route16.asm`).
- Mart inventories come from the script_mart lists per clerk; selling
  pays half price; TM prices from tm_prices.asm.

## Overworld field systems

- Ledges from ledge_tiles.asm (facing + standing tile + ledge tile +
  input direction -> two-cell hop).
- Counter talk-through uses the tileset's counter tiles
  (tileset_headers.asm), which is how mart clerks and nurses work.
- Trainer sight (`home/trainers.asm` CheckFightingMapTrainers +
  `engine/overworld/trainer_sight.asm`): extracted per-trainer range,
  inclusive tiles along the facing line; detection runs only on
  tile-aligned frames, before input handling, so on detection the d-pad
  is dead (wJoyIgnore) and the player freezes on the spotted tile; the
  "!" holds 60 frames (EmotionBubble), then the trainer walks
  distance−1 steps to the adjacent tile (none if already adjacent) and
  uses the real battle/won/after dialogue from the trainer headers.
  Sight is a pure screen-coordinate comparison with no line-of-sight
  obstruction check (TrainerEngage / CheckSpriteCanSeePlayer): an
  aligned in-range trainer engages through interposed NPCs and
  unwalkable tiles, and the walk-up (TrainerWalkUpToPlayer, a fixed
  distance−1 MoveSprite_ script) has no collision either, so the
  trainer simply walks/overlaps through anything on the line,  as OAM
  sprites overlap on hardware.
- Elevator rides (`engine/overworld/elevator.asm` ShakeElevator →
  `src/world/ElevatorShake.lua`): choosing a floor stops the music,
  bounces the BG scroll ±1 px around rest for 100 two-frame cycles with
  SFX_COLLISION retriggered every cycle, restores the scroll, plays
  SFX_SAFARI_ZONE_PA to completion, and restarts the map theme before
  the floor warp. Lead-in delays kept per script: 9 frames of Delay3s
  inside ShakeElevator (Celadon farjps in), 12 with the Silph/Rocket
  scripts' extra Delay3. The offset applies to the BG layer only, 
  sprites are OAM and stay put. After the ride the port no longer
  jump-cuts: choosing a floor rewrites the car's own exit-warp entries
  to that floor (`engine/events/elevator.asm` DisplayElevatorFloorMenu
  .UpdateWarp, per scripts/SilphCoElevator.asm /
  CeladonMartElevator.asm / RocketHideoutElevator.asm), then the player
  is walked out through the doorway onto that warp (ow:scriptMove →
  ow:takeWarp), like the original.
- Field-move gates (engine/overworld/field_move_messages.asm +
  start_sub_menus.asm): IsSurfingAllowed ported exactly,  SURF refuses
  with _CyclingIsFunText while the Cycling Road's BIT_ALWAYS_ON_BIKE is
  armed (save.forcedBike: set on the Route 16/18 forced-bike tiles,
  cleared by the gates, Fly, dungeon/blackout warps; the forced mount
  itself is silent, as in CheckForceBikeOrSurf) and with
  _CurrentTooFastText on Seafoam B4F's stairs square (7,11) until both
  EVENT_SEAFOAM4 boulders are down. Re-selecting SURF while surfing is
  ItemUseSurfboard's dismount attempt: steps ashore silently if the
  facing tile is land-passable and unoccupied, else "There's no place
  to get off!",  and the menu closes either way (wActionResult stays 1).
  STRENGTH's first page auto-advances after the cry + Delay3 (no
  prompt); "can move boulders." prompts. The GBPalWhiteOutWithDelay3
  white blink plays on every .goBackToMap closer: Strength, surf
  mount/dismount/no-place, Flash (after its text), and Dig/Teleport
  (Cut closes without a blink, per the asm).
- Wild slot table + rate per map; water encounter tables used while
  surfing.
- Cut-tree block swaps from cut_tree_blocks.asm; surfable tilesets from
  water_tilesets.asm (water tile $14, plus $32 on SHIP_PORT).

## Story events (data/scripts/story.lua and friends)

- Every hand-ported script cites its scripts/*.asm source and reuses the
  real extracted text and event-flag names.
- Custom flag names (audited equivalent): three port-internal flag
  families have no pokered EVENT constant but mirror the original's
  state exactly. EVENT_TRADED_* are per-trade names for
  wCompletedInGameTradeFlags bits (engine/events/in_game_trades.asm:
  FLAG_TEST before the offer → after-trade text, FLAG_SET on completion;
  dialogset text families, party-menu pick, the received mon joins the
  end of the party, ConnectCable→anim→TradedFor→Thanks all ported).
  EVENT_GOT_EEVEE is bookkeeping alongside the real guard,  the hidden
  ball object (scripts/CeladonMansionRoofHouse.asm HideObject, ≡
  save.objectToggles),  and self-heals older saves; a full party+box
  keeps the ball claimable (_BoxIsFullText). EVENT_BEAT_SS_ANNE_RIVAL
  stands in for scripts/SSAnne2F.asm's saved wSSAnne2FCurScript NOOP
  progression, including the lose-and-retrigger path (flag only set on
  victory). Names are kept for save compatibility. Coverage:
  tests/parity_trade_gift.lua.
- The Pallet Town intro follows pokered exactly: the trigger is
  PalletTownDefaultScript's wYCoord==1 check, Oak appears at (8,5) and
  takes FindPathToPlayer's zigzag to one tile below the player, and the
  escort is RLEList_ProfOakWalkToLab against the reverse-order playback
  of RLEList_PlayerWalkToLab (the 17th simulated press is eaten by the
  door-warp frame), followed by the OaksLab walk-in and choose-mon
  exchange with map music deferred like BIT_NO_MAP_MUSIC. Oak's speech
  ends with the real shrink: RedPicFront collapses through the extracted
  ShrinkPic1/ShrinkPic2 into the overworld walking sprite on
  OakSpeech.asm's frame timings (SFX_SHRINK, 4/4/20/50-frame beats, fade
  to white), with the closing text box held on screen. The escort's
  scripted steps run 16 frames/tile (chained single-tile scriptMoves
  start back-to-back, no idle frame); Oak marches in place on the door
  mat for RLEList_ProfOakWalkToLab's trailing NPC_CHANGE_FACING beat
  (movement.asm ChangeFacingDirection → zero-delta TryWalking); the "!"
  EmotionBubble overlaps the still-shown "Hey! Wait!" box
  (PalletTownOakText prints without a button wait, then DelayFrames 10 →
  EmotionBubble before the box clears); and the shrink beat ramps the
  music to silence over ~70 frames (wAudioFadeOutControl = 10;
  home/fade_audio.asm FadeOutAudio steps rAUDVOL 7→0) rather than
  hard-stopping.
- The 12 disguised static wild battles (Power Plant Voltorb/Electrode +
  Zapdos, Articuno, Moltres, Mewtwo) follow TalkToTrainer/
  EndTrainerBattle exactly: cry + battle text, after-battle text without
  a rematch once EVENT_BEAT_* is set, and the flag/HideObject on any
  non-blackout result (fleeing loses the legendary, as in Gen 1).
  Snorlax hides before its battle and only shows the calmed-down/
  returned line when not caught. Zapdos/Articuno/Moltres/Mewtwo's
  battle text is a text_far string ending in a bare "...@" terminator
  (no <DONE>/<PROMPT>) followed by text_asm PlayCry + WaitForSoundToFinish:
  the box types with no ▼ prompt and auto-closes only once the cry
  finishes, never on a button press,  ported via `Commands.play_cry`
  stashing the pending cry for the following `Commands.show_text` to
  consume as the TextBox's auto-close sound. Voltorb/Electrode's battle
  text has no PlayCry call in the ROM at all and keeps the ordinary
  button-wait close.
- Gym leader repeat dialogue (data/scripts/gyms.lua): each leader's
  text_asm branches on EVENT_BEAT_<LEADER>,  pre-badge talk prints the
  pre-battle text and engages the leader battle (badge/TM via
  data/scripts/victories.lua); post-badge talk prints the leader's
  post-battle advice text (Misty's is her TM11 explanation). The
  originals' middle branch (beaten but TM not handed over) is
  unreachable since the TM is granted with the victory. Giovanni's
  farewell (`ViridianGymGiovanniText` .afterBeat) hides him inside a
  fade-to-black/fade-in Transition matching ViridianGym.asm's
  GBFadeOutToBlack → HideObject → GBFadeInFromBlack, persisted
  permanently via TOGGLE_VIRIDIAN_GYM_GIOVANNI in save.objectToggles.
- Cable Club receptionists (TX_SCRIPT_CABLE_CLUB_RECEPTIONIST →
  CableClubNPC, all 12 Pokémon Centers): welcome, pre-Pokédex "making
  preparations" brush-off, and the apply/save YES-NO are ported;
  accepting saves the game and opens the link menu, declining prints
  "Please come again!".
- Cinnabar fossil deposit follows GiveFossilToCinnabarLab: a menu of
  carried fossils (FossilsList order), SeesFossilText with a Yes/No
  confirm, ComeAgainText on either cancel.
- Hall of Fame induction: each party mon's front sprite scrolls in from
  the left at 4px/frame, matching HoFShowMonOrPlayer's .ScrollPic
  front-pic phase (engine/movie/hall_of_fame.asm); the back-pic's
  enlarged/blurred pre-wipe is a VRAM-scroll-register trick not
  replicated in this sprite-based renderer. The finale
  (HoFDisplayPlayerStats) shows trainer name, play time, money, POKéDEX
  seen/owned, and Prof. Oak's rating text (engine/events/
  pokedex_rating.asm DexRatingsTable) from real save data.
- End credits + post-game reset (engine/movie/credits.asm,
  scripts/HallOfFame.asm): screen-by-screen CreditsOrder pages (hlcoord
  9,6 + signed columns), FadeInCredits' 4x5-frame ramp, 90/110/120/140-
  frame holds, DisplayCreditsMon's 27-frame 8px/frame silhouette wipe,
  LoadCopyrightTiles' three-row block, THE END at (4,8). While THE END
  is up the HoF script autosaves (wLastBlackoutMap := PALLET_TOWN; the
  player is saved in the HALL_OF_FAME room), waits 600 frames, then A/B
  triggers `jp Init`,  the boot sequence replays into the title screen.
- Victory Road's boulder switches replicate the original's
  ReplaceTileBlock data: 1F boulder at (17,13) -> block $1D at (4,6);
  2F boulders at (1,16)/(9,16) -> $15 at (3,4) and $1D at (11,7); 3F
  boulder at (3,5) -> $1D at (3,5), and the (23,15) hole drops the
  boulder to 2F (hide/show toggle). Barriers are re-applied from flags
  on map entry, exactly like the originals' map-load scripts.
- Item balls, static legendary encounters and trainer rewards
  (badges + gym TMs, the Silph Giovanni flag) are generic systems driven
  by the extracted object args and a hand-ported reward table
  (data/scripts/victories.lua).
- In-game trades use the real data/events/trades.asm table (species in,
  species out, original nickname).

## Safari game (engine/events/hidden_events/safari_game.asm + engine/battle)

- ¥500 buys 30 SAFARI BALLs and 502 steps (scripts/SafariZoneGate.asm
  sets `wSafariSteps = 502`); steps count down on the four outdoor zone
  maps and hitting 0 (or throwing the last ball) ends the game at the
  gate.
- Safari battles offer BALL / BAIT / ROCK / RUN; no player Pokémon
  acts.  The working catch rate starts at the species rate; BAIT halves
  it and adds 1-5 to the bait factor (zeroing the escape factor); ROCK
  doubles it (cap 255) and adds 1-5 to the escape factor (zeroing bait)
  -- ItemUseBait/ItemUseRock in engine/items/item_effects.asm.
- Each turn one factor decays ("is eating!" / "is angry!"); when the
  escape factor decays to 0 the catch rate resets to the species rate
  (PrintSafariZoneBattleText, engine/battle/safari_zone.asm).
- Flee check (engine/battle/core.asm): `b = 2 * (speed % 256)`; the mon
  always flees when speed > 127; while eating `b /= 4`, while angry
  `b = min(255, 2b)`; it flees when `rand(0,255) < b`.
- The SAFARI BALL rolls the ULTRA_BALL rand range (0-150) in the Gen 1
  catch formula, against the BAIT/ROCK-modified rate.

## Slot machines (engine/slots/slot_machine.asm)

- The three reels are the extracted 18-symbol wheel sequences
  (data/events/slot_machine_wheels.asm); bet 1 plays the middle row,
  bet 2 adds top+bottom, bet 3 adds both diagonals.
- Payouts: 7-7-7 = 300, BAR = 100, CHERRY = 8, MOUSE/FISH/BIRD = 15
  (SlotRewardPointers).
- Per-wheel stop/slip rules ported exactly: wheel 1 spends up to 4 slip
  charges, slipping past a centred CHERRY (in seven-and-bar mode it
  always slips all 4 via pokered's `cp HIGH(SLOTS7)` bug); wheel 2 stops
  as soon as wheels 1+2 line up any potential match (pairs checked b/b,
  b/m, m/m, t/m, t/t) or, in seven-and-bar mode, on 7/BAR; wheel 3 rolls
  past forbidden matches free and burns wSlotMachineRerollCounter
  charges on winnable no-match spins, animated tile-by-tile. Luck flags
  (SetFlags): seven-and-bar mode is sticky across spins; r==0 arms 60
  allow-matches charges; a BAR win clears flags; a 300 win zeroes the
  counter and clears flags with probability 128/256; 8/15 wins burn one
  charge. Lines are checked in asm order with the first match taken;
  A-presses are ignored while a prior wheel's slip counter is nonzero.
  Machine and COIN CASE texts are byte-identical
  (_GameCorner*Text; AbleToPlaySlotsCheck's no-coins gate included).
- Flow brackets: PromptUserToPlaySlots "A slot machine! Want to play?"
  (YesNoChoice) and MainSlotMachineLoop's "One more go?" (TwoOptionMenu);
  the x3/x2/x1 coin menu (CoinMultiplierSlotMachineText) defaults its
  cursor to x3, bet = 3 - menu item. Static frame: the real
  SlotMachineMap (gfx/slots/slots.tilemap, 20x12 tile ids < $25) blitted
  from red_slots_1.png, extracted as field.slotSymbols.tilemap
  (tools/extract/gfx.py extract_slots). Win flash:
  SlotMachine_CheckForMatches.flashScreenLoop flips rBGP (shade 3->2) b
  times at 5 frames each, b = 20/8/4/2 for the 300/100/15/8 rewards
  (SlotReward{300,100,8,15}Func). Payout drip:
  SlotMachine_PayCoinsToPlayer credits one coin every 8 frames (4 for a
  7/BAR), SFX_SLOTS_REWARD per coin, rOBP0 symbol flicker every 5 coins.

## Spinner arrow tiles (scripts/*.asm arrow movement tables)

- Viridian Gym and Rocket Hideout B2F/B3F keep per-coordinate RLE
  movement lists (map_coord_movement); each list executes backwards
  from its terminator (DecodeArrowMovementRLE), sliding the player and
  chaining onto further arrows.

## Cries (data/pokemon/cries.asm, audio/engine_1.asm)

- Each species = a base cry (one of 38 SFX_CryXX streams) + a frequency
  modifier added to every note's frequency register
  (Audio1_ApplyFrequencyModifier) + a tempo modifier
  (`sfx tempo = $80 + length`, Audio1_SetSfxTempo).  All 151 cries are
  rendered offline with those modifiers applied and play on battle
  entry and Pokédex pages.

## Hidden events & facility puzzles

- Card key doors (engine/events/card_key.asm): door tiles $18/$24
  (SILPH_CO_11F: $5e) replaced with block $0e ($03 on 11F).
- Vermilion trash cans
  (engine/events/hidden_events/vermilion_gym_trash.asm): the first-lock
  can re-rolls on every Vermilion City map load (VermilionCity_Script's
  Random & $e, even cans) and after every failed second-can guess; the
  second lock uses the GymTrashCans table verbatim, including the
  underflow bug that can place it in can 0 regardless of adjacency; a
  wrong pick resets EVENT_1ST_LOCK_OPENED and re-rolls immediately; only
  SuccessText3 prints on completion; the gym door block at (2,2) is
  $24 closed / $5 open (scripts/VermilionGym.asm). SuccessText1/
  SuccessText3/FailText play SFX_SWITCH/GO_INSIDE/DENIED from each
  text's text_asm tail after the text prints (DisplayTextID's
  WaitForTextScrollButtonPress then holds the box), so the port fires
  them from an onDone on the TextBox, landing the beep as the box
  closes rather than as it opens.
- Menu close-keys follow pokered's per-menu wMenuWatchedKeys mask, not
  a single global rule: the shared Menu base (src/ui/Menu.lua) closes
  on B only, and START-close is opt-in via opts.startCloses. Only the
  start menu sets it, matching engine/menus/draw_start_menu.asm's
  PAD_DOWN|PAD_UP|PAD_START|PAD_B|PAD_A; OptionsMenu also closes on
  START via its own loop, matching engine/menus/main_menu.asm
  DisplayOptionMenu's explicit B_PAD_B/B_PAD_START checks. Every other
  menu (bag/PC item lists PAD_A|PAD_B|PAD_SELECT, party menu /
  BUY-SELL-QUIT / USE-TOSS submenu / PC menus / Pokedex side menu
  PAD_A|PAD_B) leaves PAD_START unwatched, so START does not close
  them. START never replays SFX_PRESS_AB (HandleMenuInput_ beeps only
  for the PAD_A|PAD_B branch).
- Old man tutorial hollow cursor: the item list is itself scripted in
  pokered (DisplayListMenuID's old-man branch, home/list_menu.asm:65-91)
 ,  no input is read; the filled '▶' hovers POKé BALL for 80 frames,
  auto-presses A, then PlaceUnfilledArrowMenuCursor leaves the hollow
  '▷' on that row until ItemUseBall tears the list down for the throw.
  Ported via ListMenu's opts.script hook (src/ui/ListMenu.lua) and
  BattleState:openOldManBag driving the same beats. The MissingNo./
  wGrassRate side effects of the OLD MAN name swap are not modeled, 
  see docs/gameboy-hardware-limitations.md.
- Gym statues (gym_statues.asm): plaque with the city/leader from each
  gym's script; the player joins WINNING TRAINERS with the badge.
- Route 22 gate / Route 23 guards: real trigger rows, badge order
  (EARTH down to CASCADE) and EVENT_PASSED_*_CHECK skip flags.
- Game Corner poster (scripts/GameCorner.asm): block (8,2) $2a -> $43
  on EVENT_FOUND_ROCKET_HIDEOUT.
- Seafoam Islands (scripts/SeafoamIslandsB3F/B4F.asm): reversed-RLE
  current paths, Seafoam4HolesCoords boulder holes setting the
  EVENT_SEAFOAM*_BOULDER*_DOWN_HOLE pairs, the forced pool exit rows.
- Rock Tunnel darkness: wMapPalOffset = 6 on entry, cleared by Flash
  (BOULDERBADGE) or leaving (home/overworld.asm).

## Battle extras

- GROWL/ROAR (GetMoveSound/IsCryMove, engine/battle/animations.asm
  ~2196): the move's own MoveSoundTable tempo byte (Growl $c0, Roar
  $40, both pitch $00) layers onto the cry via `Sound.playMoveCry`'s
  `Source:setPitch(256/(128+tempoMod))`. Transform (engine/gfx/
  palettes.asm DeterminePaletteID, bit TRANSFORMED): the swapped-in pic
  is tinted PAL_GRAYMON via `PaletteFX.monPal(data, species,
  transformed)`, not the copied species' own palette, in
  `BattleState:speciesSprite`. Growl (DoGrowlSpecialEffects,
  animations.asm ~928): AnimPlayer's GROWL frame-block branch keeps a
  `growlNoteTrail` snapshot so each block's emitted sprites include the
  previous block's note copy alongside the current one (GROWL skips
  AnimationCleanOAM between blocks per the `cp GROWL` check ~line 145);
  ROAR is unaffected since the asm never applies this quirk to it.
- Master/Ultra ball tosses flicker the OBJ palette: DoBallTossSpecial
  Effects (engine/battle/animations.asm:685) XORs rOBP0 with %00111100
  after every frame block while wCurItem <= ULTRA_BALL, so the 11 toss
  blocks alternate the $F0/$CC shade maps starting normal; PlayAnimation
  pushes/pops rOBP0 around each subanimation row, so the ambient
  palette returns when the toss ends. GREAT/POKE/SAFARI balls never
  flicker, and the toss arc always follows wCurItem via
  TossBallAnimation, including the ghost-dodge throw.
- Anim-layer OBJ colorization is per 8x8 attribute cell: the SGB's
  ATTR_BLK regions color the composited DMG picture per cell, not per
  OAM entry, so an anim sprite overlapping a zone boundary takes each
  cell's palette on the pixels inside it,  AnimPlayer samples the zone
  under every cell an 8x8 tile touches and repaints differing cells
  through a cell-clipped scissor (aligned tiles stay one draw).
- Ball wobbles (ItemUseBall): Z = X*Y/255 + status2 with
  Y = rate*100/ballFactor2; <10/<30/<70 -> 0/1/2 shakes, else 3, with
  the matching ItemUseBallText01-04 lines.
- Trainer class AI (data/trainers/ai_pointers.asm +
  engine/battle/trainer_ai.asm): per-class item/switch routines with
  wAICount uses per Pokémon, ported to data/scripts/ai_classes.lua.
- Exp (engine/battle/experience.asm): baseExp*level/7 divided by the
  participant count, x1.5 for trainers, x1.5 for traded mons; stat exp
  in full to each participant.
- Move sounds: data/moves/sfx.asm (sound + pitch/tempo per move). The
  pitch/tempo modifiers are applied at synthesis time
  (Audio2_ApplyFrequencyModifier adds pitch to every frequency write;
  Audio2_SetSfxTempo scales tone-channel note lengths, noise skips it), 
  128 variant WAVs keyed "<sfx>@<pitch><tempo>" that Sound.playMove
  selects, exact rather than a playback-rate approximation. Per-row
  sounds fire as PlayAnimation does; GROWL/ROAR (IsCryMove) play the
  attacker's cry. Hit sounds by effectiveness (Damage/Super/NotVery).
- Screen-effect animations (engine/battle/animations.asm +
  engine/gfx/screen_effects.asm): every SE_* is implemented per-routine, 
  FlashScreen/FlashScreenLong (the FlashScreenLongSGB 12-entry table),
  Dark/Light/DarkenMon/Reset palette ops (shade-map permutations of the
  SGB zone palettes), all SlideMon variants, ShakeBackAndForth,
  BoundUpAndDown, SquishMonPic, Minimize (real MinimizedMonSprite),
  spiral/shoot-balls/water-droplets/leaves emitters compiled from the
  asm trajectories, per-animation-id frame-block flashes (Explosion,
  Rock Slide's rumbles, Blizzard's cadence...), AnimationWavyScreen with
  true per-scanline offsets, PredefShakeScreenHorizontally/Vertically
  and ShakeEnemyHUD. SE rows carry the faithful blocking durations.
- SGB battle colorization (SetPal_Battle, BlkPacket_Battle,
  SetAnimationPalette): the battle screen is colorized by zone,  player
  HUD, enemy HUD, player mon + message box, enemy mon; trainer front
  pics and the player/old-man back pics take PAL_MEWMON (both species
  IDs are zero at the intro, so MonsterPalettes[0]); the ghost keeps the
  disguised species' palette; attack animation sprites and thrown balls
  are colored through the OBJ palettes (wAnimPalette $F0 on SGB, ambient
  $E4, OBP1 $6C). Headless/no-shader environments fall back to the flat
  pipeline.
- Mimic resolves mid-move (MimicEffect): accuracy first, then the
  player's copy menu (enemy/link copy a random slot); the copy
  overwrites only the slot's move ID,  PP is shared with Mimic's slot, 
  and reverts on switch/battle end.
- Old man tutorial (DisplayBattleMenu's BATTLE_TYPE_OLD_MAN branch): the
  real scripted cursor,  ▶ beside FIGHT for 80 frames, beside ITEM for
  50, ITEM force-selected into the POKé BALL x50 list; the throw always
  catches at full HP (item_effects.asm jumps straight to .captured, 3
  shakes, no party/dex add, no ball consumed); backing out of the bag
  replays the script. The old man never attacks,  the original tutorial
  is menu navigation + a guaranteed catch, nothing more.

## Link battles (lockstep)

- Both sides simulate with a shared Park-Miller RNG stream (host deals
  the seed), identical pack/unpack-clamped party copies, no badge
  boosts, and a mirrored speed-tie roll (the guest inverts it); a
  canonical host-side-first state hash is exchanged per turn and any
  mismatch ends the match as a draw.

## Music (audio/engine_1.asm)

- Note duration: `frames = length * speed * tempo / 0x100` with
  fractional carry, at 60 fps (Audio1_note_length / CalculateDelay).
- Frequency: `reg = pitches[note] asr (octave - 1)` (CalculateFrequency;
  the octave byte stores `8 - octave`), `f = 131072/(2048 - reg)` for
  squares, halved for channel 3.
- note_type volume/fade renders as an NRx2-style envelope (step every
  `fade/64` s); duty_cycle maps to 12.5/25/50/75% pulse widths;
  sound_call/sound_loop honor the engine's one-level call stack and
  loop counters.

## Text & font

- The Pokédex height row uses the real ′/″ tiles: gfx/pokedex/pokedex.png
  tiles 0/1 are patched over font-extra slots $60/$61 exactly as
  engine/gfx/load_pokedex_tiles.asm loads them over vChars2 (they replace
  glyphs charmap.asm marks unused); ASCII `"` aliases to the closing-
  quote glyph $73 so stray hand-written quotes render.

## Validation against the original

- `tests/run_tests.lua` pins hand-checked values: L5 Bulbasaur 19 HP /
  9 Atk at 0 DVs, L100 Mewtwo 415 HP / 406 Spc at max DVs+statExp,
  MEDIUM_SLOW(5) = 135, type chart spot checks, deterministic damage
  rolls, Route 1 slot 1 = L3 Pidgey.
- The autopilot run reproduces the original's early flow on real map
  data: Pallet sign text, lab door warp target (5,11), Oak's Lab exit by
  walking off the mat, connection into Route 1 at matching x.
