"""Extract item data, including TM/HM machine items.

Sources:
  constants/item_constants.asm -> item ids (const list, 1-based) and
                                  add_tm/add_hm machine definitions
  data/items/names.asm         -> names (li "..." in id order)
  data/items/prices.asm        -> bcd3 prices in id order
  data/items/tm_prices.asm     -> TM prices in thousands (nybbles)
  data/items/key_items.asm     -> key item bitfield (dbit_env)

Output: data/generated/items.lua
"""

import os
import re

from . import util
from .util import parse_number, read_asm, warn


def parse_machines(pokered):
    """add_hm/add_tm rows: item ids HM_CUT.., TM_MEGA_PUNCH.. -> move."""
    hms, tms = [], []
    for lineno, line in read_asm(os.path.join(pokered, "constants/item_constants.asm")):
        s = line.strip()
        m = re.match(r"add_hm\s+(\w+)", s)
        if m:
            hms.append(m.group(1))
        m = re.match(r"add_tm\s+(\w+)", s)
        if m:
            tms.append(m.group(1))
    return hms, tms


def parse_tm_prices(pokered):
    prices = []
    for lineno, line in read_asm(os.path.join(pokered, "data/items/tm_prices.asm")):
        m = re.match(r"nybble\s+(\d+)", line.strip())
        if m:
            prices.append(int(m.group(1)) * 1000)
    return prices


def extract(pokered, out_dir):
    consts = util.parse_const_block(os.path.join(pokered, "constants/item_constants.asm"))
    consts = [c for c in consts[1:] if c]  # drop NO_ITEM slot 0

    names = []
    for lineno, line in read_asm(os.path.join(pokered, "data/items/names.asm")):
        m = re.match(r'li\s+"([^"]*)"', line.strip())
        if m:
            names.append(m.group(1))

    prices = []
    for lineno, line in read_asm(os.path.join(pokered, "data/items/prices.asm")):
        m = re.match(r"bcd3\s+([\d]+)", line.strip())
        if m:
            prices.append(int(m.group(1)))

    # KeyItemFlags bit array (toss/deposit eligibility uses THIS, not
    # price==0: e.g. MOON_STONE has price 0 but is tossable)
    key_flags = []
    for lineno, line in read_asm(os.path.join(pokered, "data/items/key_items.asm")):
        m = re.match(r"dbit\s+(TRUE|FALSE)", line.strip())
        if m:
            key_flags.append(m.group(1) == "TRUE")

    out = {}
    for i, const in enumerate(consts):
        if i >= len(names):
            break  # named items only; machines are added below
        out[const] = {
            "id": const,
            "index": i + 1,
            "name": names[i].replace("#", "POKé"),
            "price": prices[i] if i < len(prices) else 0,
            "source": f"data/items/names.asm (entry {i + 1})",
        }
        if i < len(key_flags) and key_flags[i]:
            out[const]["keyItem"] = True
    if "POKE_BALL" not in out or out["POKE_BALL"]["price"] != 200:
        util.die("item extraction sanity check failed (POKE_BALL price != 200)")

    hms, tms = parse_machines(pokered)
    tm_prices = parse_tm_prices(pokered)
    for n, move in enumerate(hms, start=1):
        out["HM_" + move] = {
            "id": "HM_" + move,
            "name": "HM%02d" % n,
            "price": 0,
            "machine": {"kind": "HM", "number": n, "move": move},
            "source": "constants/item_constants.asm (add_hm)",
        }
    for n, move in enumerate(tms, start=1):
        out["TM_" + move] = {
            "id": "TM_" + move,
            "name": "TM%02d" % n,
            "price": tm_prices[n - 1] if n - 1 < len(tm_prices) else 0,
            "machine": {"kind": "TM", "number": n, "move": move},
            "source": "constants/item_constants.asm (add_tm)",
        }
    if len(tms) != 50 or len(hms) != 5:
        warn(f"expected 50 TMs / 5 HMs, got {len(tms)}/{len(hms)}")

    util.write_lua(os.path.join(out_dir, "items.lua"), out,
                   header="Sources: constants/item_constants.asm, data/items/names.asm,\n"
                          "prices.asm, tm_prices.asm")
    return out
