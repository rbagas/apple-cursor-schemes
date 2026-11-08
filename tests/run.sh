#!/usr/bin/env bash
# Build one scheme and check the produced containers byte by byte.
#
#   ./tests/run.sh              # builds the GitHub-Dark scheme in a temp dir
#   ./tests/run.sh --keep       # leave the build output in place for poking at
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
keep=0
[ "${1:-}" = "--keep" ] && keep=1

tmp=$(mktemp -d "${TMPDIR:-/tmp}/cursor-test-XXXXXX")
[ "$keep" = 1 ] && printf 'build output: %s\n' "$tmp" || trap 'rm -rf "$tmp"' EXIT

pass=0 fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$*"; }
is() { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: expected [$3], got [$2]"; fi; }

u32() { od -An -tu4 -j "$2" -N 4 "$1" | tr -d ' '; }
u16() { od -An -tu2 -j "$2" -N 2 "$1" | tr -d ' '; }
u8() { od -An -tu1 -j "$2" -N 1 "$1" | tr -d ' '; }
text() { dd if="$1" bs=1 skip="$2" count="$3" status=none; }

printf 'building AppleCursor-GitHub-Dark...\n'
"$here/build.sh" --scheme GitHub-Dark --output "$tmp/dist" >"$tmp/build.log" 2>&1 ||
  { cat "$tmp/build.log"; bad 'build failed'; exit 1; }
ok 'build finished'

linux="$tmp/dist/linux/AppleCursor-GitHub-Dark"
win="$tmp/dist/windows/AppleCursor-GitHub-Dark"

printf '\nxcursor theme\n'
is 'theme directory exists' "$([ -f "$linux/index.theme" ] && echo yes || echo no)" yes
is 'name in index.theme' "$(sed -n 's/^Name=//p' "$linux/index.theme")" 'AppleCursor-GitHub-Dark'
is 'cursor files' "$(find "$linux/cursors" -maxdepth 1 -type f ! -name '.*' | wc -l)" 44
is 'symlink aliases' "$(find "$linux/cursors" -maxdepth 1 -type l | wc -l)" 101

cursor="$linux/cursors/left_ptr"
is 'xcursor magic' "$(u32 "$cursor" 0)" 1920295768
header=$(u32 "$cursor" 4)
count=$(u32 "$cursor" 8 | head -1)
# header layout: magic, header_size, version, ntoc
count=$(u32 "$cursor" 12)
is 'image records (14 sizes)' "$count" 14

sizes=""
hotspots_ok=1
index=0
while [ "$index" -lt 14 ]; do
  entry=$((header + index * 12))
  position=$(u32 "$cursor" $((entry + 8)))
  size=$(u32 "$cursor" $((position + 8)))
  xhot=$(u32 "$cursor" $((position + 24)))
  yhot=$(u32 "$cursor" $((position + 28)))
  delay=$(u32 "$cursor" $((position + 32)))
  sizes="$sizes $size"
  [ "$xhot" = "$((80 * size / 256))" ] || hotspots_ok=0
  [ "$yhot" = "$((38 * size / 256))" ] || hotspots_ok=0
  [ "$delay" = 20 ] || hotspots_ok=0
  index=$((index + 1))
done
is 'size ladder' "$sizes" ' 16 20 22 24 28 32 40 48 56 64 72 80 88 96'
is 'hotspots follow floor(hot*size/256), 20 ms delay' "$hotspots_ok" 1

printf '\nwindows cursors\n'
is 'role count' "$(find "$win" -name '*.cur' -o -name '*.ani' | wc -l)" 21
is 'installer present' "$([ -f "$win/install.inf" ] && echo yes || echo no)" yes
is 'inf registers a scheme' "$(grep -c 'Control Panel\\Cursors\\Schemes' "$win/install.inf")" 1
is 'inf role entries' "$(grep -c 'Control Panel\\Cursors\",' "$win/install.inf")" 21

move="$win/Move.cur"
is 'cur type 2' "$(u16 "$move" 2)" 2
is 'cur image count' "$(u16 "$move" 4)" 6
is 'first image size' "$(u8 "$move" 6)" 22
is 'first image hotspot x' "$(u16 "$move" 10)" 10
is 'first image hotspot y' "$(u16 "$move" 12)" 10

work="$win/Work.ani"
is 'ani is RIFF' "$(text "$work" 0 4)" RIFF
is 'ani form ACON' "$(text "$work" 8 4)" ACON
anih=$(grep -abo anih "$work" | head -1 | cut -d: -f1)
is 'anih header size' "$(u32 "$work" $((anih + 8)))" 36
is 'anih frame count' "$(u32 "$work" $((anih + 12)))" 40
is 'anih bit depth' "$(u32 "$work" $((anih + 28)))" 32
is 'anih rate (2 jiffies)' "$(u32 "$work" $((anih + 36)))" 2
is 'ani frame images' "$(grep -aoc icon "$work")" 40

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
