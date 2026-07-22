"""Extract field-interaction data: ledges, cut trees, water tilesets.

Sources:
  data/tilesets/ledge_tiles.asm     -> hop rules (facing, stand, ledge, pad)
  data/tilesets/cut_tree_blocks.asm -> block swap after Cut
  data/tilesets/water_tilesets.asm  -> tilesets where Surf works
  data/events/hidden_events.asm     -> hidden items / coins / slot machines,
                                       PC tiles, bench guys, gym statues,
                                       Vermilion Gym trash cans
  data/events/bench_guys.asm        -> bench guy text per map
  data/events/slot_machine_wheels.asm -> the three slot wheel symbol lists
  data/events/card_key_{coords,maps}.asm + engine/events/card_key.asm
                                    -> Silph Co card key doors
  data/maps/force_bike_surf.asm + home/overworld.asm
                                    -> forced bike/surf tiles, Cycling Road
  scripts/SeafoamIslandsB{2,3,4}F.asm -> surf currents and boulder holes
  scripts/GameCorner.asm            -> Rocket Hideout poster block swap
  scripts/Route22Gate.asm, scripts/Route23.asm -> badge gates
  constants/player_constants.asm    -> preset player/rival names
  engine/events/hidden_events/vermilion_gym_trash.asm -> trash can puzzle
  scripts/{ViridianGym,RocketHideoutB2F,RocketHideoutB3F}.asm
                                    -> spinner arrow tile movement tables
  gfx/title/*.png, gfx/splash/copyright.png -> title screen assets (via gfx.py)
  gfx/splash/*, gfx/intro/*, engine/movie/{splash,intro}.asm
                                    -> intro movie assets (via gfx.py)
  data/maps/{town_map_entries,town_map_order,names}.asm
                                    -> town map locations + cursor order
  data/credits/*.asm + engine/movie/credits.asm -> end credits + THE END
  constants/script_constants.asm + gfx/slots/*, gfx/emotes/*
                                    -> slot wheel symbols, emotion bubbles
  scripts/ViridianCity.asm          -> old man catch-demo battle
  scripts/GameCorner.asm + text/GameCorner.asm -> coin purchases
  constants/menu_constants.asm      -> PC item capacity

Output: data/generated/field.lua
  (+ assets/generated/{title,slots,credits}/*.png, assets/generated/emotes.png)
"""

import os
import re

from . import gfx, text, util
from .util import parse_number, read_asm, split_args

DIRS = {
    "SPRITE_FACING_DOWN": "down", "SPRITE_FACING_UP": "up",
    "SPRITE_FACING_LEFT": "left", "SPRITE_FACING_RIGHT": "right",
}


def parse_fly_warps(pokered):
    """data/maps/special_warps.asm: fly_warp MAP, x, y landing spots."""
    warps = {}
    order = []
    for lineno, line in read_asm(os.path.join(pokered, "data/maps/special_warps.asm")):
        m = re.match(r"\.?\w*:?\s*fly_warp\s+(\w+),\s*(\d+),\s*(\d+)", line.strip())
        if m:
            warps[m.group(1)] = {"x": int(m.group(2)), "y": int(m.group(3))}
            order.append(m.group(1))
    return warps, order


def parse_super_rod(pokered):
    """data/wild/super_rod.asm: map -> fishing group of (level, species)."""
    groups = {}
    per_map = []
    current = None
    for lineno, line in read_asm(os.path.join(pokered, "data/wild/super_rod.asm")):
        s = line.strip()
        m = re.match(r"dbw\s+(\w+),\s*\.(\w+)", s)
        if m:
            per_map.append((m.group(1), m.group(2)))
            continue
        m = re.match(r"\.(\w+):?\s*$", s)
        if m:
            current = m.group(1)
            groups[current] = []
            continue
        m = re.match(r"db\s+(\d+),\s*(\w+)$", s)
        if m and current:
            groups[current].append({"level": int(m.group(1)), "species": m.group(2)})
    out = {}
    for map_id, group in per_map:
        out[map_id] = groups.get(group, [])
    return out


def parse_trades(pokered):
    """data/events/trades.asm: npctrade give, get, dialogset, nickname."""
    # TRADE_DIALOGSET_* order (constants/script_constants.asm) indexes
    # InGameTradeTextPointers -> TradeTextPointers1/2/3
    # (engine/events/in_game_trades.asm); stored 1-based to match the
    # _WannaTrade<N>Text/_AfterTrade<N>Text/... label numbering.
    dialogsets = {
        "TRADE_DIALOGSET_CASUAL": 1,
        "TRADE_DIALOGSET_EVOLUTION": 2,
        "TRADE_DIALOGSET_HAPPY": 3,
    }
    trades = []
    for lineno, line in read_asm(os.path.join(pokered, "data/events/trades.asm")):
        m = re.match(r'npctrade\s+(\w+),\s*(\w+),\s*(\w+),\s*"([^"]*)"', line.strip())
        if m:
            trades.append({
                "give": m.group(1),   # what the NPC wants from the player
                "get": m.group(2),    # what the NPC hands over
                "dialogset": dialogsets.get(m.group(3), 1),
                "nickname": m.group(4),
            })
    return trades


def parse_hidden_events(pokered):
    """data/events/hidden_events.asm: per-map hidden_event x, y, Func, arg.

    Keeps the three data-driven kinds: HiddenItems (item pickups the
    Itemfinder detects), HiddenCoins (Game Corner floor coins) and
    StartSlotMachine (slot machine seats; arg SLOTS_* marks broken ones).
    Also collects the engine text hooks that the port implements natively:
    OpenPokemonCenterPC, PrintBenchGuyText, GymStatues and the Vermilion
    Gym GymTrashScript cans (arg = [wGymTrashCanIndex]).  For those the
    fourth macro argument is the facing direction required to trigger the
    event, except GymTrashScript where it is the can index.
    """
    items = {}
    coins = {}
    slots = {}
    extras = {"pcTiles": {}, "benchGuys": {}, "gymStatues": {}, "trashCans": []}
    current = None
    path = os.path.join(pokered, "data/events/hidden_events.asm")
    for lineno, line in read_asm(path):
        s = line.strip()
        m = re.match(r"hidden_events_for\s+(\w+)", s)
        if m:
            current = m.group(1)
            continue
        m = re.match(r"hidden_event\s+(\d+),\s*(\d+),\s*(\w+),\s*(.+)$", s)
        if not m or not current:
            continue
        x, y, func, arg = int(m.group(1)), int(m.group(2)), m.group(3), m.group(4).strip()
        if func == "HiddenItems":
            items.setdefault(current, []).append({"x": x, "y": y, "item": arg})
        elif func == "HiddenCoins":
            cm = re.match(r"COIN\s*\+\s*(\d+)", arg)
            if cm:
                coins.setdefault(current, []).append(
                    {"x": x, "y": y, "coins": int(cm.group(1))})
        elif func == "StartSlotMachine":
            state = "ok"
            if arg == "SLOTS_OUTOFORDER":
                state = "out_of_order"
            elif arg == "SLOTS_OUTTOLUNCH":
                state = "out_to_lunch"
            elif arg == "SLOTS_SOMEONESKEYS":
                state = "keys"
            slots.setdefault(current, []).append({"x": x, "y": y, "state": state})
        elif func == "OpenPokemonCenterPC":
            extras["pcTiles"].setdefault(current, []).append(
                {"x": x, "y": y, "facing": DIRS.get(arg, arg)})
        elif func == "PrintBenchGuyText":
            extras["benchGuys"].setdefault(current, []).append(
                {"x": x, "y": y, "facing": DIRS.get(arg, arg)})
        elif func == "GymStatues":
            extras["gymStatues"].setdefault(current, []).append(
                {"x": x, "y": y, "facing": DIRS.get(arg, arg)})
        elif func == "GymTrashScript":
            if current != "VERMILION_GYM":
                util.die(f"hidden_events.asm:{lineno}: GymTrashScript outside VERMILION_GYM")
            extras["trashCans"].append({"x": x, "y": y, "can": int(arg)})
    return items, coins, slots, extras


def parse_bench_guy_texts(pokered):
    """data/events/bench_guys.asm: bench_guy_text map, facing, text.

    PrintBenchGuyText (engine/events/hidden_events/bench_guys.asm) looks up
    wCurMap in this table and shows the text if the player's facing matches
    the table entry (a table bug misaligns the scan when it does not match,
    e.g. VERMILION_POKECENTER triggers facing up but its entry says left).
    """
    texts = {}
    path = os.path.join(pokered, "data/events/bench_guys.asm")
    for lineno, line in read_asm(path):
        m = re.match(r"bench_guy_text\s+(\w+),\s*(SPRITE_FACING_\w+),\s*(\w+)",
                     line.strip())
        if m:
            texts[m.group(1)] = {"facing": DIRS[m.group(2)], "text": m.group(3)}
    return texts


def parse_trash_can_puzzle(pokered, cans):
    """engine/events/hidden_events/vermilion_gym_trash.asm GymTrashScript.

    Puzzle rules (see also scripts/VermilionCity.asm .setFirstLockTrashCanIndex):
      * The first switch is placed when Vermilion City loads:
        wFirstLockTrashCanIndex = Random & $0e, i.e. one of the 8
        even-indexed cans 0,2,..,14.
      * Opening it sets EVENT_1ST_LOCK_OPENED; the second switch is then
        picked at random from the first can's row in the GymTrashCans
        adjacency table (byte 0 = candidate count, bytes 1-4 = candidate can
        indices).  A signed-offset bug can make the pick fall outside the
        row, in which case can 0 gets the second switch.
      * Searching any other can resets EVENT_1ST_LOCK_OPENED, prints the
        fail text and rerandomizes the first can (Random & $0e again).
      * Finding the second switch sets EVENT_2ND_LOCK_OPENED (doors open).
    The 15 cans sit at x = 1,3,5,7,9 / y = 7,9,11 (five map columns of
    three); can index = 3*(x-1)/2 + (y-7)/2, so adjacency entries differ by
    1 (vertical neighbour, same column) or 3 (horizontal neighbour).
    """
    path = os.path.join(pokered, "engine/events/hidden_events/vermilion_gym_trash.asm")
    adjacency = {}
    in_table = False
    text = []
    for lineno, line in read_asm(path):
        s = line.strip()
        text.append(s)
        if s == "GymTrashCans:":
            in_table = True
            continue
        if in_table:
            m = re.match(r"db\s+(\d+),\s*(\d+),\s*(\d+),\s*(\d+),\s*(\d+)$", s)
            if m:
                count = int(m.group(1))
                row = [int(m.group(i)) for i in range(2, 6)][:count]
                adjacency[len(adjacency)] = row
            elif s:
                in_table = False
    joined = "\n".join(text)
    if "and $e" not in joined or "SetEvent EVENT_2ND_LOCK_OPENED" not in joined:
        util.die("vermilion_gym_trash.asm: puzzle randomization code changed")
    if len(adjacency) != 15:
        util.die(f"vermilion_gym_trash.asm: expected 15 GymTrashCans rows, got {len(adjacency)}")
    for can in cans:
        idx = 3 * (can["x"] - 1) // 2 + (can["y"] - 7) // 2
        if idx != can["can"]:
            util.die(f"trash can index/coord mismatch: {can}")
        for adj in adjacency[can["can"]]:
            if abs(adj - can["can"]) not in (1, 3):
                util.die(f"trash can adjacency not a grid neighbour: {can['can']} -> {adj}")
    return {
        "map": "VERMILION_GYM",
        "cans": cans,
        "adjacent": adjacency,      # can index -> cans that may hold switch 2
        "firstLockCandidates": list(range(0, 15, 2)),  # Random & $0e
        "firstLockEvent": "EVENT_1ST_LOCK_OPENED",
        "secondLockEvent": "EVENT_2ND_LOCK_OPENED",
        "columns": 5, "rows": 3,    # physical layout; index = 3*(x-1)/2 + (y-7)/2
        "rules": "first switch: random even can (Random & $0e, rolled on Vermilion City load); "
                 "second switch: random can adjacent to the first (GymTrashCans table); "
                 "a wrong second can relocks and rerandomizes the first switch",
    }


def parse_slot_wheels(pokered):
    """data/events/slot_machine_wheels.asm: three symbol sequences."""
    wheels = []
    current = None
    path = os.path.join(pokered, "data/events/slot_machine_wheels.asm")
    for lineno, line in read_asm(path):
        s = line.strip()
        if re.match(r"SlotMachineWheel\d:", s):
            current = []
            wheels.append(current)
            continue
        m = re.match(r"dw\s+SLOTS(\w+)$", s)
        if m and current is not None:
            current.append(m.group(1))  # 7, MOUSE, FISH, BAR, CHERRY, BIRD
    return wheels


def parse_card_key_doors(pokered):
    """Silph Co card key doors.

    data/events/card_key_coords.asm lists the door tile coords as
    `db map, Y, X, gate id` (the three tables are unused by the engine but
    match the real door positions).  The engine (engine/events/card_key.asm
    PrintCardKeyText) instead works on any map in SilphCoMapList
    (data/events/card_key_maps.asm): if the tile in front of the player is
    $18 or $24 (locked door tiles, FACILITY tileset) -- or $5e on
    SILPH_CO_11F -- and the player has the CARD_KEY, it halves the tile
    coords to block coords and replaces that block with $0e (open door;
    $03 on SILPH_CO_11F).
    """
    doors = {}
    n_doors = 0
    path = os.path.join(pokered, "data/events/card_key_coords.asm")
    for lineno, line in read_asm(path):
        m = re.match(r"db\s+(SILPH_CO_\w+),\s*(\$\w+),\s*(\$\w+),\s*(\d+)$",
                     line.strip())
        if m:
            doors.setdefault(m.group(1), []).append(
                {"x": parse_number(m.group(3)), "y": parse_number(m.group(2)),
                 "gate": int(m.group(4))})
            n_doors += 1
    maps = []
    for lineno, line in read_asm(os.path.join(pokered, "data/events/card_key_maps.asm")):
        m = re.match(r"db\s+(SILPH_CO_\w+)$", line.strip())
        if m:
            maps.append(m.group(1))
    engine = "\n".join(l.strip() for _, l in
                       read_asm(os.path.join(pokered, "engine/events/card_key.asm")))
    for needle in ("cp $18", "cp $24", "cp $5e", "ld a, $3", "ld a, $e"):
        if needle not in engine:
            util.die(f"card_key.asm: {needle!r} not found (door tiles/blocks changed?)")
    if n_doors != 22 or len(maps) != 10:
        util.die(f"card key doors: expected 22 doors / 10 maps, got {n_doors}/{len(maps)}")
    # closedDoors is hand-ported, not extracted: no retail .blk layout places
    # a closed-door block at any of the coordinates above (the feature is
    # unused/cut in the original game), so there is no ROM or disassembly
    # source to derive this from. It restores that cut content by stamping
    # facility.bst blocks 0x54/0x5f (2F-10F) or interior.bst block 0x20
    # (11F) over each door on map load, opened by that door's
    # EVENT_SILPH_CO_n_UNLOCKED_DOORn flag. Kept in sync by hand with
    # tools/rom_manifest.json's field.cardKeyDoors.closedDoors.
    closed_doors = {
        "SILPH_CO_2F": [
            {"block": 0x54, "bx": 2, "by": 2, "event": "EVENT_SILPH_CO_2_UNLOCKED_DOOR1", "open": 0x0e},
            {"block": 0x54, "bx": 2, "by": 5, "event": "EVENT_SILPH_CO_2_UNLOCKED_DOOR2", "open": 0x0e},
        ],
        "SILPH_CO_3F": [
            {"block": 0x5f, "bx": 4, "by": 4, "event": "EVENT_SILPH_CO_3_UNLOCKED_DOOR1", "open": 0x0e},
            {"block": 0x5f, "bx": 8, "by": 4, "event": "EVENT_SILPH_CO_3_UNLOCKED_DOOR2", "open": 0x0e},
        ],
        "SILPH_CO_4F": [
            {"block": 0x54, "bx": 2, "by": 6, "event": "EVENT_SILPH_CO_4_UNLOCKED_DOOR1", "open": 0x0e},
            {"block": 0x54, "bx": 6, "by": 4, "event": "EVENT_SILPH_CO_4_UNLOCKED_DOOR2", "open": 0x0e},
        ],
        "SILPH_CO_5F": [
            {"block": 0x5f, "bx": 3, "by": 2, "event": "EVENT_SILPH_CO_5_UNLOCKED_DOOR1", "open": 0x0e},
            {"block": 0x5f, "bx": 3, "by": 6, "event": "EVENT_SILPH_CO_5_UNLOCKED_DOOR2", "open": 0x0e},
            {"block": 0x5f, "bx": 7, "by": 5, "event": "EVENT_SILPH_CO_5_UNLOCKED_DOOR3", "open": 0x0e},
        ],
        "SILPH_CO_6F": [
            {"block": 0x5f, "bx": 2, "by": 6, "event": "EVENT_SILPH_CO_6_UNLOCKED_DOOR", "open": 0x0e},
        ],
        "SILPH_CO_7F": [
            {"block": 0x54, "bx": 5, "by": 3, "event": "EVENT_SILPH_CO_7_UNLOCKED_DOOR1", "open": 0x0e},
            {"block": 0x54, "bx": 10, "by": 2, "event": "EVENT_SILPH_CO_7_UNLOCKED_DOOR2", "open": 0x0e},
            {"block": 0x54, "bx": 10, "by": 6, "event": "EVENT_SILPH_CO_7_UNLOCKED_DOOR3", "open": 0x0e},
        ],
        "SILPH_CO_8F": [
            {"block": 0x5f, "bx": 3, "by": 4, "event": "EVENT_SILPH_CO_8_UNLOCKED_DOOR", "open": 0x0e},
        ],
        "SILPH_CO_9F": [
            {"block": 0x5f, "bx": 1, "by": 4, "event": "EVENT_SILPH_CO_9_UNLOCKED_DOOR1", "open": 0x0e},
            {"block": 0x54, "bx": 9, "by": 2, "event": "EVENT_SILPH_CO_9_UNLOCKED_DOOR2", "open": 0x0e},
            {"block": 0x54, "bx": 9, "by": 5, "event": "EVENT_SILPH_CO_9_UNLOCKED_DOOR3", "open": 0x0e},
            {"block": 0x5f, "bx": 5, "by": 6, "event": "EVENT_SILPH_CO_9_UNLOCKED_DOOR4", "open": 0x0e},
        ],
        "SILPH_CO_10F": [
            {"block": 0x54, "bx": 5, "by": 4, "event": "EVENT_SILPH_CO_10_UNLOCKED_DOOR", "open": 0x0e},
        ],
        "SILPH_CO_11F": [
            {"block": 0x20, "bx": 3, "by": 6, "event": "EVENT_SILPH_CO_11_UNLOCKED_DOOR", "open": 0x03},
        ],
    }
    return {
        "maps": maps,               # maps where the engine checks for doors
        "doors": doors,             # tile coords; block coord = floor(coord/2)
        "doorTiles": [0x18, 0x24],  # locked-door tile ids (FACILITY tileset)
        "openBlock": 0x0e,          # block written over the door's block
        "silphCo11F": {"doorTile": 0x5e, "openBlock": 0x03},
        "closedDoors": closed_doors,
    }


def parse_forced_movement(pokered):
    """data/maps/force_bike_surf.asm + the Cycling Road engine handling.

    CheckForceBikeOrSurf (engine/overworld/player_state.asm) walks
    ForcedBikeOrSurfMaps; on ROUTE_16/ROUTE_18 entries it forces the bike
    (wWalkBikeSurfState = 1), on the SEAFOAM_ISLANDS entries it forces
    surfing (state 2) and kicks off the map's MOVE_OBJECT current script.

    Cycling Road slope (slopeMaps): JoypadOverworld (home/overworld.asm)
    simulates a held PAD_DOWN on ROUTE_17 whenever no d-pad/A/B input is
    held (and no trainer battle is starting); DoBikeSpeedup additionally
    suppresses the 2x bike speed on ROUTE_17 while UP/LEFT/RIGHT is held.
    """
    tiles = {}
    path = os.path.join(pokered, "data/maps/force_bike_surf.asm")
    for lineno, line in read_asm(path):
        m = re.match(r"force_bike_surf\s+(\w+),\s*(\d+),\s*(\d+)$", line.strip())
        if m:
            map_id = m.group(1)
            mode = "surf" if map_id.startswith("SEAFOAM") else "bike"
            tiles.setdefault(map_id, []).append(
                {"x": int(m.group(2)), "y": int(m.group(3)), "mode": mode})
    overworld = "\n".join(l.strip() for _, l in
                          read_asm(os.path.join(pokered, "home/overworld.asm")))
    if not re.search(r"cp ROUTE_17.*?\n(.*\n){0,4}\s*ld a, PAD_DOWN", overworld):
        util.die("home/overworld.asm: Cycling Road forced PAD_DOWN not found")
    return {"tiles": tiles, "slopeMaps": ["ROUTE_17"]}


PAD_TO_DIR = {"PAD_UP": "up", "PAD_DOWN": "down",
              "PAD_LEFT": "left", "PAD_RIGHT": "right"}


def _parse_script_tables(path):
    """Collect labelled dbmapcoord lists and `db PAD_*, n` RLE lists.

    Duplicate labels (e.g. two `.Coords` locals) get a #2, #3... suffix.
    RLE lists are returned in source order; like the spinner tables they
    are decoded into wSimulatedJoypadStatesEnd and played back with a
    decrementing index, so they execute in REVERSE source order.
    """
    coords = {}
    rle = {}
    label = None
    seen = {}
    for lineno, line in read_asm(path):
        s = line.strip()
        # local labels may omit the colon; bare instructions that happen to
        # match ("ret") just become labels no table refers to
        m = re.match(r"\.?(\w+):{0,2}$", s)
        if m:
            label = m.group(1)
            seen[label] = seen.get(label, 0) + 1
            if seen[label] > 1:
                label = f"{label}#{seen[label]}"
            continue
        m = re.match(r"dbmapcoord\s+(\d+),\s*(\d+)$", s)
        if m and label:
            coords.setdefault(label, []).append(
                {"x": int(m.group(1)), "y": int(m.group(2))})
            continue
        m = re.match(r"db\s+(PAD_\w+),\s*(\d+)$", s)
        if m and label:
            rle.setdefault(label, []).append(
                {"dir": PAD_TO_DIR[m.group(1)], "count": int(m.group(2))})
    return coords, rle


def parse_seafoam(pokered):
    """Seafoam Islands surf currents and boulder/hole wiring.

    scripts/SeafoamIslandsB3F.asm / SeafoamIslandsB4F.asm:
      * The current tiles are the SEAFOAM entries of ForcedBikeOrSurfMaps;
        stepping on one triggers the map's MOVE_OBJECT script, which (unless
        the plugging boulders' events are set) decodes an RLE movement list
        into simulated joypad presses -- executed in reverse source order,
        like the spinner tables.
      * B3F additionally sweeps the player from the surf entry at (15,8)
        toward the holes while the currents are live, and B4F force-exits
        the player upward at the pool's south edge (20..21,16..17).
      * Pushing a boulder into an upper floor's hole coords sets an
        EVENT_SEAFOAM*_BOULDER*_DOWN_HOLE flag, hides the pushed boulder
        object and shows the fallen one on the floor below (which is what
        plugs that floor's current); the holes double as dungeon warps.
    """
    b3f_coords, b3f_rle = _parse_script_tables(
        os.path.join(pokered, "scripts/SeafoamIslandsB3F.asm"))
    b4f_coords, b4f_rle = _parse_script_tables(
        os.path.join(pokered, "scripts/SeafoamIslandsB4F.asm"))
    b2f_coords, _ = _parse_script_tables(
        os.path.join(pokered, "scripts/SeafoamIslandsB2F.asm"))
    oneF_coords, _ = _parse_script_tables(
        os.path.join(pokered, "scripts/SeafoamIslands1F.asm"))
    b1f_coords, _ = _parse_script_tables(
        os.path.join(pokered, "scripts/SeafoamIslandsB1F.asm"))

    def rev(label, rle_tables):
        moves = rle_tables.get(label)
        if not moves:
            util.die(f"seafoam: missing RLE list {label}")
        return list(reversed(moves))

    def hole_wiring(script_path, holes, lands_at):
        """SetEvent / TOGGLE hide+show pairs, in source order."""
        text = "\n".join(l.strip() for _, l in read_asm(script_path))
        events = re.findall(r"SetEvent(?:ReuseHL|AfterBranchReuseHL)?\s+"
                            r"(EVENT_SEAFOAM\d_BOULDER\d_DOWN_HOLE)", text)
        toggles = re.findall(r"ld a, (TOGGLE_SEAFOAM_ISLANDS_\w+)", text)
        if len(events) != 2 or len(toggles) != 4 or len(holes) != 2:
            util.die(f"seafoam: unexpected hole wiring in {script_path}")
        out = []
        for i, hole in enumerate(holes):
            out.append({
                "x": hole["x"], "y": hole["y"],
                "boulderEvent": events[i],
                "hideObject": toggles[2 * i],
                "showObject": toggles[2 * i + 1],
                "landsAt": lands_at[i],
            })
        return out

    # fallen boulder object positions on the floor below
    def boulder_objects(objects_file):
        out = []
        for lineno, line in read_asm(os.path.join(pokered, objects_file)):
            m = re.match(r"object_event\s+(\d+),\s*(\d+),\s*SPRITE_BOULDER",
                         line.strip())
            if m:
                out.append({"x": int(m.group(1)), "y": int(m.group(2))})
        return out

    b3f_text = "\n".join(l.strip() for _, l in read_asm(
        os.path.join(pokered, "scripts/SeafoamIslandsB3F.asm")))
    m = re.search(r"ld a, \[wYCoord\]\s+cp (\d+)\s+ret nz\s+"
                  r"ld a, \[wXCoord\]\s+cp (\d+)", b3f_text)
    if not m:
        util.die("SeafoamIslandsB3F.asm: entry-current trigger coords not found")
    entry_y, entry_x = int(m.group(1)), int(m.group(2))
    if "cp 18" not in b3f_text or "cp 19" not in b3f_text:
        util.die("SeafoamIslandsB3F.asm: current tile x checks changed")

    b3f_boulders = boulder_objects("data/maps/objects/SeafoamIslandsB3F.asm")
    b4f_boulders = boulder_objects("data/maps/objects/SeafoamIslandsB4F.asm")
    b1f_boulders = boulder_objects("data/maps/objects/SeafoamIslandsB1F.asm")
    b2f_boulders = boulder_objects("data/maps/objects/SeafoamIslandsB2F.asm")
    if len(b3f_boulders) != 6 or len(b4f_boulders) != 2:
        util.die("seafoam: unexpected boulder object counts")
    # the second .Coords local in B4F is the current-tile trigger list;
    # it must agree with the hardcoded current coords below
    if b4f_coords.get("Coords#2") != [{"x": 4, "y": 14}, {"x": 5, "y": 14}]:
        util.die("SeafoamIslandsB4F.asm: current trigger coords changed")

    seafoam = {
        "SEAFOAM_ISLANDS_B3F": {
            # both currents die once these two flags are set
            "currentsDisabledByEvents": ["EVENT_SEAFOAM3_BOULDER1_DOWN_HOLE",
                                         "EVENT_SEAFOAM3_BOULDER2_DOWN_HOLE"],
            "currents": [
                {"x": 18, "y": 7,
                 "moves": rev("RLEList_StrongCurrentNearLeftBoulder", b3f_rle)},
                {"x": 19, "y": 7,
                 "moves": rev("RLEList_StrongCurrentNearRightBoulder", b3f_rle)},
            ],
            # sweeps the player from the surf entry while currents are live
            "entryCurrent": {
                "x": entry_x, "y": entry_y,
                "moves": rev("RLEList_ForcedSurfingStrongCurrentNearSteps", b3f_rle),
            },
            # pushing boulders into these B3F holes plugs the B4F current
            "holes": hole_wiring(
                os.path.join(pokered, "scripts/SeafoamIslandsB3F.asm"),
                b3f_coords.get("Seafoam4HolesCoords", []),
                b4f_boulders),
            "holeDestination": "SEAFOAM_ISLANDS_B4F",
        },
        "SEAFOAM_ISLANDS_B4F": {
            "currentsDisabledByEvents": ["EVENT_SEAFOAM4_BOULDER1_DOWN_HOLE",
                                         "EVENT_SEAFOAM4_BOULDER2_DOWN_HOLE"],
            "currents": [
                {"x": 4, "y": 14,
                 "moves": rev("RLEList_StrongCurrentNearLeftBoulder", b4f_rle)},
                {"x": 5, "y": 14,
                 "moves": rev("RLEList_StrongCurrentNearRightBoulder", b4f_rle)},
            ],
            # while the B3F boulders are NOT both down, standing here forces
            # the player up out of the water (2 up-presses on row 17, 1 on 16)
            "forcedExit": {
                "coords": b4f_coords.get("Coords", []),
                "activeUntilEvents": ["EVENT_SEAFOAM3_BOULDER1_DOWN_HOLE",
                                      "EVENT_SEAFOAM3_BOULDER2_DOWN_HOLE"],
            },
        },
    }
    # the B3F current tiles are plugged by boulders pushed through the B2F
    # holes (scripts/SeafoamIslandsB2F.asm Seafoam3HolesCoords); the fallen
    # boulders are the last two B3F boulder objects, at (18,6)/(19,6) just
    # above the current tiles (data/maps/toggleable_objects.asm maps
    # TOGGLE_..._B3F_BOULDER_3/4 to SEAFOAMISLANDSB3F_BOULDER5/6)
    seafoam["SEAFOAM_ISLANDS_B3F"]["pluggedByHolesOn"] = {
        "map": "SEAFOAM_ISLANDS_B2F",
        "holes": hole_wiring(
            os.path.join(pokered, "scripts/SeafoamIslandsB2F.asm"),
            b2f_coords.get("Seafoam3HolesCoords", []),
            b3f_boulders[-2:]),
    }
    # pushing 1F's boulders into Seafoam1HolesCoords drops them to B1F, and
    # B1F's into Seafoam2HolesCoords drops them to B2F (scripts/
    # SeafoamIslands1F.asm / SeafoamIslandsB1F.asm); this is the upper half
    # of the same cascade that pluggedByHolesOn wires for B2F->B3F.
    seafoam["SEAFOAM_ISLANDS_1F"] = {
        "holes": hole_wiring(
            os.path.join(pokered, "scripts/SeafoamIslands1F.asm"),
            oneF_coords.get("Seafoam1HolesCoords", []),
            b1f_boulders),
        "holeDestination": "SEAFOAM_ISLANDS_B1F",
    }
    seafoam["SEAFOAM_ISLANDS_B1F"] = {
        "holes": hole_wiring(
            os.path.join(pokered, "scripts/SeafoamIslandsB1F.asm"),
            b1f_coords.get("Seafoam2HolesCoords", []),
            b2f_boulders),
        "holeDestination": "SEAFOAM_ISLANDS_B2F",
    }
    return seafoam


def parse_game_corner_poster(pokered):
    """scripts/GameCorner.asm: the poster switch that opens the hideout.

    Examining the poster (bg_event TEXT_GAMECORNER_POSTER) runs
    GameCornerPosterText, which sets EVENT_FOUND_ROCKET_HIDEOUT and
    replaces the tile block at block coords (8,2) -- the top-right corner
    of the room -- with the staircase block $43 (ReplaceTileBlock takes
    b=Y, c=X block coords).  On map load,
    GameCornerSetRocketHideoutDoorTile writes the closed block $2a over
    the same block while the event is unset.
    """
    text = "\n".join(l.strip() for _, l in read_asm(
        os.path.join(pokered, "scripts/GameCorner.asm")))
    closed = re.search(r"CheckEvent EVENT_FOUND_ROCKET_HIDEOUT\s+ret nz\s+"
                       r"ld a, (\$\w+)\s+ld \[wNewTileBlockID\], a\s+"
                       r"lb bc, (\d+), (\d+)", text)
    opened = re.search(r"SetEvent EVENT_FOUND_ROCKET_HIDEOUT\s+"
                       r"ld a, (\$\w+)\s+ld \[wNewTileBlockID\], a\s+"
                       r"lb bc, (\d+), (\d+)", text)
    if not closed or not opened or closed.group(2, 3) != opened.group(2, 3):
        util.die("GameCorner.asm: poster block swap not found")
    poster = None
    for lineno, line in read_asm(os.path.join(pokered,
                                              "data/maps/objects/GameCorner.asm")):
        m = re.match(r"bg_event\s+(\d+),\s*(\d+),\s*(TEXT_GAMECORNER_POSTER)",
                     line.strip())
        if m:
            poster = {"x": int(m.group(1)), "y": int(m.group(2))}
    if poster is None:
        util.die("objects/GameCorner.asm: poster bg_event not found")
    return {
        "map": "GAME_CORNER",
        "x": int(opened.group(3)),  # block coords (c = X)
        "y": int(opened.group(2)),  # block coords (b = Y)
        "closedBlock": parse_number(closed.group(1)),
        "openBlock": parse_number(opened.group(1)),
        "event": "EVENT_FOUND_ROCKET_HIDEOUT",
        "posterText": "TEXT_GAMECORNER_POSTER",
        "poster": poster,           # bg_event tile coords of the poster
    }


def parse_badge_gates(pokered):
    """scripts/Route22Gate.asm and scripts/Route23.asm badge checks.

    Route 22 gate: standing on Route22GateScriptCoords triggers the guard,
    who checks BIT_BOULDERBADGE in wObtainedBadges.

    Route 23: Route23DefaultScript matches wYCoord against
    Route23GuardsYCoords; row i (top to bottom) is guarded by sprite i+1
    and requires the badge at BadgeTextPointers[N-1-i] (EARTHBADGE at the
    northernmost row down to CASCADEBADGE at the southernmost).  The
    y=35 row only applies at x < 14.  Passing a guard sets its
    EVENT_PASSED_<badge>_CHECK flag so it is skipped afterwards.
    """
    r22_lines = read_asm(os.path.join(pokered, "scripts/Route22Gate.asm"))
    r22_text = "\n".join(l.strip() for _, l in r22_lines)
    if "bit BIT_BOULDERBADGE" not in r22_text:
        util.die("Route22Gate.asm: BOULDERBADGE check not found")
    r22_coords, _ = _parse_script_tables(
        os.path.join(pokered, "scripts/Route22Gate.asm"))
    coords = r22_coords.get("Route22GateScriptCoords", [])

    ys = []
    badge_ptr_labels = []
    badge_names = {}
    text_labels = []
    label = None
    in_ys = in_ptrs = in_texts = False
    for lineno, line in read_asm(os.path.join(pokered, "scripts/Route23.asm")):
        s = line.strip()
        m = re.match(r"(\w+)::?\s*$", s)
        if m:
            label = m.group(1)
            in_ys = label == "Route23GuardsYCoords"
            in_ptrs = label == "BadgeTextPointers"
            continue
        if s == "def_text_pointers":
            in_texts = True
            continue
        if in_texts:
            m = re.match(r"dw_const\s+(\w+),\s*(\w+)$", s)
            if m:
                text_labels.append(m.group(1))
                continue
            in_texts = False
        if in_ys:
            m = re.match(r"db\s+(\d+)$", s)
            if m:
                ys.append(int(m.group(1)))
        elif in_ptrs:
            m = re.match(r"dw\s+(\w+)$", s)
            if m:
                badge_ptr_labels.append(m.group(1))
        m = re.match(r'db\s+"(\w+)@"$', s)
        if m and label:
            badge_names[label] = m.group(1)

    if len(ys) != 7 or len(badge_ptr_labels) != 7:
        util.die("Route23.asm: expected 7 guard rows and 7 badge pointers")
    guards = []
    for i, y in enumerate(ys):
        badge = badge_names.get(badge_ptr_labels[len(ys) - 1 - i])
        if not badge:
            util.die(f"Route23.asm: no badge name for row y={y}")
        guard = {
            "y": y,
            "badge": badge,
            "event": f"EVENT_PASSED_{badge}_CHECK",
            "sprite": i + 1,
            "text": text_labels[i] if i < len(text_labels) else None,
        }
        if i == 0:
            guard["maxX"] = 13  # y=35 row is skipped at wXCoord >= 14
        guards.append(guard)
    events = "\n".join(l.strip() for _, l in read_asm(
        os.path.join(pokered, "constants/event_constants.asm")))
    for g in guards:
        if g["event"] not in events:
            util.die(f"Route23: {g['event']} not in event_constants.asm")
    return {
        "ROUTE_22_GATE": {
            "coords": coords,
            "badge": "BOULDERBADGE",
            "text": "Route22GateGuardText",
            "failText": "Route22GateGuardNoBoulderbadgeText",
            "passText": "Route22GateGuardGoRightAheadText",
        },
        "ROUTE_23": {
            "guards": guards,
            "failText": "Route23YouDontHaveTheBadgeYetText",
            "passText": "Route23OhThatIsTheBadgeText",
        },
    }


def parse_preset_names(pokered):
    """constants/player_constants.asm: the _RED preset name menus.

    The naming menus (engine/movie/oak_speech/oak_speech2.asm with
    data/player/names.asm / names_list.asm) offer NEW NAME plus these
    three presets each.
    """
    # read_asm resolves the version conditionals (util.ASM_DEFINES), so
    # only the _RED name set reaches us
    player, rival = [], []
    path = os.path.join(pokered, "constants/player_constants.asm")
    for lineno, line in read_asm(path):
        s = line.strip()
        m = re.match(r'DEF\s+PLAYERNAME\d\s+EQUS\s+"(\w+)"', s)
        if m:
            player.append(m.group(1))
        m = re.match(r'DEF\s+RIVALNAME\d\s+EQUS\s+"(\w+)"', s)
        if m:
            rival.append(m.group(1))
    return {"player": player, "rival": rival, "customOption": "NEW NAME"}


def parse_dark_maps(pokered):
    """Rock Tunnel darkness (home/overworld.asm).

    Warping into ROCK_TUNNEL_1F sets wMapPalOffset = 6, blacking the
    screen out until Flash is used.  The offset is only cleared when
    leaving through a LAST_MAP warp back outside (or via Flash), so it
    persists across the indoor warps into ROCK_TUNNEL_B1F -- both floors
    are dark.  Flash (engine/menus/start_sub_menus.asm .flash) needs
    BOULDERBADGE and simply zeroes wMapPalOffset.
    """
    overworld = "\n".join(l.strip() for _, l in
                          read_asm(os.path.join(pokered, "home/overworld.asm")))
    if not re.search(r"cp ROCK_TUNNEL_1F\s+jr nz, \.notRockTunnel\s+"
                     r"ld a, \$06\s+ld \[wMapPalOffset\], a", overworld):
        util.die("home/overworld.asm: Rock Tunnel darkness code changed")
    return {
        "maps": ["ROCK_TUNNEL_1F", "ROCK_TUNNEL_B1F"],
        "entryMap": "ROCK_TUNNEL_1F",  # the only map that sets the offset
        "palOffset": 6,
        "flashBadge": "BOULDERBADGE",
    }


def parse_warp_carpets(pokered):
    """data/tilesets/warp_carpet_tile_ids.asm + the ExtraWarpCheck routing.

    A warp fires without stepping onto a door/warp tile when the player
    stands on the warp square and ExtraWarpCheck (home/overworld.asm)
    passes -- either on a collision (CheckWarpsCollision) or on arrival
    with the d-pad held (CheckWarpsNoCollision).  The check itself is:
      * "function 2" (IsWarpTileInFrontOfPlayer): the tile in front of the
        player is in the facing direction's warp-carpet list -- used on the
        OVERWORLD/SHIP/SHIP_PORT/PLATEAU tilesets plus the four map
        exceptions in function2Maps, with SS_ANNE_BOW checking tile $15
        instead of the lists;
      * "function 1" (IsPlayerFacingEdgeOfMap) everywhere else (and on
        SS_ANNE_3F): the player faces the edge of the map.
    """
    dir_labels = {"FacingDownWarpTiles": "down", "FacingUpWarpTiles": "up",
                  "FacingLeftWarpTiles": "left", "FacingRightWarpTiles": "right"}
    carpets = {}
    label = None
    path = os.path.join(pokered, "data/tilesets/warp_carpet_tile_ids.asm")
    for lineno, line in read_asm(path):
        s = line.strip()
        m = re.match(r"\.(\w+):$", s)
        if m:
            label = dir_labels.get(m.group(1))
            continue
        m = re.match(r"warp_carpet_tiles\s+(.+)$", s)
        if m and label:
            carpets[label] = [parse_number(a) for a in split_args(m.group(1))]
            label = None
    if sorted(carpets) != ["down", "left", "right", "up"]:
        util.die("warp_carpet_tile_ids.asm: missing facing direction lists")

    overworld = "\n".join(l.strip() for _, l in
                          read_asm(os.path.join(pokered, "home/overworld.asm")))
    m = re.search(r"ExtraWarpCheck::\n(.*?)\.doBankswitch", overworld, re.S)
    if not m:
        util.die("home/overworld.asm: ExtraWarpCheck not found")
    body = m.group(1)
    map_part, tileset_marker, tileset_part = \
        body.partition("ld a, [wCurMapTileset]")
    function2_maps = re.findall(r"cp (\w+)\njr z, \.useFunction2", map_part)
    edge_maps = re.findall(r"cp (\w+)\njr z, \.useFunction1", map_part)
    # `and a` tests for tileset 0 = OVERWORLD
    function2_tilesets = ["OVERWORLD"] + re.findall(
        r"cp (\w+)\njr z, \.useFunction2", tileset_part)
    if not tileset_marker or "and a\njr z, .useFunction2" not in tileset_part \
       or function2_maps != ["ROCKET_HIDEOUT_B1F", "ROCKET_HIDEOUT_B2F",
                             "ROCKET_HIDEOUT_B4F", "ROCK_TUNNEL_1F"] \
       or edge_maps != ["SS_ANNE_3F"] \
       or function2_tilesets != ["OVERWORLD", "SHIP", "SHIP_PORT", "PLATEAU"]:
        util.die("home/overworld.asm: ExtraWarpCheck routing changed")

    player_state = "\n".join(l.strip() for _, l in read_asm(
        os.path.join(pokered, "engine/overworld/player_state.asm")))
    m = re.search(r"IsSSAnneBowWarpTileInFrontOfPlayer:\n"
                  r"ld a, \[wTileInFrontOfPlayer\]\ncp (\$\w+)", player_state)
    if not m:
        util.die("player_state.asm: SS Anne bow warp tile check not found")
    return {
        "tiles": carpets,               # facing dir -> tile-in-front ids
        "function2Maps": function2_maps,
        "edgeMaps": edge_maps,          # tileset would say carpet; map says edge
        "function2Tilesets": function2_tilesets,
        "ssAnneBow": {"map": "SS_ANNE_BOW", "tile": parse_number(m.group(1))},
    }


def parse_dungeon_transition_maps(pokered):
    """data/maps/dungeon_maps.asm: the battle-transition dungeon lists.

    GetBattleTransitionID_IsDungeonMap checks wCurMap against the singles
    in DungeonMaps1 and the inclusive id ranges in DungeonMaps2 (the lists
    famously miss several dungeons -- kept as-is on purpose).
    """
    singles, ranges = [], []
    section = None
    path = os.path.join(pokered, "data/maps/dungeon_maps.asm")
    for lineno, line in read_asm(path):
        s = line.strip()
        if s == "DungeonMaps1:":
            section = singles
            continue
        if s == "DungeonMaps2:":
            section = ranges
            continue
        m = re.match(r"db\s+(\w+),\s*(\w+)$", s)
        if m and section is ranges:
            ranges.append({"first": m.group(1), "last": m.group(2)})
            continue
        m = re.match(r"db\s+(\w+)$", s)
        if m and m.group(1) != "-1" and section is singles:
            singles.append(m.group(1))
    return {"maps": singles, "ranges": ranges}


def parse_bike_riding(pokered):
    """data/tilesets/bike_riding_tilesets.asm + IsBikeRidingAllowed.

    The bike may be ridden on maps whose tileset is in the list, plus the
    ROUTE_23 / INDIGO_PLATEAU map exceptions (home/overworld.asm).
    """
    tilesets = []
    path = os.path.join(pokered, "data/tilesets/bike_riding_tilesets.asm")
    for lineno, line in read_asm(path):
        m = re.match(r"db\s+(\w+)$", line.strip())
        if m and m.group(1) != "-1":
            tilesets.append(m.group(1))
    overworld = "\n".join(l.strip() for _, l in
                          read_asm(os.path.join(pokered, "home/overworld.asm")))
    body = overworld[overworld.find("IsBikeRidingAllowed::"):]
    body = body[:body.find("ld a, [wCurMapTileset]")]  # map checks come first
    maps = re.findall(r"cp (\w+)\njr z, \.allowed", body)
    if maps != ["ROUTE_23", "INDIGO_PLATEAU"]:
        util.die("home/overworld.asm: IsBikeRidingAllowed map exceptions changed")
    return {"tilesets": tilesets, "maps": maps}


def parse_indoor_encounters(pokered):
    """engine/battle/wild_encounters.asm indoor rule.

    On maps with id >= FIRST_INDOOR_MAP whose tileset is not FOREST, every
    walkable tile rolls grass-table encounters (caves, towers, the Mansion).
    """
    wild = "\n".join(l.strip() for _, l in read_asm(
        os.path.join(pokered, "engine/battle/wild_encounters.asm")))
    if not re.search(r"cp FIRST_INDOOR_MAP.*\njr c, \.CantEncounter2\n"
                     r"ld a, \[wCurMapTileset\]\ncp FOREST", wild):
        util.die("wild_encounters.asm: indoor encounter rule changed")
    _, first_indoor, _ = parse_map_constants(pokered)
    return {"firstIndoorMap": first_indoor, "excludedTileset": "FOREST"}


# The three maps with spinner arrow tiles keep their movement tables in
# their map scripts (map_coord_movement x, y -> RLE list; each list is
# read backwards from the terminator -- see scripts/RocketHideoutB2F.asm).
SPINNER_SCRIPTS = {
    "VIRIDIAN_GYM": "ViridianGym.asm",
    "ROCKET_HIDEOUT_B2F": "RocketHideoutB2F.asm",
    "ROCKET_HIDEOUT_B3F": "RocketHideoutB3F.asm",
}

PAD_DIRS = {"PAD_UP": "up", "PAD_DOWN": "down",
            "PAD_LEFT": "left", "PAD_RIGHT": "right"}


def parse_spinners(pokered):
    spinners = {}
    for map_id, fname in sorted(SPINNER_SCRIPTS.items()):
        path = os.path.join(pokered, "scripts", fname)
        table = []      # (x, y, label)
        lists = {}      # label -> [(dir, count)] in source order
        current_list = None
        in_table = False
        for lineno, line in read_asm(path):
            s = line.strip()
            m = re.match(r"map_coord_movement\s+(\d+),\s*(\d+),\s*(\w+)", s)
            if m:
                in_table = True
                table.append((int(m.group(1)), int(m.group(2)), m.group(3)))
                continue
            m = re.match(r"(\w*ArrowMovement\w*):", s)
            if m:
                current_list = []
                lists[m.group(1)] = current_list
                continue
            m = re.match(r"db\s+(PAD_\w+),\s*(\d+)", s)
            if m and current_list is not None:
                current_list.append((PAD_DIRS[m.group(1)], int(m.group(2))))
                continue
            if s.startswith("db -1") and current_list is not None:
                current_list = None
        entries = []
        for x, y, label in table:
            moves = lists.get(label)
            if moves is None:
                util.die(f"spinners: {fname}: missing movement list {label}")
            # lists execute from the terminator backwards
            entries.append({"x": x, "y": y,
                            "moves": [{"dir": d, "count": c}
                                      for d, c in reversed(moves)]})
        if not entries:
            util.die(f"spinners: {fname}: no arrow tile table found")
        spinners[map_id] = entries
    return spinners


def parse_map_constants(pokered):
    """constants/map_constants.asm: ordered map ids + indoor group markers.

    Returns (maps, first_indoor, groups) where groups is an ordered list of
    (group_name, boundary): INDOORGROUP_<name> equals the map id AFTER the
    group's last map (end_indoor_group defines it as const_value).
    """
    maps = []
    groups = []
    first_indoor = None
    path = os.path.join(pokered, "constants/map_constants.asm")
    for lineno, line in read_asm(path):
        s = line.strip()
        m = re.match(r"map_const\s+(\w+),", s)
        if m:
            maps.append(m.group(1))
            continue
        m = re.match(r"end_indoor_group\s+(\w+)$", s)
        if m:
            groups.append((m.group(1), len(maps)))
            continue
        if re.match(r"DEF\s+FIRST_INDOOR_MAP\b", s):
            first_indoor = len(maps)
    if not maps or first_indoor is None or not groups:
        util.die("map_constants.asm: could not parse map ids/indoor groups")
    return maps, first_indoor, groups


def parse_town_map(pokered):
    """data/maps/town_map_entries.asm (+ names.asm, town_map_order.asm).

    Every map gets a town-map position and display name:
      * outdoor maps (id < FIRST_INDOOR_MAP) index ExternalMapEntries
        directly; `outdoor_map x, y, Name` stores `dn y, x` + name pointer.
      * indoor maps are looked up in InternalMapEntries by LoadTownMapEntry
        (engine/items/town_map.asm): the first entry whose INDOORGROUP_*
        boundary exceeds the map id wins, so one entry covers a contiguous
        id range (`indoor_map GROUP, x, y, Name`).
    Coordinates are a 16x16 nybble grid; the cursor/player marker is drawn
    at pixel (x*8 + 24, y*8 + 24) in OAM coords (TownMapCoordsToOAMCoords),
    i.e. an 8px grid over the 160x144 map screen.  Routes only get a single
    x,y point in this data (no spans).  TownMapOrder is the SELECT-cursor
    order when scrolling through locations.
    """
    maps, first_indoor, groups = parse_map_constants(pokered)

    names = {}
    for lineno, line in read_asm(os.path.join(pokered, "data/maps/names.asm")):
        m = re.match(r'(\w+):\s*db\s+"([^"]*)"', line.strip())
        if m:
            names[m.group(1)] = text.decode_string(m.group(2), lineno,
                                                   "data/maps/names.asm")

    external = []   # (x, y, name label), index = map id
    internal = []   # (group, x, y, name label)
    path = os.path.join(pokered, "data/maps/town_map_entries.asm")
    for lineno, line in read_asm(path):
        s = line.strip()
        m = re.match(r"outdoor_map\s+(\d+),\s*(\d+),\s*(\w+)$", s)
        if m:
            external.append((int(m.group(1)), int(m.group(2)), m.group(3)))
            continue
        m = re.match(r"indoor_map\s+(\w+),\s*(\d+),\s*(\d+),\s*(\w+)$", s)
        if m:
            internal.append((m.group(1), int(m.group(2)), int(m.group(3)),
                             m.group(4)))
    if len(external) != first_indoor:
        util.die(f"town map: {len(external)} outdoor entries != FIRST_INDOOR_MAP "
                 f"({first_indoor})")
    if [g for g, _ in groups] != [e[0] for e in internal]:
        util.die("town map: indoor_map groups do not match map_constants.asm")

    def entry(x, y, label):
        if label not in names or not (0 <= x <= 15 and 0 <= y <= 15):
            util.die(f"town map: bad entry {x},{y},{label}")
        return {"x": x, "y": y, "name": names[label]}

    locations = {}
    for map_id, (x, y, label) in zip(maps[:first_indoor], external):
        if not map_id.startswith("UNUSED_MAP"):
            locations[map_id] = entry(x, y, label)
    prev = first_indoor
    for (group, x, y, label), (_, boundary) in zip(internal, groups):
        if boundary <= prev or boundary > len(maps):
            util.die(f"town map: group {group} boundary {boundary} out of order")
        for map_id in maps[prev:boundary]:
            if not map_id.startswith("UNUSED_MAP"):
                locations[map_id] = entry(x, y, label)
        prev = boundary
    if prev != len(maps):
        util.die("town map: indoor groups do not cover all maps")

    cursor_order = []
    started = False
    for lineno, line in read_asm(os.path.join(pokered, "data/maps/town_map_order.asm")):
        s = line.strip()
        if s == "TownMapOrder:":
            started = True
            continue
        m = re.match(r"db\s+(\w+)$", s)
        if started and m:
            cursor_order.append(m.group(1))
    for map_id in cursor_order:
        if map_id not in locations:
            util.die(f"town map: cursor order map {map_id} has no entry")

    return {
        "locations": locations,     # map id -> {x, y, name} (16x16 grid)
        "cursorOrder": cursor_order,
        "gridPixelSize": 8,         # marker pixel = coord*8 + 24 (OAM coords)
    }


def parse_credits(pokered):
    """The end-credits roll (engine/movie/credits.asm Credits).

    data/credits/credits_order.asm is a byte stream: CRED_* string ids
    accumulate lines on the current screen, and CRED_TEXT / CRED_TEXT_FADE
    / CRED_TEXT_MON / CRED_TEXT_FADE_MON terminate it (FADE = palette
    fade-in, MON = scroll in the next CreditsMons entry afterwards).
    CRED_COPYRIGHT draws the copyright logo (the `title.copyright` asset)
    on the current screen; CRED_THE_END ends the roll and shows the
    the_end graphic.  Each string in credits_text.asm starts with a signed
    db: the x offset from column 9 where the line is placed (lines are
    printed at rows 6, 8, 10, ... of the screen).
    """
    cred_names = util.parse_const_block(
        os.path.join(pokered, "constants/credits_constants.asm"),
        stop_at="NUM_CRED_STRINGS")

    # CreditsTextPointers: CRED_* value -> string label
    pointers = []
    strings = {}
    skip = False
    label = None
    path = os.path.join(pokered, "data/credits/credits_text.asm")
    for lineno, line in read_asm(path):
        s = line.strip()
        if re.match(r"IF\s+DEF\(_RED\)", s):
            continue
        if re.match(r"IF\s+DEF\(", s):
            skip = True
            continue
        if s == "ENDC":
            skip = False
            continue
        if skip:
            continue
        m = re.match(r"dw\s+(\w+)$", s)
        if m:
            pointers.append(m.group(1))
            continue
        m = re.match(r"(\w+):$", s)
        if m and m.group(1) != "CreditsTextPointers":
            label = m.group(1)
            continue
        m = re.match(r'db\s+(-\d+),\s*"([^"]*)"$', s)
        if m and label:
            strings[label] = {
                "column": 9 + int(m.group(1)),   # hlcoord 9,6 + signed offset
                "text": text.decode_string(m.group(2), lineno,
                                           "data/credits/credits_text.asm"),
            }
    if len(pointers) != len(cred_names) or any(n is None for n in cred_names):
        util.die("credits: text pointer table does not match CRED_* constants")

    mons = []
    for lineno, line in read_asm(os.path.join(pokered, "data/credits/credits_mons.asm")):
        m = re.match(r"db\s+(\w+)$", line.strip())
        if m:
            mons.append(m.group(1))

    cred_index = {name: i for i, name in enumerate(cred_names)}
    commands = {"CRED_TEXT": (False, False), "CRED_TEXT_FADE": (True, False),
                "CRED_TEXT_MON": (False, True), "CRED_TEXT_FADE_MON": (True, True)}
    screens = []
    current = {"lines": []}
    the_end_seen = False
    mon_count = 0
    path = os.path.join(pokered, "data/credits/credits_order.asm")
    for lineno, line in read_asm(path):
        m = re.match(r"db\s+(.+)$", line.strip())
        if not m:
            continue
        for tok in split_args(m.group(1)):
            if the_end_seen:
                util.die("credits_order.asm: data after CRED_THE_END")
            if tok in commands:
                fade, mon = commands[tok]
                current["fade"] = fade
                if mon:
                    if mon_count >= len(mons):
                        util.die("credits_order.asm: more MON screens than CreditsMons")
                    current["mon"] = mons[mon_count]
                    mon_count += 1
                screens.append(current)
                current = {"lines": []}
            elif tok == "CRED_COPYRIGHT":
                current["copyright"] = True
            elif tok == "CRED_THE_END":
                the_end_seen = True
            elif tok in cred_index:
                label = pointers[cred_index[tok]]
                if label not in strings:
                    util.die(f"credits_order.asm:{lineno}: no string for {tok}")
                current["lines"].append(dict(strings[label]))
            else:
                util.die(f"credits_order.asm:{lineno}: unknown token {tok}")
    if not the_end_seen or current["lines"]:
        util.die("credits_order.asm: missing CRED_THE_END terminator")
    if mon_count != len(mons):
        util.die(f"credits: {len(mons)} CreditsMons but {mon_count} MON screens")
    return {
        "screens": screens,     # {lines = {{text, column}...}, fade, mon?, copyright?}
        "mons": mons,           # CreditsMons, consumed in order by MON screens
    }


def parse_old_man_battle(pokered):
    """scripts/ViridianCity.asm: the old man's catch-demo wild battle.

    ViridianCityOldManStartCatchTrainingScript sets wBattleType =
    BATTLE_TYPE_OLD_MAN, wCurEnemyLevel = 5 and wCurOpponent = WEEDLE;
    engine/battle/core.asm special-cases that battle type (the player's
    name is temporarily swapped for OLD MAN, the source of the MissingNo.
    glitch).  The end script shows the "you need to weaken the target"
    text afterwards.
    """
    script = "\n".join(l.strip() for _, l in read_asm(
        os.path.join(pokered, "scripts/ViridianCity.asm")))
    m = re.search(r"ld a, BATTLE_TYPE_OLD_MAN\s+ld \[wBattleType\], a\s+"
                  r"ld a, (\d+)\s+ld \[wCurEnemyLevel\], a\s+"
                  r"ld a, (\w+)\s+ld \[wCurOpponent\], a", script)
    if not m:
        util.die("ViridianCity.asm: old man battle setup not found")
    core = "\n".join(l.strip() for _, l in read_asm(
        os.path.join(pokered, "engine/battle/core.asm")))
    if "ASSERT BATTLE_TYPE_OLD_MAN == 1" not in core:
        util.die("core.asm: old man battle type handling changed")
    texts = {}
    for text_id, key in (("TEXT_VIRIDIANCITY_OLD_MAN", "text"),
                         ("TEXT_VIRIDIANCITY_OLD_MAN_YOU_NEED_TO_WEAKEN_THE_TARGET",
                          "afterText")):
        tm = re.search(rf"dw_const\s+(\w+),\s+{text_id}$", script, re.M)
        if not tm:
            util.die(f"ViridianCity.asm: {text_id} not found")
        texts[key] = tm.group(1)
    return {
        "map": "VIRIDIAN_CITY",
        "species": m.group(2),
        "level": int(m.group(1)),
        "battleType": "BATTLE_TYPE_OLD_MAN",
        "text": texts["text"],              # ViridianCityOldManText
        "afterText": texts["afterText"],    # ...YouNeedToWeakenTheTargetText
    }


def parse_coin_purchases(pokered):
    """scripts/GameCorner.asm GameCornerClerk1Text: coins for money.

    The only purchase the script implements is 50 coins for ¥1000 (BCD:
    hMoney = 00 10 00, hCoins = 00 50); text/GameCorner.asm's dialogue
    ("It's ¥1000 for 50 coins") matches.  There is NO 500-coin/¥10000
    option in Red.  Requires the COIN_CASE and room for the coins
    (Has9990Coins must carry).
    """
    script = "\n".join(l.strip() for _, l in read_asm(
        os.path.join(pokered, "scripts/GameCorner.asm")))
    buys = re.findall(
        r"xor a\s+ldh \[hMoney\], a\s+ldh \[hMoney \+ 2\], a\s+"
        r"ld a, \$(\d+)\s+ldh \[hMoney \+ 1\], a\s+"
        r"ld hl, hMoney \+ 2\s+ld de, wPlayerMoney \+ 2\s+ld c, \$3\s+"
        r"predef SubBCDPredef\s+"
        r"xor a\s+ldh \[hUnusedCoinsByte\], a\s+ldh \[hCoins\], a\s+"
        r"ld a, \$(\d+)\s+ldh \[hCoins \+ 1\], a", script)
    if len(buys) != 1:
        util.die(f"GameCorner.asm: expected exactly 1 coin purchase, got {len(buys)}")
    money_mid, coins_low = buys[0]
    # BCD: hMoney = 00 <mid> 00, hCoins = 00 <low>
    price = int(f"00{money_mid}00")
    coins = int(f"00{coins_low}")
    dialogue = "\n".join(l.strip() for _, l in read_asm(
        os.path.join(pokered, "text/GameCorner.asm")))
    if f"¥{price} for {coins}" not in dialogue:
        util.die("GameCorner text/script coin purchase mismatch")
    return [{"coins": coins, "price": price}]


def parse_pc_item_cap(pokered):
    """constants/menu_constants.asm PC_ITEM_CAPACITY (wNumBoxItems size).

    engine/items/inventory.asm AddItemToInventory uses it as the cap when
    hl = wNumBoxItems (`ld d, PC_ITEM_CAPACITY`).
    """
    cap = None
    path = os.path.join(pokered, "constants/menu_constants.asm")
    for lineno, line in read_asm(path):
        m = re.match(r"DEF\s+PC_ITEM_CAPACITY\s+EQU\s+(\d+)$", line.strip())
        if m:
            cap = int(m.group(1))
    if cap is None:
        util.die("menu_constants.asm: PC_ITEM_CAPACITY not found")
    inventory = "\n".join(l.strip() for _, l in read_asm(
        os.path.join(pokered, "engine/items/inventory.asm")))
    if "ld d, PC_ITEM_CAPACITY" not in inventory:
        util.die("inventory.asm: PC_ITEM_CAPACITY use not found")
    return cap


def extract(pokered, out_dir):
    ledges = []
    for lineno, line in read_asm(os.path.join(pokered, "data/tilesets/ledge_tiles.asm")):
        m = re.match(r"db\s+(SPRITE_FACING_\w+),\s*(\$\w+),\s*(\$\w+),\s*PAD_(\w+)", line.strip())
        if m:
            ledges.append({
                "facing": DIRS[m.group(1)],
                "standingTile": parse_number(m.group(2)),
                "ledgeTile": parse_number(m.group(3)),
                "input": m.group(4).lower(),
            })

    cut_trees = []
    for lineno, line in read_asm(os.path.join(pokered, "data/tilesets/cut_tree_blocks.asm")):
        m = re.match(r"db\s+(\$\w+),\s*(\$\w+)$", line.strip())
        if m:
            cut_trees.append({"before": parse_number(m.group(1)),
                              "after": parse_number(m.group(2))})

    water = []
    started = False
    for lineno, line in read_asm(os.path.join(pokered, "data/tilesets/water_tilesets.asm")):
        s = line.strip()
        if s.startswith("WaterTilesets"):
            started = True
            continue
        m = re.match(r"db\s+(\w+)$", s)
        if started and m and m.group(1) != "-1":
            water.append(m.group(1))

    # tile-pair collisions (data/tilesets/pair_collision_tile_ids.asm):
    # you may not cross between tile1 and tile2 in the given tileset --
    # elevation edges in caves and the forest.  Land pairs apply while
    # walking; water pairs while surfing.
    tile_pairs = {"land": [], "water": []}
    group = None
    for lineno, line in read_asm(
            os.path.join(pokered, "data/tilesets/pair_collision_tile_ids.asm")):
        s = line.strip()
        if s.startswith("TilePairCollisionsLand"):
            group = "land"
            continue
        if s.startswith("TilePairCollisionsWater"):
            group = "water"
            continue
        m = re.match(r"db\s+(\w+),\s*(\$\w+),\s*(\$\w+)", s)
        if group and m:
            tile_pairs[group].append({
                "tileset": m.group(1),
                "a": parse_number(m.group(2)),
                "b": parse_number(m.group(3)),
            })

    trades = parse_trades(pokered)
    fly_warps, fly_order = parse_fly_warps(pokered)
    super_rod = parse_super_rod(pokered)
    hidden_items, hidden_coins, slot_machines, extras = parse_hidden_events(pokered)
    slot_wheels = parse_slot_wheels(pokered)
    spinners = parse_spinners(pokered)

    # resolve bench guy texts (map -> text label + facing the engine checks)
    bench_texts = parse_bench_guy_texts(pokered)
    for map_id, guys in extras["benchGuys"].items():
        entry = bench_texts.get(map_id)
        for guy in guys:
            if entry:
                guy["text"] = entry["text"]
                guy["textFacing"] = entry["facing"]
    hidden_extras = {
        "pcTiles": extras["pcTiles"],
        "benchGuys": extras["benchGuys"],
        "gymStatues": extras["gymStatues"],
        "trashCans": parse_trash_can_puzzle(pokered, extras["trashCans"]),
    }

    card_key_doors = parse_card_key_doors(pokered)
    forced_movement = parse_forced_movement(pokered)
    seafoam = parse_seafoam(pokered)
    game_corner_poster = parse_game_corner_poster(pokered)
    badge_gates = parse_badge_gates(pokered)
    preset_names = parse_preset_names(pokered)
    dark_maps = parse_dark_maps(pokered)
    warp_carpets = parse_warp_carpets(pokered)
    dungeon_transition_maps = parse_dungeon_transition_maps(pokered)
    bike_riding = parse_bike_riding(pokered)
    indoor_encounters = parse_indoor_encounters(pokered)

    town_map = parse_town_map(pokered)
    credits = parse_credits(pokered)
    old_man_battle = parse_old_man_battle(pokered)
    coin_purchases = parse_coin_purchases(pokered)
    pc_item_cap = parse_pc_item_cap(pokered)

    # title screen assets live next to the other generated assets; build_data
    # passes only the data dir, so derive assets/generated from it
    assets_dir = os.path.normpath(
        os.path.join(out_dir, os.pardir, os.pardir, "assets", "generated"))
    title = gfx.extract_title(pokered, assets_dir)
    intro = gfx.extract_intro(pokered, assets_dir)
    slot_symbols = gfx.extract_slots(pokered, assets_dir)
    emotion_bubbles = gfx.extract_emotes(pokered, assets_dir)
    oak_speech = gfx.extract_oak_speech(pokered, assets_dir)
    overworld_fx = gfx.extract_overworld_fx(pokered, assets_dir)
    credits["theEnd"] = gfx.extract_the_end(pokered, assets_dir)
    battle_hud = gfx.extract_battle_hud(pokered, assets_dir)
    town_map["background"] = gfx.extract_town_map_bg(pokered, assets_dir)

    if not ledges or not cut_trees or "OVERWORLD" not in water or len(trades) < 8 \
       or "PALLET_TOWN" not in fly_warps:
        util.die("field extraction sanity check failed")
    if "VIRIDIAN_FOREST" not in hidden_items or len(slot_wheels) != 3 \
       or "VIRIDIAN_GYM" not in spinners:
        util.die("hidden events / slots / spinner extraction sanity check failed")
    if "SILPH_CO_2F" not in card_key_doors["doors"] \
       or len(card_key_doors["doors"]["SILPH_CO_11F"]) != 2:
        util.die("card key door extraction sanity check failed")
    if len(hidden_extras["trashCans"]["cans"]) != 15 \
       or len(hidden_extras["pcTiles"]) < 10 \
       or "VIRIDIAN_GYM" not in hidden_extras["gymStatues"] \
       or hidden_extras["benchGuys"].get("VIRIDIAN_POKECENTER",
                                         [{}])[0].get("text") is None:
        util.die("hidden extras extraction sanity check failed")
    if sorted(forced_movement["tiles"]) != ["ROUTE_16", "ROUTE_18",
                                            "SEAFOAM_ISLANDS_B3F",
                                            "SEAFOAM_ISLANDS_B4F"] \
       or forced_movement["slopeMaps"] != ["ROUTE_17"]:
        util.die("forced movement extraction sanity check failed")
    for map_id in ("SEAFOAM_ISLANDS_B3F", "SEAFOAM_ISLANDS_B4F"):
        if len(seafoam[map_id]["currents"]) != 2 \
           or not all(c["moves"] for c in seafoam[map_id]["currents"]):
            util.die("seafoam current extraction sanity check failed")
    if len(seafoam["SEAFOAM_ISLANDS_B3F"]["holes"]) != 2 \
       or len(seafoam["SEAFOAM_ISLANDS_B4F"]["forcedExit"]["coords"]) != 4:
        util.die("seafoam hole/exit extraction sanity check failed")
    if len(seafoam["SEAFOAM_ISLANDS_1F"]["holes"]) != 2 \
       or len(seafoam["SEAFOAM_ISLANDS_B1F"]["holes"]) != 2:
        util.die("seafoam 1F/B1F hole extraction sanity check failed")
    if game_corner_poster["closedBlock"] == game_corner_poster["openBlock"] \
       or game_corner_poster["closedBlock"] != 0x2A \
       or game_corner_poster["openBlock"] != 0x43:
        util.die("Game Corner poster extraction sanity check failed")
    if len(badge_gates["ROUTE_23"]["guards"]) != 7 \
       or badge_gates["ROUTE_23"]["guards"][0]["badge"] != "EARTHBADGE" \
       or badge_gates["ROUTE_23"]["guards"][-1]["badge"] != "CASCADEBADGE" \
       or len(badge_gates["ROUTE_22_GATE"]["coords"]) != 2:
        util.die("badge gate extraction sanity check failed")
    if "RED" not in preset_names["player"] or "BLUE" not in preset_names["rival"] \
       or len(preset_names["player"]) != 3 or len(preset_names["rival"]) != 3:
        util.die("preset name extraction sanity check failed")
    if "ROCK_TUNNEL_1F" not in dark_maps["maps"]:
        util.die("dark map extraction sanity check failed")
    if warp_carpets["tiles"]["down"] != [0x01, 0x12, 0x17, 0x3D, 0x04, 0x18, 0x33] \
       or warp_carpets["tiles"]["up"] != [0x01, 0x5C] \
       or warp_carpets["tiles"]["left"] != [0x1A, 0x4B] \
       or warp_carpets["tiles"]["right"] != [0x0F, 0x4E] \
       or warp_carpets["ssAnneBow"]["tile"] != 0x15:
        util.die("warp carpet extraction sanity check failed")
    if dungeon_transition_maps["maps"] != ["VIRIDIAN_FOREST", "ROCK_TUNNEL_1F",
                                           "SEAFOAM_ISLANDS_1F", "ROCK_TUNNEL_B1F"] \
       or len(dungeon_transition_maps["ranges"]) != 4 \
       or dungeon_transition_maps["ranges"][0] != {"first": "MT_MOON_1F",
                                                   "last": "MT_MOON_B2F"}:
        util.die("dungeon transition map extraction sanity check failed")
    if bike_riding["tilesets"] != ["OVERWORLD", "FOREST", "UNDERGROUND",
                                   "SHIP_PORT", "CAVERN"]:
        util.die("bike riding tileset extraction sanity check failed")
    if indoor_encounters["firstIndoorMap"] != 0x25:
        util.die("indoor encounter boundary sanity check failed")
    if len(title) != 5 or any(not v["width"] for v in title.values()) \
       or (title["gamefreakInc"]["width"],
           title["gamefreakInc"]["height"]) != (72, 8):
        util.die("title asset extraction sanity check failed")
    if any((intro["gengar"][f]["width"], intro["gengar"][f]["height"])
           != (56, 56) for f in ("frame1", "frame2", "frame3")) \
       or any((intro["nidorino"][f]["width"], intro["nidorino"][f]["height"])
              != (48, 48) for f in ("frame1", "frame2", "frame3")) \
       or (intro["fallingStar"]["width"], intro["bigStar"]["width"],
           intro["gamefreakText"]["width"]) != (8, 16, 80):
        util.die("intro asset extraction sanity check failed")
    if town_map["locations"].get("PALLET_TOWN") != {"x": 2, "y": 11,
                                                    "name": "PALLET TOWN"} \
       or town_map["locations"].get("CERULEAN_CAVE_1F", {}).get("name") != "CERULEAN CAVE" \
       or len(town_map["cursorOrder"]) != 47 \
       or town_map["cursorOrder"][0] != "PALLET_TOWN":
        util.die("town map extraction sanity check failed")
    if len(credits["screens"]) != 35 or len(credits["mons"]) != 15 \
       or credits["screens"][0]["lines"][1]["text"] != "RED VERSION STAFF" \
       or credits["screens"][1]["lines"] != [{"column": 6, "text": "DIRECTOR"},
                                             {"column": 3, "text": "SATOSHI TAJIRI"}] \
       or not credits["screens"][-1].get("copyright") \
       or credits["mons"][0] != "VENUSAUR":
        util.die("credits extraction sanity check failed")
    wheel_symbols = {sym for wheel in slot_wheels for sym in wheel}
    if wheel_symbols != set(slot_symbols["symbols"]) \
       or slot_symbols["symbols"]["7"]["tiles"] != 0x0200:
        util.die("slot symbol extraction sanity check failed")
    if [b["name"] for b in emotion_bubbles["bubbles"]] != \
       ["EXCLAMATION_BUBBLE", "QUESTION_BUBBLE", "SMILE_BUBBLE"]:
        util.die("emotion bubble extraction sanity check failed")
    if old_man_battle["species"] != "WEEDLE" or old_man_battle["level"] != 5:
        util.die("old man battle extraction sanity check failed")
    if coin_purchases != [{"coins": 50, "price": 1000}]:
        util.die("coin purchase extraction sanity check failed")
    if pc_item_cap != 50:
        util.die("PC item capacity sanity check failed")

    data = {"ledges": ledges, "cutTreeSwaps": cut_trees,
                    "waterTilesets": water, "tilePairs": tile_pairs,
                    "trades": trades,
                    "flyWarps": fly_warps, "flyOrder": fly_order,
                    "superRod": super_rod,
                    "hiddenItems": hidden_items, "hiddenCoins": hidden_coins,
                    "slotMachines": slot_machines, "slotWheels": slot_wheels,
                    "spinners": spinners,
                    "cardKeyDoors": card_key_doors,
                    "hiddenExtras": hidden_extras,
                    "forcedMovement": forced_movement,
                    "seafoam": seafoam,
                    "gameCornerPoster": game_corner_poster,
                    "badgeGates": badge_gates,
                    "presetNames": preset_names,
                    "darkMaps": dark_maps,
                    "warpCarpets": warp_carpets,
                    "dungeonTransitionMaps": dungeon_transition_maps,
                    "bikeRiding": bike_riding,
                    "indoorEncounters": indoor_encounters,
                    "title": title,
                    "intro": intro,
                    "battleHud": battle_hud,
                    "townMap": town_map,
                    "credits": credits,
                    "slotSymbols": slot_symbols,
                    "emotionBubbles": emotion_bubbles,
                    "oakSpeech": oak_speech,
                    "overworldFx": overworld_fx,
                    "oldManBattle": old_man_battle,
                    "coinPurchases": coin_purchases,
                    "pcItemCap": pc_item_cap,
                    "source": "data/tilesets/{ledge_tiles,cut_tree_blocks,water_tilesets}.asm,\n"
                              "data/events/{trades,hidden_events,slot_machine_wheels,\n"
                              "bench_guys,card_key_coords,card_key_maps}.asm,\n"
                              "data/maps/{special_warps,force_bike_surf}.asm,\n"
                              "engine/events/card_key.asm,\n"
                              "engine/events/hidden_events/vermilion_gym_trash.asm,\n"
                              "scripts/{SeafoamIslandsB2F,SeafoamIslandsB3F,SeafoamIslandsB4F,\n"
                              "GameCorner,Route22Gate,Route23}.asm,\n"
                              "constants/player_constants.asm, home/overworld.asm,\n"
                              "gfx/title/*.png + gfx/splash/copyright.png,\n"
                              "gfx/splash/*.png + gfx/intro/* + gfx/battle/move_anim_1.png\n"
                              "+ engine/movie/{splash,intro}.asm,\n"
                              "scripts/*.asm spinner tables,\n"
                              "data/maps/{town_map_entries,town_map_order,names}.asm\n"
                              "+ constants/map_constants.asm + engine/items/town_map.asm,\n"
                              "data/credits/{credits_order,credits_text,credits_mons}.asm\n"
                              "+ constants/credits_constants.asm + engine/movie/credits.asm\n"
                              "+ gfx/credits/the_end.png,\n"
                              "constants/script_constants.asm (SLOTS*, *_BUBBLE)\n"
                              "+ gfx/slots/red_slots_{1,2}.png + gfx/emotes/*.png\n"
                              "+ engine/{slots/slot_machine,overworld/emotion_bubbles}.asm,\n"
                              "scripts/ViridianCity.asm + engine/battle/core.asm,\n"
                              "scripts/GameCorner.asm + text/GameCorner.asm,\n"
                              "constants/menu_constants.asm + engine/items/inventory.asm,\n"
                              "data/tilesets/{warp_carpet_tile_ids,bike_riding_tilesets}.asm,\n"
                              "data/maps/dungeon_maps.asm,\n"
                              "engine/overworld/player_state.asm,\n"
                              "engine/battle/wild_encounters.asm"}
    util.write_lua(os.path.join(out_dir, "field.lua"), data,
                   header="Ledges, Cut trees, water, trades, Fly spots, hidden items,\n"
                          "slot machines, spinner arrow tiles, card key doors,\n"
                          "hidden event extras (PCs/bench guys/statues/trash cans),\n"
                          "forced bike/surf tiles, Seafoam currents, Game Corner\n"
                          "poster, badge gates, preset names, dark maps, title assets,\n"
                          "intro movie assets, town map, credits, slot symbols,\n"
                          "emotion bubbles,\n"
                          "old man catch demo, coin purchases, PC item capacity.")
    return data
