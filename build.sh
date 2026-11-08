#!/usr/bin/env bash
# Build every colour scheme as XCursor themes and Windows cursors.
#
# Upstream renders its SVGs to PNG bitmaps with cbmp and builds cursors with
# ctgen. This script needs neither: it renders with rsvg-convert, writes XCursor
# files with xcursorgen, and emits the Windows containers with printf.
#
#   ./build.sh                          build every scheme, both platforms
#   ./build.sh --scheme Nord            one scheme
#   ./build.sh --platforms linux        one platform
#   ./build.sh --list                   show the schemes
#   ./build.sh --jobs 4                 limit parallel renders (default: CPU count)
#   ./build.sh --output /tmp/out        somewhere other than dist/
#
# Needs: bash, awk, sed, rsvg-convert (librsvg2-tools), xcursorgen.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
output="$here/dist"
platforms="linux windows"
wanted=()
windows_profile="win_rg"
canvas=256
jobs=$(nproc 2>/dev/null || echo 4)
use_cache=1
clear_cache=0
force=0
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/apple-cursor-schemes"
# Windows plays an .ani in jiffies (1/60 s). Upstream ships a 20 ms delay as 2
# jiffies, so mirror that instead of the config's win_delay.
ani_rate=2
# An .ani frame carries one image; Windows scales it to the chosen cursor size.
ani_target=64

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
say() { printf '  %s\n' "$*"; }

usage() { sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --scheme) [ $# -ge 2 ] || die '--scheme needs a value'; wanted+=("$2"); shift 2 ;;
    --scheme=*) wanted+=("${1#*=}"); shift ;;
    --platforms) [ $# -ge 2 ] || die '--platforms needs a value'; platforms="$2"; shift 2 ;;
    --platforms=*) platforms="${1#*=}"; shift ;;
    --output) [ $# -ge 2 ] || die '--output needs a value'; output="$2"; shift 2 ;;
    --output=*) output="${1#*=}"; shift ;;
    --windows-profile) windows_profile="win_${2#win_}"; shift 2 ;;
    --jobs) [ $# -ge 2 ] || die '--jobs needs a value'; jobs="$2"; shift 2 ;;
    --jobs=*) jobs="${1#*=}"; shift ;;
    --no-cache) use_cache=0; shift ;;
    --force) force=1; shift ;;
    --clear-cache) clear_cache=1; shift ;;
    --cache-dir) [ $# -ge 2 ] || die '--cache-dir needs a value'; cache_dir="$2"; shift 2 ;;
    --cache-dir=*) cache_dir="${1#*=}"; shift ;;
    --list) awk -F'|' '/^[^#[:space:]]/ {printf "%-18s fill %-8s outline %s\n", $1, $2, $3}' "$here/schemes.conf"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

for tool in rsvg-convert xcursorgen awk sed xargs; do
  command -v "$tool" >/dev/null 2>&1 || die "missing $tool (Fedora: librsvg2-tools xcursorgen; Debian: librsvg2-bin xcursorgen; Arch: librsvg xorg-xcursorgen)"
done

schemes() { awk -F'|' '/^[^#[:space:]]/' "$here/schemes.conf"; }

# Rendered images are cached by content hash, so a rebuild after changing one
# colour only rasterises what actually changed. Consumers read straight from the
# cache, which also keeps the work directory on the same filesystem as the cache.
if [ "$clear_cache" = 1 ]; then
  rm -rf "$cache_dir/render"
  say "cleared $cache_dir/render"
fi
mkdir -p "$cache_dir/render"
render_root="$cache_dir/render"
work=$(mktemp -d "$cache_dir/build-XXXXXX")
trap 'rm -rf "$work"' EXIT

declare -A SVG_HASH=()

# ---------------------------------------------------------------- byte output
# Little-endian helpers: the Windows containers are written with printf.
le8() { printf "\\$(printf '%03o' $(( $1 & 255 )))"; }
le16() { le8 $(( $1 & 255 )); le8 $(( ($1 >> 8) & 255 )); }
le32() {
  le8 $(( $1 & 255 )); le8 $(( ($1 >> 8) & 255 ))
  le8 $(( ($1 >> 16) & 255 )); le8 $(( ($1 >> 24) & 255 ))
}
le_text() { printf '%s' "$1"; }

# ------------------------------------------------------------------ TOML read
# The upstream configs are regular enough to read with awk: one section per
# cursor, flat keys, and arrays that may span lines.
manifest_x11() {
  awk '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function quoted(s, out) {
      out = ""
      # TOML strings are single quoted here; \047 is an apostrophe inside awk.
      while (match(s, /[\047"][^\047"]*[\047"]/)) {
        out = out (out == "" ? "" : ",") substr(s, RSTART + 1, RLENGTH - 2)
        s = substr(s, RSTART + RLENGTH)
      }
      return out
    }
    /^\[/ {
      if (section ~ /^cursors\./ && section != "cursors.fallback_settings")
        print name "|" png "|" hx "|" hy "|" quoted(syms)
      section = trim(substr($0, 2, length($0) - 2))
      name = (section ~ /^cursors\./) ? substr(section, 9) : ""
      png = ""; hx = ""; hy = ""; syms = ""; collecting = 0
      next
    }
    collecting { syms = syms " " $0; if ($0 ~ /\]/) collecting = 0 }
    /^[ \t]*x11_symlinks[ \t]*=/ {
      syms = $0
      if ($0 !~ /\]/) collecting = 1
      next
    }
    /^[ \t]*png[ \t]*=/ { png = quoted($0); next }
    /^[ \t]*x_hotspot[ \t]*=/ { hx = trim(substr($0, index($0, "=") + 1)); next }
    /^[ \t]*y_hotspot[ \t]*=/ { hy = trim(substr($0, index($0, "=") + 1)); next }
    END {
      if (section ~ /^cursors\./ && section != "cursors.fallback_settings")
        print name "|" png "|" hx "|" hy "|" quoted(syms)
    }
  ' "$1"
}

manifest_windows() {
  awk '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function quoted(s, out) {
      out = ""
      while (match(s, /[\047"][^\047"]*[\047"]/)) {
        out = out (out == "" ? "" : ",") substr(s, RSTART + 1, RLENGTH - 2)
        s = substr(s, RSTART + RLENGTH)
      }
      return out
    }
    /^\[/ {
      if (section ~ /^cursors\./ && section != "cursors.fallback_settings")
        print name "|" png "|" hx "|" hy "|" win "|" wsize
      section = trim(substr($0, 2, length($0) - 2))
      name = (section ~ /^cursors\./) ? substr(section, 9) : ""
      png = ""; hx = ""; hy = ""; win = ""; wsize = ""
      next
    }
    /^[ \t]*png[ \t]*=/ { png = quoted($0); next }
    /^[ \t]*win_name[ \t]*=/ { win = quoted($0); next }
    /^[ \t]*win_sizes[ \t]*=/ { wsize = trim(substr($0, index($0, "=") + 1)); gsub(/[^0-9 ]/, "", wsize); next }
    /^[ \t]*x_hotspot[ \t]*=/ { hx = trim(substr($0, index($0, "=") + 1)); next }
    /^[ \t]*y_hotspot[ \t]*=/ { hy = trim(substr($0, index($0, "=") + 1)); next }
    END {
      if (section ~ /^cursors\./ && section != "cursors.fallback_settings")
        print name "|" png "|" hx "|" hy "|" win "|" wsize
    }
  ' "$1"
}

# Fallback values, read only from [cursors.fallback_settings].
fallback_sizes() {
  awk -F'[][, ]+' -v key="$2" '/^\[/ { f = ($0 ~ /fallback_settings/) }
    f && $0 ~ key { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) printf "%s ", $i }' "$1"
}
fallback_number() {
  awk -v key="$2" '/^\[/ { f = ($0 ~ /fallback_settings/) }
    f && $1 == key { print $3; exit }' "$1"
}

# frames_for <png-spec>: newline separated SVG paths, animation order
frames_for() {
  case "$1" in
    *-\*.png) find "$here/svg/${1%%-\**}" -maxdepth 1 -name '*.svg' | sort ;;
    *) printf '%s\n' "$here/svg/${1%.png}.svg" ;;
  esac
}

# ------------------------------------------------------------------- hotspots
x_hotspot() { printf '%s' $(( $1 * $2 / canvas )); }
win_hotspot() { printf '%s' $(( ($1 * $2 - 1) / canvas )); }

# --------------------------------------------------------------------- render
# One pass over the whole scheme: colour-substituted SVGs are written once, then
# every needed (svg, size) pair is rendered in parallel, deduplicated by path.
# XCursor and Windows then share the results, which is why this is one pass.
plan_scheme() {
  local name="$1" fill="$2" outline="$3"
  local dir="$work/$name" svg_out png_out
  svg_out="$dir/svg"; png_out="$dir/png"
  mkdir -p "$svg_out" "$png_out"
  : > "$dir/tasks"
  : > "$dir/plan.linux"
  : > "$dir/plan.windows"

  local x11="$here/configs/x.build.toml" win="$here/configs/$windows_profile.build.toml"
  local x11_sizes win_sizes cursor png hx hy syms role override frame index
  x11_sizes=$(fallback_sizes "$x11" x11_sizes)
  win_sizes=$(fallback_sizes "$win" win_sizes)

  local -A seen=()
  cache_hit=0; cache_miss=0
  plan_one() { # cursor png hx hy sizes-list animated-size
    local spec="$1" png="$2" spec_hx="$3" spec_hy="$4" list="$5" fixed="$6"
    local -a glyphs=() sizes=()
    mapfile -t glyphs < <(frames_for "$png")
    local svg size n out
    for n in "${!glyphs[@]}"; do
      svg="$svg_out/$spec-$n.svg"
      if [ ! -f "$svg" ]; then
        sed "s/#00FF00/$fill/Ig; s/#0000FF/$outline/Ig" "${glyphs[$n]}" > "$svg"
      fi
      SVG_HASH["$spec-$n"]=$(sha256sum "$svg" | cut -d' ' -f1)
    done
    if [ -n "$fixed" ]; then sizes=("$fixed"); else read -ra sizes <<< "$list"; fi
    for size in "${sizes[@]}"; do
      for n in "${!glyphs[@]}"; do
        out="$render_root/${SVG_HASH[$spec-$n]}-$size.png"
        if [ -z "${seen[$out]:-}" ]; then
          seen[$out]=1
          if [ "$use_cache" = 1 ] && [ -s "$out" ]; then
            cache_hit=$((cache_hit + 1))
          else
            cache_miss=$((cache_miss + 1))
            printf '%s\0%s\0%s\0' "$svg_out/$spec-$n.svg" "$size" "$out" >> "$dir/tasks"
          fi
        fi
      done
    done
  }

  if [ "${PLAN_LINUX:-1}" = 1 ]; then
  while IFS='|' read -r cursor png hx hy syms; do
    [ -n "$cursor" ] || continue
    printf '%s|%s|%s|%s|%s\n' "$cursor" "$png" "${hx:-$(fallback_number "$x11" x_hotspot)}" \
      "${hy:-$(fallback_number "$x11" y_hotspot)}" "$syms" >> "$dir/plan.linux"
    plan_one "$cursor" "$png" "${hx:-$(fallback_number "$x11" x_hotspot)}" \
      "${hy:-$(fallback_number "$x11" y_hotspot)}" "$x11_sizes" ""
  done < <(manifest_x11 "$x11")
  fi

  if [ "${PLAN_WINDOWS:-1}" = 1 ]; then
  while IFS='|' read -r cursor png hx hy role override; do
    [ -n "$cursor" ] || continue
    [ -n "$role" ] || continue
    printf '%s|%s|%s|%s|%s|%s\n' "$cursor" "$png" "${hx:-$(fallback_number "$win" x_hotspot)}" \
      "${hy:-$(fallback_number "$win" y_hotspot)}" "$role" "$override" >> "$dir/plan.windows"
    # An .ani frame is a single image: upstream pins those to 65 px.
    if [ -n "$override" ]; then
      plan_one "$cursor" "$png" "${hx:-$(fallback_number "$win" x_hotspot)}" \
        "${hy:-$(fallback_number "$win" y_hotspot)}" "" "${override%% *}"
    else
      plan_one "$cursor" "$png" "${hx:-$(fallback_number "$win" x_hotspot)}" \
        "${hy:-$(fallback_number "$win" y_hotspot)}" "$win_sizes" ""
    fi
  done < <(manifest_windows "$win")
  fi
}

render_scheme() {
  local name="$1" dir="$work/$1"
  local count
  count=$(tr -cd '\0' < "$dir/tasks" | wc -c)
  count=$(( count / 3 ))
  if [ "$count" -eq 0 ]; then
    say "rendered 0 images, $cache_hit reused from cache"
    return
  fi
  tr '\0' '\n' < "$dir/tasks" | xargs -d '\n' -n 3 -P "$jobs" "$here/lib/render.sh"
  # A killed build can leave a truncated image behind; drop those so the next run
  # re-renders them instead of caching a broken frame forever.
  local broken=0 png
  while IFS= read -r -d '' png; do
    [ -s "$png" ] || { rm -f "$png"; broken=$((broken + 1)); }
  done < <(tr '\0' '\n' < "$dir/tasks" | awk 'NR % 3 == 0 { printf "%s\0", $0 }')
  say "rendered $count images with $jobs jobs, $cache_hit reused from cache${broken:+, $broken broken removed}"
}

# ------------------------------------------------------------------- XCursor
build_linux() {
  local name="$1" theme="AppleCursor-$1" comment="$2"
  local dir="$work/$1" target="$output/linux/$theme"
  local x11="$here/configs/x.build.toml"
  local sizes delay cursor png hx hy syms size hot_x hot_y n frames

  sizes=($(fallback_sizes "$x11" x11_sizes))
  delay=$(fallback_number "$x11" x11_delay)

  rm -rf "$target"; mkdir -p "$target/cursors"
  while IFS='|' read -r cursor png hx hy syms; do
    [ -n "$cursor" ] || continue
    mapfile -t frames < <(frames_for "$png")
    local cfg="$dir/x11-$cursor.conf"
    : > "$cfg"
    for size in "${sizes[@]}"; do
      hot_x=$(x_hotspot "$hx" "$size")
      hot_y=$(x_hotspot "$hy" "$size")
      for n in "${!frames[@]}"; do
        printf '%s %s %s %s %s\n' "$size" "$hot_x" "$hot_y" "$render_root/${SVG_HASH[$cursor-$n]}-$size.png" "$delay" >> "$cfg"
      done
    done
    xcursorgen "$cfg" "$target/cursors/$cursor"
    local alias
    for alias in $(printf '%s' "$syms" | tr ',' ' '); do
      ln -sf "$cursor" "$target/cursors/$alias"
    done
  done < "$dir/plan.linux"

  cat > "$target/index.theme" <<EOF
[Icon Theme]
Name=$theme
Comment=$comment · apple_cursor v2.0.1 artwork
Inherits="hicolor"
EOF
  cat > "$target/cursor.theme" <<EOF
[Icon Theme]
Name=$theme
Inherits="hicolor"
EOF
  chmod -R u+rwX,go+rX "$target"
  say "linux   $target ($(find "$target/cursors" -maxdepth 1 -type f | wc -l) files, $(find "$target/cursors" -maxdepth 1 -type l | wc -l) aliases)"
}

# -------------------------------------------------------------------- Windows
write_cur() { # out file... with SIZES/HOTXS/HOTYS describing every image
  local out="$1"; shift
  local files=("$@")
  local count=${#files[@]}
  local offset=$(( 6 + 16 * count ))
  local index byte_size
  exec 3> "$out"
  le16 0 >&3; le16 2 >&3; le16 "$count" >&3
  for index in "${!files[@]}"; do
    byte_size=$(stat -c%s "${files[$index]}")
    le8 $(( SIZES[index] == 256 ? 0 : SIZES[index] )) >&3
    le8 $(( SIZES[index] == 256 ? 0 : SIZES[index] )) >&3
    le8 0 >&3; le8 0 >&3
    le16 "${HOTXS[index]}" >&3
    le16 "${HOTYS[index]}" >&3
    le32 "$byte_size" >&3
    le32 "$offset" >&3
    offset=$(( offset + byte_size ))
  done
  exec 3>&-
  cat "${files[@]}" >> "$out"
}

write_ani() { # out cur-file... -> RIFF/ACON at ani_rate jiffies
  local out="$1"; shift
  local files=("$@")
  local count=${#files[@]}
  local sizes_bytes=$(( 4 * count )) frames=0 file
  for file in "${files[@]}"; do frames=$(( frames + 8 + $(stat -c%s "$file") )); done
  local list_size=$(( 4 + frames ))
  local payload=$(( 4 + (8 + 36) + (8 + sizes_bytes) + (8 + list_size) ))
  exec 3> "$out"
  le_text RIFF >&3; le32 "$payload" >&3; le_text ACON >&3
  le_text anih >&3; le32 36 >&3
  le32 36 >&3; le32 "$count" >&3; le32 "$count" >&3
  le32 0 >&3; le32 0 >&3; le32 32 >&3; le32 1 >&3; le32 "$ani_rate" >&3; le32 1 >&3
  le_text rate >&3; le32 "$sizes_bytes" >&3
  local i; for ((i = 0; i < count; i++)); do le32 "$ani_rate" >&3; done
  le_text LIST >&3; le32 "$list_size" >&3; le_text fram >&3
  for file in "${files[@]}"; do
    le_text icon >&3; le32 "$(stat -c%s "$file")" >&3; cat "$file" >&3
  done
  exec 3>&-
}

INSTALL_INF_HEAD='; %THEME%, generated by build.sh
; Artwork: apple_cursor v2.0.1 (GPL-3.0) https://github.com/ful1e5/apple_cursor

[Version]
signature="$CHICAGO$"
%THEME%

[DefaultInstall]
CopyFiles = Scheme.Cur
AddReg    = Scheme.Reg,Wreg

[DestinationDirs]
Scheme.Cur = 10,"%CUR_DIR%"

[Scheme.Reg]
HKCU,"Control Panel\Cursors\Schemes","%SCHEME_NAME%",,"%SCHEME_PATHS%"

[Wreg]
HKCU,"Control Panel\Cursors",,0x00020000,"%SCHEME_NAME%"
'

ROLE_MAP=(
  'Arrow pointer' 'Help help' 'AppStarting work' 'Wait busy' 'crosshair cross'
  'precisionhair cross' 'IBeam text' 'NWPen handwriting' 'SizeNS vert'
  'SizeWE horz' 'Grab move' 'SizeAll move' 'UpArrow alternate' 'Hand link'
  'Pin pin' 'Person person' 'Pan pan' 'Grabbing grabbing' 'Zoom-in zoom-in'
  'Zoom-out zoom-out'
)
SCHEME_ORDER=(pointer help work busy cross text handwriting vert horz move
              alternate link pin person pan grabbing zoom-in zoom-out dng2
              unavailiable dng1)

build_windows() {
  local name="$1" theme="AppleCursor-$1"
  local dir="$work/$1" target="$output/windows/$theme"
  local win="$here/configs/$windows_profile.build.toml"
  local sizes win_sizes cursor png hx hy role override size frame frames n

  win_sizes=($(fallback_sizes "$win" win_sizes))
  rm -rf "$target"; mkdir -p "$target"
  local produced=()

  while IFS='|' read -r cursor png hx hy role override; do
    [ -n "$cursor" ] || continue
    [ -n "$role" ] || continue
    mapfile -t frames < <(frames_for "$png")
    if [ ${#frames[@]} -gt 1 ]; then
      # Animated: one image per frame at the pinned size.
      size=${override%% *}
      SIZES=("$size")
      HOTXS=("$(win_hotspot "$hx" "$size")")
      HOTYS=("$(win_hotspot "$hy" "$size")")
      local parts=()
      for n in "${!frames[@]}"; do
        write_cur "$dir/ani-$cursor-$n.cur" "$render_root/${SVG_HASH[$cursor-$n]}-$size.png"
        parts+=("$dir/ani-$cursor-$n.cur")
      done
      write_ani "$target/$role.ani" "${parts[@]}"
      produced+=("$(printf '%s' "$role" | tr 'A-Z' 'a-z')=$role.ani")
    else
      SIZES=(); HOTXS=(); HOTYS=()
      local files=()
      for size in "${win_sizes[@]}"; do
        SIZES+=("$size")
        HOTXS+=("$(win_hotspot "$hx" "$size")")
        HOTYS+=("$(win_hotspot "$hy" "$size")")
        files+=("$render_root/${SVG_HASH[$cursor-0]}-$size.png")
      done
      write_cur "$target/$role.cur" "${files[@]}"
      produced+=("$(printf '%s' "$role" | tr 'A-Z' 'a-z')=$role.cur")
    fi
  done < "$dir/plan.windows"

  write_windows_metadata "$target" "$theme" "${produced[@]}"
  say "windows $target ($(find "$target" -name '*.cur' -o -name '*.ani' | wc -l) cursors)"
}

write_windows_metadata() {
  local target="$1" theme="$2"; shift 2
  local -A files=()
  local pair
  for pair in "$@"; do files["${pair%%=*}"]="${pair#*=}"; done

  local role_registry="" paths="" file_list="" string_vars=""
  for pair in "${ROLE_MAP[@]}"; do
    local role="${pair%% *}" variable="${pair##* }"
    [ -n "${files[$variable]:-}" ] || continue
    role_registry+="HKCU,\"Control Panel\\Cursors\",$role,0x00020000,\"%10%\\%CUR_DIR%\\%$variable%\"\n"
  done
  local variable
  for variable in "${SCHEME_ORDER[@]}"; do
    [ -n "${files[$variable]:-}" ] || continue
    paths+="%10%\\%CUR_DIR%\\%$variable%,"
  done
  paths="${paths%,}"
  for variable in $(printf '%s\n' "${!files[@]}" | sort); do
    file_list+="${files[$variable]}"$'\n'
    string_vars+=$(printf '%-20s = "%s"\n' "$variable" "${files[$variable]}")
  done

  {
    printf '%s' "${INSTALL_INF_HEAD//%THEME%/$theme Cursors}"
    printf '%b' "$role_registry"
    printf '%s\n' 'HKLM,"SOFTWARE\Microsoft\Windows\CurrentVersion\Runonce\Setup\","",,"rundll32.exe shell32.dll,Control_RunDLL main.cpl @0,1"'
    printf '\n[Scheme.Cur]\n%s\n' "${file_list%$'\n'}"
    printf '\n[Strings]\nCUR_DIR             = "Cursors\\%s Cursors"\nSCHEME_NAME         = "%s Cursors"\n' "$theme" "$theme"
    printf '%s\n' "$string_vars"
  } | sed "s|%SCHEME_PATHS%|$paths|" > "$target/install.inf"

  cat > "$target/uninstall.bat" <<EOF
@echo off
REM Remove the "$theme Cursors" scheme installed by install.inf.
REG DELETE "HKCU\\Control Panel\\Cursors\\Schemes" /v "$theme Cursors" /f
echo Removed $theme Cursors. Open Mouse Properties to pick another scheme.
EOF
}

# ----------------------------------------------------------------------- stamp
# Rebuilding a theme that has not changed means reassembling 44 XCursor files and
# 21 Windows cursors: about six seconds of xcursorgen work per scheme. A stamp of
# every input lets an unchanged theme be skipped completely.
stamp_key() { # scheme-line platform config-file
  { printf '%s|%s\n' "$1" "$2"
    cat "$3" "$here/lib/render.sh" "$here/build.sh" "$here/schemes.conf"
  } | sha256sum | cut -d' ' -f1
}

theme_current() { # dir key
  [ "$force" = 0 ] || return 1
  [ -f "$1/.stamp" ] || return 1
  [ "$(cat "$1/.stamp")" = "$2" ] || return 1
  [ -e "$1/cursors/left_ptr" ] || [ -e "$1/Pointer.cur" ]
}

# ------------------------------------------------------------------------ main
declare -a selected=()
if [ ${#wanted[@]} -eq 0 ]; then
  while IFS= read -r line; do selected+=("$line"); done < <(schemes)
else
  for want in "${wanted[@]}"; do
    line=$(schemes | awk -F'|' -v want="$want" '$1 == want')
    [ -n "$line" ] || die "unknown scheme: $want (try --list)"
    selected+=("$line")
  done
fi

mkdir -p "$output"
want_linux=0; want_windows=0
[[ " $platforms " == *" linux "* ]] && want_linux=1
[[ " $platforms " == *" windows "* ]] && want_windows=1

for scheme in "${selected[@]}"; do
  IFS='|' read -r name fill outline comment <<< "$scheme"
  linux_dir="$output/linux/AppleCursor-$name"
  win_dir="$output/windows/AppleCursor-$name"
  linux_key=$(stamp_key "$scheme" linux "$here/configs/x.build.toml")
  win_key=$(stamp_key "$scheme" windows "$here/configs/$windows_profile.build.toml")

  need_linux=0; need_win=0
  [ "$want_linux" = 1 ] && { theme_current "$linux_dir" "$linux_key" || need_linux=1; }
  [ "$want_windows" = 1 ] && { theme_current "$win_dir" "$win_key" || need_win=1; }
  if [ "$need_linux" = 0 ] && [ "$need_win" = 0 ]; then
    say "$name: unchanged, skipped"
    continue
  fi

  # Only plan the work that is actually stale.
  PLAN_LINUX=$([ "$want_linux" = 1 ] && [ "$need_linux" = 1 ] && echo 1 || echo 0)
  PLAN_WINDOWS=$([ "$want_windows" = 1 ] && [ "$need_win" = 1 ] && echo 1 || echo 0)
  plan_scheme "$name" "$fill" "$outline"
  render_scheme "$name"
  if [ "$need_linux" = 1 ]; then
    build_linux "$name" "$comment"
    printf '%s\n' "$linux_key" > "$linux_dir/.stamp"
  fi
  if [ "$need_win" = 1 ]; then
    build_windows "$name"
    printf '%s\n' "$win_key" > "$win_dir/.stamp"
  fi
done
say "done: ${#selected[@]} scheme(s) in $output"
