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
# Debug APK (default Android debug keystore)
scripts/build_android.sh

# Release APK (signing is manual,  see below)
scripts/build_android.sh --release

# Zip game.love + branding only (no Android SDK required)
scripts/build_android.sh --package-only
```

Or via `scripts/build.sh android`.

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

- Debug task: `assembleEmbedNoRecordDebug`
- Release task: `assembleEmbedNoRecordRelease`

APKs land under `app/build/outputs/apk/embedNoRecord/{debug,release}/`.
`scripts/build_android.sh` also copies the built APK(s) to `dist/android/{debug,release}/`.

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
| Permissions | INTERNET / RECORD_AUDIO / WRITE_EXTERNAL_STORAGE stripped; VIBRATE + BLUETOOTH kept |

## Signing

- **Debug**: default Android debug keystore (no setup).
- **Release**: out-of-band. Create a keystore yourself and wire it into
  `app/build.gradle`,  **do not commit keystores or passwords**.

Example (placeholder only):

```bash
keytool -genkey -v -keystore /path/to/pokemonred-release.jks \
  -alias pokemonred -keyalg RSA -keysize 2048 -validity 10000
```
