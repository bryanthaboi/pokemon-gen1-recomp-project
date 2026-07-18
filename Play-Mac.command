#!/bin/bash
# Pokémon Red (LÖVE2D) - double-click launcher for macOS.
#
# First run: decodes a user-provided .gb file, installs anything missing,
# builds the game data, then launches.
# Every later run: launches the game straight away.

cd "$(dirname "$0")" || exit 1

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m !!\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31merror:\033[0m %s\n' "$*"; }

pause_exit() { # keep the Terminal window readable after a failure
  echo
  read -n 1 -s -r -p "Press any key to close this window..."
  echo
  exit "${1:-0}"
}

ask() { # ask "question" -> yes by default
  local a
  read -r -p "$1 [Y/n] " a
  case "$a" in n|N|no|NO) return 1 ;; *) return 0 ;; esac
}

printf '\n  \033[1mPokémon Red - LÖVE2D port\033[0m\n\n'

have_love() {
  command -v love >/dev/null 2>&1 && return 0
  [ -x "/Applications/love.app/Contents/MacOS/love" ] && return 0
  [ -x "$HOME/Applications/love.app/Contents/MacOS/love" ] && return 0
  return 1
}

# ---------------------------------------------------------------- fast path
if [ -f data/generated/maps.lua ] && have_love; then
  say "already set up, launching the game"
  scripts/run.sh || { err "the game failed to start"; pause_exit 1; }
  exit 0
fi

say "first-time setup"

# ------------------------------------------------------- Xcode CLT (python3)
if ! command -v python3 >/dev/null 2>&1; then
  warn "python3 is missing; it comes with Apple's command-line tools"
  if ask "Install Apple's command-line tools now?"; then
    xcode-select --install 2>/dev/null || true
    echo
    warn "Finish the Apple installer window that just opened, then"
    warn "double-click Play-Mac.command again to continue."
    pause_exit 0
  else
    err "cannot continue without python3"
    pause_exit 1
  fi
fi

# ----------------------------------------------------------------- Homebrew
if ! have_love && ! command -v brew >/dev/null 2>&1 \
    && [ ! -x /opt/homebrew/bin/brew ] && [ ! -x /usr/local/bin/brew ]; then
  warn "LÖVE (the game engine) is not installed; the easiest installer is Homebrew"
  if ask "Install Homebrew now? (asks for your macOS password)"; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
      || { err "Homebrew install failed"; pause_exit 1; }
  else
    warn "OK, download LÖVE 11.x yourself from https://love2d.org,"
    warn "drop love.app into /Applications, then run this again."
    pause_exit 1
  fi
fi
# make brew visible in THIS shell (fresh installs aren't on PATH yet)
[ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"
[ -x /usr/local/bin/brew ]    && eval "$(/usr/local/bin/brew shellenv)"

# ------------------------------------------------------------------- build
echo
scripts/setup.sh \
  || { err "setup failed - see the messages above"; pause_exit 1; }

say "setup done, launching the game"
scripts/run.sh || { err "the game failed to start"; pause_exit 1; }
exit 0
