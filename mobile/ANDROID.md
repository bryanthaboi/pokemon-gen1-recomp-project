# Android (love-android 11.5a)

`mobile/android/` is a **vendored copy** of
[love2d/love-android](https://github.com/love2d/love-android) at tag
**11.5a** (matches `conf.lua` `t.version = "11.5"`), tracked directly in
this repo,  no git submodules involved. Nested `love` sources live at
`mobile/android/love/src/jni/love` (also vendored). Build outputs
(`app/build/`, `love/build/`, `.gradle/`, `local.properties`) stay
gitignored.

## Refreshing the vendored tree

To pick up a newer love-android release, replace the tree and re-vendor:

```bash
rm -rf mobile/android
git clone --depth 1 --branch <new-tag> --recurse-submodules --shallow-submodules \
  https://github.com/love2d/love-android.git mobile/android
rm -rf mobile/android/.git mobile/android/love/src/jni/love/.git \
       mobile/android/.gitmodules
```

`scripts/build_android.sh` re-applies project branding on every run
(`gradle.properties` app id / name / portrait, plus permission trims), so a
refresh is safe,  just rebuild.

## Build

```bash
# Build the APK
scripts/build_android.sh

# Build the APK, setting app.version_name/app.version_code to match a release
scripts/build_android.sh --version 0.2.5

# Zip game.love + branding only (no Android SDK required)
scripts/build_android.sh --package-only
```

Or via `scripts/build.sh android [--version X.Y.Z]`.

The embedded `game.love` deliberately excludes `data/generated/`,
`assets/generated/`, and any ROM. It contains the first-boot Lua importer and
`tools/rom_manifest.json`.

The current importer has desktop file pickers only. A production Android
release still needs a Storage Access Framework handoff that passes the chosen
ROM to LÖVE; the APK packaging itself is data-free.

### SDK / NDK

love-android 11.5a expects:

- **JDK 17**
- Android SDK with **API 34**
- NDK **25.2.9519653** (Apple Silicon host supported)

Set `ANDROID_SDK_ROOT` (or `ANDROID_HOME`), or let the script write
`local.properties` when it finds `~/Library/Android/sdk`.

Gradle flavor used: **`embedNoRecord`** (game fused into the APK, no microphone).
Build task: `assembleEmbedNoRecordDebug`.

The APK lands under `app/build/outputs/apk/embedNoRecord/debug/`.
`scripts/build_android.sh` also copies it to `dist/android/debug/`.

### Payload path

`app/src/embed/assets/game.love` - zip of `main.lua`, `conf.lua`, `src/`,
`data/`, `assets/`, and `tools/rom_manifest.json`. Generated game data,
scripts, tests, and mobile build sources are excluded.

## Branding (applied by the build script)

| Setting | Value |
| --- | --- |
| `app.application_id` | `com.theboisclub.pokemonred` |
| `app.name` | Pokemon Red |
| `app.orientation` | `portrait` |
| `app.version_name` / `app.version_code` | set from `--version X.Y.Z` (code = major*10000 + minor*100 + patch); left as-is if `--version` is omitted |
| Permissions | INTERNET / RECORD_AUDIO / WRITE_EXTERNAL_STORAGE stripped; VIBRATE + BLUETOOTH kept |

## Releases

`.github/workflows/release.yml` builds the APK with `--version` set to the
release version and publishes it alongside the macOS/Windows/Linux builds as
`PokemonRed-<version>-android.apk`.

## Signing

Signed with the default Android keystore (no setup required).
