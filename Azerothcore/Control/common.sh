#!/usr/bin/env bash

set -euo pipefail

CONTROL_CONFIG="${CONTROL_CONFIG:-$(dirname "${BASH_SOURCE[0]}")/control.conf}"
[ -f "$CONTROL_CONFIG" ] || { echo "Control configuration missing: $CONTROL_CONFIG"; exit 1; }
source "$CONTROL_CONFIG"

RESET='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; WHITE='\033[1;37m'; NC="$RESET"

menu_title() {
    local icon="$1" title="$2" process="$3" session="${4:-}" heading heading_line
    heading="${icon} ${title}"
    printf -v heading_line '| %-76s |' "$heading"
    clear
    printf '%b\n' "${CYAN}+------------------------------------------------------------------------------+${RESET}"
    printf '%b\n' "${CYAN}${heading_line}${RESET}"
    printf '%b\n' "${CYAN}+------------------------------------------------------------------------------+${RESET}"
    server_status "$process" "$session"
    echo ""
}

menu_section() {
    echo ""
    echo -e "${YELLOW}${BOLD}--- $1 ---${RESET}"
}

pause_control() {
    echo ""
    read -rp "Press ENTER to return... " _
}

require_path() {
    [ -e "$1" ] || { echo "Path not found: $1"; return 1; }
}

server_start() {
    local process="$1" engine="$2" binary="$3" conf="$4" session="$5"

    require_path "$engine" || return 1
    require_path "$binary" || return 1
    require_path "$conf" || return 1

    if pgrep -x "$process" >/dev/null 2>&1 || tmux has-session -t "$session" 2>/dev/null; then
        echo "$process is already running or already owns the session $session."
        return 0
    fi

    tmux new-session -d -s "$session" \
        "cd '$ACORE_DIR' && '$engine' start '$binary' --server-config '$conf' --session-manager none"
    echo "$process started: $session"
}

server_stop() {
    local process="$1" session="$2" shutdown_command="${3:-}" max_wait="${4:-120}"
    local waited=0

    if ! pgrep -x "$process" >/dev/null 2>&1; then
        tmux kill-session -t "$session" 2>/dev/null || true
        echo "$process is not running."
        return 0
    fi

    if [ -n "$shutdown_command" ] && tmux has-session -t "$session" 2>/dev/null; then
        tmux send-keys -t "$session" "saveall" Enter
        tmux send-keys -t "$session" "$shutdown_command" Enter
    else
        pkill -TERM -x "$process" 2>/dev/null || true
    fi

    while pgrep -x "$process" >/dev/null 2>&1 && [ "$waited" -lt "$max_wait" ]; do
        sleep 1
        waited=$((waited + 1))
        if [ $((waited % 30)) -eq 0 ]; then
            echo "$process is shutting down gracefully (${waited}s)..."
        fi
    done

    if pgrep -x "$process" >/dev/null 2>&1; then
        echo "$process still responding after ${max_wait}s; no automatic KILL."
        return 1
    fi

    tmux kill-session -t "$session" 2>/dev/null || true
    echo "$process stopped gracefully."
}

server_restart() {
    local process="$1" engine="$2" binary="$3" conf="$4" session="$5" shutdown_command="${6:-}"
    server_stop "$process" "$session" "$shutdown_command" "${7:-120}" || return 1
    sleep 2
    server_start "$process" "$engine" "$binary" "$conf" "$session"
}

server_reload() {
    local process="$1" session="$2"
    if ! pgrep -x "$process" >/dev/null 2>&1 || ! tmux has-session -t "$session" 2>/dev/null; then
        echo "$process is not running with an active tmux session."
        return 1
    fi
    tmux send-keys -t "$session" "reload config" Enter
    echo "Config reload sent to $process."
}

read_login_database() {
    local line
    line=$(grep -E '^[[:space:]]*LoginDatabaseInfo[[:space:]]*=' "$AUTH_CONF" | tail -n 1)
    line=$(echo "$line" | cut -d= -f2- | cut -d# -f1 | xargs | sed 's/^"//;s/"$//')
    IFS=';' read -r DB_HOST DB_PORT DB_USER DB_PASS DB_NAME <<< "$line"
    [ -n "${DB_HOST:-}" ] && [ -n "${DB_PORT:-}" ] && [ -n "${DB_USER:-}" ] && [ -n "${DB_NAME:-}" ]
}

mysql_auth() {
    read_login_database || { echo "Could not read LoginDatabaseInfo."; return 1; }
    MYSQL_PWD="$DB_PASS" mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" "$DB_NAME" "$@"
}

server_status() {
    local process="$1" session="$2"
    if pgrep -x "$process" >/dev/null 2>&1; then
        echo -e "Status: ${GREEN}${BOLD}ONLINE${RESET}"
        ps -C "$process" -o pid=,etime=,%cpu=,%mem=,cmd=
    else
        echo -e "Status: ${RED}${BOLD}OFFLINE${RESET}"
    fi
    if tmux has-session -t "$session" 2>/dev/null; then
        echo -e "tmux: ${GREEN}ACTIVE${RESET} ($session)"
    else
        echo -e "tmux: ${DIM}INACTIVE${RESET} ($session)"
    fi
}

safe_build() {
    local dir="$1"
    require_path "$dir" || return 1
    (cd "$dir" && make -j "$(nproc)" && make install)
}
