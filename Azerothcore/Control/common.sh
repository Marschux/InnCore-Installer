#!/usr/bin/env bash

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

# The AzerothCore source/build trees and the tmux session belong to SERVER_USER.
# Run as root and git refuses the checkout ("dubious ownership") and tmux shows
# the server as OFFLINE. Re-exec the menu as the owner once, up front.
reexec_as_owner() {
    if [ "$(id -u)" -eq 0 ] && [ -n "${SERVER_USER:-}" ] && [ "$SERVER_USER" != root ]; then
        exec sudo -u "$SERVER_USER" -- "$@"
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

# Bring a checkout to the tip of its current branch. Fast-forward if possible;
# otherwise show what is in the way and offer a hard reset (git pull --ff-only
# just fails silently on local changes / diverged history).
git_update() {   # git_update <repo-dir>
    local dir="$1" branch
    [ -d "$dir/.git" ] || { echo "Not a git checkout: $dir"; return 1; }
    branch="$(gitq "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    [ -n "$branch" ] && [ "$branch" != HEAD ] || { echo "Could not determine branch in $dir"; return 1; }
    # A half-finished merge or rebase from a previous aborted run blocks every
    # git operation below with an unhelpful error.
    gitq "$dir" merge --abort >/dev/null 2>&1 || true
    gitq "$dir" rebase --abort >/dev/null 2>&1 || true
    echo "Fetching origin ($branch) for $dir ..."
    gitq "$dir" fetch --prune origin || { echo "fetch failed."; return 1; }
    local dirty=0
    gitq "$dir" diff --quiet && gitq "$dir" diff --cached --quiet || dirty=1
    if [ "$dirty" -eq 0 ] && gitq "$dir" merge --ff-only "origin/$branch" >/dev/null 2>&1; then
        echo "Updated to origin/$branch (fast-forward)."
        return 0
    fi
    echo ""
    echo "Cannot update cleanly (uncommitted changes and/or diverged history):"
    gitq "$dir" status --short
    echo ""
    read -rp "Discard ALL local changes and hard-reset to origin/$branch? [y/N]: " a
    case "$a" in
        y|Y|j|J)
            gitq "$dir" reset --hard "origin/$branch" && gitq "$dir" clean -fd \
                && echo "Reset to origin/$branch." ;;
        *) echo "Left $dir unchanged." ;;
    esac
}

# Links RBAC permission 195 to every "Two side ..." permission in the auth DB.
# The AllowTwoSide.Interaction.* flags in worldserver.conf alone do NOT enable
# cross-faction group/guild/chat - the DB permission has to be linked too.
apply_two_side_rbac() {
    mysql_auth -N -s -e "SHOW TABLES LIKE 'rbac_permissions';" 2>/dev/null | grep -q rbac_permissions \
        || { echo "rbac_permissions not found - start the authserver once so it creates the schema."; return 1; }
    mysql_auth -e "INSERT IGNORE INTO rbac_linked_permissions (id, linkedId)
                   SELECT 195, id FROM rbac_permissions WHERE name LIKE 'Two side %';" || return 1
    local n
    n="$(mysql_auth -N -s -e "SELECT COUNT(*) FROM rbac_linked_permissions WHERE id=195;")"
    echo "Cross-faction RBAC applied: permission 195 links ${n} two-side permission(s)."
    echo "Restart the worldserver (or '.reload rbac' in its console) to load it."
}

# Enable/disable a boot autostart oneshot that drives one role's menu wrapper.
# Shared by auth and world - only the unit name, description and wrapper differ.
autostart_toggle() {   # autostart_toggle <service> <description> <menu-wrapper> [after-units]
    local svc="$1" desc="$2" wrapper="$3" after="${4:-network-online.target mysql.service}" c
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        echo -e "Current: ${GREEN}autostart ENABLED${RESET}"
    elif [ -f "/etc/systemd/system/$svc" ]; then
        echo -e "Current: ${YELLOW}unit present but disabled${RESET}"
    else
        echo -e "Current: ${RED}autostart DISABLED${RESET}"
    fi
    echo "  1) Enable autostart on boot        2) Disable autostart"
    read -rp "Choice [1-2]: " c
    case "$c" in
        1)
            sudo -n systemctl --version >/dev/null 2>&1 \
                || { echo "Passwordless sudo for systemctl is not set up - re-run the installer."; return 1; }
            sudo tee "/etc/systemd/system/$svc" >/dev/null <<EOF
[Unit]
Description=$desc
Wants=network-online.target
After=$after

[Service]
Type=oneshot
User=$SERVER_USER
Group=$SERVER_USER
WorkingDirectory=$ACORE_DIR
RemainAfterExit=yes
KillMode=none
ExecStartPre=/bin/sleep 5
ExecStart=$wrapper start
ExecStop=$wrapper stop
TimeoutStartSec=120
TimeoutStopSec=180

[Install]
WantedBy=multi-user.target
EOF
            sudo systemctl daemon-reload
            sudo systemctl enable "$svc" >/dev/null 2>&1 \
                && echo "Autostart enabled (the running server was not touched)."
            ;;
        2)
            sudo systemctl disable "$svc" 2>/dev/null || true
            sudo rm -f "/etc/systemd/system/$svc"
            sudo systemctl daemon-reload
            sudo systemctl reset-failed "$svc" 2>/dev/null || true
            echo "Autostart disabled."
            ;;
        *) echo "Nothing changed." ;;
    esac
}

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

# SRP6 salt + verifier for an AzerothCore account, printed as "SALT VERIFIER"
# (uppercase hex). Lets the menu create/repair accounts straight in the auth DB
# without a running worldserver console.
srp6_hex() {   # srp6_hex <user> <pass>
    command -v python3 >/dev/null 2>&1 || { echo "python3 is required for account passwords." >&2; return 1; }
    python3 - "$1" "$2" <<'PY'
import os, hashlib, sys
u, p = sys.argv[1].upper(), sys.argv[2].upper()
N = int("894B645E89E1535BBDAD5B8B290650530801B18EBFBF5E8FAB3C82872A3E9BB7", 16)
salt = os.urandom(32)
h2 = hashlib.sha1(salt + hashlib.sha1(f"{u}:{p}".encode()).digest()).digest()
v = pow(7, int.from_bytes(h2, "little"), N)
print(salt.hex().upper(), v.to_bytes(32, "little").hex().upper())
PY
}

# Refresh the installed Control scripts from the repo checkout (CONTROL_SOURCE_DIR).
# Pulls first when the checkout is a git repo. Fails loudly with the fix when the
# checkout is not readable by the server user (e.g. cloned into a 700 home).
update_control_scripts() {   # update_control_scripts <menu-basename>
    local src="$CONTROL_SOURCE_DIR" f
    if [ ! -r "$src/common.sh" ]; then
        echo "Cannot read the repo checkout at:"
        echo "  $src"
        echo "Re-clone it somewhere $USER can read (e.g. under /opt, then"
        echo "'sudo chmod -R a+rX <dir>') and set CONTROL_SOURCE_DIR in"
        echo "  $SCRIPT_DIR/control.conf"
        return 1
    fi
    if gitq "$src" rev-parse --git-dir >/dev/null 2>&1; then
        local branch remote
        branch="$(gitq "$src" rev-parse --abbrev-ref HEAD 2>/dev/null)"
        remote="$(gitq "$src" remote get-url origin 2>/dev/null)"
        echo "Fetching $branch from ${remote:-origin} ..."
        # This checkout is only a distribution point - force it to match the
        # remote so line-ending churn or a stray edit can't block the update.
        if gitq "$src" fetch --prune origin "$branch"; then
            gitq "$src" reset --hard "origin/$branch" \
                && gitq "$src" clean -fd \
                || echo "!! reset failed - installing the files as they are on disk."
        else
            echo "!! git fetch failed - installing the files as they are on disk."
        fi
    else
        echo "!! $src is not a git checkout - installing whatever files are there."
    fi
    # $SCRIPT_DIR is owned by the server user (this menu runs as them), no sudo.
    local files=(common.sh clean-build.sh "$1")
    if [ "$1" = world-menu.sh ]; then files+=(world-restart-runner.sh); fi
    for f in "${files[@]}"; do
        [ -f "$src/$f" ] && install -m 0755 "$src/$f" "$SCRIPT_DIR/$f"
    done
    echo "Control scripts updated from $src"
    # Called from inside the menu: the running process still holds the old code,
    # so offer to re-exec. Called as `authmenu update` from a shell: just return.
    [ "${MENU_RUNNING:-0}" = 1 ] || return 0
    echo ""
    read -rp "Restart the menu now to load the new version? [Y/n]: " a
    case "$a" in n|N|no|NO) return 0 ;; *) exec "$SCRIPT_DIR/$1" ;; esac
}

# --- Daily restart schedule (worldserver) -----------------------------------
# restart_times.conf : one "HH:MM;LEAD_MINUTES" per line (LEAD = in-game warning)
# restart_skip.conf  : "YYYY-MM-DD" (whole day) or "YYYY-MM-DD;HH:MM" (one slot)
RESTART_TIMES_CONF="${RESTART_TIMES_CONF:-${SCRIPT_DIR:-.}/restart_times.conf}"
RESTART_SKIP_CONF="${RESTART_SKIP_CONF:-${SCRIPT_DIR:-.}/restart_skip.conf}"

restart_is_skipped() {   # restart_is_skipped <YYYY-MM-DD> <HH:MM>
    local d="$1" t="$2" ed et
    [ -s "$RESTART_SKIP_CONF" ] || return 1
    while IFS=';' read -r ed et || [ -n "$ed" ]; do
        ed="$(printf '%s' "$ed" | xargs)"; et="$(printf '%s' "$et" | xargs)"
        [ -n "$ed" ] || continue
        [ "${ed#\#}" = "$ed" ] || continue
        [ "$ed" = "$d" ] || continue
        [ -z "$et" ] && return 0
        [ "$et" = "$t" ] && return 0
    done < "$RESTART_SKIP_CONF"
    return 1
}

# Echoes "EPOCH;HH:MM;LEAD" of the soonest non-skipped restart, or nothing.
restart_next() {
    [ -s "$RESTART_TIMES_CONF" ] || return 1
    local now next=0 nt="" nl="" t l day dd ce
    now="$(date +%s)"
    while IFS=';' read -r t l || [ -n "$t" ]; do
        t="$(printf '%s' "$t" | xargs)"; l="$(printf '%s' "$l" | xargs)"
        [[ "$t" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || continue
        [[ "$l" =~ ^[0-9]+$ ]] || continue
        for day in $(seq 0 60); do
            dd="$(date -d "+$day days" +%Y-%m-%d)"
            ce="$(date -d "$dd $t" +%s 2>/dev/null)" || continue
            [ "$ce" -le "$now" ] && continue
            restart_is_skipped "$dd" "$t" && continue
            if [ "$next" -eq 0 ] || [ "$ce" -lt "$next" ]; then next="$ce"; nt="$t"; nl="$l"; fi
            break
        done
    done < "$RESTART_TIMES_CONF"
    [ "$next" -eq 0 ] && return 1
    printf '%s;%s;%s\n' "$next" "$nt" "$nl"
}

current_branch() {
    local b
    b="$(git_owner rev-parse --abbrev-ref HEAD 2>/dev/null)"
    { [ -n "$b" ] && [ "$b" != HEAD ] && echo "$b"; } || echo unknown
}

# Per-role tmux server. Without -L both roles share one socket (per user), so a
# second role's `new-session` lands in the first role's systemd cgroup and
# stopping one unit kills both. CONTROL_TMUX_L comes from control.conf.
tmx() { tmux -L "${CONTROL_TMUX_L:-default}" "$@"; }

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
    c=$((c - 4))
    [ "$c" -gt 94 ] && c=94
    [ "$c" -lt 60 ] && c=60
    echo "$c"
}

box_title() {   # box_title <title> [color]
    local t="$1" c="${2:-$CYAN}" w pad rule tw
    w="$(menu_width)"
    rule="$(printf '═%.0s' $(seq 1 "$w"))"
    # Display width: submenu titles start with one emoji that counts as a single
    # code point but renders two columns wide - add 1 so the box stays aligned.
    tw=${#t}
    case "$t" in [!$'\x20'-$'\x7e']*) tw=$((tw + 1)) ;; esac
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

require_path() {
    [ -e "$1" ] || { echo "Path not found: $1"; return 1; }
}

server_start() {
    local process="$1" engine="$2" binary="$3" conf="$4" session="$5"

    require_path "$engine" || return 1
    require_path "$binary" || return 1
    require_path "$conf" || return 1

    if pgrep -x "$process" >/dev/null 2>&1 || tmx has-session -t "$session" 2>/dev/null; then
        echo "$process is already running or already owns the session $session."
        return 0
    fi

    tmx new-session -d -s "$session" \
        "cd '$ACORE_DIR' && '$engine' start '$binary' --server-config '$conf' --session-manager none"
    echo "$process started: $session"
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

    if ! pgrep -x "$process" >/dev/null 2>&1; then
        tmx kill-session -t "$session" 2>/dev/null || true
        echo "$process is not running."
        return 0
    fi

    log="$(server_log "$process" 2>/dev/null || true)"
    if [ -n "$log" ]; then mark="$(wc -l < "$log" 2>/dev/null || echo 0)"; fi

    # send=0: the caller already issued its own shutdown (the restart runner
    # sends an announce + timed `server shutdown`); just wait it out and verify.
    if [ "$send" = 1 ]; then
        if [ -n "$shutdown_command" ] && tmx has-session -t "$session" 2>/dev/null; then
            tmx send-keys -t "$session" "saveall" Enter
            tmx send-keys -t "$session" "$shutdown_command" Enter
        else
            pkill -TERM -x "$process" 2>/dev/null || true
        fi
    fi

    last_cpu="$(proc_cpu_ticks "$process")"; last_size="$mark"
    echo "Waiting for $process to stop..."

    while pgrep -x "$process" >/dev/null 2>&1; do
        sleep 1; waited=$((waited + 1))
        cpu="$(proc_cpu_ticks "$process")"
        size="$last_size"
        if [ -n "$log" ]; then size="$(wc -l < "$log" 2>/dev/null || echo "$last_size")"; fi

        if [ "$draining" -eq 0 ] && [ -n "$log" ] \
           && tail -n +"$((mark + 1))" "$log" 2>/dev/null | grep -q "Closing down DatabasePool"; then
            draining=1
            echo "Draining the database queue - this will not be interrupted."
        fi

        if [ "$cpu" != "$last_cpu" ] || [ "$size" != "$last_size" ]; then
            last_cpu="$cpu"; last_size="$size"; stalled=0
        elif [ "$draining" -eq 0 ]; then
            stalled=$((stalled + 1))
            if [ "$stalled" -ge "$stall_limit" ]; then
                echo "$process: no activity for ${stall_limit}s and still running; no automatic KILL."
                return 1
            fi
        fi
        if [ $((waited % 30)) -eq 0 ]; then echo "  ...still shutting down (${waited}s)"; fi
    done

    tmx kill-session -t "$session" 2>/dev/null || true
    if [ -n "$log" ] && ! tail -n +"$((mark + 1))" "$log" 2>/dev/null | grep -q "All connections on DatabasePool .* closed"; then
        echo "$process stopped - but the log does not confirm the DB pool closed. Check $log."
    else
        echo "$process stopped gracefully."
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
            if [ "$i" -gt 1 ]; then echo "Port $port released."; fi
            return 0
        fi
        exec 3>&- 2>/dev/null || true
        sleep 1
    done
    echo "Port $port still in use after 20s - starting anyway."
}

server_restart() {
    local process="$1" engine="$2" binary="$3" conf="$4" session="$5" shutdown_command="${6:-}"
    server_stop "$process" "$session" "$shutdown_command" "${7:-120}" || return 1
    wait_for_port_release "$conf"
    server_start "$process" "$engine" "$binary" "$conf" "$session"
}

server_kill() {
    local process="$1" session="$2"
    echo "Force-stopping $process..."
    pkill -TERM -x "$process" 2>/dev/null
    for _ in $(seq 1 5); do pgrep -x "$process" >/dev/null 2>&1 || break; sleep 1; done
    if pgrep -x "$process" >/dev/null 2>&1; then
        pkill -KILL -x "$process" 2>/dev/null
        sleep 1
    fi
    tmx kill-session -t "$session" 2>/dev/null || true
    pgrep -x "$process" >/dev/null 2>&1 && { echo "$process still alive - check manually."; return 1; }
    echo "$process force-stopped."
}

server_reload() {
    local process="$1" session="$2"
    if ! pgrep -x "$process" >/dev/null 2>&1 || ! tmx has-session -t "$session" 2>/dev/null; then
        echo "$process is not running with an active tmux session."
        return 1
    fi
    tmx send-keys -t "$session" "reload config" Enter
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

# Run a SELECT and print it as a table, or "(none)" when it returns no rows
# (mysql --table prints nothing at all on an empty result).
list_table() {
    local out
    out="$(mysql_auth --batch --table -e "$1" 2>&1)"
    [ -n "$out" ] && printf '%s\n' "$out" || echo "(none)"
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

# Records / reports the source commit that was last built, so the build menu can
# say whether a rebuild is due. Keyed per repo basename, stored next to the menu.
build_state_file() { echo "$SCRIPT_DIR/.built-commit.$(basename "$1")"; }

build_hint() {   # build_hint <repo-dir>
    local head built
    head="$(gitq "$1" rev-parse --short HEAD 2>/dev/null || true)"
    [ -n "$head" ] || return 0
    built=""
    if [ -f "$(build_state_file "$1")" ]; then
        built="$(cut -c1-7 < "$(build_state_file "$1")" 2>/dev/null || true)"
    fi
    if [ -z "$built" ]; then
        echo -e "  ${DIM}Source @ $head - no build recorded yet.${RESET}"
    elif [ "$head" = "$built" ]; then
        echo -e "  ${DIM}Source @ $head - matches last build.${RESET}"
    else
        echo -e "  ${YELLOW}Source @ $head - last build was $built, rebuild recommended.${RESET}"
    fi
}

safe_build() {   # safe_build <build-dir> [repo-dir]
    local dir="$1" repo="${2:-}"
    require_path "$dir" || return 1
    run_as_owner bash -c "cd '$dir' && make -j \"\$(nproc)\" && make install" || return 1
    if [ -n "$repo" ]; then gitq "$repo" rev-parse HEAD 2>/dev/null > "$(build_state_file "$repo")" || true; fi
    return 0
}

# Apply a flat "key = value" summary into a real .conf: every key that already
# exists in the target is replaced in place, unknown keys are reported and
# skipped. A timestamped backup of the target is written first.
apply_values() {
    local values="$1" target="$2" backup key value ek ev
    require_path "$values" || return 1
    require_path "$target" || return 1

    backup="${target}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$target" "$backup" || { echo "Backup failed."; return 1; }
    echo -e "${DIM}Backup: $backup${RESET}"
    echo ""

    while IFS='=' read -r key value || [ -n "$key" ]; do
        key="$(echo "$key" | xargs 2>/dev/null)"
        [[ -z "$key" || "$key" == \#* ]] && continue
        # Value is written verbatim: the summary file is the source of truth for
        # quoting. Only strip a trailing " # comment" (space-guarded so a '#'
        # inside a quoted value or password survives) and surrounding whitespace.
        value="$(printf '%s' "$value" | sed -E 's/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
        ek="$(printf '%s' "$key"   | sed 's/[][\\/.^$*+?{}|()]/\\&/g')"
        ev="$(printf '%s' "$value" | sed 's/[\\/&]/\\&/g')"
        if grep -qE "^${ek}[[:space:]]*=" "$target"; then
            sed -i -E "s@^${ek}[[:space:]]*=.*@${key} = ${ev}@" "$target"
            echo -e "  ${GREEN}✓${RESET} $key = $value"
        else
            echo -e "  ${YELLOW}– skipped (not in target):${RESET} $key"
        fi
    done < <(sed 's/\r$//' "$values")
    echo ""
    echo -e "${GREEN}$target updated.${RESET}"
}

# Pick and edit any .conf under the AzerothCore etc tree (worldserver.conf plus
# every module conf) - covers plugins added later that ship their own conf.
edit_any_conf() {
    local dir="$ACORE_DIR/env/dist/etc" files sel i=1 f
    mapfile -t files < <(find "$dir" -maxdepth 2 -name '*.conf' ! -name '*.conf.dist' 2>/dev/null | sort)
    [ "${#files[@]}" -gt 0 ] || { echo "No .conf files found under $dir"; return 1; }
    for f in "${files[@]}"; do printf '  %2d) %s\n' "$i" "${f#"$dir"/}"; i=$((i + 1)); done
    read -rp "Choice [1-${#files[@]}]: " sel
    [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#files[@]}" ] || { echo "Invalid choice."; return 1; }
    "${EDITOR:-nano}" "${files[$((sel - 1))]}"
}
