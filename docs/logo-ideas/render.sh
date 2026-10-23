#!/bin/sh
# Renders every concept to PNG (1024 and 120 px) and builds the contact sheet.
# Needs rsvg-convert (librsvg) and ImageMagick 7: brew install librsvg imagemagick
set -eu
cd "$(dirname "$0")"
mkdir -p png
for svg in [0-9][0-9]-*.svg; do
  name=${svg%.svg}
  rsvg-convert -w 1024 -h 1024 "$svg" -o "png/$name-1024.png"
  rsvg-convert -w 120 -h 120 "$svg" -o "png/$name-120.png"
  # The contact sheet shows each icon under the iOS corner mask (radius about 22% of the side).
  magick "png/$name-1024.png" -alpha set -resize 240x240 \
    \( -size 240x240 xc:none -fill white -draw "roundrectangle 0,0 239,239 54,54" \) \
    -compose DstIn -composite "png/.$name-sheet.png"
done
# Two rows of seven, 28 px of dark margin round each icon; no text, so no font is needed.
set -- png/.[0-9][0-9]-*-sheet.png
magick -background '#0b0d12' \
  \( "$1" "$2" "$3" "$4" "$5" "$6" "$7" -bordercolor '#0b0d12' -border 28 +append \) \
  \( "$8" "$9" "${10}" "${11}" "${12}" "${13}" "${14}" -bordercolor '#0b0d12' -border 28 +append \) \
  -append -bordercolor '#0b0d12' -border 28 contact-sheet.png
rm -f png/.[0-9][0-9]-*-sheet.png
