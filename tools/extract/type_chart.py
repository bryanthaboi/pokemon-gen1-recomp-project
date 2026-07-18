"""Extract the Gen 1 type effectiveness chart.

Source: data/types/type_matchups.asm
  db attacker, defender, SUPER_EFFECTIVE|NOT_VERY_EFFECTIVE|NO_EFFECT

Also extracts type names from data/types/names.asm.
Output: data/generated/type_chart.lua
Multipliers are stored x10 (20 = 2x, 5 = 0.5x, 0 = immune) like the game.
"""

import os
import re

from . import util
from .util import read_asm, split_args

EFFECT = {"SUPER_EFFECTIVE": 20, "NOT_VERY_EFFECTIVE": 5, "NO_EFFECT": 0}


def extract(pokered, out_dir):
    matchups = []
    for lineno, line in read_asm(os.path.join(pokered, "data/types/type_matchups.asm")):
        m = re.match(r"db\s+(.*)$", line.strip())
        if not m:
            continue
        a = split_args(m.group(1))
        if len(a) != 3 or a[0] == "-1":
            continue
        if a[2] not in EFFECT:
            util.warn(f"type_matchups.asm:{lineno}: unknown effectiveness {a[2]}")
            continue
        matchups.append({"attacker": a[0], "defender": a[1], "multiplier": EFFECT[a[2]]})
    if len(matchups) < 50:
        util.die(f"type chart parsed only {len(matchups)} rows")

    names = []
    for lineno, line in read_asm(os.path.join(pokered, "data/types/names.asm")):
        m = re.match(r'(?:\.\w+:\s*)?db\s+"([^"@]*)@?"', line.strip())
        if m:
            names.append(m.group(1))

    util.write_lua(os.path.join(out_dir, "type_chart.lua"),
                   {"source": "data/types/type_matchups.asm",
                    "matchups": matchups, "names": names},
                   header="Multipliers are x10: 20 = super effective, 5 = not very, 0 = immune.")
    return matchups
