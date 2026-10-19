#!/usr/bin/env bash
# Build dist/server-setup: one self-contained file with every lib inlined.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/dist/server-setup"
mkdir -p "$root/dist"
libs=$(sed -n 's/^for _f in \(.*\); do$/\1/p' "$root/bin/server-setup")
[[ -n $libs ]] || { echo "lib list not found in bin/server-setup" >&2; exit 1; }
{
  sed -n '1,/^# >>> libs/p' "$root/bin/server-setup" | sed '$d'
  echo "# ---- bundled by tools/build.sh from $(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unknown) ----"
  for f in $libs; do
    echo "# ==== lib/$f.sh ===="
    grep -v '^# shellcheck shell=bash$' "$root/lib/$f.sh"
    echo
  done
  sed -n '/^# <<< libs/,$p' "$root/bin/server-setup" | sed '1d'
} >"$out"
chmod 755 "$out"
( cd "$root/dist" && sha256sum server-setup >server-setup.sha256 )
echo "built $out ($(wc -l <"$out") lines)"
