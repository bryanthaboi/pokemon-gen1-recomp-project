#!/usr/bin/env bash

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: run scripts/build.sh linux (this file is a sourceable helper)" >&2
  exit 2
fi

build_linux() {
  say "building Linux (x86_64 AppImage) app"
  local image_name="love-$LOVE_VERSION-x86_64.AppImage"
  local love_image="$CACHE/$image_name"
  if [ ! -f "$love_image" ]; then
    say "downloading official LÖVE $LOVE_VERSION x86_64 AppImage"
    curl -fL --progress-bar \
      "https://github.com/love2d/love/releases/download/$LOVE_VERSION/$image_name" \
      -o "$love_image" || fail "download failed, check LOVE_VERSION or your network"
  fi

  local tool_name="appimagetool-x86_64.AppImage"
  local appimage_tool="$CACHE/$tool_name"
  if [ ! -f "$appimage_tool" ]; then
    say "downloading appimagetool"
    curl -fL --progress-bar \
      "https://github.com/AppImage/AppImageKit/releases/download/continuous/$tool_name" \
      -o "$appimage_tool" || fail "appimagetool download failed"
  fi
  chmod +x "$love_image" "$appimage_tool"

  local app_dir="$WORK/$APP_NAME.AppDir"
  local out_dir="$WORK/$APP_NAME-linux-x86_64"
  rm -rf "$app_dir" "$out_dir"
  mkdir -p "$app_dir" "$out_dir"

  say "embedding game.love in the AppImage"
  (cd "$WORK" && "$love_image" --appimage-extract >/dev/null)
  mv "$WORK/squashfs-root"/* "$app_dir"/
  mv "$WORK/squashfs-root"/.[!.]* "$app_dir"/ 2>/dev/null || true
  rmdir "$WORK/squashfs-root"
  cp "$LOVE_FILE" "$app_dir/game.love"
  sed -i.bak 's|#FUSE_PATH="$APPDIR/my_game.love"|FUSE_PATH="$APPDIR/game.love"|' "$app_dir/AppRun"
  rm -f "$app_dir/AppRun.bak"
  grep -Fq 'FUSE_PATH="$APPDIR/game.love"' "$app_dir/AppRun" \
    || fail "could not configure the LÖVE AppImage launcher"

  local appimage_out="$out_dir/$APP_NAME-x86_64.AppImage"
  ARCH=x86_64 "$appimage_tool" --appimage-extract-and-run \
    "$app_dir" "$appimage_out" >/dev/null
  chmod +x "$appimage_out"

  local zip_out="$DIST/linux/$APP_NAME-linux-x86_64.zip"
  rm -f "$zip_out"
  (cd "$WORK" && zip -q -9 -r "$zip_out" "$APP_NAME-linux-x86_64")
  say "Linux build: $zip_out"
}
