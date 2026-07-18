#!/usr/bin/env python3
"""Generate non-ROM metadata used by tools/build_rom_data.py.

The resulting JSON contains symbolic IDs, dimensions, and enum names that
were erased during assembly. It deliberately contains no ROM byte ranges or
graphics/audio payload.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from extract import (battle_anims, constants, field, font, items, maps,  # noqa: E402
                     pokemon, sprites, text, tilesets, trainers, util)
from rom_data import CANONICAL_RED_SHA1, SymbolTable  # noqa: E402


def simple_constants(pokered, relpath, stop_at=None):
    return util.parse_const_block(
        os.path.join(pokered, relpath), stop_at=stop_at)


def charmap(pokered):
    expansions = dict(text.EXPANSIONS)
    expansions.update({
        "<DOT>": ".",
        "<to>": "to",
        "<LV>": "{LV}",
        "<ID>": "{ID}",
    })
    out = {}
    path = os.path.join(pokered, "constants/charmap.asm")
    for _, line in util.read_asm(path):
        m = re.match(
            r'charmap\s+"((?:[^"\\]|\\.)*)",\s*(\$[0-9a-fA-F]+)',
            line.strip())
        if not m:
            continue
        value = int(m.group(2)[1:], 16)
        if str(value) in out:
            continue
        seq = m.group(1).replace('\\"', '"')
        out[str(value)] = expansions.get(seq, seq)
    return out


def sfx_keys(pokered, symbols):
    """Map the one-byte sound IDs stored in MoveSoundTable to audio keys."""
    out = {}
    # Move animations always resolve their one-byte IDs through the battle
    # SFX headers. The same address-derived IDs are reused by the other two
    # audio banks, so accepting all SFX_* symbols would create collisions.
    battle_bank = symbols["SFX_Pound"].bank
    path = os.path.join(pokered, "constants/music_constants.asm")
    for _, line in util.read_asm(path):
        m = re.match(r"music_const\s+SFX_\w+,\s*(SFX_\w+)", line.strip())
        if not m:
            continue
        label = m.group(1)
        symbol = symbols.by_name.get(label)
        if not symbol or symbol.bank != battle_bank:
            continue
        delta = symbol.address - 0x4000
        if delta < 0 or delta % 3:
            continue
        sound_id = delta // 3
        if not 0 <= sound_id <= 0xFF:
            continue
        key = re.sub(r"_[123]$", "", label.removeprefix("SFX_"))
        out[str(sound_id)] = key
    return out


def battle_animation_metadata(pokered):
    """Return names and dimensions that do not survive ROM assembly."""
    consts = battle_anims.parse_anim_constants(pokered)
    base_coords = battle_anims.parse_base_coords(pokered)
    frame_blocks = battle_anims.parse_frame_blocks(pokered)
    subanims = battle_anims.parse_subanimations(
        pokered, len(frame_blocks), len(base_coords), consts)
    special_effects = {
        str(value): name
        for name, value in consts.items()
        if name.startswith("SE_")
    }
    sheets = (
        "move_anim_0.png", "move_anim_1.png", "move_anim_0.png")
    return {
        "baseCoordCount": len(base_coords),
        "frameBlockCount": len(frame_blocks),
        "subanimCount": len(subanims),
        "moveCount": battle_anims.NUM_ATTACKS,
        "miscAnimations": battle_anims.MISC_ANIMS,
        "subanimTypes": battle_anims.SUBANIMTYPE_NAMES,
        "firstSpecialEffect": min(
            int(value) for value in special_effects),
        "specialEffects": special_effects,
        "tilesheets": [
            {
                "path": f"assets/generated/battle/anims/{filename}",
                "source": f"gfx/battle/{filename}",
                "width": 128,
                "height": 40,
            }
            for filename in sheets
        ],
    }


def pokemon_metadata(pokered, dex_order):
    pics = pokemon.parse_pic_files(pokered)
    by_dex_const = {}
    base_dir = os.path.join(pokered, "data/pokemon/base_stats")
    for fname in sorted(os.listdir(base_dir)):
        if not fname.endswith(".asm"):
            continue
        rel = f"data/pokemon/base_stats/{fname}"
        stats = pokemon.parse_base_stats_file(
            os.path.join(base_dir, fname), rel)
        by_dex_const[stats["dexConst"]] = stats

    assets = {}
    for species in dex_order:
        stats = by_dex_const["DEX_" + species]
        front = pics.get(stats.get("picFront", ""))
        back = pics.get(stats.get("picBack", ""))
        assets[species] = {
            "front": os.path.splitext(os.path.basename(front))[0]
            if front else None,
            "back": os.path.splitext(os.path.basename(back))[0]
            if back else None,
            "frontLabel": stats.get("picFront") if front else None,
            "backLabel": stats.get("picBack") if back else None,
        }

    growth_rates = []
    for _, line in util.read_asm(
            os.path.join(pokered, "constants/pokemon_data_constants.asm")):
        m = re.match(r"const\s+GROWTH_(\w+)", line.strip())
        if m:
            growth_rates.append(m.group(1))
    return assets, growth_rates


def trainer_pic_metadata(pokered):
    pics = {}
    for _, line in util.read_asm(os.path.join(pokered, "gfx/pics.asm")):
        m = re.match(
            r'(\w+)Pic::?\s+INCBIN\s+"(gfx/trainers/[^"]+)"',
            line.strip())
        if m:
            base = os.path.splitext(os.path.basename(m.group(2)))[0]
            pics[m.group(1)] = {
                "label": m.group(1) + "Pic",
                "path": f"assets/generated/battle/trainers/{base}.png",
                "imageBase": base,
            }

    labels, _ = trainers.parse_parties(pokered)
    # Keep missing pictures as explicit false values. JSON null becomes nil in
    # Lua and would collapse these two array positions in the runtime importer.
    return [pics.get(label) or False for label in labels]


def map_metadata(pokered, map_dims):
    """Keep only map names and other labels that assembly erased."""
    headers_dir = os.path.join(pokered, "data/maps/headers")
    blocks_files = maps.parse_blocks_files(pokered)
    toggles = maps.parse_toggleable_objects(pokered)
    out = {}
    for fname in sorted(os.listdir(headers_dir)):
        if not fname.endswith(".asm"):
            continue
        header = maps.parse_header(os.path.join(headers_dir, fname))
        if "const" not in header or header["const"] not in map_dims:
            continue
        const = header["const"]
        label = header["label"]
        if const in out:
            def spells_const(value):
                return value.upper() == const.replace("_", "")

            if spells_const(out[const]["label"]) == spells_const(label):
                raise ValueError(f"duplicate map header for {const}")
            if spells_const(out[const]["label"]):
                continue

        parsed = maps.parse_objects(
            os.path.join(pokered, "data/maps/objects", f"{label}.asm"))
        object_names = parsed["objectNames"]
        object_specs = []
        for index, obj in enumerate(parsed["objects"]):
            spec = {"text": obj["text"]}
            for key in ("trainerClass", "trainerParty", "pokemon", "item"):
                if key in obj:
                    spec[key] = obj[key]
            if index < len(object_names):
                spec["name"] = object_names[index]
                if toggles.get(const, {}).get(object_names[index]) == "OFF":
                    spec["hidden"] = True
            object_specs.append(spec)

        block_rel = blocks_files.get(label, f"maps/{label}.blk")
        out[const] = {
            "label": label,
            "blockLength": os.path.getsize(os.path.join(pokered, block_rel)),
            "signTexts": [sign["text"] for sign in parsed["signs"]],
            "objects": object_specs,
        }
    return out


def tileset_metadata(pokered, order):
    """Describe tileset payload sizes and symbolic enum names."""
    from PIL import Image

    labels = tilesets.parse_incbin_labels(pokered)
    headers = []
    path = os.path.join(pokered, "data/tilesets/tileset_headers.asm")
    for _, line in util.read_asm(path):
        match = tilesets.TILESET_RE.match(line.strip())
        if match:
            headers.append(match)
    if len(headers) != len(order):
        raise ValueError("tileset header count does not match constants")

    out = []
    for match, const_name in zip(headers, order):
        name = match.group(1)
        gfx_rel = labels[f"{name}_GFX"]
        block_rel = labels[f"{name}_Block"]
        png_rel = re.sub(r"\.2bpp$", ".png", gfx_rel)
        with Image.open(os.path.join(pokered, png_rel)) as image:
            width, height = image.size
        block_size = os.path.getsize(os.path.join(pokered, block_rel))
        if block_size % 16:
            raise ValueError(f"{block_rel} is not a whole number of blocks")
        out.append({
            "id": const_name,
            "name": name,
            "imageBase": os.path.splitext(os.path.basename(png_rel))[0],
            "imageWidth": width,
            "imageHeight": height,
            "blockCount": block_size // 16,
        })
    return out


def sprite_metadata(pokered, order):
    """Describe overworld sprite labels and source atlas dimensions."""
    from PIL import Image

    files = sprites.parse_sprite_files(pokered)
    sheets = sprites.parse_sheet_table(pokered)
    if len(sheets) != len(order):
        raise ValueError("sprite sheet count does not match constants")

    out = []
    for (label, _tiles, _line), const_name in zip(sheets, order):
        source = files[label]
        png_path = re.sub(r"\.2bpp$", ".png", source)
        with Image.open(os.path.join(pokered, png_path)) as image:
            width, height = image.size
        out.append({
            "id": const_name,
            "label": label,
            "imageBase": os.path.splitext(os.path.basename(png_path))[0],
            "imageWidth": width,
            "imageHeight": height,
        })

    bike_source = files["RedBikeSprite"]
    bike_png = re.sub(r"\.2bpp$", ".png", bike_source)
    with Image.open(os.path.join(pokered, bike_png)) as image:
        bike_width, bike_height = image.size
    return {
        "order": out,
        "bike": {
            "label": "RedBikeSprite",
            "imageBase": "red_bike",
            "imageWidth": bike_width,
            "imageHeight": bike_height,
        },
    }


def text_metadata(pokered):
    """Keep text labels, runtime substitutions, and script integration data."""
    paths = []
    text_dir = os.path.join(pokered, "text")
    paths.extend(
        os.path.join(text_dir, name)
        for name in sorted(os.listdir(text_dir))
        if name.endswith(".asm"))
    data_text_dir = os.path.join(pokered, "data/text")
    paths.extend(
        os.path.join(data_text_dir, name)
        for name in sorted(os.listdir(data_text_dir))
        if re.match(r"text_\d+\.asm$", name))
    paths.append(os.path.join(pokered, "data/pokemon/dex_text.asm"))

    labels = []
    dynamic = {}
    current = None
    command_ids = {"text_ram": 1, "text_bcd": 2, "text_decimal": 9}
    token_names = {"text_ram": "RAM", "text_bcd": "NUM",
                   "text_decimal": "NUM"}
    for path in paths:
        for _, line in util.read_asm(path):
            stripped = line.strip()
            match = re.match(r"(_\w+)::?\s*$", stripped)
            if match:
                current = match.group(1)
                labels.append(current)
                continue
            match = re.match(
                r"(text_ram|text_bcd|text_decimal)\s+(.+)$", stripped)
            if match and current:
                macro, args = match.groups()
                token = (
                    "{" + token_names[macro] + ":"
                    + args.replace('"', "") + "}")
                dynamic.setdefault(current, []).append(
                    [command_ids[macro], token])

    pointers = text.parse_script_text_pointers(pokered)
    trainer_headers = text.parse_trainer_headers(pokered)
    for headers in trainer_headers.values():
        for header in headers.values():
            header.pop("source", None)
    return {
        "labels": sorted(set(labels)),
        "dynamic": dynamic,
        "pointers": pointers,
        "trainerHeaders": trainer_headers,
    }


def _without_sources(value):
    if isinstance(value, dict):
        return {
            key: _without_sources(item)
            for key, item in value.items()
            if key != "source"
        }
    if isinstance(value, list):
        return [_without_sources(item) for item in value]
    return value


def field_metadata(pokered):
    """Capture the port's hand-authored field integration, without artwork."""
    with tempfile.TemporaryDirectory() as temp_dir:
        out_dir = os.path.join(temp_dir, "data", "generated")
        os.makedirs(out_dir)
        return _without_sources(field.extract(pokered, out_dir))


def _audio_headers(pokered, symbols, prefix, label_prefix):
    headers = {}
    root = os.path.join(pokered, "audio/headers")
    for filename in sorted(os.listdir(root)):
        if not filename.startswith(prefix) or not filename.endswith(".asm"):
            continue
        match = re.search(r"(\d+)\.asm$", filename)
        engine = int(match.group(1)) if match else 1
        for _, line in util.read_asm(os.path.join(root, filename)):
            match = re.match(rf"({label_prefix}\w+)::?\s*$", line.strip())
            if not match:
                continue
            name = match.group(1)
            symbol = symbols.by_name.get(name)
            if symbol:
                headers[name] = {
                    "engine": engine,
                    "bank": symbol.bank,
                    "address": symbol.address,
                }
    return headers


def _music_label(const_name, music_headers):
    candidate = "Music_" + "".join(
        part.capitalize()
        for part in const_name.removeprefix("MUSIC_").split("_"))
    folded = candidate.lower()
    return next(
        (name for name in music_headers if name.lower() == folded),
        candidate)


def audio_metadata(pokered, symbols, map_order):
    """Names and addresses needed to interpret audio bytecode from ROM."""
    music_headers = _audio_headers(
        pokered, symbols, "musicheaders", "Music_")
    all_sfx_headers = _audio_headers(
        pokered, symbols, "sfxheaders", "SFX_")

    sfx_headers = {}
    for name in sorted(all_sfx_headers):
        spec = all_sfx_headers[name]
        base = name.removeprefix("SFX_")
        suffix = f"_{spec['engine']}"
        if base.endswith(suffix):
            base = base[:-len(suffix)]
        if base == "Headers" \
                or base.startswith(("Cry", "Noise_Instrument", "Unused")):
            continue
        sfx_headers.setdefault(base, spec)

    cry_headers = {}
    for number in range(0x26):
        name = f"SFX_Cry{number:02X}_1"
        if name in all_sfx_headers:
            cry_headers[str(number)] = all_sfx_headers[name]

    noise_headers = {}
    for engine in (1, 2, 3):
        per_engine = {}
        for number in range(1, 20):
            name = f"SFX_Noise_Instrument{number:02d}_{engine}"
            if name in all_sfx_headers:
                per_engine[str(number)] = all_sfx_headers[name]
        noise_headers[str(engine)] = per_engine

    map_song_consts = []
    path = os.path.join(pokered, "data/maps/songs.asm")
    for _, line in util.read_asm(path):
        match = re.match(r"db\s+(MUSIC_\w+),", line.strip())
        if match:
            map_song_consts.append(match.group(1))
    map_songs = {}
    for map_name, const_name in zip(map_order, map_song_consts):
        label = _music_label(const_name, music_headers)
        if label in music_headers:
            map_songs[map_name] = label

    cry_data = symbols["CryData"]
    wave_banks = {}
    for engine in (1, 2, 3):
        wave = symbols[f"Audio{engine}_WavePointers.wave0"]
        wave_banks[str(engine)] = {
            "bank": wave.bank,
            "address": wave.address,
        }

    return {
        "musicHeaders": music_headers,
        "sfxHeaders": sfx_headers,
        "cryHeaders": cry_headers,
        "noiseHeaders": noise_headers,
        "cryData": {
            "bank": cry_data.bank,
            "address": cry_data.address,
        },
        "waveBanks": wave_banks,
        "mapSongs": map_songs,
        "battle": {
            "wild": "Music_WildBattle",
            "trainer": "Music_TrainerBattle",
            "gym": "Music_GymLeaderBattle",
            "final": "Music_FinalBattle",
            "wildWin": "Music_DefeatedWildMon",
            "trainerWin": "Music_DefeatedTrainer",
            "gymWin": "Music_DefeatedGymLeader",
        },
    }


DIRECT_SYMBOLS = {
    "AttackAnimationPointers",
    "BadgeNumbersTileGraphics",
    "BaseStats",
    "BugIconFrame1",
    "BugIconFrame2",
    "CircleTile",
    "CryData",
    "DoorTileIDPointers",
    "EvosMovesPointerTable",
    "FlowerTile1",
    "FlowerTile2",
    "FlowerTile3",
    "FontGraphics",
    "FrameBlockBaseCoords",
    "FrameBlockPointers",
    "FossilAerodactylPic",
    "FossilKabutopsPic",
    "GhostPic",
    "GymLeaderFaceAndBadgeTileGraphics",
    "ItemNames",
    "ItemPrices",
    "KeyItemFlags",
    "MewBaseStats",
    "MonPartyData",
    "MonsterNames",
    "MonsterPalettes",
    "MoveNames",
    "MoveAnimationTiles0",
    "MoveAnimationTiles1",
    "MoveAnimationTiles2",
    "MoveAnimationTilesPointers",
    "MoveSoundTable",
    "Moves",
    "NothingWildMons",
    "OldManPicBack",
    "PlantIconFrame1",
    "PlantIconFrame2",
    "PokeballTileGraphics",
    "PokedexEntryPointers",
    "PokedexTileGraphics",
    "QuadrupedIconFrame1",
    "QuadrupedIconFrame2",
    "RedBikeSprite",
    "RedPicBack",
    "RedPicFront",
    "SnakeIconFrame1",
    "SnakeIconFrame2",
    "SpinnerArrowAnimTiles",
    "SpriteSheetPointerTable",
    "SubanimationPointers",
    "SuperPalettes",
    "TechnicalMachinePrices",
    "TextBoxGraphics",
    "Tilesets",
    "TrainerAI",
    "TrainerClassMoveChoiceModifications",
    "TrainerDataPointers",
    "TrainerInfoTextBoxTileGraphics",
    "TrainerNames",
    "TrainerPicAndMoneyPointers",
    "TypeEffects",
    "WarpTileIDPointers",
    "WildDataPointers",
}

FIELD_ASSET_SYMBOLS = {
    "BattleHudTiles1",
    "BattleHudTiles2",
    "BattleHudTiles3",
    "BattleTransitionTile",
    "FallingStar",
    "FightIntroBackMon",
    "FightIntroFrontMon",
    "FightIntroFrontMon2",
    "FightIntroFrontMon3",
    "GameFreakIntro",
    "GameFreakLogoGraphics",
    "GengarIntroTiles1",
    "GengarIntroTiles2",
    "GengarIntroTiles3",
    "HappyEmote",
    "HpBarAndStatusGraphics",
    "LedgeHoppingShadow",
    "MoveAnimationTiles1",
    "NintendoCopyrightLogoGraphics",
    "PlayerCharacterTitleGraphics",
    "PokeCenterFlashingMonitorAndHealBall",
    "PokemonLogoGraphics",
    "QuestionEmote",
    "RedFishingRodTiles",
    "RedFishingTilesBack",
    "RedFishingTilesFront",
    "RedFishingTilesSide",
    "SSAnneSmokePuffTile",
    "ShockEmote",
    "ShrinkPic1",
    "ShrinkPic2",
    "SlotMachineTiles1",
    "SlotMachineTiles2",
    "TheEndGfx",
    "TownMapCursor",
    "Version_GFX",
    "WorldMapTileGraphics",
}


def embedded_symbols(data, symbols):
    """Return only addresses consumed by the ROM-backed extractor."""
    names = set(DIRECT_SYMBOLS | FIELD_ASSET_SYMBOLS)
    names.update(
        spec["label"] + "_h" for spec in data["maps"].values())
    names.update(data["typeNameLabels"])
    names.update(data["text"]["labels"])
    for spec in data["pokemonAssets"].values():
        for key in ("frontLabel", "backLabel"):
            if spec.get(key):
                names.add(spec[key])
    for spec in data["trainerPics"]:
        if spec:
            names.add(spec["label"])

    missing = sorted(name for name in names if name not in symbols.by_name)
    if missing:
        raise ValueError(
            "required symbols are missing: " + ", ".join(missing))
    return {
        name: [symbols[name].bank, symbols[name].address]
        for name in sorted(names)
    }


def generate(pokered, symbols_path):
    symbols = SymbolTable(symbols_path)
    map_order, map_dims = constants.extract_map_constants(pokered)
    tilesets = [
        n for n in simple_constants(
            pokered, "constants/tileset_constants.asm") if n
    ]
    sprites = simple_constants(pokered, "constants/sprite_constants.asm")
    species = simple_constants(pokered, "constants/pokemon_constants.asm")
    moves = simple_constants(
        pokered, "constants/move_constants.asm", stop_at="NUM_ATTACKS")
    types = constants.extract_types(pokered)

    # Named elevator floors follow the 83 inventory items in the same
    # ItemNames/ItemPrices tables. Machine IDs live later at $C4+ and are
    # represented separately below.
    item_order = simple_constants(
        pokered, "constants/item_constants.asm")[1:]
    # parse_const_block sees the `const HM_\1` macro body as a literal
    # pseudo-entry; everything before it is the real contiguous name table.
    item_order = item_order[:item_order.index("HM_")]
    hms, tms = items.parse_machines(pokered)
    effects = simple_constants(
        pokered, "constants/move_effect_constants.asm")
    trainer_order = [
        name for name in trainers.parse_trainer_consts(pokered)
        if name and name != "NOBODY"
    ]
    dex_order = [
        name.removeprefix("DEX_")
        for name in simple_constants(
            pokered, "constants/pokedex_constants.asm")
        if name
    ]
    pokemon_assets, growth_rates = pokemon_metadata(pokered, dex_order)
    palette_order = [
        name.removeprefix("PAL_")
        for name in simple_constants(
            pokered, "constants/palette_constants.asm")
        if name and name.startswith("PAL_")
    ]
    icon_order = [
        name.removeprefix("ICON_")
        for name in simple_constants(
            pokered, "constants/icon_constants.asm")
        if name and name.startswith("ICON_")
    ][:10]
    tile_animations = [
        name or "UNUSED"
        for name in simple_constants(
            pokered, "constants/map_data_constants.asm")
        if name and name.startswith("TILEANIM_")
    ]

    constants_data = {
        "source": "ROM metadata manifest",
        "mapOrder": map_order,
        "maps": map_dims,
        "tilesetOrder": tilesets,
        "spriteOrder": [n or "UNUSED" for n in sprites[1:]],
        "speciesOrder": [n or "UNUSED" for n in species[1:]],
        "moveOrder": [n or "UNUSED" for n in moves[1:]],
        "types": types,
    }

    type_name_labels = [
        symbol.name for symbol in symbols.prefixed("TypeNames.")
    ]
    dex_entries = pokemon.parse_dex_entries(
        pokered, constants_data["speciesOrder"])
    texts = text_metadata(pokered)
    field_data = field_metadata(pokered)
    audio_data = audio_metadata(pokered, symbols, map_order)

    data = {
        "format": 2,
        "romSha1": CANONICAL_RED_SHA1,
        "constants": constants_data,
        "charmap": charmap(pokered),
        "moveEffects": [name or "UNUSED" for name in effects],
        "items": item_order,
        "numItems": 83,
        "hms": hms,
        "tms": tms,
        "trainers": trainer_order,
        "trainerPics": trainer_pic_metadata(pokered),
        "dexOrder": dex_order,
        "pokemonAssets": pokemon_assets,
        "growthRates": growth_rates,
        "tmhmMoves": tms + hms,
        "paletteOrder": palette_order,
        "iconOrder": icon_order,
        "maps": map_metadata(pokered, map_dims),
        "tilesets": tileset_metadata(pokered, tilesets),
        "tileAnimations": tile_animations,
        "sprites": sprite_metadata(
            pokered, [name or "UNUSED" for name in sprites[1:]]),
        "fontCharmap": font.parse_charmap(pokered),
        "sfxKeys": sfx_keys(pokered, symbols),
        "typeNameLabels": type_name_labels,
        "dexEntryLabels": {
            species: entry.get("text")
            for species, entry in dex_entries.items()
            if entry.get("text")
        },
        "text": texts,
        "field": field_data,
        "audio": audio_data,
        "battleAnimations": battle_animation_metadata(pokered),
    }
    data["symbols"] = embedded_symbols(data, symbols)
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pokered", required=True)
    parser.add_argument("--symbols", required=True)
    parser.add_argument(
        "--out",
        default=os.path.join(os.path.dirname(__file__), "rom_manifest.json"))
    args = parser.parse_args()

    pokered = os.path.abspath(args.pokered)
    if not os.path.isfile(os.path.join(pokered, "main.asm")):
        raise SystemExit(f"{pokered} is not a pokered checkout")
    data = generate(pokered, os.path.abspath(args.symbols))
    with open(args.out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(data, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
