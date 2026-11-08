#!/usr/bin/env bash
# Render a contact sheet of the schemes: one row per scheme, dark and light cells.
#
#   ./preview.sh                     -> dist/preview.png
#   ./preview.sh --size 128 --out /tmp/sheet.png
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
size=96
out="$here/dist/preview.png"

while [ $# -gt 0 ]; do
  case "$1" in
    --size) size="$2"; shift 2 ;;
    --size=*) size="${1#*=}"; shift ;;
    --out) out="$2"; shift 2 ;;
    --out=*) out="${1#*=}"; shift ;;
    -h|--help) sed -n '2,5p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

for tool in rsvg-convert magick; do
  command -v "$tool" >/dev/null || { printf 'error: missing %s\n' "$tool" >&2; exit 1; }
done

work=$(mktemp -d "${TMPDIR:-/tmp}/cursor-preview-XXXXXX")
trap 'rm -rf "$work"' EXIT

# cursor|label pairs
shown=('left_ptr|arrow' 'hand2|hand' 'xterm|text' 'all-scroll|move')
backgrounds=('1e1e2e|dark' 'ffffff|light')
rows=()

while IFS='|' read -r name fill outline comment; do
  case "$name" in ''|'#'*) continue ;; esac
  cells=()
  for entry in "${shown[@]}"; do
    cursor="${entry%%|*}"
    label="${entry##*|}"
    sed "s/#00FF00/$fill/Ig; s/#0000FF/$outline/Ig" "$here/svg/$cursor.svg" > "$work/$cursor.svg"
    for bg in "${backgrounds[@]}"; do
      hex="${bg%%|*}"
      mode="${bg##*|}"
      rsvg-convert -w "$size" -h "$size" -o "$work/$name-$cursor-$mode.png" "$work/$cursor.svg"
      magick -size $((size + 24))x$((size + 34)) "xc:#$hex" \
        "$work/$name-$cursor-$mode.png" -geometry +12+12 -composite \
        -fill "#8a8a95" -pointsize 11 -annotate +8+$((size + 28)) "$label $mode" \
        "$work/cell-$name-$cursor-$mode.png"
      cells+=("$work/cell-$name-$cursor-$mode.png")
    done
  done
  magick "${cells[@]}" +append "$work/row.png"
  magick "$work/row.png" -background '#0b0b10' -fill '#cdd6f4' -pointsize 13 \
    -gravity west -splice 150x0 -annotate +8+0 "$name" "$work/labelled-$name.png"
  rows+=("$work/labelled-$name.png")
done < "$here/schemes.conf"

mkdir -p "$(dirname "$out")"
magick "${rows[@]}" -append "$out"
printf 'wrote %s (%s px cells, %s schemes)\n' "$out" "$size" "${#rows[@]}"
