#!/bin/bash
# Regenerate every raster icon from assets/logo.svg.
#
# One SVG covers every size. That is a constraint worth keeping: an earlier
# draft had interior detail that dissolved below ~64 px, which needed a second
# simplified source and a size threshold here to work around. If you add
# interior detail back, check it at 16 px first -- you will need both again.
#
# The generated PNGs are committed. Xcode needs them present at build time and
# release.yml builds from a plain checkout, so the release path must not depend
# on librsvg being installed.
#
# Usage: ./scripts/generate-icon.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
SRC="$ROOT/assets/logo.svg"
ICONSET="$ROOT/ClaudeCodeStats/ClaudeCodeStats/Assets.xcassets/AppIcon.appiconset"

command -v rsvg-convert >/dev/null || {
  echo "error: rsvg-convert not found. brew install librsvg" >&2
  exit 1
}
[ -f "$SRC" ] || { echo "error: missing source $SRC" >&2; exit 1; }

render() {  # render <pixels> <output>
  rsvg-convert -w "$1" -h "$1" "$SRC" -o "$2"
  printf '  %-24s %4spx\n' "$(basename "$2")" "$1"
}

mkdir -p "$ICONSET"

# Clear the outputs before rendering. If a render fails -- a malformed SVG is
# the usual cause, and `--` inside an XML comment is illegal and will do it --
# set -e aborts here, and without this the previous PNGs would still be sitting
# on disk. Xcode would then build clean against stale artwork and you would be
# looking at the old icon wondering why your edit did nothing. Better to leave
# the tree obviously broken than quietly wrong.
rm -f "$ICONSET"/icon_*.png
rm -f "$ROOT/assets/logo-512.png" "$ROOT/assets/favicon-32.png" "$ROOT/assets/favicon-16.png"

echo "AppIcon.appiconset:"
# macOS wants each point size at 1x and 2x: 16, 32, 128, 256, 512.
render 16   "$ICONSET/icon_16x16.png"
render 32   "$ICONSET/icon_16x16@2x.png"
render 32   "$ICONSET/icon_32x32.png"
render 64   "$ICONSET/icon_32x32@2x.png"
render 128  "$ICONSET/icon_128x128.png"
render 256  "$ICONSET/icon_128x128@2x.png"
render 256  "$ICONSET/icon_256x256.png"
render 512  "$ICONSET/icon_256x256@2x.png"
render 512  "$ICONSET/icon_512x512.png"
render 1024 "$ICONSET/icon_512x512@2x.png"

cat > "$ICONSET/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png",      "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png",      "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png",    "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png",    "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png",    "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

cat > "$(dirname "$ICONSET")/Contents.json" <<'JSON'
{
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

# Web / repo surfaces, from the same source.
echo "web:"
render 512 "$ROOT/assets/logo-512.png"      # README, GitHub social preview
render 32  "$ROOT/assets/favicon-32.png"
render 16  "$ROOT/assets/favicon-16.png"

echo
echo "Done. Source: assets/logo.svg"
