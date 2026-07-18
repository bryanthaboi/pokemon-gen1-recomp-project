"""Extract dialogue text and the character map.

Sources:
  text/*.asm            -> _SomeText:: labels with text/line/cont/para macros
  constants/charmap.asm -> character -> glyph code mapping (for the font)
  scripts/<Map>.asm     -> TEXT_* constant -> text label resolution

Text encoding in the generated tables:
  \n  new line inside a page   (`line`)
  \v  scrolled line            (`cont`)
  \f  new page                 (`para` / <PAGE>)
  {PLAYER} {RIVAL} {TARGET} {USER} ...  runtime string tokens

`#` expands to "POKé" and <PKMN>/<PC>/<TM>/... expand per the charmap, so
generated strings contain plain (UTF-8) text renderable by the glyph font.

Unknown text commands emit warnings and a {UNSUPPORTED:...} token so nothing
is silently dropped (docs/extraction-notes.md lists the known ones).
"""

import os
import re

from . import util
from .util import read_asm, warn

# Multi-char charmap sequences that expand to plain text.
EXPANSIONS = {
    "#": "POKé",
    "<PKMN>": "POKéMON",
    "<PC>": "PC",
    "<TM>": "TM",
    "<TRAINER>": "TRAINER",
    "<ROCKET>": "ROCKET",
    "<……>": "……",
    "<LV>": "{LV}",
    "<PLAYER>": "{PLAYER}",
    "<RIVAL>": "{RIVAL}",
    "<TARGET>": "{TARGET}",
    "<USER>": "{USER}",
    "<ID>": "{ID}",
    "<PARA>": "\f",
    "<PAGE>": "\f",
    "<LINE>": "\n",
    "<CONT>": "\v",
    "<NEXT>": "\n",
    "<DONE>": "",
    "<PROMPT>": "",
    "<NULL>": "",
    "@": "",
}

# text macro -> separator prepended before its string argument
STRING_MACROS = {
    "text": "",
    "next": "\n",   # not used in red, but harmless
    "line": "\n",
    "cont": "\v",
    "para": "\f",
    "page": "\f",
    "text_start": "",
}

# Macros that end a text block.
END_MACROS = {"done", "prompt", "text_end", "text_promptbutton",
              "text_waitbutton", "dex"}

# Macros we understand but represent as tokens (dynamic content).
DYNAMIC_MACROS = {
    "text_ram": "RAM",
    "text_decimal": "NUM",
    "text_bcd": "NUM",
    "text_low": "",
    "text_pause": "",
    "text_dots": "DOTS",
}


def decode_string(s, lineno, path):
    """Expand charmap sequences inside a quoted asm string."""
    out = []
    i = 0
    while i < len(s):
        ch = s[i]
        if ch == "<":
            end = s.find(">", i)
            if end == -1:
                warn(f"{path}:{lineno}: unterminated <...> in string")
                out.append(ch)
                i += 1
                continue
            tok = s[i:end + 1]
            if tok in EXPANSIONS:
                out.append(EXPANSIONS[tok])
            else:
                # single glyph tokens like <BOLD_V>, <COLON>, <ED>
                out.append("{" + tok[1:-1] + "}")
            i = end + 1
        elif ch in EXPANSIONS:
            out.append(EXPANSIONS[ch])
            i += 1
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def parse_text_file(path, texts, rel):
    """Parse one text/*.asm file into texts[label] = string."""
    label = None
    parts = []
    unsupported = set()
    skip_vc_branch = False

    def flush():
        nonlocal label, parts
        if label is not None:
            texts[label] = {"text": "".join(parts), "source": rel}
        label, parts = None, []

    for lineno, line in read_asm(path):
        s = line.strip()
        if not s:
            continue
        if s.startswith("vc_patch "):
            continue
        if s.startswith("IF DEF(_RED_VC) || DEF(_BLUE_VC)"):
            skip_vc_branch = True
            continue
        if skip_vc_branch:
            if s == "ELSE":
                skip_vc_branch = False
            continue
        if s in ("ENDC", "vc_patch_end"):
            continue
        m = re.match(r"(_\w+)::?\s*$", s)
        if m:
            flush()
            label = m.group(1)
            continue
        if label is None:
            continue
        m = re.match(r"(\w+)(?:\s+(.*))?$", s)
        if not m:
            continue
        macro, rest = m.group(1), (m.group(2) or "").strip()
        if macro in STRING_MACROS:
            sm = re.match(r'"((?:[^"\\]|\\.)*)"', rest)
            if sm:
                parts.append(STRING_MACROS[macro] + decode_string(sm.group(1), lineno, rel))
            elif rest:
                warn(f"{rel}:{lineno}: {macro} without string literal: {rest!r}")
            continue
        if macro in END_MACROS:
            flush()
            continue
        if macro in DYNAMIC_MACROS:
            tokname = DYNAMIC_MACROS[macro]
            if tokname:
                parts.append("{" + tokname + ":" + rest.replace('"', "") + "}")
            continue
        if macro in ("text_far", "text_asm"):
            # text banks sometimes chain; record a link token
            parts.append("{FAR:" + rest + "}" if macro == "text_far" else "{ASM}")
            continue
        unsupported.add(macro)
        parts.append("{UNSUPPORTED:" + macro + "}")

    flush()
    for macro in sorted(unsupported):
        warn(f"{rel}: unsupported text macro '{macro}'")


def parse_marts(pokered):
    """data/items/marts.asm: clerk text label -> script_mart item list."""
    marts = {}
    label = None
    for lineno, line in read_asm(os.path.join(pokered, "data/items/marts.asm")):
        s = line.strip()
        m = re.match(r"(\w+)::?\s*$", s)
        if m:
            label = m.group(1)
            continue
        m = re.match(r"script_mart\s+(.*)$", s)
        if m and label:
            marts[label] = [a for a in re.split(r",\s*", m.group(1)) if a]
            label = None
    return marts


def parse_script_text_pointers(pokered):
    """Resolve TEXT_* constants to text labels via scripts/*.asm.

    A `dw_const SomeText, TEXT_FOO` entry points at a local label whose body
    is usually `text_far _SomeText` + `text_end`.  Bodies containing
    text_asm are flagged so the runtime knows a hand-ported script owns
    them.  Special TX_SCRIPT macros are recognized: script_mart item lists
    (also resolved from data/items/marts.asm for labels defined there),
    script_pokecenter_nurse, script_pokecenter_pc and
    script_cable_club_receptionist (engine/link/cable_club_npc.asm).
    Returns {map_label: {TEXT_CONST: {text=..., asm=bool, mart=..., ...}}}.
    """
    scripts_dir = os.path.join(pokered, "scripts")
    marts = parse_marts(pokered)
    result = {}
    for fname in sorted(os.listdir(scripts_dir)):
        if not fname.endswith(".asm"):
            continue
        map_label = fname[:-4]
        path = os.path.join(scripts_dir, fname)
        lines = read_asm(path)
        pointers = {}   # TEXT_CONST -> local label
        for lineno, line in lines:
            m = re.match(r"dw_const\s+(\w+),\s*(TEXT_\w+)", line.strip())
            if m:
                pointers[m.group(2)] = m.group(1)

        # index label -> line span
        label_at = {}
        for i, (lineno, line) in enumerate(lines):
            m = re.match(r"(\w+):{1,2}\s*$", line.strip())
            if m:
                label_at[m.group(1)] = i

        entries = {}
        for const, label in pointers.items():
            info = {"label": label}
            i = label_at.get(label)
            if i is None:
                if label in marts:
                    info["mart"] = marts[label]
                else:
                    info["asm"] = True
            else:
                j = i + 1
                fars = []
                is_asm = False
                while j < len(lines):
                    s = lines[j][1].strip()
                    j += 1
                    if not s:
                        continue
                    if re.match(r"\w+:{1,2}\s*$", s):  # next top-level label
                        break
                    m = re.match(r"text_far\s+(\w+)", s)
                    if m:
                        fars.append(m.group(1))
                        continue
                    if s.startswith("text_asm"):
                        is_asm = True
                        continue
                    m = re.match(r"script_mart\s+(.*)$", s)
                    if m:
                        info["mart"] = [a for a in re.split(r",\s*", m.group(1)) if a]
                        continue
                    if s.startswith("script_pokecenter_nurse"):
                        info["nurse"] = True
                        continue
                    if s.startswith("script_pokecenter_pc"):
                        info["pc"] = True
                        continue
                    if s.startswith("script_cable_club_receptionist"):
                        # TX_SCRIPT_CABLE_CLUB_RECEPTIONIST -> CableClubNPC
                        # (home/text_script.asm, engine/link/cable_club_npc.asm)
                        info["cableClub"] = True
                        continue
                    if s.startswith("text_end") or s == "done":
                        break
                if fars:
                    info["text"] = fars[0]
                if is_asm:
                    info["asm"] = True
            entries[const] = info
        if entries:
            result[map_label] = entries
    return result


def parse_trainer_headers(pokered):
    """Extract per-map trainer headers from scripts/*.asm.

    `def_trainers N` gives the object index of the first trainer (default
    1); each `trainer EVENT, range, BattleText, EndBattleText,
    AfterBattleText` row applies to consecutive objects.  The three text
    labels are local labels resolved through their `text_far` bodies.
    Returns {map_label: {objIndex: {event, range, battle, won, after}}}.
    """
    scripts_dir = os.path.join(pokered, "scripts")
    result = {}
    for fname in sorted(os.listdir(scripts_dir)):
        if not fname.endswith(".asm"):
            continue
        map_label = fname[:-4]
        lines = read_asm(os.path.join(scripts_dir, fname))

        # local label -> first text_far target
        far_of = {}
        current = None
        for lineno, line in lines:
            s = line.strip()
            m = re.match(r"(\w+):{1,2}\s*$", s)
            if m:
                current = m.group(1)
                continue
            m = re.match(r"text_far\s+(\w+)", s)
            if m and current and current not in far_of:
                far_of[current] = m.group(1)

        start = None
        headers = {}
        idx = 0
        for lineno, line in lines:
            s = line.strip()
            m = re.match(r"def_trainers(?:\s+(\d+))?$", s)
            if m:
                start = int(m.group(1)) if m.group(1) else 1
                idx = 0
                continue
            m = re.match(r"trainer\s+(EVENT_\w+),\s*(\d+),\s*(\w+),\s*(\w+),\s*(\w+)", s)
            if m and start is not None:
                obj_index = start + idx
                idx += 1
                headers[obj_index] = {
                    "event": m.group(1),
                    "range": int(m.group(2)),
                    "battle": far_of.get(m.group(3)),
                    "won": far_of.get(m.group(4)),
                    "after": far_of.get(m.group(5)),
                    "source": f"scripts/{fname}:{lineno}",
                }
        if headers:
            result[map_label] = headers
    return result


def extract(pokered, out_dir):
    texts = {}
    text_dir = os.path.join(pokered, "text")
    for fname in sorted(os.listdir(text_dir)):
        if fname.endswith(".asm"):
            parse_text_file(os.path.join(text_dir, fname), texts, f"text/{fname}")
    # engine strings (nurse dialogue, battle messages, ...) live in
    # data/text/text_*.asm with the same macro format
    data_text_dir = os.path.join(pokered, "data/text")
    for fname in sorted(os.listdir(data_text_dir)):
        if re.match(r"text_\d+\.asm$", fname):
            parse_text_file(os.path.join(data_text_dir, fname), texts,
                            f"data/text/{fname}")
    # Pokédex descriptions
    parse_text_file(os.path.join(pokered, "data/pokemon/dex_text.asm"), texts,
                    "data/pokemon/dex_text.asm")

    pointers = parse_script_text_pointers(pokered)
    trainer_headers = parse_trainer_headers(pokered)

    util.write_lua(os.path.join(out_dir, "text.lua"),
                   {k: v["text"] for k, v in sorted(texts.items())},
                   header="Source: pret/pokered text/*.asm")
    util.write_lua(os.path.join(out_dir, "text_pointers.lua"), pointers,
                   header="Source: pret/pokered scripts/*.asm (def_text_pointers tables)\n"
                          "Entries may carry mart/nurse/pc/cableClub markers from TX_SCRIPT macros.")
    util.write_lua(os.path.join(out_dir, "trainer_headers.lua"), trainer_headers,
                   header="Source: pret/pokered scripts/*.asm (def_trainers tables)\n"
                          "Keyed by map label, then object index; range is sight distance.")
    return texts, pointers
