#!/usr/bin/env bash
# Packages the LÖVE2D Pokémon Red port into an iOS app via LÖVE 11.5's
# official iOS Xcode project (love-11.5-ios-source.zip).
#
# Usage: scripts/build_ios.sh [--fetch] [--device] [--release] [--package-only]
#
#   (default)         Simulator Debug (CODE_SIGNING_ALLOWED=NO)
#   --device          iphoneos SDK (needs signing / DEVELOPMENT_TEAM)
#   --release         Release configuration
#   --fetch           Download love-11.5-ios-source.zip into mobile/ios/love-src/
#   --package-only    Zip game.love + apply plist overlay; skip xcodebuild
#
# Prerequisites:
#   - macOS + Xcode (xcodebuild)
#   - mobile/ios/love-src/ (see --fetch / mobile/ios/README.md)
#   - prebuilt iOS libraries under love-src/platform/xcode/ios/libraries/
#
# Output: dist/ios/<Config>-<sdk>/PokemonRed.app (convenience copy)
#         mobile/ios/build/Build/Products/<Config>-<sdk>/PokemonRed.app

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS_DIR="$ROOT/mobile/ios"
LOVE_SRC="$IOS_DIR/love-src"
CACHE="$IOS_DIR/cache"
BUILD_DIR="$IOS_DIR/build"
DIST="$ROOT/dist/ios"
OVERLAY_PLIST="$IOS_DIR/overlays/love-ios.plist"
XCODE_DIR="$LOVE_SRC/platform/xcode"
PROJECT="$XCODE_DIR/love.xcodeproj"
RESOURCES_DIR="$XCODE_DIR/ios/resources"
LOVE_FILE="$RESOURCES_DIR/game.love"
LIBS_DIR="$XCODE_DIR/ios/libraries"

APP_NAME="PokemonRed"
DISPLAY_NAME="Pokemon Red"
BUNDLE_ID="com.theboisclub.pokemonred"
LOVE_VERSION="$(tr -d '[:space:]' < "$IOS_DIR/LOVE_VERSION" 2>/dev/null || echo 11.5)"
IOS_SOURCE_ZIP="love-${LOVE_VERSION}-ios-source.zip"
APPLE_LIBS_ZIP="love-${LOVE_VERSION}-apple-libraries.zip"
IOS_SOURCE_URL="https://github.com/love2d/love/releases/download/${LOVE_VERSION}/${IOS_SOURCE_ZIP}"
APPLE_LIBS_URL="https://github.com/love2d/love/releases/download/${LOVE_VERSION}/${APPLE_LIBS_ZIP}"

FETCH=false
DEVICE=false
RELEASE=false
PACKAGE_ONLY=false

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --fetch) FETCH=true ;;
    --device) DEVICE=true ;;
    --release) RELEASE=true ;;
    --package-only) PACKAGE_ONLY=true ;;
    -h|--help)
      sed -n '2,22p' "$0"
      exit 0
      ;;
    *) fail "unknown argument: $1 (try --fetch, --device, --release, or --package-only)" ;;
  esac
  shift
done

# --------------------------------------------------------------- host checks
if [ "$(uname -s)" != "Darwin" ]; then
  fail "iOS builds require macOS (Darwin). This host is $(uname -s).
  Run scripts/build_ios.sh on a Mac with Xcode installed."
fi

if ! $PACKAGE_ONLY; then
  command -v xcodebuild >/dev/null 2>&1 \
    || fail "xcodebuild not found. Install Xcode from the App Store, then run:
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
fi

# --------------------------------------------------------------- fetch love-src
fetch_love_ios() {
  mkdir -p "$CACHE"
  local zip_path="$CACHE/$IOS_SOURCE_ZIP"
  if [ ! -f "$zip_path" ]; then
    say "downloading $IOS_SOURCE_ZIP (LÖVE $LOVE_VERSION iOS sources)"
    curl -fL --progress-bar "$IOS_SOURCE_URL" -o "$zip_path" \
      || fail "download failed: $IOS_SOURCE_URL"
  else
    say "using cached $zip_path"
  fi

  say "extracting into $LOVE_SRC"
  rm -rf "$LOVE_SRC"
  local tmp
  tmp="$(mktemp -d "$CACHE/extract.XXXXXX")"
  unzip -q "$zip_path" -d "$tmp"
  # Zip root is love-<version>-ios-source/
  local extracted
  extracted="$(find "$tmp" -maxdepth 1 -mindepth 1 -type d ! -name '__MACOSX' | head -1)"
  [ -n "$extracted" ] || fail "unexpected layout inside $IOS_SOURCE_ZIP"
  mv "$extracted" "$LOVE_SRC"
  rm -rf "$tmp"
  say "love-src ready (LÖVE $LOVE_VERSION)"
}

if [ ! -d "$XCODE_DIR/love.xcodeproj" ]; then
  if $FETCH; then
    fetch_love_ios
  else
    fail "LÖVE $LOVE_VERSION iOS sources not found at mobile/ios/love-src/.
  Fetch them (documented download of love-${LOVE_VERSION}-ios-source.zip):
    scripts/build_ios.sh --fetch
  Or manually:
    mkdir -p mobile/ios/cache
    curl -fL -o mobile/ios/cache/$IOS_SOURCE_ZIP \\
      $IOS_SOURCE_URL
    unzip -q mobile/ios/cache/$IOS_SOURCE_ZIP -d mobile/ios/cache
    mv mobile/ios/cache/love-${LOVE_VERSION}-ios-source mobile/ios/love-src
  See mobile/ios/README.md."
  fi
elif $FETCH; then
  say "love-src already present; skipping download (delete mobile/ios/love-src to refresh)"
fi

[ -d "$XCODE_DIR/love.xcodeproj" ] \
  || fail "missing $PROJECT after fetch"

# --------------------------------------------------------------- apple libraries
require_ios_libraries() {
  if [ -d "$LIBS_DIR/SDL2.xcframework" ]; then
    return 0
  fi
  fail "prebuilt iOS libraries missing at:
  $LIBS_DIR
  love-ios expects SDL2.xcframework (and friends) there.

  The official love-${LOVE_VERSION}-ios-source.zip normally includes them.
  If they are absent, install love-${LOVE_VERSION}-apple-libraries.zip:

    mkdir -p mobile/ios/cache
    curl -fL -o mobile/ios/cache/$APPLE_LIBS_ZIP \\
      $APPLE_LIBS_URL
    unzip -q mobile/ios/cache/$APPLE_LIBS_ZIP -d mobile/ios/cache
    rm -rf mobile/ios/love-src/platform/xcode/ios/libraries
    cp -R mobile/ios/cache/love-apple-dependencies/iOS/libraries \\
      mobile/ios/love-src/platform/xcode/ios/libraries

  See mobile/ios/README.md (Apple libraries dependency)."
}

require_ios_libraries

# --------------------------------------------------------------- branding / plist
apply_ios_branding() {
  [ -f "$OVERLAY_PLIST" ] || fail "missing overlay plist: $OVERLAY_PLIST"
  local dest="$XCODE_DIR/ios/love-ios.plist"
  say "applying iOS branding (portrait-only Info.plist, display name)"
  cp "$OVERLAY_PLIST" "$dest"
}

# --------------------------------------------------------------- game.love
pack_game_love() {
  say "packing game.love for love-ios resources"
  mkdir -p "$RESOURCES_DIR"
  rm -f "$LOVE_FILE"
  # Same payload as scripts/build.sh / build_android.sh: game sources only.
  (cd "$ROOT" && zip -q -9 -r "$LOVE_FILE" \
    main.lua conf.lua src data assets tools/rom_manifest.json \
    -x '*.DS_Store' -x '*/.git/*' -x '*/.DS_Store' \
    -x 'data/generated/*' -x 'assets/generated/*')
  if unzip -Z1 "$LOVE_FILE" \
      | grep -Eq '^(data|assets)/generated/[^/]+|^(data|assets)/generated/.+/'; then
    fail "game.love unexpectedly contains generated ROM data"
  fi
  say "game.love: $(du -h "$LOVE_FILE" | cut -f1) -> $LOVE_FILE"
}

# Ensure game.love is in the love-ios Copy Bundle Resources phase (idempotent).
ensure_game_love_in_xcode() {
  local pbx="$XCODE_DIR/love.xcodeproj/project.pbxproj"
  [ -f "$pbx" ] || fail "missing $pbx"

  if grep -q 'ios/resources/game.love' "$pbx"; then
    return 0
  fi

  say "wiring game.love into love-ios Copy Bundle Resources"
  python3 - "$pbx" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
if "ios/resources/game.love" in text:
    raise SystemExit(0)

file_ref = "A1B2C3D41E5F678901234567"
build_file = "A1B2C3D41E5F678901234568"

file_ref_entry = (
    f"\t\t{file_ref} /* game.love */ = {{isa = PBXFileReference; "
    f"lastKnownFileType = file; name = game.love; "
    f'path = ios/resources/game.love; sourceTree = "<group>"; }};\n'
)
build_file_entry = (
    f"\t\t{build_file} /* game.love in Resources */ = {{isa = PBXBuildFile; "
    f"fileRef = {file_ref} /* game.love */; }};\n"
)

# PBXBuildFile section
marker = "/* Begin PBXBuildFile section */\n"
if marker not in text:
    raise SystemExit("PBXBuildFile section not found")
text = text.replace(marker, marker + build_file_entry, 1)

# PBXFileReference section
marker = "/* Begin PBXFileReference section */\n"
if marker not in text:
    raise SystemExit("PBXFileReference section not found")
text = text.replace(marker, marker + file_ref_entry, 1)

# Add to love-ios Resources build phase (FA0B7F041A95AAF3000E1D17)
old = (
    "\t\tFA0B7F041A95AAF3000E1D17 /* Resources */ = {\n"
    "\t\t\tisa = PBXResourcesBuildPhase;\n"
    "\t\t\tbuildActionMask = 2147483647;\n"
    "\t\t\tfiles = (\n"
    "\t\t\t\tFA5D249C1A96CF4300C6FC8F /* Images.xcassets in Resources */,\n"
    "\t\t\t\tFA7C636A1A9C49570000FD29 /* Launch Screen.xib in Resources */,\n"
    "\t\t\t);\n"
)
new = (
    "\t\tFA0B7F041A95AAF3000E1D17 /* Resources */ = {\n"
    "\t\t\tisa = PBXResourcesBuildPhase;\n"
    "\t\t\tbuildActionMask = 2147483647;\n"
    "\t\t\tfiles = (\n"
    "\t\t\t\tFA5D249C1A96CF4300C6FC8F /* Images.xcassets in Resources */,\n"
    "\t\t\t\tFA7C636A1A9C49570000FD29 /* Launch Screen.xib in Resources */,\n"
    f"\t\t\t\t{build_file} /* game.love in Resources */,\n"
    "\t\t\t);\n"
)
if old not in text:
    # Fallback: insert before the closing of that files = ( list if markers differ slightly
    needle = "\t\tFA0B7F041A95AAF3000E1D17 /* Resources */ = {"
    if needle not in text:
        raise SystemExit("love-ios Resources build phase not found")
    # Insert build file line after "files = (" within that block
    idx = text.index(needle)
    files_idx = text.index("files = (", idx)
    insert_at = text.index("\n", files_idx) + 1
    text = (
        text[:insert_at]
        + f"\t\t\t\t{build_file} /* game.love in Resources */,\n"
        + text[insert_at:]
    )
else:
    text = text.replace(old, new, 1)

# Add file ref to the ios group if present
ios_group = "FA5D24961A96CE0A00C6FC8F /* ios */ = {"
if ios_group in text and file_ref not in text[text.index(ios_group):text.index(ios_group)+400]:
    # Prefer adding under Resources group,  skip if structure unknown; path is absolute enough via sourceTree
    pass

path.write_text(text)
print("patched project.pbxproj")
PY
}

# --------------------------------------------------------------- xcodebuild
run_xcodebuild() {
  local config sdk destination
  if $RELEASE; then
    config="Release"
  else
    config="Debug"
  fi

  if $DEVICE; then
    sdk="iphoneos"
    destination="generic/platform=iOS"
  else
    sdk="iphonesimulator"
    destination="generic/platform=iOS Simulator"
  fi

  mkdir -p "$BUILD_DIR"

  # Prefer -target + SYMROOT over -derivedDataPath: modern Xcode requires
  # -scheme whenever -derivedDataPath is set, and love-ios ships no shared schemes.
  local args=(
    -project "$PROJECT"
    -target love-ios
    -configuration "$config"
    -sdk "$sdk"
    -destination "$destination"
    SYMROOT="$BUILD_DIR/Build/Products"
    OBJROOT="$BUILD_DIR/Build/Intermediates"
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"
    PRODUCT_NAME="$APP_NAME"
    MARKETING_VERSION="$LOVE_VERSION"
    ONLY_ACTIVE_ARCH=NO
  )

  if ! $DEVICE; then
    # Simulator: no signing required
    args+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=)
  else
    warn "device build: configure signing in Xcode or set DEVELOPMENT_TEAM / CODE_SIGN_IDENTITY"
    if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
      args+=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
    fi
    if [ -n "${CODE_SIGN_IDENTITY:-}" ]; then
      args+=(CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY")
    fi
  fi

  if ! xcodebuild -showsdks 2>/dev/null | grep -q "$sdk"; then
    fail "Xcode SDK '$sdk' is not installed (xcodebuild -showsdks).
  Open Xcode → Settings → Platforms (or Components) and install iOS.
  Simulator builds need the iOS Simulator platform; device builds need iOS."
  fi

  say "xcodebuild love-ios ($config / $sdk)"
  set +e
  (
    cd "$XCODE_DIR"
    xcodebuild "${args[@]}"
  )
  local xc_status=$?
  set -e
  if [ "$xc_status" -ne 0 ]; then
    fail "xcodebuild failed (exit $xc_status).
  Common causes:
    - iOS platform/SDK not installed in Xcode (Settings → Platforms)
    - device build without DEVELOPMENT_TEAM / provisioning (see mobile/ios/README.md)
    - Xcode too new for LÖVE $LOVE_VERSION sources (try an older Xcode)
  Packaging still succeeded: $LOVE_FILE"
  fi

  local products="$BUILD_DIR/Build/Products/${config}-${sdk}"
  local app="$products/$APP_NAME.app"
  if [ ! -d "$app" ]; then
    # PRODUCT_NAME override can still leave love.app on older projects
    if [ -d "$products/love.app" ]; then
      app="$products/love.app"
      warn "built app is love.app (PRODUCT_NAME override not applied); fusing game.love anyway"
    else
      warn "xcodebuild finished but no .app under $products"
      find "$BUILD_DIR/Build/Products" -name '*.app' 2>/dev/null | head -20 || true
      return 0
    fi
  fi

  # Fuse even if the pbxproj wire-up failed,  LÖVE runs any bundled *.love.
  if [ ! -f "$app/game.love" ]; then
    say "fusing game.love into $(basename "$app")"
    cp "$LOVE_FILE" "$app/game.love"
  fi

  local dist_dir="$DIST/${config}-${sdk}"
  rm -rf "$dist_dir"
  mkdir -p "$dist_dir"
  cp -R "$app" "$dist_dir/"
  say "copied to $dist_dir/$(basename "$app")"

  say "iOS app: $app"
  say "bundle id: $BUNDLE_ID  display: $DISPLAY_NAME"
  if $DEVICE; then
    warn "signing/provisioning is manual,  see mobile/ios/README.md"
  else
    say "simulator tip: xcrun simctl install booted \"$app\""
  fi
}

# --------------------------------------------------------------- main
apply_ios_branding
pack_game_love
ensure_game_love_in_xcode

if $PACKAGE_ONLY; then
  say "package-only: skipping xcodebuild (game.love + plist ready under mobile/ios/love-src/)"
  exit 0
fi

run_xcodebuild
say "done"
