#!/usr/bin/env bash
# One-shot: full setup, then launch the game (macOS-friendly).
#
# Usage: scripts/play.sh [--rom /path/to/pokemon-red.gb]

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

"$HERE/setup.sh" "$@"
exec "$HERE/run.sh"
