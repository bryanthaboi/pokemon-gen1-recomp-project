#!/usr/bin/env bash
# Run the LÖVE2D Pokémon Red port (macOS-friendly).
#
# Assumes scripts/setup.sh has been run once (generated data present and
# LÖVE installed).  Extra arguments are passed through to LÖVE.
#
# Link play is peer-to-peer (lua-enet, bundled with LÖVE): one player
# picks HOST A GAME in START > LINK and reads out the address shown;
# the other picks JOIN A GAME and types it in.  UDP port 7777 by
# default (override with POKEPORT_LINK_PORT on both sides).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$ROOT/data/generated/maps.lua" ] \
  || fail "generated data missing,  run scripts/setup.sh first"

find_love() {
  command -v love >/dev/null 2>&1 && { echo "love"; return; }
  for app in "/Applications/love.app" "$HOME/Applications/love.app"; do
    if [ -x "$app/Contents/MacOS/love" ]; then
      echo "$app/Contents/MacOS/love"
      return
    fi
  done
  return 1
}

LOVE_BIN="$(find_love)" \
  || fail "LÖVE not found,  run scripts/setup.sh (or install from https://love2d.org)"

exec "$LOVE_BIN" "$ROOT" "$@"
