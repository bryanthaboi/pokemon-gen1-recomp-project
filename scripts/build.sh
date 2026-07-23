#!/usr/bin/env bash
# Packages the LÖVE2D Pokémon Red port into distributable macOS, Windows,
# and Linux builds. Runs entirely on macOS (no cross-compiling needed,
# the Windows and Linux builds reuse LÖVE's prebuilt win64 / AppImage
# binaries, fusing our game.love onto them the same way love.exe does).
#
# Usage: scripts/build.sh [mac|win|linux|android|ios|all] [--version X.Y.Z] [--identity "Developer ID Application: ..."]
#                          [--notary-profile NAME] [--no-notarize]
#                          [--release]   # ios only: release config instead of debug
#
# Output: dist/mac/gen1recomp-macos.zip
#         dist/win/gen1recomp-win64.zip
#         dist/linux/gen1recomp-linux.zip (fused x86_64 AppImage)
#         dist/android/debug/*.apk (full gradle output stays under
#           mobile/android/app/build/outputs/apk/embedNoRecord/)
#         dist/ios/<Config>-<sdk>/gen1recomp.app (full xcodebuild output stays
#           under mobile/ios/build/Build/Products/)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HERE="$ROOT/.bazinga"
CACHE="$HERE/cache"
WORK="$HERE/work"
DIST="$ROOT/dist"
ENTITLEMENTS="$ROOT/scripts/macos-entitlements.plist"

APP_NAME="gen1recomp"
BUNDLE_ID="com.theboisclub.pokemonred"
LOVE_VERSION="11.5"
VERSION="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo dev)"
VERSION_EXPLICIT=false
IDENTITY=""
TARGET="all"
NOTARY_PROFILE="notary-profile"
NOTARIZE=true
IOS_RELEASE=false

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    mac|win|linux|android|ios|all) TARGET="$1" ;;
    --version) VERSION="$2"; VERSION_EXPLICIT=true; shift ;;
    --identity) IDENTITY="$2"; shift ;;
    --notary-profile) NOTARY_PROFILE="$2"; shift ;;
    --no-notarize) NOTARIZE=false ;;
    --release) IOS_RELEASE=true ;;
    *) fail "unknown argument: $1" ;;
  esac
  shift
done

mkdir -p "$CACHE" "$WORK" "$DIST/mac" "$DIST/win" "$DIST/linux"

# --------------------------------------------------------------- game.love
say "packing game.love"
LOVE_FILE="$WORK/game.love"
rm -f "$LOVE_FILE"
(cd "$ROOT" && zip -q -9 -r "$LOVE_FILE" \
  main.lua conf.lua src data assets tools/rom_manifest.json tools/rom_manifest_blue.json \
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
  # A cache hit only checks existence, not validity -- a prior run truncated
  # by a network drop mid-download (curl still leaves the partial file if
  # the exit code slips through) would otherwise be reused forever.
  if [ -f "$love_zip" ] && ! unzip -tqq "$love_zip" >/dev/null 2>&1; then
    warn "cached $zip_name is not a valid zip,  removing and re-downloading"
    rm -f "$love_zip"
  fi
  if [ ! -f "$love_zip" ]; then
    say "downloading LÖVE $LOVE_VERSION win64 binaries"
    curl -fL --progress-bar \
      "https://github.com/love2d/love/releases/download/$LOVE_VERSION/$zip_name" \
      -o "$love_zip" || fail "download failed,  check LOVE_VERSION or your network"
    unzip -tqq "$love_zip" >/dev/null 2>&1 \
      || fail "downloaded $zip_name is not a valid zip (truncated download?)"
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

# --------------------------------------------------------------- Linux
build_linux() {
  say "building Linux (x86_64 AppImage) app"
  local appimage_name="love-$LOVE_VERSION-x86_64.AppImage"
  local love_appimage="$CACHE/$appimage_name"
  # Same cache-validity gap as the win64 zip above: an AppImage is just an
  # ELF, so check the magic bytes before trusting a cached copy is complete.
  if [ -f "$love_appimage" ] && [ "$(head -c 4 "$love_appimage" | od -An -tx1 | tr -d ' \n')" != "7f454c46" ]; then
    warn "cached $appimage_name is not a valid ELF binary,  removing and re-downloading"
    rm -f "$love_appimage"
  fi
  if [ ! -f "$love_appimage" ]; then
    say "downloading LÖVE $LOVE_VERSION Linux AppImage"
    curl -fL --progress-bar \
      "https://github.com/love2d/love/releases/download/$LOVE_VERSION/$appimage_name" \
      -o "$love_appimage" || fail "download failed,  check LOVE_VERSION or your network"
    [ "$(head -c 4 "$love_appimage" | od -An -tx1 | tr -d ' \n')" = "7f454c46" ] \
      || fail "downloaded $appimage_name is not a valid ELF binary (truncated download?)"
  fi
  chmod +x "$love_appimage"

  # The Windows-style `cat love.exe game.love` fusion does NOT work here:
  # an AppImage is a small runtime ELF with a squashfs appended, and at
  # launch the runtime mounts the squashfs and executes bin/love from
  # *inside* it -- bytes appended to the outer file are never read, so
  # users would just get vanilla LÖVE's no-game screen. Instead, unpack
  # the squashfs, drop game.love in, point AppRun's FUSE_PATH hook at it
  # (the hook ships commented-out in LÖVE's official AppImage), and glue
  # runtime + repacked squashfs back together.
  command -v unsquashfs >/dev/null && command -v mksquashfs >/dev/null \
    || fail "squashfs tools not found; install with: brew install squashfs"

  # The squashfs starts right where the ELF ends:
  # e_shoff + e_shnum * e_shentsize (all little-endian in the ELF64 header).
  local e_shoff e_shentsize e_shnum sfs_offset
  e_shoff=$(od -An -j40 -N8 -tu8 "$love_appimage" | tr -d ' ')
  e_shentsize=$(od -An -j58 -N2 -tu2 "$love_appimage" | tr -d ' ')
  e_shnum=$(od -An -j60 -N2 -tu2 "$love_appimage" | tr -d ' ')
  sfs_offset=$((e_shoff + e_shentsize * e_shnum))
  [ "$(dd if="$love_appimage" bs=1 skip="$sfs_offset" count=4 2>/dev/null)" = "hsqs" ] \
    || fail "no squashfs superblock at computed offset $sfs_offset (unexpected AppImage layout)"

  local appdir="$WORK/linux-appdir"
  rm -rf "$appdir"
  unsquashfs -q -no-xattrs -o "$sfs_offset" -d "$appdir" "$love_appimage" >/dev/null

  cp "$LOVE_FILE" "$appdir/game.love"
  sed -i '' 's|^#FUSE_PATH="$APPDIR/my_game.love"$|FUSE_PATH="$APPDIR/game.love"|' "$appdir/AppRun"
  grep -q '^FUSE_PATH="\$APPDIR/game.love"$' "$appdir/AppRun" \
    || fail "failed to enable FUSE_PATH in AppRun (upstream AppRun changed?)"

  # Match the upstream image's compression (gzip, 128K blocks) so the
  # bundled runtime can read it.
  local sfs_out="$WORK/game.squashfs"
  rm -f "$sfs_out"
  mksquashfs "$appdir" "$sfs_out" \
    -comp gzip -b 131072 -noappend -all-root -no-xattrs -quiet >/dev/null

  local out_bin="$WORK/$APP_NAME-x86_64.AppImage"
  rm -f "$out_bin"
  head -c "$sfs_offset" "$love_appimage" > "$out_bin"
  cat "$sfs_out" >> "$out_bin"
  chmod +x "$out_bin"

  local zip_out="$DIST/linux/$APP_NAME-linux.zip"
  rm -f "$zip_out"
  (cd "$WORK" && zip -q -9 -j "$zip_out" "$(basename "$out_bin")")
  say "Linux build: $zip_out"
}

# --------------------------------------------------------------- Android
build_android() {
  say "building Android (delegating to scripts/build_android.sh)"
  local args=()
  if [ "$VERSION_EXPLICIT" = true ]; then
    args+=(--version "$VERSION")
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
  linux) build_linux ;;
  android) build_android ;;
  ios) build_ios ;;
  all) build_mac; build_win; build_linux ;;
esac

case "$TARGET" in
  android) say "done. See $DIST/android/" ;;
  ios) say "done. See $DIST/ios/" ;;
  *) say "done. Artifacts in $DIST" ;;
esac
