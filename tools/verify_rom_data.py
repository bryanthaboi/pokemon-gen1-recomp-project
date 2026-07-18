#!/usr/bin/env python3
"""Compare ROM-backed core data with the existing source-backed extractors."""

from __future__ import annotations

import argparse
import os
import sys
import tempfile

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import build_rom_data  # noqa: E402
from extract import (battle_anims, constants, encounters, field, font,  # noqa: E402
                     icons, items, maps, moves, palettes, pokemon, sprites,
                     text, tilesets, trainers, type_chart)
from rom_data import RomImage, SymbolTable, load_manifest  # noqa: E402


def without_source(value):
    if isinstance(value, dict):
        return {
            key: without_source(item)
            for key, item in value.items()
            if key != "source"
        }
    if isinstance(value, list):
        return [without_source(item) for item in value]
    return value


def compare(name, expected, actual):
    expected = without_source(expected)
    actual = without_source(actual)
    if expected != actual:
        raise AssertionError(f"{name}: ROM output differs from source output")
    print(f"ok: {name}")


def compare_png_tree(name, expected_dir, actual_dir):
    def pngs(root):
        return sorted(
            os.path.relpath(os.path.join(parent, filename), root)
            for parent, _, filenames in os.walk(root)
            for filename in filenames
            if filename.endswith(".png")
        )

    expected_files = pngs(expected_dir)
    actual_files = pngs(actual_dir)
    if expected_files != actual_files:
        raise AssertionError(
            f"{name}: generated PNG file lists differ")
    for relative in expected_files:
        with Image.open(os.path.join(expected_dir, relative)) as expected, \
                Image.open(os.path.join(actual_dir, relative)) as actual:
            expected_rgba = expected.convert("RGBA")
            actual_rgba = actual.convert("RGBA")
            if expected_rgba.size != actual_rgba.size \
                    or expected_rgba.tobytes() != actual_rgba.tobytes():
                raise AssertionError(
                    f"{name}: pixels differ for {relative}")
    print(f"ok: {name} ({len(expected_files)} PNGs)")


def source_type_chart(pokered, temp_dir):
    matchups = type_chart.extract(pokered, temp_dir)
    names = []
    import re
    from extract.util import read_asm
    path = os.path.join(pokered, "data/types/names.asm")
    for _, line in read_asm(path):
        m = re.match(r'(?:\.\w+:\s*)?db\s+"([^"@]*)@?"', line.strip())
        if m:
            names.append(m.group(1))
    return {"matchups": matchups, "names": names}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rom", required=True)
    parser.add_argument("--symbols", required=True)
    parser.add_argument("--pokered", required=True)
    parser.add_argument(
        "--manifest",
        default=os.path.join(os.path.dirname(__file__), "rom_manifest.json"))
    args = parser.parse_args()

    manifest = load_manifest(args.manifest)
    rom = RomImage(args.rom, manifest["romSha1"])
    source_symbols = SymbolTable(args.symbols)
    for name, location in manifest["symbols"].items():
        source_symbol = source_symbols[name]
        if location != [source_symbol.bank, source_symbol.address]:
            raise AssertionError(f"embedded symbol differs: {name}")
    symbols = SymbolTable(manifest["symbols"])
    with tempfile.TemporaryDirectory() as temp_dir:
        source_assets = os.path.join(temp_dir, "assets", "generated")
        rom_assets = os.path.join(temp_dir, "rom-assets")
        source_constants = constants.extract(args.pokered, temp_dir)
        source_tilesets = tilesets.extract(
            args.pokered, temp_dir, source_assets,
            source_constants["tilesetOrder"])
        source_maps = maps.extract(
            args.pokered, temp_dir, source_constants["maps"])
        source_font = font.extract(
            args.pokered, temp_dir, source_assets)
        source_sprites = sprites.extract(
            args.pokered, temp_dir, source_assets,
            source_constants["spriteOrder"])
        source_moves = moves.extract(
            args.pokered, temp_dir, source_constants["moveOrder"])
        source_battle_anims = battle_anims.extract(
            args.pokered, temp_dir, source_assets,
            source_constants["moveOrder"])
        source_items = items.extract(args.pokered, temp_dir)
        source_types = source_type_chart(args.pokered, temp_dir)
        source_palettes, source_mon_palettes = palettes.extract(
            args.pokered, temp_dir)
        source_icons_by_dex = icons.extract(
            args.pokered, temp_dir, source_assets)
        source_icons = {
            "byDex": source_icons_by_dex,
            "icons": {
                **icons.SPRITE_ICONS,
                **{
                    name: f"assets/generated/icons/{icons.SHEET_FILES[name]}.png"
                    for name in icons.SHEET_ICONS
                },
            },
        }
        source_palette_data = {
            "palettes": source_palettes,
            "order": manifest["paletteOrder"],
            "pokemon": source_mon_palettes,
        }
        source_pokemon = pokemon.extract(
            args.pokered, temp_dir, source_assets,
            source_constants["speciesOrder"])
        source_trainers = trainers.extract(
            args.pokered, temp_dir, source_assets)
        source_encounters = encounters.extract(
            args.pokered, temp_dir, source_constants["mapOrder"])
        source_texts, source_text_pointers = text.extract(
            args.pokered, temp_dir)
        source_text_values = {
            label: value["text"] for label, value in source_texts.items()
        }
        # This label intentionally falls through into _EndUsedMove1Text in
        # the ROM command stream.
        source_text_values["_MoveNameText"] += \
            source_text_values["_EndUsedMove1Text"]
        source_trainer_headers = text.parse_trainer_headers(args.pokered)
        source_field_dir = os.path.join(temp_dir, "data", "generated")
        os.makedirs(source_field_dir)
        source_field = field.extract(args.pokered, source_field_dir)

        rom_dir = os.path.join(temp_dir, "rom")
        os.makedirs(rom_dir)
        actual = build_rom_data.build(
            rom, symbols, manifest, rom_dir, rom_assets,
            build_rom_data.DATASETS)

        compare("constants", source_constants, actual["constants"])
        compare("tilesets", source_tilesets, actual["tilesets"])
        compare_png_tree(
            "tileset assets",
            os.path.join(source_assets, "tilesets"),
            os.path.join(rom_assets, "tilesets"))
        compare("maps", source_maps, actual["maps"])
        compare("font", source_font, actual["font"])
        compare_png_tree(
            "font assets",
            os.path.join(source_assets, "fonts"),
            os.path.join(rom_assets, "fonts"))
        compare("sprites", source_sprites, actual["sprites"])
        compare_png_tree(
            "sprite assets",
            os.path.join(source_assets, "sprites"),
            os.path.join(rom_assets, "sprites"))
        compare("moves", source_moves, actual["moves"])
        compare(
            "battle animations",
            source_battle_anims, actual["battle_anims"])
        compare("items", source_items, actual["items"])
        compare("type_chart", source_types, actual["type_chart"])
        compare("palettes", source_palette_data, actual["palettes"])
        compare("icons", source_icons, actual["icons"])
        compare_png_tree(
            "icon assets",
            os.path.join(source_assets, "icons"),
            os.path.join(rom_assets, "icons"))
        compare("pokemon", source_pokemon, actual["pokemon"])
        compare("trainers", source_trainers, actual["trainers"])
        compare_png_tree(
            "battle assets",
            os.path.join(source_assets, "battle"),
            os.path.join(rom_assets, "battle"))
        compare_png_tree(
            "trainer card assets",
            os.path.join(source_assets, "trainer_card"),
            os.path.join(rom_assets, "trainer_card"))
        compare("encounters", source_encounters, actual["encounters"])
        compare("text", source_text_values, actual["text"]["texts"])
        compare(
            "text pointers", source_text_pointers,
            actual["text"]["pointers"])
        compare(
            "trainer headers", source_trainer_headers,
            actual["text"]["trainerHeaders"])
        compare("field", source_field, actual["field"])
        compare_png_tree("all assets", source_assets, rom_assets)
    print("all implemented ROM datasets match the source-backed pipeline")
    return 0


if __name__ == "__main__":
    sys.exit(main())
