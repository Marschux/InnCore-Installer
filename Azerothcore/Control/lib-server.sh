#!/usr/bin/env bash
#
# Privilege handling, git-as-owner, per-role tmux and worldserver/authserver
# process control. Sourced via common.sh.

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
