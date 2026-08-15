#!/usr/bin/env bash

set -euo pipefail

CONTROL_CONFIG="${CONTROL_CONFIG:-$(dirname "${BASH_SOURCE[0]}")/control.conf}"
[ -f "$CONTROL_CONFIG" ] || { echo "Control-Konfiguration fehlt: $CONTROL_CONFIG"; exit 1; }
source "$CONTROL_CONFIG"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

menu_title() {
    local icon="$1" title="$2" process="$3" session="${4:-}"
    clear
    echo -e "${CYAN}==============================================================================${NC}"
    echo -e "${CYAN}  $icon  $title${NC}"
    echo -e "${CYAN}==============================================================================${NC}"
    server_status "$process" "$session"
    echo ""
}

menu_section() { echo -e "${YELLOW}--- $1 ---${NC}"; }

pause_control() {
    echo ""
    read -rp "ENTER drücken, um zurückzukehren... " _
}

require_path() {
    [ -e "$1" ] || { echo "Pfad nicht gefunden: $1"; return 1; }
}

read_login_database() {
    local line
    line=$(grep -E '^[[:space:]]*LoginDatabaseInfo[[:space:]]*=' "$AUTH_CONF" | tail -n 1)
    line=$(echo "$line" | cut -d= -f2- | cut -d# -f1 | xargs | sed 's/^"//;s/"$//')
    IFS=';' read -r DB_HOST DB_PORT DB_USER DB_PASS DB_NAME <<< "$line"
    [ -n "${DB_HOST:-}" ] && [ -n "${DB_PORT:-}" ] && [ -n "${DB_USER:-}" ] && [ -n "${DB_NAME:-}" ]
}

mysql_auth() {
    read_login_database || { echo "LoginDatabaseInfo konnte nicht gelesen werden."; return 1; }
    MYSQL_PWD="$DB_PASS" mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" "$DB_NAME" "$@"
}

server_status() {
    local process="$1" session="$2"
    if pgrep -x "$process" >/dev/null 2>&1; then
        echo "Status: ONLINE"
        ps -C "$process" -o pid=,etime=,%cpu=,%mem=,cmd=
    else
        echo "Status: OFFLINE"
    fi
    if tmux has-session -t "$session" 2>/dev/null; then
        echo "tmux: ACTIVE ($session)"
    else
        echo "tmux: INACTIVE ($session)"
    fi
}

safe_build() {
    local dir="$1"
    require_path "$dir" || return 1
    (cd "$dir" && make -j "$(nproc)" && make install)
}
