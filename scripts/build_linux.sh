build_linux() {
    say "building linux app"
    local zip_name="love-"
    local love_zip="$CACHE/$zip_name"
    if [ ! -f "$love_zip"]; then 
        say "downloading LÖVE $LOVE_VERSION linux binaries"
        curl -fL --progress-bar \ 
            "https://github.com/love2d/love/releases/download/$LOVE_VERSION/$zip_name" \ 
            -o "$love_zip" || fail "download failed, check LOVE_VERSION or your network"
    fi

    local extract_dir="$WORK/love-linux"
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    unzip -q "$love_zip" -d "$extract_dir"
    local love_dir 
    love_dir="$(find "$extract_dir" -maxdepth 1 -mindepth 1 -type d | head -1)"

    local out_dir="$WORK/$APP_NAME-linux"
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