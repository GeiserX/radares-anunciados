#!/bin/sh
# Renders every concept to PNG (1024, 120 and 60 px) and builds the contact sheet.
# Needs rsvg-convert (librsvg) and ImageMagick 7: brew install librsvg imagemagick
set -eu
cd "$(dirname "$0")"
mkdir -p png
for svg in [0-9][0-9]-*.svg; do
  name=${svg%.svg}
  rsvg-convert -w 1024 -h 1024 "$svg" -o "png/$name-1024.png"
  rsvg-convert -w 120 -h 120 "$svg" -o "png/$name-120.png"
  # 60 px is the home-screen icon at 1x; it is the size where thin lines and small details die.
  rsvg-convert -w 60 -h 60 "$svg" -o "png/$name-60.png"
  # The contact sheet shows each icon under the iOS corner mask (radius about 22% of the side).
  magick "png/$name-1024.png" -alpha set -resize 240x240 \
    \( -size 240x240 xc:none -fill white -draw "roundrectangle 0,0 239,239 54,54" \) \
    -compose DstIn -composite "png/.$name-sheet.png"
done
# Rows of six, 28 px of dark margin round each icon; no labels, so no font is needed.
# A short last row is padded with dark tiles so every row has the same width.
bg='#0b0d12'
set -- png/.[0-9][0-9]-*-sheet.png
row=0
while [ $# -gt 0 ]; do
  tiles=""
  for _ in 1 2 3 4 5 6; do
    if [ $# -gt 0 ]; then tiles="$tiles $1"; shift; else tiles="$tiles png/.blank-sheet.png"; fi
  done
  [ -f png/.blank-sheet.png ] || magick -size 240x240 "xc:$bg" png/.blank-sheet.png
  # shellcheck disable=SC2086
  magick $tiles -bordercolor "$bg" -border 28 +append "png/.row-$row.png"
  row=$((row + 1))
done
magick png/.row-*.png -append -bordercolor "$bg" -border 28 +repage contact-sheet.png
rm -f png/.row-*.png png/.blank-sheet.png
rm -f png/.[0-9][0-9]-*-sheet.png
