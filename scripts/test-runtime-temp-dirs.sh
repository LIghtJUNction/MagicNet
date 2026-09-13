#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export MODDIR="$work/module" KAM_HOME="$work/module"
mkdir -p "$MODDIR/tmp"
. "$root/src/MagicNet/lib/kamfw/init_dirs.sh"
kam_init_dirs --required
[ ! -e "$MODDIR/tmp" ] && [ ! -e "$MODDIR/.tmp" ]
. "$root/src/MagicNet/lib/kamfw/__runtime__.sh"
kamfw_init_home
[ ! -e "$MODDIR/tmp" ] && [ ! -e "$MODDIR/.tmp" ]
mkdir -p "$MODDIR/tmp" "$MODDIR/.tmp"
printf 'keep' > "$MODDIR/tmp/active"
printf 'keep' > "$MODDIR/.tmp/active"
kam_init_dirs --required
kamfw_init_home
[ -f "$MODDIR/tmp/active" ] && [ -f "$MODDIR/.tmp/active" ]
printf '%s\n' 'runtime temporary directory tests passed'
