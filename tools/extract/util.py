"""Shared helpers for parsing RGBDS assembly from pret/pokered.

Every extractor in this package reads specific known files, parses known
macros/tables, warns on unsupported syntax, and fails loudly on malformed
output.  See docs/extraction-notes.md.
"""

import os
import re
import sys

WARNINGS = []


def warn(msg):
    WARNINGS.append(msg)
    print(f"warning: {msg}", file=sys.stderr)


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(1)


# We build the Red version: rgbasm-style conditionals resolve with
# _RED defined, so IF DEF(_BLUE) blocks are dropped (the wild data,
# title mons, prizes etc. are version-gated in pokered).
ASM_DEFINES = {"_RED"}

_IF_RE = None

def read_asm(path):
    """Read an asm file as a list of (lineno, text) with comments stripped.

    Semicolon comments are removed, but semicolons inside double-quoted
    strings are preserved.  IF DEF(x)/ELSE/ENDC blocks are resolved
    against ASM_DEFINES; unrecognized IF conditions keep their body
    (safe for the non-version conditionals we do not model).
    """
    import re as _re
    lines = []
    # stack of (taking, condition_known) for nested IFs
    stack = []
    with open(path, encoding="utf-8") as f:
        for lineno, raw in enumerate(f, 1):
            line = strip_comment(raw.rstrip("\n"))
            s = line.strip()
            m = _re.match(
                r"IF\s+DEF\((\w+)\)\s*\|\|\s*DEF\((\w+)\)\s*$",
                s, _re.IGNORECASE)
            if m:
                taking = any(name in ASM_DEFINES for name in m.groups())
                stack.append([taking, True])
                continue
            m = _re.match(r"IF\s+(!)?DEF\((\w+)\)\s*$", s, _re.IGNORECASE)
            if m:
                defined = m.group(2) in ASM_DEFINES
                taking = (not defined) if m.group(1) else defined
                stack.append([taking, True])
                continue
            if _re.match(r"IF\b", s):
                stack.append([True, False])  # unmodeled condition: keep body
                continue
            if _re.match(r"ELSE\s*$", s, _re.IGNORECASE) and stack:
                if stack[-1][1]:
                    stack[-1][0] = not stack[-1][0]
                continue
            if _re.match(r"ENDC\s*$", s, _re.IGNORECASE) and stack:
                stack.pop()
                continue
            if any(not fr[0] for fr in stack):
                continue
            lines.append((lineno, line))
    return lines


def strip_comment(line):
    out = []
    in_str = False
    for ch in line:
        if ch == '"':
            in_str = not in_str
        elif ch == ";" and not in_str:
            break
        out.append(ch)
    return "".join(out).rstrip()


def parse_number(tok):
    """Parse an RGBDS numeric literal: $hex, %binary, decimal, or -N."""
    tok = tok.strip()
    neg = tok.startswith("-")
    if neg:
        tok = tok[1:].strip()
    if tok.startswith("$"):
        val = int(tok[1:], 16)
    elif tok.startswith("%"):
        val = int(tok[1:], 2)
    elif tok.isdigit():
        val = int(tok)
    else:
        raise ValueError(f"not a number: {tok!r}")
    return -val if neg else val


def split_args(argstr):
    """Split macro arguments on commas, respecting double quotes."""
    args, cur, in_str = [], [], False
    for ch in argstr:
        if ch == '"':
            in_str = not in_str
            cur.append(ch)
        elif ch == "," and not in_str:
            args.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    tail = "".join(cur).strip()
    if tail:
        args.append(tail)
    return args


def parse_const_block(path, stop_at=None):
    """Parse a file of `const_def` / `const NAME` style constant lists.

    Returns an ordered list of names (index = const value, starting at the
    most recent const_def base).  Only handles the simple linear form used by
    e.g. sprite_constants.asm and pokemon_constants.asm.
    """
    names = []
    value = None
    for lineno, line in read_asm(path):
        s = line.strip()
        if not s:
            continue
        if stop_at and re.match(rf"DEF\s+{stop_at}\b", s):
            break
        m = re.match(r"const_def(?:\s+(\d+))?$", s)
        if m:
            value = int(m.group(1)) if m.group(1) else 0
            continue
        m = re.match(r"const\s+(\w+)", s)
        if m and value is not None:
            while len(names) < value:
                names.append(None)
            names.append(m.group(1))
            value += 1
            continue
        m = re.match(r"const_skip(?:\s+(\d+))?$", s)
        if m and value is not None:
            n = int(m.group(1)) if m.group(1) else 1
            for _ in range(n):
                names.append(None)
            value += n
    return names


# ---------------------------------------------------------------------------
# Lua serialization
# ---------------------------------------------------------------------------

LUA_KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
    "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return",
    "then", "true", "until", "while",
}

_IDENT_RE = re.compile(r"^[A-Za-z_]\w*$")


def _lua_key(k):
    if isinstance(k, int):
        return f"[{k}]"
    if _IDENT_RE.match(k) and k not in LUA_KEYWORDS:
        return k
    return "[" + _lua_str(k) + "]"


def _lua_str(s):
    out = s.replace("\\", "\\\\").replace('"', '\\"')
    out = out.replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
    out = out.replace("\f", "\\f").replace("\v", "\\v")
    return '"' + out + '"'


def lua_value(v, indent=0, compact_lists=True):
    pad = "  " * indent
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return repr(v)
    if isinstance(v, str):
        return _lua_str(v)
    if isinstance(v, (list, tuple)):
        if not v:
            return "{}"
        items = [lua_value(x, indent + 1, compact_lists) for x in v]
        if compact_lists and all(isinstance(x, (int, float)) for x in v):
            # wrap long numeric arrays
            lines, cur = [], []
            for it in items:
                cur.append(it)
                if sum(len(c) + 2 for c in cur) > 90:
                    lines.append(", ".join(cur) + ",")
                    cur = []
            if cur:
                lines.append(", ".join(cur) + ",")
            if len(lines) == 1 and len(lines[0]) <= 92:
                return "{ " + lines[0].rstrip(",") + " }"
            body = ("\n" + pad + "  ").join(lines)
            return "{\n" + pad + "  " + body + "\n" + pad + "}"
        body = (",\n" + pad + "  ").join(items)
        return "{\n" + pad + "  " + body + ",\n" + pad + "}"
    if isinstance(v, dict):
        if not v:
            return "{}"
        keys = sorted(v.keys(), key=lambda k: (isinstance(k, str), k))
        parts = []
        for k in keys:
            parts.append(f"{_lua_key(k)} = {lua_value(v[k], indent + 1, compact_lists)}")
        body = (",\n" + pad + "  ").join(parts)
        return "{\n" + pad + "  " + body + ",\n" + pad + "}"
    raise TypeError(f"cannot serialize {type(v)}")


def write_lua(path, value, header=None):
    """Write `return <value>` as a Lua module.  Deterministic output."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("-- Generated by tools/build_data.py. DO NOT EDIT.\n")
        if header:
            for line in header.splitlines():
                f.write(f"-- {line}\n")
        f.write("return ")
        f.write(lua_value(value))
        f.write("\n")
    print(f"wrote {path}")
