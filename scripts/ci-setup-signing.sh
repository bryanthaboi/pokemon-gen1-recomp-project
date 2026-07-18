#!/usr/bin/env bash
# One-time setup of the local signing + notarization material used by
# .github/workflows/release.yml to codesign + notarize the macOS build on the
# self-hosted runner.
#
# The self-hosted runner IS this Mac, so the material stays here in a protected
# directory (default ~/.config/pokemon-ci) instead of GitHub secrets. This
# avoids GitHub's ~48 KB per-secret limit (a multi-identity .p12 is far larger)
# and keeps the private key on your machine.
#
# Writes:
#   $CI_DIR/signing.p12   - your Developer ID signing identity (cert + key)
#   $CI_DIR/signing.pass  - random password protecting that .p12
#   $CI_DIR/notary.env    - APPLE_ID / APPLE_TEAM_ID / APPLE_APP_PASSWORD
#
# Run on the runner machine:  bash scripts/ci-setup-signing.sh
set -euo pipefail

CI_DIR="${POKEMON_CI_DIR:-$HOME/.config/pokemon-ci}"
LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

mkdir -p "$CI_DIR"
chmod 700 "$CI_DIR"

# --- Team ID (auto-detect from the Developer ID Application identity) --------
TEAM_ID="$(security find-identity -v -p codesigning \
  | sed -n -E 's/.*Developer ID Application:.*\(([A-Z0-9]{10})\).*/\1/p' | head -1)"
[ -n "$TEAM_ID" ] || fail "No 'Developer ID Application' identity found in your keychain"
say "Detected Team ID: $TEAM_ID"

# --- Export the signing identity to a password-protected .p12 ---------------
P12PW="$(openssl rand -base64 24)"
P12="$CI_DIR/signing.p12"
say "Exporting signing identity from the login keychain to $P12"
say "(macOS may prompt for your login password / to allow export — that's expected)"
security export -k "$LOGIN_KC" -t identities -f pkcs12 -P "$P12PW" -o "$P12" \
  || fail "export failed — unlock the keychain and retry, or export via Keychain Access"
[ -s "$P12" ] || fail "exported .p12 is empty"
printf '%s' "$P12PW" > "$CI_DIR/signing.pass"
chmod 600 "$P12" "$CI_DIR/signing.pass"
say "Wrote signing.p12 ($(wc -c < "$P12" | tr -d ' ') bytes) + signing.pass"

# --- Notarization credentials ----------------------------------------------
read -rp  "Apple ID email (for notarization): " APPLE_ID
[ -n "$APPLE_ID" ] || fail "Apple ID is required"
read -rsp "App-specific password (from appleid.apple.com): " APPLE_APP_PASSWORD; echo
[ -n "$APPLE_APP_PASSWORD" ] || fail "App-specific password is required"

umask 077
cat > "$CI_DIR/notary.env" <<EOF
APPLE_ID=$APPLE_ID
APPLE_TEAM_ID=$TEAM_ID
APPLE_APP_PASSWORD=$APPLE_APP_PASSWORD
EOF
chmod 600 "$CI_DIR/notary.env"
say "Wrote notary.env"

say "Done. Material stored in $CI_DIR:"
ls -l "$CI_DIR"
say "Re-run the Release workflow (Actions tab) — or push to main — for a signed + notarized release."
