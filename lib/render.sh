#!/usr/bin/env bash
# Render one SVG at one size. Called in parallel by build.sh.
#   render.sh <svg> <size> <out.png>
set -euo pipefail
exec rsvg-convert -w "$2" -h "$2" -o "$3" "$1"
