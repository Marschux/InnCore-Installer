#!/usr/bin/env bash
#
# Control toolkit, part 1: config + colour palette, then the functions used on
# every menu repaint (UI frames, tmux / process control, status). The rarely
# used build / DB / config helpers live in common-ops.sh, sourced at the end.
# Every menu / manager script sources THIS file only.

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

# Generic guard used across the server / build / config helpers.
require_path() {
    [ -e "$1" ] || { echo "Path not found: $1"; return 1; }
}

# --- menu rendering: frames, prompts, status rows --------------------------

wait_for_user() {
    echo ""
    echo -e "${CYAN}↩  Press [ENTER] to return to the menu...${RESET}"
    read -r _ || true
}

menu_section() {
    echo ""
    echo -e "${1}${BOLD}${2}${RESET}"
}

# Inner width for menu frames: fits the terminal (leaving a 2-col margin),
# clamped so it neither overflows an 80-col console nor sprawls on a wide one.
menu_width() {
    local c
    c="$(tput cols 2>/dev/null || echo 80)"
    c=$((c - 2))
    [ "$c" -gt 79 ] && c=79
    [ "$c" -lt 58 ] && c=58
    echo "$c"
}

box_title() {   # box_title <title> [color]
    local t="$1" c="${2:-$CYAN}" w pad rule tw rest
    w="$(menu_width)"
    rule="$(printf '═%.0s' $(seq 1 "$w"))"
    # Display width. Submenu titles are "<emoji><2 spaces><ASCII text>"; ${#t}
    # miscounts the emoji (bytes under a non-UTF-8 locale, and terminals render
    # these glyphs 1 col wide anyway), so measure only the ASCII tail after the
    # first space (locale-safe) and add 2: one for the emoji, one for that space.
    case "$t" in
        [!$'\x20'-$'\x7e']*) rest="${t#* }"; tw=$(( ${#rest} + 2 )) ;;
        *) tw=${#t} ;;
    esac
    pad=$(( (w - tw) / 2 ))
    printf "${c}╔%s╗${RESET}\n" "$rule"
    printf "${c}║${RESET}%*s${BOLD}${WHITE}%s${RESET}%*s${c}║${RESET}\n" "$pad" "" "$t" "$((w - pad - tw))" ""
    printf "${c}╚%s╝${RESET}\n" "$rule"
}

hr() { printf "${DIM}%s${RESET}\n" "$(printf '─%.0s' $(seq 1 "$(( $(menu_width) + 2 ))"))"; }
menu_footer() { printf "${CYAN}%s${RESET}\n" "$(printf '═%.0s' $(seq 1 "$(( $(menu_width) + 2 ))"))"; }

# Header for a nested submenu: same box as the main screen, tinted to the
# section colour, followed by a blank line.
submenu_title() {   # submenu_title <title> <color>
    clear
    box_title "$1" "$2"
    echo ""
}

# Repaint without a visible clear: cursor home, print the frame with
# erase-to-end-of-line on every row, then erase everything below. Falls back to
# a full clear when the frame no longer fits on screen.
draw_menu() {
    local render_fn="$1" frame term_rows frame_rows
    frame="$($render_fn)"
    term_rows="$(tput lines 2>/dev/null || echo 0)"
    frame_rows="$(printf '%s\n' "$frame" | wc -l)"
    if [ "$term_rows" -gt 0 ] && [ $((frame_rows + 2)) -ge "$term_rows" ]; then
        clear
        printf '%s\n' "$frame"
        return
    fi
    frame="${frame//$'\n'/$'\033[K'$'\n'}"
    printf '\033[H%s\033[K\n\033[0J' "$frame"
}

run_step() {   # run_step "<script or function>" [args...]
    clear
    "$@"
    wait_for_user
}

# Fixed-width label so the status block lines up regardless of icon/word width.
status_row() { printf ' %s  %-15s' "$1" "$2"; }

status_dot() {   # status_dot <process-name> <session>
    local process="$1" session="$2" label
    label="${process^}:"
    if tmx has-session -t "$session" 2>/dev/null; then
        if pgrep -x "$process" >/dev/null 2>&1; then
            echo -e "$(status_row 🟢 "$label")${GREEN}${BOLD}ONLINE${RESET}"
        else
            echo -e "$(status_row 🟡 "$label")${YELLOW}tmux active, process missing${RESET}"
        fi
    else
        if pgrep -x "$process" >/dev/null 2>&1; then
            echo -e "$(status_row 🟠 "$label")${YELLOW}process running, tmux missing${RESET}"
        else
            echo -e "$(status_row 🔴 "$label")${RED}${BOLD}OFFLINE${RESET}"
        fi
    fi
}

autostart_dot() {   # autostart_dot <service-name>
    local svc="$1"
    if [ -z "$svc" ]; then
        echo -e "$(status_row 🚀 "Autostart:")${RED}service name missing${RESET}"
    elif systemctl is-enabled "$svc" >/dev/null 2>&1; then
        echo -e "$(status_row 🚀 "Autostart:")${GREEN}ENABLED${RESET}"
    elif [ -f "/etc/systemd/system/$svc" ]; then
        echo -e "$(status_row 🚀 "Autostart:")${YELLOW}service exists, disabled${RESET}"
    else
        echo -e "$(status_row 🚀 "Autostart:")${RED}DISABLED${RESET}"
    fi
}

# Header row: which commit the installed Control scripts came from, and whether
# the repo has newer ones. The fetch runs detached in the background with its
# result cached in a file - the menu repaints far too often (and on a 60s read
# timeout) to touch the network from the render path.
CONTROL_UPDATE_CACHE="${CONTROL_UPDATE_CACHE:-${SCRIPT_DIR:-.}/.update-check}"
CONTROL_UPDATE_MAX_AGE="${CONTROL_UPDATE_MAX_AGE:-21600}"   # 6h

# Written by update_control_scripts / the installer. Falls back to the source
# checkout's HEAD, which is the same thing unless someone pulled there by hand.
control_installed_commit() {
    local f="${SCRIPT_DIR:-.}/.control-commit"
    if [ -s "$f" ]; then head -1 "$f"; else
        gitq "${CONTROL_SOURCE_DIR:-/nonexistent}" rev-parse --short HEAD 2>/dev/null
    fi
}

# Cache holds the number of commits between the installed one and origin; the
# job's output goes to <cache>.log, so a header stuck on "unknown" can be
# explained without re-running the fetch by hand.
# Stale (or missing) cache: bump its mtime first so a hanging or failing fetch
# cannot respawn on every repaint, then let the background job fill it in.
control_update_refresh() {
    local src="${CONTROL_SOURCE_DIR:-}" age=0 inst
    # rev-parse, not [ -d "$src/.git" ]: CONTROL_SOURCE_DIR is the repo's
    # Control/ subdirectory, so .git lives further up.
    [ -n "$src" ] || return 0
    gitq "$src" rev-parse --git-dir >/dev/null 2>&1 || return 0
    if [ -f "$CONTROL_UPDATE_CACHE" ]; then
        age=$(( $(date +%s) - $(stat -c %Y "$CONTROL_UPDATE_CACHE" 2>/dev/null || echo 0) ))
        [ "$age" -lt "$CONTROL_UPDATE_MAX_AGE" ] && return 0
    fi
    touch "$CONTROL_UPDATE_CACHE" 2>/dev/null || return 0
    inst="$(control_installed_commit)"
    (
        # No stdin and no credential prompt: a background git that asks for a
        # password over the terminal gets stopped by SIGTTIN and the header
        # would sit on "checking..." forever. timeout caps a stalled network.
        # Always write something, so a failed check reads as "unknown" instead.
        exec </dev/null
        export GIT_TERMINAL_PROMPT=0
        g() { timeout 60 git -C "$src" -c safe.directory='*' "$@"; }
        b="$(g rev-parse --abbrev-ref HEAD 2>/dev/null)"
        n=""
        if [ -n "$b" ] && [ "$b" != HEAD ] && g fetch --quiet --prune origin "$b"; then
            n="$(g rev-list --count "${inst:-HEAD}..origin/$b" 2>/dev/null)"
        fi
        printf '%s\n' "${n:-x}" > "$CONTROL_UPDATE_CACHE"
    ) >"$CONTROL_UPDATE_CACHE.log" 2>&1 &
    disown 2>/dev/null || true
}

control_version_dot() {
    control_update_refresh
    local inst n state
    inst="$(control_installed_commit)"
    read -r n < "$CONTROL_UPDATE_CACHE" 2>/dev/null || n=""
    case "$n" in
        '')          state="${DIM}checking...${RESET}" ;;
        0)           state="${GREEN}up to date${RESET}" ;;
        *[!0-9]*)    state="${DIM}unknown${RESET}" ;;
        1)           state="${YELLOW}update available (1 commit)${RESET}" ;;
        *)           state="${YELLOW}update available ($n commits)${RESET}" ;;
    esac
    echo -e "$(status_row 🧬 "Control:")${CYAN}${inst:-unknown}${RESET}  ${state}"
}

# --- privilege, git-as-owner, tmux, server process control ----------------

# The AzerothCore source/build trees and the tmux session belong to SERVER_USER.
# Run as root and git refuses the checkout ("dubious ownership") and tmux shows
# the server as OFFLINE. Re-exec the menu as the owner once, up front.
reexec_as_owner() {
    if [ "$(id -u)" -eq 0 ] && [ -n "${SERVER_USER:-}" ] && [ "$SERVER_USER" != root ]; then
        exec sudo -u "$SERVER_USER" -- "$@"
    fi
    # Non-root and not the owner: no re-exec happens, so tmux sessions, git and
    # the server logs land under the wrong account with no obvious error. Warn
    # loudly but keep going (some setups drive this as a third dedicated user).
    if [ "$(id -u)" -ne 0 ] && [ -n "${SERVER_USER:-}" ] && [ "$(id -un)" != "$SERVER_USER" ]; then
        echo -e "${YELLOW}⚠️  Running as $(id -un), not root and not $SERVER_USER.${RESET}" >&2
        echo -e "${YELLOW}   Start this menu with 'sudo ${0##*/}' or as $SERVER_USER, or tmux/logs${RESET}" >&2
        echo -e "${YELLOW}   end up owned by the wrong user.${RESET}" >&2
        sleep 2
    fi
}

# Run a single command as the owner (used for the rare root-invoked path).
run_as_owner() {
    if [ "$(id -u)" -eq 0 ] && [ -n "${SERVER_USER:-}" ] && [ "$SERVER_USER" != root ]; then
        sudo -u "$SERVER_USER" -- "$@"
    else
        "$@"
    fi
}

git_owner() { run_as_owner git -C "$ACORE_DIR" "$@"; }

# git in <dir> as the owner, tolerating a checkout owned by someone else.
gitq() { run_as_owner git -C "$1" -c safe.directory='*' "${@:2}"; }

# Graceful server stop, then reboot the whole LXC. The reboot is detached with
# setsid: `systemctl reboot` tears down sshd while this shell is still attached,
# so a foreground call makes the menu look like it crashed instead of printing
# the message below.
reboot_lxc() {   # reboot_lxc <process> <session> [shutdown-command]
    echo "This stops ${1} and reboots the entire LXC."
    read -rp "Type REBOOT to confirm: " c
    [ "$c" = REBOOT ] || { echo "Cancelled."; return 0; }
    server_stop "$1" "$2" "${3:-}" 180 || echo "(stop did not finish cleanly - rebooting anyway)"
    echo "Rebooting in 3 seconds..."
    setsid bash -c 'sleep 3; sudo systemctl reboot' >/dev/null 2>&1 </dev/null &
    disown 2>/dev/null || true
}

# Per-role tmux server. Without -L both roles share one socket (per user), so a
# second role's `new-session` lands in the first role's systemd cgroup and
# stopping one unit kills both. CONTROL_TMUX_L comes from control.conf.
tmx() { tmux -L "${CONTROL_TMUX_L:-default}" "$@"; }

server_start() {
    local process="$1" engine="$2" binary="$3" conf="$4" session="$5"
    local name="${process^}"

    echo -e "${CYAN}🚀  Starting ${process} via run-engine...${RESET}"

    if pgrep -x "$process" >/dev/null 2>&1 || tmx has-session -t "$session" 2>/dev/null; then
        echo -e "${YELLOW}⚠️  ${name} is already running: ${session}${RESET}"
        return 0
    fi

    require_path "$engine" || return 1
    require_path "$binary" || return 1
    require_path "$conf" || return 1

    tmx new-session -d -s "$session" \
        "cd '$ACORE_DIR' && '$engine' start '$binary' --server-config '$conf' --session-manager none"
    echo -e "${GREEN}✅  ${name} started.${RESET}"
}

# Server log for drain detection. AzerothCore writes it into the working dir the
# process was started from ($ACORE_DIR), older layouts into the bin dir.
server_log() {   # server_log <process>
    local name d
    case "$1" in authserver) name=Auth.log ;; worldserver) name=Server.log ;; *) return 1 ;; esac
    for d in "$ACORE_DIR" "$ACORE_DIR/env/dist/bin" "$ACORE_DIR/env/dist/logs"; do
        [ -f "$d/$name" ] && { printf '%s\n' "$d/$name"; return 0; }
    done
    return 1
}

# utime+stime in clock ticks - the log alone can't tell a hung process from one
# that is quietly draining its database queue.
proc_cpu_ticks() {   # proc_cpu_ticks <process>
    local pid; pid="$(pgrep -x "$1" | head -n1)"
    [ -n "$pid" ] || { echo 0; return 0; }
    awk '{print $14 + $15}' "/proc/$pid/stat" 2>/dev/null || echo 0
}

# Graceful stop that watches progress instead of counting seconds: it waits as
# long as the process burns CPU or the log grows, becomes unbounded once the DB
# pool starts draining, and only asks (never auto-kills) after <stall_limit>
# seconds of no progress at all.
server_stop() {
    local process="$1" session="$2" shutdown_command="${3:-}" stall_limit="${4:-120}" send="${5:-1}"
    local waited=0 stalled=0 draining=0 log mark=0 last_cpu last_size cpu size
    local name="${process^}"

    echo -e "${CYAN}🛑  Stopping ${process}...${RESET}"

    if ! pgrep -x "$process" >/dev/null 2>&1; then
        if tmx has-session -t "$session" 2>/dev/null; then
            echo -e "${YELLOW}⚠️  tmux session exists, but no ${process} process is running.${RESET}"
            echo -e "${CYAN}🧹  Closing empty tmux session...${RESET}"
            tmx kill-session -t "$session" 2>/dev/null || true
        else
            echo -e "${YELLOW}⚠️  No running ${process} process found.${RESET}"
        fi
        return 0
    fi

    log="$(server_log "$process" 2>/dev/null || true)"
    if [ -n "$log" ]; then mark="$(wc -l < "$log" 2>/dev/null || echo 0)"; fi

    # send=0: the caller already issued its own shutdown (the restart runner
    # sends an announce + timed `server shutdown`); just wait it out and verify.
    if [ "$send" = 1 ]; then
        if [ -n "$shutdown_command" ] && tmx has-session -t "$session" 2>/dev/null; then
            echo -e "${CYAN}💾  Saving world...${RESET}"
            tmx send-keys -t "$session" "saveall" Enter
            echo -e "${CYAN}🛑  Sending shutdown (${shutdown_command#server shutdown }s notice)...${RESET}"
            tmx send-keys -t "$session" "$shutdown_command" Enter
        else
            echo -e "${CYAN}📨  Sending TERM to ${process} process...${RESET}"
            pkill -TERM -x "$process" 2>/dev/null || true
        fi
    fi

    last_cpu="$(proc_cpu_ticks "$process")"; last_size="$mark"
    echo -e "${CYAN}⏳  Waiting for ${process} to stop...${RESET}"

    while pgrep -x "$process" >/dev/null 2>&1; do
        sleep 1; waited=$((waited + 1))
        cpu="$(proc_cpu_ticks "$process")"
        size="$last_size"
        if [ -n "$log" ]; then size="$(wc -l < "$log" 2>/dev/null || echo "$last_size")"; fi

        if [ "$draining" -eq 0 ] && [ -n "$log" ] \
           && tail -n +"$((mark + 1))" "$log" 2>/dev/null | grep -q "Closing down DatabasePool"; then
            draining=1
            echo -e "${CYAN}💾  Writing pending database queries - will not interrupt this.${RESET}"
        fi

        if [ "$cpu" != "$last_cpu" ] || [ "$size" != "$last_size" ]; then
            last_cpu="$cpu"; last_size="$size"; stalled=0
        elif [ "$draining" -eq 0 ]; then
            stalled=$((stalled + 1))
            if [ "$stalled" -ge "$stall_limit" ]; then
                echo -e "${YELLOW}⚠️  No activity for ${stall_limit}s and the process is still running.${RESET}"
                return 1
            fi
        fi
        if [ $((waited % 30)) -eq 0 ]; then echo "    ...still shutting down (${waited}s)"; fi
    done

    if tmx has-session -t "$session" 2>/dev/null; then
        echo -e "${CYAN}🧹  Closing tmux session: ${session}${RESET}"
        tmx kill-session -t "$session" 2>/dev/null || true
    fi
    if [ -n "$log" ] && ! tail -n +"$((mark + 1))" "$log" 2>/dev/null | grep -q "All connections on DatabasePool .* closed"; then
        echo -e "${YELLOW}⚠️  ${name} stopped, but the log does not show the database pools closing.${RESET}"
        echo -e "${YELLOW}    Check $log before trusting the last save.${RESET}"
    else
        echo -e "${GREEN}✅  ${name} stopped, database queue drained.${RESET}"
    fi
}

# Wait (bounded) for the server's listen port to be free again instead of a flat
# sleep - a restart that races the old process fails to bind.
wait_for_port_release() {   # wait_for_port_release <conf>
    local conf="$1" port i
    port="$(grep -hE '^[[:space:]]*(RealmServerPort|WorldServerPort)[[:space:]]*=' "$conf" 2>/dev/null \
            | head -1 | sed 's/.*=[[:space:]]*//; s/[[:space:]"]//g; s/#.*//')"
    [[ "$port" =~ ^[0-9]+$ ]] || { sleep 2; return 0; }
    for i in $(seq 1 20); do
        if ! (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
            if [ "$i" -gt 1 ]; then echo -e "${CYAN}⏳  Port $port released.${RESET}"; fi
            return 0
        fi
        exec 3>&- 2>/dev/null || true
        sleep 1
    done
    echo -e "${YELLOW}⚠️  Port $port is still in use after 20s - starting anyway.${RESET}"
}

server_restart() {
    local process="$1" engine="$2" binary="$3" conf="$4" session="$5" shutdown_command="${6:-}"
    local name="${process^}"
    echo -e "${CYAN}🔄  Restarting ${process}...${RESET}"
    server_stop "$process" "$session" "$shutdown_command" "${7:-120}" || return 1
    wait_for_port_release "$conf"
    server_start "$process" "$engine" "$binary" "$conf" "$session"
    echo -e "${GREEN}✅  ${name} restart completed.${RESET}"
}

server_kill() {
    local process="$1" session="$2"
    local name="${process^}"
    echo -e "${YELLOW}🧨  EMERGENCY STOP: Force-stopping ${process}...${RESET}"
    pkill -TERM -x "$process" 2>/dev/null
    for _ in $(seq 1 5); do pgrep -x "$process" >/dev/null 2>&1 || break; sleep 1; done
    if pgrep -x "$process" >/dev/null 2>&1; then
        echo -e "${RED}🧨  ${name} is still stuck. Sending KILL...${RESET}"
        pkill -KILL -x "$process" 2>/dev/null
        sleep 1
    fi
    if tmx has-session -t "$session" 2>/dev/null; then
        echo -e "${CYAN}🧹  Killing tmux session: ${session}${RESET}"
        tmx kill-session -t "$session" 2>/dev/null || true
    fi
    pgrep -x "$process" >/dev/null 2>&1 && { echo -e "${RED}⚠️  ${name} still alive - check manually.${RESET}"; return 1; }
    echo -e "${GREEN}✅  Emergency stop completed.${RESET}"
}

server_reload() {
    local process="$1" session="$2"
    local name="${process^}"
    echo -e "${CYAN}♻️  Sending AzerothCore config reload...${RESET}"
    if ! pgrep -x "$process" >/dev/null 2>&1 || ! tmx has-session -t "$session" 2>/dev/null; then
        echo -e "${YELLOW}⚠️  ${name} is not running with an active tmux session.${RESET}"
        return 1
    fi
    tmx send-keys -t "$session" "reload config" Enter
    echo -e "${GREEN}✅  reload config was sent.${RESET}"
    echo -e "${DIM}💡  Note: some changes still require a real restart.${RESET}"
}

server_status() {
    local process="$1" session="$2"
    if pgrep -x "$process" >/dev/null 2>&1; then
        echo -e "Status: ${GREEN}${BOLD}ONLINE${RESET}"
        ps -C "$process" -o pid=,etime=,%cpu=,%mem=,cmd=
    else
        echo -e "Status: ${RED}${BOLD}OFFLINE${RESET}"
    fi
    if tmx has-session -t "$session" 2>/dev/null; then
        echo -e "tmux: ${GREEN}ACTIVE${RESET} ($session)"
    else
        echo -e "tmux: ${DIM}INACTIVE${RESET} ($session)"
    fi
}

# Rarely-used build / DB / config helpers.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common-ops.sh"
