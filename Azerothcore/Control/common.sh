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

# Standard AzerothCore layout under ACORE_DIR. control.conf only carries what
# differs per box (ACORE_DIR, SERVER_USER, ...); set any of these there to override.
: "${AUTH_ENGINE:=$ACORE_DIR/apps/startup-scripts/src/run-engine}"
: "${AUTH_BINARY:=$ACORE_DIR/env/dist/bin/authserver}"
: "${AUTH_CONF:=$ACORE_DIR/env/dist/etc/authserver.conf}"
: "${AUTH_SESSION:=auth-session}"
: "${AUTH_SERVICE_NAME:=azerothcore-auth.service}"
: "${WORLD_ENGINE:=$ACORE_DIR/apps/startup-scripts/src/run-engine}"
: "${WORLD_BINARY:=$ACORE_DIR/env/dist/bin/worldserver}"
: "${WORLD_CONF:=$ACORE_DIR/env/dist/etc/worldserver.conf}"
: "${PLAYERBOTS_CONF:=$ACORE_DIR/env/dist/etc/modules/playerbots.conf}"
: "${WORLD_SESSION:=world-session}"
: "${WORLD_SERVICE_NAME:=azerothcore-world.service}"
WORLD_TIMER_NAME="azerothcore-world-restart.service"   # fixed: the sudoers grant names it

RESET='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BLUE='\033[1;34m'; WHITE='\033[1;37m'
GRAY='\033[1;30m'; PURPLE='\033[38;5;141m'; TEAL='\033[38;5;44m'; GOLD='\033[38;5;220m'
NC="$RESET"

COLOR_SERVER="$CYAN"
COLOR_LOGS="$GRAY"
COLOR_BUILD="$BLUE"
COLOR_CONFIG="$GOLD"
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

# Typed confirmation for destructive steps; anything else prints "Cancelled."
# and fails, so callers write: confirm_word DELETE || return 0
confirm_word() {   # confirm_word <WORD>
    local a
    read -rp "Type $1 to confirm: " a
    [ "$a" = "$1" ] && return 0
    echo -e "${YELLOW}👋 Cancelled.${RESET}"
    return 1
}

menu_section() {
    echo ""
    echo -e "${1}${BOLD}${2}${RESET}"
}

# Inner width for menu frames into <var>: fits the terminal (leaving a 2-col
# margin), clamped so it neither overflows an 80-col console nor sprawls on a
# wide one. draw_menu sets MENU_COLS once per repaint so the frame's several
# rules don't each spawn tput.
menu_width() {   # menu_width <var>
    local c="${MENU_COLS:-}"
    [ -n "$c" ] || c="$(tput cols 2>/dev/null || echo 80)"
    c=$((c - 2))
    [ "$c" -gt 79 ] && c=79
    [ "$c" -lt 58 ] && c=58
    printf -v "$1" '%s' "$c"
}

# <n> copies of <char> into <var>, without seq / subshells.
_rule() {   # _rule <var> <char> <n>
    local _r
    printf -v _r '%*s' "$3" ''
    printf -v "$1" '%s' "${_r// /$2}"
}

box_title() {   # box_title <title> [color]
    local t="$1" c="${2:-$CYAN}" w pad rule tw rest
    menu_width w
    _rule rule '═' "$w"
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

_full_rule() {   # _full_rule <color> <char>
    local w r
    menu_width w
    _rule r "$2" $((w + 2))
    printf "${1}%s${RESET}\n" "$r"
}
hr() { _full_rule "$DIM" '─'; }
menu_footer() { _full_rule "$CYAN" '═'; }

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
    local render_fn="$1" frame term_rows nl MENU_COLS
    MENU_COLS="$(tput cols 2>/dev/null || echo 80)"
    frame="$($render_fn)"
    term_rows="$(tput lines 2>/dev/null || echo 0)"
    nl="${frame//[!$'\n']/}"   # frame has ${#nl}+1 lines
    if [ "$term_rows" -gt 0 ] && [ $((${#nl} + 3)) -ge "$term_rows" ]; then
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
# realmlist.flag is a bitmask: decode every set bit (34 = offline + new).
# Bit 2 is the worldserver's own online/offline marker, not something the
# operator sets: it only shows when no other flag is set, so 34 reads "New".
# Into <var>, no subshell: these run once per realm row.
realm_flag_names() {   # realm_flag_names <var> <flag>
    local _f="$2" _out="" _p
    if ! [[ "$_f" =~ ^[0-9]+$ ]]; then printf -v "$1" '%s' "$_f"; return 0; fi
    for _p in 1:Invalid 4:Build 8:Medium 16:Medium 32:New 64:Recommended 128:Full; do
        if (( _f & ${_p%%:*} )); then _out+="+${_p#*:}"; fi
    done
    if (( _f & ~255 )); then _out+="+$(( _f & ~255 ))"; fi
    if [ -z "$_out" ]; then
        if (( _f & 2 )); then _out=Offline; else _out=Online; fi
    fi
    printf -v "$1" '%s' "${_out#+}"
}

# realmlist.icon -> realm type, into <var>.
realm_type_name() {   # realm_type_name <var> <icon>
    local _t
    case "$2" in 0|4) _t=Normal ;; 1) _t=PvP ;; 6) _t=RP ;; 8) _t="RP PvP" ;; *) _t=Unknown ;; esac
    printf -v "$1" '%s' "$_t"
}

status_row() { printf ' %s  %-15s' "$1" "$2"; echo -e "$3"; }   # status_row <icon> <label> <value>

status_dot() {   # status_dot <process-name> <session>
    local process="$1" session="$2" label
    label="${process^}:"
    if has_session "$session"; then
        if is_running "$process"; then
            status_row 🟢 "$label" "${GREEN}${BOLD}ONLINE${RESET}"
        else
            status_row 🟡 "$label" "${YELLOW}tmux active, process missing${RESET}"
        fi
    else
        if is_running "$process"; then
            status_row 🟠 "$label" "${YELLOW}process running, tmux missing${RESET}"
        else
            status_row 🔴 "$label" "${RED}${BOLD}OFFLINE${RESET}"
        fi
    fi
}

# Coloured autostart state of <service> into <var> (status row + autostart menu).
autostart_state() {   # autostart_state <var> <service-name>
    local _as   # _-prefixed: a local named like the caller's <var> would swallow printf -v
    if [ -z "$2" ]; then
        _as="${RED}service name missing${RESET}"
    elif systemctl is-enabled --quiet "$2" 2>/dev/null; then
        _as="${GREEN}ENABLED${RESET}"
    elif [ -f "/etc/systemd/system/$2" ]; then
        _as="${YELLOW}service exists, disabled${RESET}"
    else
        _as="${RED}DISABLED${RESET}"
    fi
    printf -v "$1" '%s' "$_as"
}
autostart_dot() { local s; autostart_state s "$1"; status_row 🚀 "Autostart:" "$s"; }   # autostart_dot <service-name>

# Header row: the AzerothCore checkout's branch and commit, plus whether origin
# carries newer ones. The fetch runs detached in the background with its result
# cached in a file: the menu repaints far too often (and on a 60s read timeout)
# to touch the network from the render path. The job's output goes to
# <cache>.log so a header stuck on "unknown" can be explained without re-running
# the fetch by hand.
ACORE_UPDATE_CACHE="${ACORE_UPDATE_CACHE:-${SCRIPT_DIR:-.}/.update-check}"
ACORE_UPDATE_MAX_AGE="${ACORE_UPDATE_MAX_AGE:-21600}"   # 6h

# Cache holds how many commits origin is ahead. Stale (or missing): bump its
# mtime first so a hanging or failing fetch cannot respawn on every repaint,
# then let the background job fill it in.
# Caller has already checked that ACORE_DIR is a git checkout.
acore_update_refresh() {
    local src="$ACORE_DIR" age=0
    if [ -f "$ACORE_UPDATE_CACHE" ]; then
        age=$(( EPOCHSECONDS - $(stat -c %Y "$ACORE_UPDATE_CACHE" 2>/dev/null || echo 0) ))
        [ "$age" -lt "$ACORE_UPDATE_MAX_AGE" ] && return 0
    fi
    touch "$ACORE_UPDATE_CACHE" 2>/dev/null || return 0
    (
        # No stdin and no credential prompt: a background git that asks for a
        # password over the terminal gets stopped by SIGTTIN and the header
        # would sit on "checking..." forever. timeout caps a stalled network.
        # Always write something, so a failed check reads as "unknown" instead.
        exec </dev/null
        export GIT_TERMINAL_PROMPT=0
        g() { timeout 120 git -C "$src" -c safe.directory='*' "$@"; }
        b="$(g rev-parse --abbrev-ref HEAD 2>/dev/null)"
        n=""
        if [ -n "$b" ] && [ "$b" != HEAD ] && g fetch --quiet origin "$b"; then
            n="$(g rev-list --count "HEAD..origin/$b" 2>/dev/null)"
        fi
        printf '%s\n' "${n:-x}" > "$ACORE_UPDATE_CACHE"
    ) >"$ACORE_UPDATE_CACHE.log" 2>&1 &
    disown 2>/dev/null || true
}

# Two header rows: the checkout's branch + commit, and the cached update state.
acore_version_dot() {
    local rev head="" branch="" n state
    # One git call for both: full sha, then the branch name ("HEAD" if detached).
    if rev="$(gitq "${ACORE_DIR:-}" rev-parse HEAD --abbrev-ref HEAD 2>/dev/null)"; then
        head="${rev:0:9}"; branch="${rev#*$'\n'}"
        acore_update_refresh
    fi
    [ -n "$branch" ] && [ "$branch" != HEAD ] || branch=unknown
    read -r n < "$ACORE_UPDATE_CACHE" 2>/dev/null || n=""
    case "$n" in
        '')       state="${DIM}checking...${RESET}" ;;
        0)        state="${GREEN}up to date${RESET}" ;;
        *[!0-9]*) state="${DIM}unknown - see ${ACORE_UPDATE_CACHE##*/}.log${RESET}" ;;
        1)        state="${YELLOW}1 commit behind origin${RESET}" ;;
        *)        state="${YELLOW}$n commits behind origin${RESET}" ;;
    esac
    status_row 🌿 "Branch:" "${CYAN}${branch}${RESET}  ${DIM}${head:-?}${RESET}"
    status_row 🔄 "Update:" "${state}"
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

# git in <dir>, tolerating a checkout owned by someone else. Everything here
# already runs as the owner (menus re-exec above, units set User=).
gitq() { git -C "$1" -c safe.directory='*' "${@:2}"; }

# Graceful server stop, then reboot the whole LXC. The reboot is detached with
# setsid: `systemctl reboot` tears down sshd while this shell is still attached,
# so a foreground call makes the menu look like it crashed instead of printing
# the message below.
reboot_lxc() {   # reboot_lxc <process> <session> [shutdown-command]
    echo "This stops ${1} and reboots the entire LXC."
    confirm_word REBOOT || return 0
    server_stop "$1" "$2" "${3:-}" 180 || echo "(stop did not finish cleanly - rebooting anyway)"
    echo "Rebooting in 3 seconds..."
    setsid bash -c 'sleep 3; sudo systemctl reboot' >/dev/null 2>&1 </dev/null &
    disown 2>/dev/null || true
}

# Per-role tmux server. Without -L both roles share one socket (per user), so a
# second role's `new-session` lands in the first role's systemd cgroup and
# stopping one unit kills both. CONTROL_TMUX_L comes from control.conf.
tmx() { tmux -L "${CONTROL_TMUX_L:-default}" "$@"; }
has_session() { tmx has-session -t "$1" 2>/dev/null; }   # has_session <session>
is_running() { pgrep -x "$1" >/dev/null 2>&1; }         # is_running <process>

# The tmux server belongs to the cgroup of whoever starts it. Started from an SSH
# login (menu) it sits in that session's scope, and on a box shutdown systemd
# SIGTERMs the scope right away: tmux and the server die before the unit's
# ExecStop can send saveall/shutdown, so queued saves are lost. Outside the unit,
# start through it instead (systemctl restart: ExecStop finds nothing to stop,
# ExecStart starts in the unit's cgroup). Without an installed unit, warn.
start_via_unit() {   # start_via_unit <process> <session>; 1 = start here yourself
    local unit="azerothcore-${1%server}.service"
    grep -q "/$unit\$" /proc/self/cgroup 2>/dev/null && return 1   # we are the unit
    if [ ! -f "/etc/systemd/system/$unit" ]; then
        echo -e "${YELLOW}⚠️  Autostart is off: a box shutdown will not stop ${1} cleanly.${RESET}"
        return 1
    fi
    echo -e "${CYAN}🚀  Starting ${1} through ${unit}, so a box shutdown stops it cleanly...${RESET}"
    if ! sudo -n systemctl restart "$unit"; then
        echo -e "${YELLOW}⚠️  systemctl restart ${unit} failed - starting directly.${RESET}"
        return 1
    fi
    console_follow "$2"
}

server_start() {
    local process="$1" engine="$2" binary="$3" conf="$4" session="$5"
    local name="${process^}"

    if is_running "$process" || has_session "$session"; then
        echo -e "${YELLOW}⚠️  ${name} is already running: ${session}${RESET}"
        return 0
    fi
    start_via_unit "$process" "$session" && return 0

    echo -e "${CYAN}🚀  Starting ${process} via run-engine...${RESET}"

    require_path "$engine" || return 1
    require_path "$binary" || return 1
    require_path "$conf" || return 1

    tmx new-session -d -s "$session" \
        "cd '$ACORE_DIR' && '$engine' start '$binary' --server-config '$conf' --session-manager none"
    echo -e "${GREEN}✅  ${name} started.${RESET}"
    console_follow "$session"
}

# Boot and shutdown both happen inside tmux (DB updates, map loading, bot
# generation, the shutdown countdown and the database drain) while the menu only
# prints "started"/"waiting". Attach so it can be watched live; detaching with
# Ctrl-B D (or the session ending on shutdown) continues the menu flow.
# Menu only and only on a real terminal, so the restart runner and any scripted
# call keep running unattended.
console_follow() {   # console_follow <session>
    local session="$1"
    [ "${MENU_RUNNING:-0}" = 1 ] || return 0
    [ -t 0 ] || return 0
    has_session "$session" || return 0
    echo -e "${DIM}Opening the console - Ctrl-B then D returns to the menu.${RESET}"
    sleep 2
    tmx attach -t "$session" 2>/dev/null || true
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

# utime+stime in clock ticks; the log alone can't tell a hung process from one
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

    if ! is_running "$process"; then
        if has_session "$session"; then
            echo -e "${YELLOW}⚠️  tmux session exists, but no ${process} process is running.${RESET}"
            echo -e "${CYAN}🧹  Closing empty tmux session...${RESET}"
            tmx kill-session -t "$session" 2>/dev/null || true
        else
            echo -e "${YELLOW}⚠️  No running ${process} process found.${RESET}"
        fi
        return 0
    fi

    # Byte offsets, not line counts: Server.log is never rotated and reaches
    # GBs, and wc -l / tail -n +N rescan the whole file every second of the wait.
    log="$(server_log "$process" 2>/dev/null || true)"
    if [ -n "$log" ]; then mark="$(stat -c %s "$log" 2>/dev/null || echo 0)"; fi

    # send=0: the caller already issued its own shutdown (the restart runner
    # sends an announce + timed `server shutdown`); just wait it out and verify.
    if [ "$send" = 1 ]; then
        if [ -n "$shutdown_command" ] && has_session "$session"; then
            echo -e "${CYAN}💾  Saving world...${RESET}"
            tmx send-keys -t "$session" "saveall" Enter
            echo -e "${CYAN}🛑  Sending shutdown (${shutdown_command#server shutdown }s notice)...${RESET}"
            tmx send-keys -t "$session" "$shutdown_command" Enter
            console_follow "$session"
        else
            echo -e "${CYAN}📨  Sending TERM to ${process} process...${RESET}"
            pkill -TERM -x "$process" 2>/dev/null || true
        fi
    fi

    last_cpu="$(proc_cpu_ticks "$process")"; last_size="$mark"
    echo -e "${CYAN}⏳  Waiting for ${process} to stop...${RESET}"

    while is_running "$process"; do
        sleep 1; waited=$((waited + 1))
        cpu="$(proc_cpu_ticks "$process")"
        size="$last_size"
        if [ -n "$log" ]; then size="$(stat -c %s "$log" 2>/dev/null || echo "$last_size")"; fi

        if [ "$draining" -eq 0 ] && [ -n "$log" ] \
           && tail -c +"$((mark + 1))" "$log" 2>/dev/null | grep -q "Closing down DatabasePool"; then
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

    if has_session "$session"; then
        echo -e "${CYAN}🧹  Closing tmux session: ${session}${RESET}"
        tmx kill-session -t "$session" 2>/dev/null || true
    fi
    if [ -n "$log" ] && ! tail -c +"$((mark + 1))" "$log" 2>/dev/null | grep -q "All connections on DatabasePool .* closed"; then
        echo -e "${YELLOW}⚠️  ${name} stopped, but the log does not show the database pools closing.${RESET}"
        echo -e "${YELLOW}    Check $log before trusting the last save.${RESET}"
    else
        echo -e "${GREEN}✅  ${name} stopped, database queue drained.${RESET}"
    fi
}

# Wait (bounded) for the server's listen port to be free again instead of a flat
# sleep: a restart that races the old process fails to bind.
wait_for_port_release() {   # wait_for_port_release <conf>
    local conf="$1" port i
    port="$(grep -hE '^[[:space:]]*(RealmServerPort|WorldServerPort)[[:space:]]*=' "$conf" 2>/dev/null \
            | head -1 | sed 's/.*=[[:space:]]*//; s/[[:space:]"]//g; s/#.*//')"
    [[ "$port" =~ ^[0-9]+$ ]] || { sleep 2; return 0; }
    for ((i = 1; i <= 20; i++)); do
        if ! (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
            if [ "$i" -gt 1 ]; then echo -e "${CYAN}⏳  Port $port released.${RESET}"; fi
            return 0
        fi
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
    for _ in 1 2 3 4 5; do is_running "$process" || break; sleep 1; done
    if is_running "$process"; then
        echo -e "${RED}🧨  ${name} is still stuck. Sending KILL...${RESET}"
        pkill -KILL -x "$process" 2>/dev/null
        sleep 1
    fi
    if has_session "$session"; then
        echo -e "${CYAN}🧹  Killing tmux session: ${session}${RESET}"
        tmx kill-session -t "$session" 2>/dev/null || true
    fi
    is_running "$process" && { echo -e "${RED}⚠️  ${name} still alive - check manually.${RESET}"; return 1; }
    echo -e "${GREEN}✅  Emergency stop completed.${RESET}"
}

server_reload() {
    local process="$1" session="$2"
    local name="${process^}"
    echo -e "${CYAN}♻️  Sending AzerothCore config reload...${RESET}"
    if ! is_running "$process" || ! has_session "$session"; then
        echo -e "${YELLOW}⚠️  ${name} is not running with an active tmux session.${RESET}"
        return 1
    fi
    tmx send-keys -t "$session" "reload config" Enter
    echo -e "${GREEN}✅  reload config was sent.${RESET}"
    echo -e "${DIM}💡  Note: some changes still require a real restart.${RESET}"
}

server_status() {
    local process="$1" session="$2"
    if is_running "$process"; then
        echo -e "Status: ${GREEN}${BOLD}ONLINE${RESET}"
        ps -C "$process" -o pid=,etime=,%cpu=,%mem=,cmd=
    else
        echo -e "Status: ${RED}${BOLD}OFFLINE${RESET}"
    fi
    if has_session "$session"; then
        echo -e "tmux: ${GREEN}ACTIVE${RESET} ($session)"
    else
        echo -e "tmux: ${DIM}INACTIVE${RESET} ($session)"
    fi
}

# Rarely-used build / DB / config helpers.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common-ops.sh"
