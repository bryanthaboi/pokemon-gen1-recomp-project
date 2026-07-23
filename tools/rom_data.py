"""Shared ROM and RGBDS symbol helpers for the ROM-backed data builder."""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass


CANONICAL_RED_SHA1 = "ea9bcae617fdf159b045185467ae58b2e4a48b9a"
CANONICAL_BLUE_SHA1 = "d7037c83e1ae5b39bde3c30787637ba1d4c48ce2"
ROM_BANK_SIZE = 0x4000


@dataclass(frozen=True)
class Symbol:
    bank: int
    address: int
    name: str


class SymbolTable:
    """Resolve named CPU addresses from an RGBDS file or manifest mapping."""

    def __init__(self, source):
        self.by_name = {}
        self.by_location = {}
        if isinstance(source, dict):
            for name, location in source.items():
                if not isinstance(location, list) or len(location) != 2:
                    raise ValueError(
                        f"invalid embedded symbol location for {name!r}")
                self._add(Symbol(int(location[0]), int(location[1]), name))
            return

        with open(source, encoding="utf-8") as f:
            for raw in f:
                match = re.match(
                    r"^([0-9a-fA-F]{2}):([0-9a-fA-F]{4})\s+(\S+)", raw)
                if match:
                    self._add(Symbol(
                        int(match.group(1), 16),
                        int(match.group(2), 16),
                        match.group(3)))

    def _add(self, symbol):
        self.by_name[symbol.name] = symbol
        self.by_location.setdefault(
            (symbol.bank, symbol.address), []).append(symbol.name)

    def __getitem__(self, name):
        return self.by_name[name]

    def names_at(self, bank, address):
        return self.by_location.get((bank, address), [])

    def prefixed(self, prefix):
        return sorted(
            (s for s in self.by_name.values() if s.name.startswith(prefix)),
            key=lambda s: (s.bank, s.address, s.name),
        )


class RomImage:
    def __init__(self, path, expected_sha1=CANONICAL_RED_SHA1):
        with open(path, "rb") as f:
            self.data = f.read()
        self.sha1 = hashlib.sha1(self.data).hexdigest()
        if expected_sha1 and self.sha1 != expected_sha1:
            raise ValueError(
                f"unsupported ROM SHA-1 {self.sha1}; expected {expected_sha1}")

    @staticmethod
    def offset(bank, address):
        if bank == 0:
            if not 0 <= address < ROM_BANK_SIZE:
                raise ValueError(f"ROM0 address out of range: ${address:04x}")
            return address
        if not ROM_BANK_SIZE <= address < ROM_BANK_SIZE * 2:
            raise ValueError(
                f"bank {bank:02x} address out of range: ${address:04x}")
        return bank * ROM_BANK_SIZE + (address - ROM_BANK_SIZE)

    def byte(self, bank, address):
        return self.data[self.offset(bank, address)]

    def word(self, bank, address):
        pos = self.offset(bank, address)
        return self.data[pos] | (self.data[pos + 1] << 8)

    def bytes(self, bank, address, length):
        pos = self.offset(bank, address)
        return self.data[pos:pos + length]

    def at(self, symbol):
        return self.offset(symbol.bank, symbol.address)


def load_manifest(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def decode_text(raw, charmap, stop=0x50):
    """Decode Gen 1 text bytes using a manifest's byte-to-text map."""
    out = []
    for value in raw:
        if value == stop:
            break
        out.append(charmap.get(str(value), f"{{BYTE:{value:02X}}}"))
    return "".join(out)


def read_string(rom, bank, address, charmap, stop=0x50, max_length=4096):
    out = []
    for i in range(max_length):
        value = rom.byte(bank, address + i)
        if value == stop:
            return "".join(out), i + 1
        out.append(charmap.get(str(value), f"{{BYTE:{value:02X}}}"))
    raise ValueError(
        f"unterminated string at {bank:02x}:{address:04x} "
        f"(limit {max_length})")


def bcd(raw):
    value = 0
    for byte in raw:
        value = value * 100 + ((byte >> 4) * 10) + (byte & 0x0F)
    return value


class _BitReader:
    def __init__(self, data):
        self.data = data
        self.byte = 0
        self.bit = 7

    def read(self, count=1):
        value = 0
        for _ in range(count):
            if self.byte >= len(self.data):
                raise ValueError("compressed picture ended unexpectedly")
            value = (value << 1) | (
                (self.data[self.byte] >> self.bit) & 1)
            self.bit -= 1
            if self.bit < 0:
                self.byte += 1
                self.bit = 7
        return value


def _fill_pic_plane(reader, width):
    mode = reader.read()
    group_count = width * width * 0x20
    groups = []
    while len(groups) < group_count:
        if mode:
            while len(groups) < group_count:
                group = reader.read(2)
                if group == 0:
                    break
                groups.append(group)
        else:
            prefix = 0
            while reader.read():
                prefix += 1
                if prefix >= 16:
                    raise ValueError("invalid compressed picture zero run")
            zero_count = (1 << (prefix + 1)) - 1
            zero_count += reader.read(prefix + 1)
            groups.extend(
                [0] * min(zero_count, group_count - len(groups)))
        mode ^= 1

    reordered = []
    for y in range(width):
        for x in range(width * 8):
            for group in range(4):
                reordered.append(
                    groups[(y * 4 + group) * width * 8 + x])
    packed = bytearray(width * width * 8)
    for index in range(len(packed)):
        start = index * 4
        packed[index] = (
            (reordered[start] << 6)
            | (reordered[start + 1] << 4)
            | (reordered[start + 2] << 2)
            | reordered[start + 3]
        )
    return packed


def _unfilter_pic_plane(plane, width):
    codes = (
        (0x0, 0x1, 0x3, 0x2, 0x7, 0x6, 0x4, 0x5,
         0xF, 0xE, 0xC, 0xD, 0x8, 0x9, 0xB, 0xA),
        (0xF, 0xE, 0xC, 0xD, 0x8, 0x9, 0xB, 0xA,
         0x0, 0x1, 0x3, 0x2, 0x7, 0x6, 0x4, 0x5),
    )
    for x in range(width * 8):
        bit = 0
        for y in range(width):
            index = y * width * 8 + x
            high = codes[bit][plane[index] >> 4]
            bit = high & 1
            low = codes[bit][plane[index] & 0x0F]
            bit = low & 1
            plane[index] = (high << 4) | low


def _transpose_pic_tiles(data, width):
    tile_count = width * width
    for index in range(tile_count):
        other = (index * width + index // width) % tile_count
        if index < other:
            left = index * 16
            right = other * 16
            saved = data[left:left + 16]
            data[left:left + 16] = data[right:right + 16]
            data[right:right + 16] = saved


def decompress_pic(data):
    """Decode pokered's pkmncompress picture stream into row-major 2bpp."""
    reader = _BitReader(data)
    width = reader.read(4)
    height = reader.read(4)
    if not width or width != height:
        raise ValueError(
            f"compressed picture is not a non-empty square ({width}x{height})")

    order = reader.read()
    planes = [None, None]
    planes[order] = _fill_pic_plane(reader, width)
    mode = reader.read()
    if mode:
        mode += reader.read()
    planes[order ^ 1] = _fill_pic_plane(reader, width)

    _unfilter_pic_plane(planes[order], width)
    if mode != 1:
        _unfilter_pic_plane(planes[order ^ 1], width)
    if mode != 0:
        for index in range(width * width * 8):
            planes[order ^ 1][index] ^= planes[order][index]

    output = bytearray(width * width * 16)
    for index in range(width * width * 8):
        output[index * 2] = planes[0][index]
        output[index * 2 + 1] = planes[1][index]
    _transpose_pic_tiles(output, width)
    return bytes(output), width
