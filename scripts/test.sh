#!/usr/bin/env bash
# Unified test entry point (21-testing-and-ci §CI).
#
# Runs every tier that this checkout can run and exits non-zero if any of
# them fails.  The tier split is what makes that possible: T1/T2/T4 need
# nothing but the committed fixture dataset, so they run anywhere --
# including CI, which has no ROM.  T3 asserts Pokemon Red facts and needs
# data/generated/, so it is skipped automatically when the ROM has never
# been imported rather than failing the run.
#
#   scripts/test.sh                 every tier this checkout can run
#   scripts/test.sh --quick         skip the slow content tier
#   scripts/test.sh --bless         re-pin the fingerprint goldens
#   WITH_SHOTS=1 scripts/test.sh    also capture and diff golden shots
#                                   (fails today -- see the T5 block below)
#
# LUA overrides the interpreter (luajit here; CI installs lua5.4 too, but
# the engine targets LuaJIT/5.1 semantics so luajit is the default).

set -uo pipefail

cd "$(dirname "$0")/.."

LUA=${LUA:-luajit}
BLESS=0
QUICK=0
SHOTS=${WITH_SHOTS:-0}

for arg in "$@"; do
  case "$arg" in
    --bless) BLESS=1 ;;
    --bless-shots) SHOTS=1; BLESS=1 ;;
    --quick) QUICK=1 ;;
    --help|-h) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if ! command -v "$LUA" >/dev/null 2>&1; then
  echo "no lua interpreter '$LUA' on PATH (set LUA=...)" >&2
  exit 2
fi

# The save-directory sandbox (conf.lua reads POKEPORT_IDENTITY) is scoped
# to the shot tier, which is the only one that starts a real LOVE process
# and could write into a developer's save folder.  Exporting it for the
# whole run instead would change what SaveIO.defaultPath() returns, and the
# save-editor suite pins that to the default identity.
SANDBOX_IDENTITY="ci-$$"

FAILED=()
run_tier() {
  local label="$1"; shift
  echo ""
  echo "=============================================================="
  echo "  $label"
  echo "=============================================================="
  if "$@"; then
    echo "-- $label: PASS"
  else
    echo "-- $label: FAIL"
    FAILED+=("$label")
  fi
}

# ------- ROM-free tiers: these are what CI runs

run_tier "T1/T2 engine invariants + parity gates" "$LUA" tests/run_engine.lua
run_tier "T4 mod-SDK" "$LUA" tests/run_modkit.lua

# The modded-link desync suite (symmetric mod, handshake fail-closed,
# extra-bag round trip) is ROM-free and runs inside the T4 tier above, as
# tests/modkit/cases/link_desync.lua.
#
# tests/run_link_tests.lua is a different matter: it calls Data:load() at
# :27 and so needs data/generated/.  It is grouped with the content tier
# until that bootstrap can take an injected dataset.
# ------- content tier: only meaningful with an imported ROM


# tests/run_tests.lua is expected to be clean.  It used to carry two stale
# chip-audio assertions on the allowlist below (Pikachu cry WAV exists /
# low-health alarm sfx extracted); both have since been fixed, so the
# baseline is zero and any failure fails the tier.  Keep the allowlist
# mechanism rather than ignoring the exit code -- that would hide every
# future content regression.
KNOWN_CONTENT_FAILURES=0
KNOWN_CONTENT_LINES=""

run_content_behavior() {
  local out
  out=$("$LUA" tests/run_tests.lua 2>&1)
  local count
  count=$(printf '%s\n' "$out" | grep -c '^FAIL ' || true)
  local lines
  lines=$(printf '%s\n' "$out" | grep '^FAIL ' | sort)

  if [ "$count" -eq "$KNOWN_CONTENT_FAILURES" ] \
     && [ "$lines" = "$(printf '%s\n' "$KNOWN_CONTENT_LINES" | sort)" ]; then
    printf '%s\n' "$out" | tail -3
    if [ "$KNOWN_CONTENT_FAILURES" -gt 0 ]; then
      echo "(the $KNOWN_CONTENT_FAILURES known stale assertions, unchanged)"
    fi
    return 0
  fi

  printf '%s\n' "$out" | grep '^FAIL ' || true
  printf '%s\n' "$out" | tail -2
  echo "expected exactly $KNOWN_CONTENT_FAILURES known failures; got $count"
  return 1
}

if [ -f data/generated/maps.lua ]; then
  if [ "$QUICK" = "1" ]; then
    echo ""
    echo "-- T3 content: skipped (--quick)"
  else
    run_tier "T3 content behavior (Red)" run_content_behavior
    run_tier "T3 save editor" "$LUA" tests/run_save_editor_tests.lua
    run_tier "T5 link (loopback lockstep)" "$LUA" tests/run_link_tests.lua
  fi
else
  echo ""
  echo "-- T3 content + run_link_tests: skipped (no data/generated/ --"
  echo "   import a ROM to run them; the modded-link cases ran in T4)"
fi

# ------- golden screenshots: needs love + a display

if [ "$SHOTS" = "1" ]; then
  SHOT_DIR=${SHOT_DIR:-/tmp/pokeport-shots}
  export SHOT_DIR
  mkdir -p "$SHOT_DIR"
  SHOT_DRIVER=tests/drivers/shots_fixture.lua

  # The fixture goldens are not capturable yet.  A driver only ever runs
  # after main.lua's bootGame(), so it cannot redirect Data:load(), and
  # src/core/Data.lua has no POKEPORT_DATA_DIR branch -- 21-testing-and-ci
  # §"Engine changes" specifies one, but it is not implemented, so a LOVE
  # process has no way to boot tests/fixture_data.  On a ROM-less checkout
  # main.lua does not even reach the game: RomImporter.isReady() is false
  # and it opens the importer instead.
  #
  # WITH_SHOTS is opt-in, so asking for a tier that cannot run is an error,
  # not a skip.  Reporting "pass" here is what made the whole pipeline look
  # delivered while never diffing a single pixel.
  if [ ! -f "$SHOT_DRIVER" ]; then
    echo ""
    echo "-- T5 shots: NOT WIRED ($SHOT_DRIVER does not exist)."
    echo "   Fixture capture needs the POKEPORT_DATA_DIR override in"
    echo "   src/core/Data.lua so LOVE can boot tests/fixture_data."
    FAILED+=("T5 shots (requested but not wired)")
  elif ! command -v love >/dev/null 2>&1; then
    echo ""
    echo "-- T5 shots: love is not on PATH but WITH_SHOTS was requested"
    FAILED+=("T5 shots (love missing)")
  else
    RUNNER="love ."
    command -v xvfb-run >/dev/null 2>&1 && RUNNER="xvfb-run -a love ."
    run_tier "T5 shot capture" \
      env POKEPORT_IDENTITY="$SANDBOX_IDENTITY" POKEPORT_DRIVER="$SHOT_DRIVER" $RUNNER
    if [ "$BLESS" = "1" ]; then
      run_tier "T5 shot bless" \
        python3 tools/compare_shots.py tests/goldens/shots "$SHOT_DIR" --bless
    else
      run_tier "T5 shot diff" \
        python3 tools/compare_shots.py tests/goldens/shots "$SHOT_DIR"
    fi
  fi
fi

# ------- fingerprint blessing

if [ "$BLESS" = "1" ] && [ "$SHOTS" != "1" ]; then
  echo ""
  echo "re-pinning fingerprint goldens (deliberate parity change -- record it"
  echo "in docs/known-differences.md or docs/new-features.md)"
  "$LUA" tests/bless_fingerprints.lua || FAILED+=("fingerprint bless")
fi

# ------- verdict

echo ""
echo "=============================================================="
if [ ${#FAILED[@]} -eq 0 ]; then
  echo "  ALL TIERS PASSED"
  echo "=============================================================="
  exit 0
fi

echo "  ${#FAILED[@]} TIER(S) FAILED"
for tier in "${FAILED[@]}"; do echo "    - $tier"; done
echo "=============================================================="
exit 1
