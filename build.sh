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
# Windows plays an .ani in jiffies (1/60 s). Upstream ships a 20 ms delay as 2
# jiffies, so mirror that instead of the config's win_delay.
ani_rate=2
# An .ani frame carries one image; Windows scales it to the chosen cursor size.
ani_target=64

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
say() { printf '  %s\n' "$*"; }

usage() { sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --scheme) [ $# -ge 2 ] || die '--scheme needs a value'; wanted+=("$2"); shift 2 ;;
    --scheme=*) wanted+=("${1#*=}"); shift ;;
    --platforms) [ $# -ge 2 ] || die '--platforms needs a value'; platforms="$2"; shift 2 ;;
    --platforms=*) platforms="${1#*=}"; shift ;;
    --output) [ $# -ge 2 ] || die '--output needs a value'; output="$2"; shift 2 ;;
    --output=*) output="${1#*=}"; shift ;;
    --windows-profile) windows_profile="win_${2#win_}"; shift 2 ;;
    --list) awk -F'|' '/^[^#[:space:]]/ {printf "%-18s fill %-8s outline %s\n", $1, $2, $3}' "$here/schemes.conf"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

for tool in rsvg-convert xcursorgen awk sed; do
  command -v "$tool" >/dev/null 2>&1 || die "missing $tool (Fedora: librsvg2-tools xcursorgen; Debian: librsvg2-bin x11-apps; Arch: librsvg xorg-xcursorgen)"
done

schemes() { awk -F'|' '/^[^#[:space:]]/' "$here/schemes.conf"; }

work=$(mktemp -d "${TMPDIR:-/tmp}/cursor-build-XXXXXX")
trap 'rm -rf "$work"' EXIT

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
    /^[ \t]*x11_sizes[ \t]*=/ { sizes = $0; if ($0 !~ /\]/) collecting = 2; next }
    /^[ \t]*x11_delay[ \t]*=/ { delay = trim(substr($0, index($0, "=") + 1)); next }
    collecting == 2 { sizes = sizes " " $0; if ($0 ~ /\]/) collecting = 0 }
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
      # TOML strings are single quoted here; \047 is an apostrophe inside awk.
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

# Fallback values from the [cursors.fallback_settings] section.
fallback_x11_sizes() { awk -F'[][, ]+' '/^\[/ { f = ($0 ~ /fallback_settings/) } f && /^[ \t]*x11_sizes/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) printf "%s ", $i }' "$1"; }
fallback_x11_hotspot() {
  awk -v key="$2" '/^\[/ { f = ($0 ~ /fallback_settings/) } f && $1 == key { print $3; exit }' "$1"
}
fallback_win_sizes() { awk -F'[][, ]+' '/^\[/ { f = ($0 ~ /fallback_settings/) } f && /^[ \t]*win_sizes/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) printf "%s ", $i }' "$1"; }

# --------------------------------------------------------------- SVG renderer
# render <svg> <size> <fill> <out.png>
render() {
  local svg="$1" size="$2" fill="$3" out="$4" tmp
  tmp="$work/$(basename "$svg").$$.svg"
  sed "s/#00FF00/$fill/Ig; s/#0000FF/$outline/Ig" "$svg" > "$tmp"
  rsvg-convert -w "$size" -h "$size" -o "$out" "$tmp"
  rm -f "$tmp"
}

# frames <png-spec> -> newline separated SVG paths
frames_for() {
  local spec="$1"
  case "$spec" in
    *-\*.png)
      local dir="$here/svg/${spec%%-\**}"
      find "$dir" -maxdepth 1 -name '*.svg' | sort
      ;;
    *) printf '%s\n' "$here/svg/${spec%.png}.svg" ;;
  esac
}

# ------------------------------------------------------------------- XCursor
# x_hotspot <hotspot> <size>: upstream's plain floor formula
x_hotspot() { printf '%s' $(( $1 * $2 / canvas )); }
# win_hotspot <hotspot> <size>: upstream's (value - 1) // 256 formula
win_hotspot() { printf '%s' $(( ($1 * $2 - 1) / canvas )); }

build_linux() {
  local name="$1" fill="$2" comment="${3:-}" theme="AppleCursor-$1"
  local target="$output/linux/$theme" x11="$here/configs/x.build.toml"
  local sizes delay hx hy syms frame size hot_x hot_y
  mapfile -t sizes <<< "$(fallback_x11_sizes "$x11" | tr ' ' '\n' | sed '/^$/d')"
  hx=$(fallback_x11_hotspot "$x11" x_hotspot)
  hy=$(fallback_x11_hotspot "$x11" y_hotspot)
  delay=$(awk '/^\[/ { f = ($0 ~ /fallback_settings/) } f && $1 == "x11_delay" { print $3; exit }' "$x11")

  rm -rf "$target"; mkdir -p "$target/cursors"
  local count=0
  while IFS='|' read -r name_spec png spec_hx spec_hy syms; do
    [ -n "$name_spec" ] || continue
    local cfg="$work/x11-$name_spec.conf" index=0
    : > "$cfg"
    while read -r frame; do
      for size in "${sizes[@]}"; do
        hot_x=$(x_hotspot "${spec_hx:-$hx}" "$size")
        hot_y=$(x_hotspot "${spec_hy:-$hy}" "$size")
        render "$frame" "$size" "$fill" "$work/f-$name_spec-$index.png"
        printf '%s %s %s %s %s\n' "$size" "$hot_x" "$hot_y" "$work/f-$name_spec-$index.png" "$delay" >> "$cfg"
        index=$((index + 1))
      done
    done < <(frames_for "$png")
    xcursorgen "$cfg" "$target/cursors/$name_spec"
    if [ -n "$syms" ]; then
      local alias
      for alias in $(printf '%s' "$syms" | tr ',' ' '); do
        ln -sf "$name_spec" "$target/cursors/$alias"
      done
    fi
    count=$((count + 1))
  done < <(manifest_x11 "$x11")

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
  say "linux   $target ($(find "$target/cursors" -maxdepth 1 -type f | wc -l) files, $(find "$target/cursors" -maxdepth 1 -type l | wc -l) aliases, $count cursors)"
}

# -------------------------------------------------------------------- Windows
# cur <out> <file>... with SIZES/HOTXS/HOTYS arrays describing every image.
write_cur() {
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

# ani <out> <cur-file>... as a RIFF/ACON animation at ANI_RATE jiffies.
write_ani() {
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

# Windows role name -> file variable, in the order Windows reads a scheme.
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
  local name="$1" fill="$2" theme="AppleCursor-$1"
  local target="$output/windows/$theme" win="$here/configs/$windows_profile.build.toml"
  local sizes hx hy
  mapfile -t sizes <<< "$(fallback_win_sizes "$win" | tr ' ' '\n' | sed '/^$/d')"
  hx=$(fallback_x11_hotspot "$win" x_hotspot)
  hy=$(fallback_x11_hotspot "$win" y_hotspot)

  rm -rf "$target"; mkdir -p "$target"
  local decl=() produced=()
  local name_spec png spec_hx spec_hy role frame size index frame_size
  while IFS='|' read -r name_spec png spec_hx spec_hy role override; do
    [ -n "$name_spec" ] || continue
    [ -n "$role" ] || continue
    mapfile -t glyphs < <(frames_for "$png")
    if [ -n "$override" ]; then
      # Per-cursor win_sizes from upstream: the animated pointers ship 65 px frames.
      mapfile -t sizes <<< "$(printf '%s' "$override" | tr ' ' '\n' | sed '/^$/d')"
    else
      mapfile -t sizes <<< "$(fallback_win_sizes "$win" | tr ' ' '\n' | sed '/^$/d')"
    fi
    if [ ${#glyphs[@]} -gt 1 ]; then
      # Animated: one image per frame, near 64 px, so Windows can scale it.
      frame_size=${sizes[0]}
      if [ -z "$override" ]; then
        for size in "${sizes[@]}"; do
          if [ $(( size > ani_target ? size - ani_target : ani_target - size )) -lt \
               $(( frame_size > ani_target ? frame_size - ani_target : ani_target - frame_size )) ]; then
            frame_size=$size
          fi
        done
      fi
      SIZES=("$frame_size"); HOTXS=("$(win_hotspot "${spec_hx:-$hx}" "$frame_size")")
      HOTYS=("$(win_hotspot "${spec_hy:-$hy}" "$frame_size")")
      local parts=()
      index=0
      for frame in "${glyphs[@]}"; do
        render "$frame" "$frame_size" "$fill" "$work/ani-$name_spec-$index.png"
        write_cur "$work/ani-$name_spec-$index.cur" "$work/ani-$name_spec-$index.png"
        parts+=("$work/ani-$name_spec-$index.cur")
        index=$((index + 1))
      done
      write_ani "$target/$role.ani" "${parts[@]}"
      produced+=("$(printf '%s' "$role" | tr 'A-Z' 'a-z')=$role.ani")
    else
      SIZES=(); HOTXS=(); HOTYS=(); local files=()
      index=0
      for size in "${sizes[@]}"; do
        SIZES+=("$size")
        HOTXS+=("$(win_hotspot "${spec_hx:-$hx}" "$size")")
        HOTYS+=("$(win_hotspot "${spec_hy:-$hy}" "$size")")
        render "${glyphs[0]}" "$size" "$fill" "$work/cur-$name_spec-$index.png"
        files+=("$work/cur-$name_spec-$index.png")
        index=$((index + 1))
      done
      write_cur "$target/$role.cur" "${files[@]}"
      produced+=("$(printf '%s' "$role" | tr 'A-Z' 'a-z')=$role.cur")
    fi
  done < <(manifest_windows "$win")

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
for scheme in "${selected[@]}"; do
  IFS='|' read -r name fill outline comment <<< "$scheme"
  [[ " $platforms " == *" linux "* ]] && build_linux "$name" "$fill" "$comment"
  [[ " $platforms " == *" windows "* ]] && build_windows "$name" "$fill"
done
say "done: ${#selected[@]} scheme(s) in $output"
