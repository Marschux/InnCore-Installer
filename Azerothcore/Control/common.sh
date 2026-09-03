#!/usr/bin/env bash
#
# Loader for the Control toolkit: reads control.conf, defines the colour
# palette, then sources the topic libs (lib-ui, lib-server, lib-build, lib-db,
# lib-config). Every menu / manager script sources THIS file only.

set -euo pipefail

CONTROL_CONFIG="${CONTROL_CONFIG:-$(dirname "${BASH_SOURCE[0]}")/control.conf}"
[ -f "$CONTROL_CONFIG" ] || { echo "Control configuration missing: $CONTROL_CONFIG"; exit 1; }
source "$CONTROL_CONFIG"

RESET='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BLUE='\033[1;34m'; WHITE='\033[1;37m'
GRAY='\033[1;30m'; PURPLE='\033[38;5;141m'; TEAL='\033[38;5;44m'; GOLD='\033[38;5;220m'
NC="$RESET"

COLOR_SERVER="$CYAN"
COLOR_LOGS="$GRAY"
COLOR_BUILD="$BLUE"
COLOR_CONFIG="$GOLD"
COLOR_MANAGE="$PURPLE"
COLOR_TOOLS="$TEAL"
COLOR_EXIT="$RED"

# Generic guard used across the server / build / config libs.
require_path() {
    [ -e "$1" ] || { echo "Path not found: $1"; return 1; }
}

_lib_dir="$(dirname "${BASH_SOURCE[0]}")"
for _lib in lib-ui lib-server lib-build lib-db lib-config; do
    # shellcheck source=/dev/null
    source "$_lib_dir/$_lib.sh"
done
unset _lib_dir _lib
