#!/usr/bin/env bash
# Packages the LÖVE2D Pokémon Red port into an Android APK via love-android 11.5a.
#
# Usage: scripts/build_android.sh [--version X.Y.Z] [--package-only]
#
#   --version X.Y.Z  set app.version_name / app.version_code (else left as-is)
#   --package-only   zip game.love + apply branding; skip gradle
#
# Prerequisites:
#   - mobile/android vendored love-android tree at tag 11.5a (in-repo; see mobile/ANDROID.md)
#   - Android SDK + NDK (SDK API 34, NDK 25.2.9519653)
#   - JDK 17
#
# Output (after gradle):
#   dist/android/debug/*.apk (convenience copy)
#   mobile/android/app/build/outputs/apk/embedNoRecord/debug/*.apk

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_DIR="$ROOT/mobile/android"
EMBED_ASSETS="$ANDROID_DIR/app/src/embed/assets"
LOVE_FILE="$EMBED_ASSETS/game.love"
DIST="$ROOT/dist/android"
APP_NAME="Pokemon Red"
APPLICATION_ID="com.theboisclub.pokemonred"
LOVE_ANDROID_VERSION="11.5a"
NDK_VERSION="25.2.9519653"

VERSION=""
PACKAGE_ONLY=false

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift ;;
    --package-only) PACKAGE_ONLY=true ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *) fail "unknown argument: $1 (try --version X.Y.Z or --package-only)" ;;
  esac
  shift
done

VERSION_CODE=""
if [ -n "$VERSION" ]; then
  if ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    fail "invalid --version '$VERSION' (expected X.Y.Z)"
  fi
  major="${VERSION%%.*}"
  rest="${VERSION#*.}"
  minor="${rest%%.*}"
  patch="${rest##*.}"
  VERSION_CODE=$((major * 10000 + minor * 100 + patch))
fi

# --------------------------------------------------------------- preconditions
if [ ! -f "$ANDROID_DIR/settings.gradle" ] || [ ! -f "$ANDROID_DIR/gradlew" ]; then
  fail "love-android not found at mobile/android/.
  The love-android $LOVE_ANDROID_VERSION tree is vendored in this repo,  your checkout
  looks incomplete. Re-clone or 'git checkout -- mobile/android'. See mobile/ANDROID.md."
fi

if [ ! -d "$ANDROID_DIR/love/src/jni/love/src" ]; then
  fail "liblove sources missing under mobile/android/love/src/jni/love/.
  They are vendored in this repo,  your checkout looks incomplete.
  Re-clone or 'git checkout -- mobile/android'. See mobile/ANDROID.md."
fi

# --------------------------------------------------------------- branding
# love-android 11.5+ reads app id / name / orientation from gradle.properties.
# Manifest still gets permission trims. Re-applied every build so refreshing
# the vendored love-android tree does not lose project settings.
apply_android_branding() {
  local props="$ANDROID_DIR/gradle.properties"
  local manifest="$ANDROID_DIR/app/src/main/AndroidManifest.xml"
  [ -f "$props" ] || fail "missing $props"
  [ -f "$manifest" ] || fail "missing $manifest"

  say "applying Android branding (gradle.properties + permission trim)"

  python3 - "$props" "$APPLICATION_ID" "$APP_NAME" "$VERSION" "$VERSION_CODE" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
app_id, name, version, version_code = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
text = path.read_text()

def set_prop(text, key, value):
    pat = re.compile(rf"(?m)^{re.escape(key)}=.*$")
    line = f"{key}={value}"
    if pat.search(text):
        return pat.sub(line, text)
    return text.rstrip() + "\n" + line + "\n"

# Prefer plain app.name; clear byte-array form so it cannot win.
text = re.sub(r"(?m)^app\.name_byte_array=.*\n?", "", text)
text = set_prop(text, "app.name", name)
text = set_prop(text, "app.application_id", app_id)
text = set_prop(text, "app.orientation", "portrait")
if version:
    text = set_prop(text, "app.version_name", version)
    text = set_prop(text, "app.version_code", version_code)
path.write_text(text)
PY

  python3 - "$manifest" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()

# Drop network / mic / legacy storage,  not needed for offline play.
# Keep VIBRATE (love.system.vibrate) and BLUETOOTH (optional gamepads).
# Orientation / label come from gradle.properties placeholders.
for perm in (
    "android.permission.INTERNET",
    "android.permission.RECORD_AUDIO",
    "android.permission.WRITE_EXTERNAL_STORAGE",
):
    text = re.sub(
        rf'\s*<uses-permission android:name="{re.escape(perm)}"[^/]*/>\s*',
        "\n",
        text,
    )
text = re.sub(r'\s*android:usesCleartextTraffic="true"', "", text)
path.write_text(text)
PY
}

# --------------------------------------------------------------- game.love
pack_game_love() {
  say "packing game.love for love-android embed flavor"
  mkdir -p "$EMBED_ASSETS"
  rm -f "$LOVE_FILE"
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

# --------------------------------------------------------------- SDK check
require_android_sdk() {
  local sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
  if [ -z "$sdk" ]; then
    for candidate in \
      "$HOME/Library/Android/sdk" \
      "$HOME/Android/Sdk" \
      /usr/local/lib/android/sdk; do
      if [ -d "$candidate" ]; then
        sdk="$candidate"
        break
      fi
    done
  fi

  if [ -z "$sdk" ] || [ ! -d "$sdk" ]; then
    fail "Android SDK not found.
  Install Android Studio (or command-line tools), then either:
    export ANDROID_SDK_ROOT=\$HOME/Library/Android/sdk
  or create mobile/android/local.properties with:
    sdk.dir=/path/to/Android/sdk
  love-android $LOVE_ANDROID_VERSION expects SDK API 34 and NDK $NDK_VERSION
  (see mobile/ANDROID.md)."
  fi

  export ANDROID_SDK_ROOT="$sdk"
  export ANDROID_HOME="$sdk"

  local props="$ANDROID_DIR/local.properties"
  # Always rewrite so a leftover Docker sdk.dir=/opt/android-sdk cannot stick.
  printf 'sdk.dir=%s\n' "$sdk" > "$props"

  if ! command -v java >/dev/null 2>&1; then
    fail "java not found. Install JDK 17 (Android Studio's bundled JDK is fine)."
  fi

  if [ ! -d "$sdk/ndk/$NDK_VERSION" ]; then
    warn "NDK $NDK_VERSION not found under $sdk/ndk/"
    warn "Install via SDK Manager (Show Package Details → NDK $NDK_VERSION)."
  fi
}

# --------------------------------------------------------------- gradle
run_gradle() {
  local task="assembleEmbedNoRecordDebug"
  say "building APK ($task)"

  if ! (
    cd "$ANDROID_DIR"
    ./gradlew --no-daemon "$task"
  ); then
    fail "gradle $task failed.
  Packaging already wrote: $LOVE_FILE
  Common causes: missing SDK/NDK $NDK_VERSION, or JDK ≠ 17. See mobile/ANDROID.md.
  You can still iterate on the .love payload with: scripts/build_android.sh --package-only"
  fi

  local out_dir="$ANDROID_DIR/app/build/outputs/apk/embedNoRecord/debug"
  if [ -d "$out_dir" ]; then
    say "APK output:"
    find "$out_dir" -name '*.apk' -exec ls -lh {} \;

    local dist_dir="$DIST/debug"
    rm -rf "$dist_dir"
    mkdir -p "$dist_dir"
    find "$out_dir" -name '*.apk' -exec cp {} "$dist_dir/" \;
    say "copied to $dist_dir/"
  else
    warn "gradle finished but no APK dir at $out_dir,  check gradle logs above"
  fi
}

# --------------------------------------------------------------- main
apply_android_branding
pack_game_love

if $PACKAGE_ONLY; then
  say "package-only: skipping gradle (game.love + branding ready under mobile/android/)"
  exit 0
fi

require_android_sdk
run_gradle
say "done"
