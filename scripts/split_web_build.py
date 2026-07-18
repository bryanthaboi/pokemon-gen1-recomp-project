#!/usr/bin/env python3
"""Split a love.js web build's game.data into <chunk-size chunks and patch
game.js to fetch+reassemble them client-side. Run after every love.js
invocation (build love.js straight into dist/web/). Custom player
theme/branding (background + CSS) lives in scripts/web-theme/,  copy it into
the love.js output dir's theme/ folder and set
<link rel="stylesheet" href="theme/love.css"> in index.html.
"""
import argparse
import os
import re
import sys

FETCH_REMOTE_PACKAGE_RE = re.compile(
    r"    function fetchRemotePackage\(packageName, packageSize, callback, errback\) \{.*?\n    \};\n",
    re.DOTALL,
)

def make_patched_fetch(chunk_size):
    return f"""    function fetchRemotePackage(packageName, packageSize, callback, errback) {{
      var CHUNK_SIZE = {chunk_size};
      var numChunks = Math.ceil(packageSize / CHUNK_SIZE);
      var buffer = new Uint8Array(packageSize);
      var loadedChunks = 0;
      var hadError = false;

      function chunkURL(i) {{
        return packageName + '.part' + ('000' + i).slice(-3);
      }}

      function onChunkLoaded(i, data) {{
        buffer.set(new Uint8Array(data), i * CHUNK_SIZE);
        loadedChunks++;
        if (Module['setStatus']) Module['setStatus']('Downloading data... (' + loadedChunks + '/' + numChunks + ' parts)');
        if (loadedChunks === numChunks && !hadError) {{
          callback(buffer.buffer);
        }}
      }}

      for (var i = 0; i < numChunks; i++) {{
        (function(i) {{
          var xhr = new XMLHttpRequest();
          xhr.open('GET', chunkURL(i), true);
          xhr.responseType = 'arraybuffer';
          xhr.onload = function() {{
            if (xhr.status == 200 || xhr.status == 304 || xhr.status == 206 || (xhr.status == 0 && xhr.response)) {{
              onChunkLoaded(i, xhr.response);
            }} else if (!hadError) {{
              hadError = true;
              errback(new Error(xhr.statusText + " : " + chunkURL(i)));
            }}
          }};
          xhr.onerror = function() {{
            if (!hadError) {{ hadError = true; errback(new Error("NetworkError for: " + chunkURL(i))); }}
          }};
          xhr.send(null);
        }})(i);
      }}
    }};
"""

def split_file(src_path, chunk_size):
    parts = []
    with open(src_path, 'rb') as f:
        i = 0
        while True:
            data = f.read(chunk_size)
            if not data:
                break
            part_path = f"{src_path}.part{i:03d}"
            with open(part_path, 'wb') as out:
                out.write(data)
            parts.append(part_path)
            i += 1
    return parts

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('outdir', help='love.js output directory (e.g. .bazinga/online)')
    ap.add_argument('--chunk-size-mb', type=int, default=20, help='max chunk size in MB (default 20, keep under host cap e.g. 25MB)')
    args = ap.parse_args()

    chunk_size = args.chunk_size_mb * 1024 * 1024
    game_data = os.path.join(args.outdir, 'game.data')
    game_js = os.path.join(args.outdir, 'game.js')

    if not os.path.isfile(game_data):
        sys.exit(f"error: {game_data} not found,  run love.js first")
    if not os.path.isfile(game_js):
        sys.exit(f"error: {game_js} not found,  run love.js first")

    # clean up any stale parts from a previous run
    for name in os.listdir(args.outdir):
        if re.match(r"^game\.data\.part\d{3}$", name):
            os.remove(os.path.join(args.outdir, name))

    parts = split_file(game_data, chunk_size)
    os.remove(game_data)

    with open(game_js, 'r') as f:
        src = f.read()

    if not FETCH_REMOTE_PACKAGE_RE.search(src):
        sys.exit("error: could not find fetchRemotePackage() in game.js,  love.js template may have changed")

    patched = FETCH_REMOTE_PACKAGE_RE.sub(make_patched_fetch(chunk_size), src, count=1)
    with open(game_js, 'w') as f:
        f.write(patched)

    sizes = [os.path.getsize(p) for p in parts]
    print(f"split game.data into {len(parts)} parts (chunk size {args.chunk_size_mb}MB):")
    for p, s in zip(parts, sizes):
        print(f"  {os.path.basename(p)}: {s / 1024 / 1024:.1f} MB")
    print("patched game.js fetchRemotePackage() to fetch+reassemble parts")

if __name__ == '__main__':
    main()
