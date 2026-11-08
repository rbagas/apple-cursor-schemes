#!/usr/bin/env bash
# Install the built cursor themes on Linux (X11 and Wayland desktops).
#
#   ./install.sh                        install AppleCursor-GitHub-Dark
#   ./install.sh --scheme Nord          install one scheme
#   ./install.sh --all                  install every scheme, keep the current one
#   ./install.sh --list                 show the available schemes
#   ./install.sh --size 32 --scheme X   install and set the GNOME cursor size
#   ./install.sh --uninstall --all      remove installed themes and settings
#   ./install.sh --system --all         install into /usr/share/icons (needs root)
#
# Themes are plain directories, so any desktop can also just copy
# dist/linux/<theme> into ~/.local/share/icons and select it in its settings.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
prefix_scheme="AppleCursor-GitHub-Dark"
schemes=()
all=0
size=""
target="user"
apply=1
uninstall=0
force=0

usage() { sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
say() { printf '  %s\n' "$*"; }

available_schemes() {
  if [ -d "$here/dist/linux" ]; then
    for dir in "$here"/dist/linux/AppleCursor-*; do
      [ -d "$dir" ] && basename "$dir" | sed 's/^AppleCursor-//'
    done
  elif [ -f "$here/schemes.toml" ]; then
    sed -n "s/^name = '\(.*\)'$/\1/p" "$here/schemes.toml"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --scheme) [ $# -ge 2 ] || die '--scheme needs a value'; schemes+=("$2"); shift 2 ;;
    --scheme=*) schemes+=("${1#*=}"); shift ;;
    --all) all=1; shift ;;
    --list) available_schemes; exit 0 ;;
    --size) [ $# -ge 2 ] || die '--size needs a value'; size="$2"; shift 2 ;;
    --size=*) size="${1#*=}"; shift ;;
    --system) target="system"; shift ;;
    --no-apply) apply=0; shift ;;
    --uninstall) uninstall=1; shift ;;
    --force) force=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[ "$all" = 1 ] && mapfile -t schemes < <(available_schemes)
[ ${#schemes[@]} -eq 0 ] && schemes=("${prefix_scheme#AppleCursor-}")

if [ "$target" = system ]; then
  icons=/usr/share/icons
  [ "$(id -u)" -eq 0 ] || die '--system writes to /usr/share/icons; run it with sudo'
else
  icons="${XDG_DATA_HOME:-$HOME/.local/share}/icons"
fi
mkdir -p "$icons"

apply_settings() {
  local theme="$1"
  if [ "$apply" = 0 ]; then
    say "skipped settings (--no-apply); select $theme in your desktop's cursor settings"
    return
  fi
  if command -v gsettings >/dev/null 2>&1; then
    if gsettings set org.gnome.desktop.interface cursor-theme "$theme" 2>/dev/null; then
      say "GNOME cursor theme: $theme"
      [ -n "$size" ] || size=$(gsettings get org.gnome.desktop.interface cursor-size 2>/dev/null || echo 24)
      gsettings set org.gnome.desktop.interface cursor-size "${size:-24}" 2>/dev/null &&
        say "GNOME cursor size: ${size:-24}" || true
    else
      say "gsettings not usable here; select $theme in your desktop's cursor settings"
    fi
  else
    say "no gsettings; select $theme in your desktop's cursor settings"
  fi
  if [ "$target" = user ]; then
    local conf="${XDG_CONFIG_HOME:-$HOME/.config}/environment.d/90-cursor.conf"
    mkdir -p "$(dirname "$conf")"
    {
      printf '# Written by apple-cursor-schemes install.sh.\n'
      printf '# Makes Xwayland, Qt and Electron apps use the same pointer as GTK.\n'
      printf 'XCURSOR_THEME=%s\n' "$theme"
      printf 'XCURSOR_SIZE=%s\n' "${size:-24}"
    } > "$conf"
    say "wrote $conf (takes effect at next login)"
  fi
}

uninstall_one() {
  local theme="AppleCursor-$1"
  if [ -d "$icons/$theme" ]; then
    rm -rf "$icons/$theme"
    say "removed $icons/$theme"
  else
    say "$theme was not installed in $icons"
  fi
  local conf="${XDG_CONFIG_HOME:-$HOME/.config}/environment.d/90-cursor.conf"
  if [ -f "$conf" ] && grep -q "^XCURSOR_THEME=$theme$" "$conf"; then
    rm -f "$conf"
    say "removed $conf"
    if command -v gsettings >/dev/null 2>&1; then
      gsettings set org.gnome.desktop.interface cursor-theme Adwaita 2>/dev/null &&
        say 'GNOME cursor theme reset to Adwaita'
    fi
  fi
}

if [ "$uninstall" = 1 ]; then
  for scheme in "${schemes[@]}"; do uninstall_one "$scheme"; done
  exit 0
fi

installed=()
for scheme in "${schemes[@]}"; do
  theme="AppleCursor-$scheme"
  src="$here/dist/linux/$theme"
  if [ ! -d "$src" ]; then
    printf '%s is not built yet; building it now...\n' "$theme"
    python3 "$here/tools/build_schemes.py" --scheme "$scheme" --platforms linux --output "$here/dist" ||
      die "could not build $theme (needs python3, pycairo and librsvg; see README)"
    src="$here/dist/linux/$theme"
  fi
  [ -d "$src/cursors" ] || die "$src does not look like a cursor theme"
  if [ -e "$icons/$theme" ] && [ "$force" = 0 ]; then
    say "$icons/$theme exists; use --force to replace it"
    installed+=("$theme")
    continue
  fi
  rm -rf "$icons/$theme"
  cp -a "$src" "$icons/$theme"
  chmod -R u+rwX,go+rX "$icons/$theme"
  say "installed $icons/$theme ($(find "$icons/$theme/cursors" -maxdepth 1 -type l | wc -l) aliases, $(du -sh "$icons/$theme" | cut -f1))"
  installed+=("$theme")
done

if [ ${#installed[@]} -eq 1 ]; then
  apply_settings "${installed[0]}"
elif [ ${#installed[@]} -gt 1 ]; then
  say "installed ${#installed[@]} themes; pick one with: ./install.sh --scheme NAME --force"
fi

cat <<'EOF'

Pick it up:
  GTK and GNOME Shell switch immediately.
  Xwayland, Qt and Electron apps follow after a logout/login.
  Other desktops: choose the theme in their cursor settings.
EOF
