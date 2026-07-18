# iOS build (LÖVE 11.5)

macOS + Xcode only. Pins the official **LÖVE 11.5** iOS Xcode tree
(`love-11.5-ios-source.zip` from [love2d/love releases](https://github.com/love2d/love/releases/tag/11.5)),
matching `conf.lua`'s `t.version = "11.5"`.

There is no separate `love2d/love-ios` GitHub repo for 11.5; the release zip
**is** the vendored iOS project (Xcode project under
`love-src/platform/xcode/love.xcodeproj`, target `love-ios`).

Pin file: [`LOVE_VERSION`](./LOVE_VERSION) → `11.5`.

## Quick start (simulator)

```bash
# Fetch LÖVE 11.5 iOS sources (once) + build for Simulator
scripts/build_ios.sh --fetch
```

The embedded `game.love` contains no ROM or generated game data. The current
first-boot importer has desktop file pickers only, so a production iOS release
still needs a UIDocumentPicker handoff that passes the selected ROM to LÖVE.

Default output: an unsigned Simulator `.app` under `mobile/ios/build/`
(no Apple Developer account required). A convenience copy also lands under
`dist/ios/<Config>-<sdk>/`.

Install on a booted simulator (example):

```bash
xcrun simctl install booted mobile/ios/build/Build/Products/Debug-iphonesimulator/PokemonRed.app
xcrun simctl launch booted com.theboisclub.pokemonred
```

Or open `mobile/ios/love-src/platform/xcode/love.xcodeproj` in Xcode,
select the `love-ios` target, and Run on a Simulator after
`scripts/build_ios.sh --package-only` (or a full build) has placed `game.love`.

## Device / Release

```bash
scripts/build_ios.sh --device            # Debug, physical device SDK
scripts/build_ios.sh --device --release  # Release configuration
```

Device builds need a signing identity and provisioning profile configured in
Xcode (or via `DEVELOPMENT_TEAM` / `CODE_SIGN_IDENTITY` env vars). This repo
does **not** store certificates, profiles, or App Store Connect secrets.

Manual out-of-band steps:

1. Apple Developer account + App ID for `com.theboisclub.pokemonred`
2. Development or Distribution certificate + provisioning profile
3. In Xcode: open `love.xcodeproj` → target `love-ios` → Signing & Capabilities
   → select your Team (or set `DEVELOPMENT_TEAM=XXXXXXXXXX` when invoking
   `scripts/build_ios.sh --device`)
4. Archive / export an `.ipa` from Xcode Organizer for TestFlight / Ad Hoc

## Layout

| Path | Role |
|------|------|
| `LOVE_VERSION` | Engine pin (`11.5`) |
| `overlays/love-ios.plist` | Portrait-only Info.plist + display name **Pokemon Red** (copied over the upstream plist every build) |
| `love-src/` | Downloaded `love-11.5-ios-source` tree (**gitignored**,  do not commit) |
| `cache/` | Downloaded zips (**gitignored**) |
| `build/` | `xcodebuild` derived data (**gitignored**) |

Game payload lands at:

`love-src/platform/xcode/ios/resources/game.love`

and is fused into the built `.app` (LÖVE auto-runs any bundled `*.love`).

## Apple libraries dependency

The official `love-11.5-ios-source.zip` already ships prebuilt iOS
xcframeworks under `platform/xcode/ios/libraries/` (SDL2, LuaJIT, freetype,
ogg, vorbis, theora, modplug).

If that folder is missing or incomplete (e.g. you cloned sources without
libs), download the matching prebuilts and install them:

```bash
curl -fL -o mobile/ios/cache/love-11.5-apple-libraries.zip \
  https://github.com/love2d/love/releases/download/11.5/love-11.5-apple-libraries.zip
unzip -q mobile/ios/cache/love-11.5-apple-libraries.zip -d mobile/ios/cache
rm -rf mobile/ios/love-src/platform/xcode/ios/libraries
cp -R mobile/ios/cache/love-apple-dependencies/iOS/libraries \
  mobile/ios/love-src/platform/xcode/ios/libraries
```

`scripts/build_ios.sh` checks for `libraries/SDL2.xcframework` and fails with
these instructions if it is absent.

Upstream also documents
[love-apple-dependencies](https://github.com/love2d/love-apple-dependencies)
as an alternate source of the same libraries.

## App identity

| Field | Value |
|-------|--------|
| Display name | Pokemon Red |
| `PRODUCT_NAME` | PokemonRed |
| Bundle ID | `com.theboisclub.pokemonred` |
| Orientations | Portrait only (`UIInterfaceOrientationPortrait`) |

Overrides are applied by the build script (`xcodebuild` settings + plist overlay)
so refreshing `love-src/` does not lose branding.

## Flags (`scripts/build_ios.sh`)

| Flag | Meaning |
|------|---------|
| *(default)* | Simulator, Debug, no signing |
| `--fetch` | Download/extract `love-11.5-ios-source.zip` if `love-src/` is missing |
| `--device` | Build against `iphoneos` instead of `iphonesimulator` |
| `--release` | `Release` configuration instead of `Debug` |
| `--package-only` | Zip `game.love` + apply plist overlay; skip `xcodebuild` |

Also: `scripts/build.sh ios` delegates here (`--release` is forwarded).

## Preconditions

- macOS (Darwin) with Xcode + `xcodebuild` on `PATH`
- iOS platform installed in Xcode (Settings → Platforms). `xcodebuild -showsdks`
  should list `iphonesimulator` / `iphoneos`. A partial install can fail IB/xib
  compiles with `iOS … Platform Not Installed` even when the SDK name appears.
- `love-src/` present (`--fetch` or manual unzip of `love-11.5-ios-source.zip`)
- iOS libraries under `love-src/platform/xcode/ios/libraries/` (see above)
