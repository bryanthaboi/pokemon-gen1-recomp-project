#!/usr/bin/env bash
# Packages the LÖVE2D Pokémon Red port into distributable macOS and
# Windows builds. Runs entirely on macOS (no cross-compiling needed, 
# the Windows build reuses LÖVE's prebuilt win64 binaries).
#
# Usage: scripts/build.sh [mac|win|android|ios|all] [--version X.Y.Z] [--identity "Developer ID Application: ..."]
#                          [--notary-profile NAME] [--no-notarize]
#                          [--release]   # android/ios: release config instead of debug
#
# Output: dist/mac/PokemonRed-macos.zip
#         dist/win/PokemonRed-win64.zip
#         dist/android/{debug,release}/*.apk (full gradle output stays under
#           mobile/android/app/build/outputs/apk/embedNoRecord/)
#         dist/ios/<Config>-<sdk>/PokemonRed.app (full xcodebuild output stays
#           under mobile/ios/build/Build/Products/)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HERE="$ROOT/.bazinga"
CACHE="$HERE/cache"
WORK="$HERE/work"
DIST="$ROOT/dist"
ENTITLEMENTS="$ROOT/scripts/macos-entitlements.plist"

APP_NAME="PokemonRed"
BUNDLE_ID="com.theboisclub.pokemonred"
LOVE_VERSION="11.5"
VERSION="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo dev)"
IDENTITY=""
TARGET="all"
NOTARY_PROFILE="notary-profile"
NOTARIZE=true
ANDROID_RELEASE=false
IOS_RELEASE=false

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    mac|win|android|ios|all) TARGET="$1" ;;
    --version) VERSION="$2"; shift ;;
    --identity) IDENTITY="$2"; shift ;;
    --notary-profile) NOTARY_PROFILE="$2"; shift ;;
    --no-notarize) NOTARIZE=false ;;
    --release) ANDROID_RELEASE=true; IOS_RELEASE=true ;;
    *) fail "unknown argument: $1" ;;
  esac
  shift
done

mkdir -p "$CACHE" "$WORK" "$DIST/mac" "$DIST/win"

# --------------------------------------------------------------- game.love
say "packing game.love"
LOVE_FILE="$WORK/game.love"
rm -f "$LOVE_FILE"
(cd "$ROOT" && zip -q -9 -r "$LOVE_FILE" \
  main.lua conf.lua src data assets tools/rom_manifest.json \
  -x '*.DS_Store' 'data/generated/*' 'assets/generated/*')
if unzip -Z1 "$LOVE_FILE" \
    | grep -Eq '^(data|assets)/generated/[^/]+|^(data|assets)/generated/.+/'; then
  fail "game.love unexpectedly contains generated ROM data"
fi
say "game.love: $(du -h "$LOVE_FILE" | cut -f1)"

# --------------------------------------------------------------- macOS
build_mac() {
  say "building macOS app"
  local love_app="${LOVE_APP:-/Applications/love.app}"
  [ -d "$love_app" ] || fail "LÖVE.app not found at $love_app (install it or set LOVE_APP=/path/to/love.app)"

  local out_app="$WORK/$APP_NAME.app"
  rm -rf "$out_app"
  cp -R "$love_app" "$out_app"

  # drop any bundled placeholder .love and fuse ours in
  find "$out_app/Contents/Resources" -maxdepth 1 -name '*.love' -delete
  cp "$LOVE_FILE" "$out_app/Contents/Resources/game.love"

  local plist="$out_app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_NAME" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_NAME" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_ID" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$plist"

  if [ -f "$ROOT/assets/icon.icns" ]; then
    cp "$ROOT/assets/icon.icns" "$out_app/Contents/Resources/GameIcon.icns"
  fi

  local id="$IDENTITY"
  if [ -z "$id" ]; then
    id="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Developer ID Application' | head -1 | sed -E 's/^[^"]*"(.*)"$/\1/' || true)"
  fi
  if [ -n "$id" ]; then
    say "codesigning with: $id"
    codesign --deep --force --options runtime --timestamp \
      --entitlements "$ENTITLEMENTS" --sign "$id" "$out_app"
    codesign --verify --deep --strict --verbose=2 "$out_app"
  else
    warn "no 'Developer ID Application' identity found,  shipping unsigned."
    warn "install your cert in Keychain Access, then re-run (or pass --identity \"Developer ID Application: Name (TEAMID)\")."
    warn "unsigned builds will be Gatekeeper-blocked on other Macs; notarize with 'xcrun notarytool submit' once signed."
    NOTARIZE=false
  fi

  if [ "$NOTARIZE" = true ]; then
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
      warn "keychain profile '$NOTARY_PROFILE' not found/working,  skipping notarization."
      warn "set it up with: xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id ... --team-id ... --password ..."
    else
      local notarize_zip="$WORK/$APP_NAME-notarize.zip"
      rm -f "$notarize_zip"
      (cd "$WORK" && ditto -c -k --keepParent "$APP_NAME.app" "$notarize_zip")
      say "submitting to Apple notary service (this can take a few minutes)"
      xcrun notarytool submit "$notarize_zip" --keychain-profile "$NOTARY_PROFILE" --wait
      say "stapling notarization ticket"
      xcrun stapler staple "$out_app"
      rm -f "$notarize_zip"
    fi
  fi

  local zip_out="$DIST/mac/$APP_NAME-macos.zip"
  rm -f "$zip_out"
  (cd "$WORK" && ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$zip_out")
  say "macOS build: $zip_out"
}

# --------------------------------------------------------------- Windows
build_win() {
  say "building Windows (win64) app"
  local zip_name="love-$LOVE_VERSION-win64.zip"
  local love_zip="$CACHE/$zip_name"
  if [ ! -f "$love_zip" ]; then
    say "downloading LÖVE $LOVE_VERSION win64 binaries"
    curl -fL --progress-bar \
      "https://github.com/love2d/love/releases/download/$LOVE_VERSION/$zip_name" \
      -o "$love_zip" || fail "download failed,  check LOVE_VERSION or your network"
  fi

  local extract_dir="$WORK/love-win64"
  rm -rf "$extract_dir"
  mkdir -p "$extract_dir"
  unzip -q "$love_zip" -d "$extract_dir"
  local love_dir
  love_dir="$(find "$extract_dir" -maxdepth 1 -mindepth 1 -type d | head -1)"

  local out_dir="$WORK/$APP_NAME-win64"
  rm -rf "$out_dir"
  mkdir -p "$out_dir"
  cp "$love_dir"/*.dll "$out_dir"/
  cp "$love_dir"/license.txt "$out_dir"/ 2>/dev/null || true

  cat "$love_dir/love.exe" "$LOVE_FILE" > "$out_dir/$APP_NAME.exe"

  local zip_out="$DIST/win/$APP_NAME-win64.zip"
  rm -f "$zip_out"
  (cd "$WORK" && zip -q -9 -r "$zip_out" "$APP_NAME-win64")
  say "Windows build: $zip_out"
}

# --------------------------------------------------------------- Android
build_android() {
  say "building Android (delegating to scripts/build_android.sh)"
  local args=()
  if [ "$ANDROID_RELEASE" = true ]; then
    args+=(--release)
  fi
  "$ROOT/scripts/build_android.sh" ${args[@]+"${args[@]}"}
}

# --------------------------------------------------------------- iOS
build_ios() {
  say "building iOS (delegating to scripts/build_ios.sh)"
  local args=()
  if [ "$IOS_RELEASE" = true ]; then
    args+=(--release)
  fi
  "$ROOT/scripts/build_ios.sh" ${args[@]+"${args[@]}"}
}

case "$TARGET" in
  mac) build_mac ;;
  win) build_win ;;
  android) build_android ;;
  ios) build_ios ;;
  all) build_mac; build_win ;;
esac

case "$TARGET" in
  android) say "done. See $DIST/android/" ;;
  ios) say "done. See $DIST/ios/" ;;
  *) say "done. Artifacts in $DIST" ;;
esac
