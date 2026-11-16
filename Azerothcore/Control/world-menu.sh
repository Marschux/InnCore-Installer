#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# git and the tmux session belong to SERVER_USER; re-run as them if invoked as root.
reexec_as_owner "$0" "$@"

# Interactive loop: a single failing status probe must not kill the menu.
set +e

RESTART_RUNNER="$SCRIPT_DIR/world-restart-runner.sh"

update_control() { update_control_scripts world-menu.sh; }

start_world() {
    server_start worldserver "$WORLD_ENGINE" "$WORLD_BINARY" "$WORLD_CONF" "$WORLD_SESSION"
}
stop_world()    { server_stop worldserver "$WORLD_SESSION" "server shutdown 30" 180; }
kill_world() {
    echo -e "${RED}Force-kill discards every character save still queued.${RESET}"
    echo "Use [3] Stop unless the server is genuinely stuck (e.g. hangs on"
    echo "\"Waiting for N characters loading into database\" on a first start)."
    echo "After killing such a hang, lower Playerbots.MaxRandomBots before restarting."
    read -rp "Type KILL to confirm: " c
    if [ "$c" = KILL ]; then
        server_kill worldserver "$WORLD_SESSION"
    else
        echo "Cancelled."
    fi
}
restart_world() { server_restart worldserver "$WORLD_ENGINE" "$WORLD_BINARY" "$WORLD_CONF" "$WORLD_SESSION" "server shutdown 30" 180; }
reload_world()  { server_reload worldserver "$WORLD_SESSION"; }

save_world() {
    if tmx has-session -t "$WORLD_SESSION" 2>/dev/null; then
        tmx send-keys -t "$WORLD_SESSION" 'saveall' Enter
        echo "Save command sent to the Worldserver."
    else
        echo "No active Worldserver tmux session found."
    fi
}

pull_updates() {
    git_update "$ACORE_DIR"
    [ -d "$ACORE_DIR/modules/mod-playerbots/.git" ] && { echo ""; git_update "$ACORE_DIR/modules/mod-playerbots"; }
}

autostart_world() { autostart_toggle "$WORLD_SERVICE_NAME" "AzerothCore Worldserver" "$WORLD_MENU"; }

restart_sched_reload() {
    if systemctl is-active --quiet "$WORLD_TIMER_NAME" 2>/dev/null; then
        sudo systemctl restart "$WORLD_TIMER_NAME" && echo "Scheduler reloaded with the new schedule."
    fi
}

restart_sched_enable() {
    [ -s "$RESTART_TIMES_CONF" ] || { echo "Add at least one restart time first."; return 1; }
    [ -x "$RESTART_RUNNER" ] || chmod +x "$RESTART_RUNNER" 2>/dev/null
    sudo tee "/etc/systemd/system/$WORLD_TIMER_NAME" >/dev/null <<EOF
[Unit]
Description=AzerothCore worldserver daily restart scheduler
After=network-online.target

[Service]
Type=simple
User=$SERVER_USER
WorkingDirectory=$SCRIPT_DIR
ExecStart=$RESTART_RUNNER
Restart=always
RestartSec=60

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now "$WORLD_TIMER_NAME" && echo "Daily restart scheduler enabled."
}

restart_sched_disable() {
    sudo systemctl disable --now "$WORLD_TIMER_NAME" 2>/dev/null || true
    sudo systemctl daemon-reload
    echo "Daily restart scheduler disabled."
}

restart_timer() {
    local f="$RESTART_TIMES_CONF" s="$RESTART_SKIP_CONF" nd t l d
    touch "$f" "$s" 2>/dev/null
    while true; do
        clear
        box_title "DAILY RESTART SCHEDULE" "$COLOR_TOOLS"; echo ""
        if systemctl is-active --quiet "$WORLD_TIMER_NAME" 2>/dev/null; then
            echo -e "  Scheduler: ${GREEN}ACTIVE${RESET}"
        else
            echo -e "  Scheduler: ${RED}inactive${RESET}"
        fi
        echo ""
        echo "  Restart times:"
        if [ -s "$f" ]; then
            grep -vE '^\s*(#|$)' "$f" | while IFS=';' read -r t l; do printf "    %s   lead %s min\n" "$t" "$l"; done
        else echo "    (none)"; fi
        echo ""
        echo "  Skipped:"
        if grep -qvE '^\s*(#|$)' "$s" 2>/dev/null; then
            grep -vE '^\s*(#|$)' "$s" | while IFS=';' read -r d t; do
                [ -n "$t" ] && echo "    $d $t" || echo "    $d (whole day)"
            done
        else echo "    (none)"; fi
        if nd="$(restart_next)"; then
            IFS=';' read -r t l d <<< "$nd"
            echo -e "\n  Next: ${CYAN}$(date -d "@$t" '+%F %H:%M')${RESET} (lead $d min)"
        fi
        echo ""; menu_footer
        echo -e "  ${COLOR_TOOLS}[1]${RESET} Add/replace a time        ${COLOR_TOOLS}[2]${RESET} Delete a time"
        echo -e "  ${COLOR_TOOLS}[3]${RESET} Skip a date               ${COLOR_TOOLS}[4]${RESET} Un-skip a date"
        echo -e "  ${COLOR_TOOLS}[5]${RESET} Enable        ${COLOR_TOOLS}[6]${RESET} Disable   ${COLOR_TOOLS}[0]${RESET} Back"
        read -rp "🔹  Choice: " c
        case "$c" in
            1) read -rp "Time HH:MM: " t; read -rp "Lead minutes (in-game warning) [15]: " l; l="${l:-15}"
               if [[ "$t" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] && [[ "$l" =~ ^[0-9]+$ ]] && [ "$l" -ge 1 ] && [ "$l" -le 1440 ]; then
                   grep -v "^${t};" "$f" > "$f.tmp" 2>/dev/null; mv "$f.tmp" "$f"
                   echo "${t};${l}" >> "$f"; sort -o "$f" "$f"
                   echo "Saved $t (lead $l min)."; restart_sched_reload
               else echo "Invalid time or lead."; fi
               sleep 1 ;;
            2) read -rp "Time HH:MM to delete: " t
               grep -v "^${t};" "$f" > "$f.tmp" 2>/dev/null; mv "$f.tmp" "$f"
               echo "Removed $t."; restart_sched_reload; sleep 1 ;;
            3) read -rp "Date YYYY-MM-DD: " d; read -rp "Time HH:MM (blank = whole day): " t
               if date -d "$d" >/dev/null 2>&1; then
                   [ -n "$t" ] && echo "${d};${t}" >> "$s" || echo "$d" >> "$s"
                   sort -u -o "$s" "$s"; echo "Skip added."; restart_sched_reload
               else echo "Invalid date."; fi
               sleep 1 ;;
            4) read -rp "Line to un-skip (YYYY-MM-DD or YYYY-MM-DD;HH:MM): " d
               grep -vxF "$d" "$s" > "$s.tmp" 2>/dev/null; mv "$s.tmp" "$s"
               echo "Removed."; restart_sched_reload; sleep 1 ;;
            5) restart_sched_enable; sleep 1 ;;
            6) restart_sched_disable; sleep 1 ;;
            0) return ;;
            *) echo "Invalid option."; sleep 1 ;;
        esac
    done
}

delete_account() {
    read_login_database || { echo "Could not read LoginDatabaseInfo."; return 1; }
    read -rp "Account ID to delete: " id
    [[ "$id" =~ ^[0-9]+$ ]] || { echo "Invalid account ID."; return 1; }
    read -rp "Type DELETE to confirm: " confirm
    [ "$confirm" = DELETE ] && mysql_auth -e "DELETE FROM account WHERE id=$id; DELETE FROM account_access WHERE id=$id;" && echo "Account deleted."
}

# Interactive MySQL shell into the character database (CharacterDatabaseInfo
# from worldserver.conf).
char_db_console() {
    read_db_info CharacterDatabaseInfo "$WORLD_CONF" \
        || { echo "Could not read CharacterDatabaseInfo from $WORLD_CONF."; return 1; }
    echo "Opening $DB_NAME @ $DB_HOST:$DB_PORT  (Ctrl-D to exit)"
    MYSQL_PWD="$DB_PASS" mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" "$DB_NAME"
}

config_menu() {
    while true; do
        submenu_title "📝  CONFIG & MAINTENANCE" "$COLOR_CONFIG"
        menu_section "$COLOR_CONFIG" "🌍  WORLDSERVER"
        echo -e "  ${DIM}values/values_world.conf  ->  ${WORLD_CONF}${RESET}"
        echo -e "  ${COLOR_CONFIG}[1]${RESET}  ✏️   Edit summary          ${COLOR_CONFIG}[2]${RESET}  ✅  Apply to worldserver.conf"

        menu_section "$COLOR_CONFIG" "🤖  PLAYERBOTS"
        echo -e "  ${DIM}values/values_playerbots.conf  ->  ${PLAYERBOTS_CONF}${RESET}"
        echo -e "  ${COLOR_CONFIG}[3]${RESET}  ✏️   Edit summary          ${COLOR_CONFIG}[4]${RESET}  ✅  Apply to playerbots.conf"

        menu_section "$COLOR_CONFIG" "📄  RAW FILES"
        echo -e "  ${COLOR_CONFIG}[5]${RESET}  🔧  Edit any .conf (worldserver + module plugins)"
        echo ""
        echo -e "  ${COLOR_CONFIG}[0]${RESET}  🚪  Back"
        echo ""; menu_footer
        read -rp "🔹  Choice [0-5]: " choice
        case "$choice" in
            1) "${EDITOR:-nano}" "$SCRIPT_DIR/values/values_world.conf" ;;
            2) run_step apply_values "$SCRIPT_DIR/values/values_world.conf" "$WORLD_CONF" ;;
            3) "${EDITOR:-nano}" "$SCRIPT_DIR/values/values_playerbots.conf" ;;
            4) run_step apply_values "$SCRIPT_DIR/values/values_playerbots.conf" "$PLAYERBOTS_CONF" ;;
            5) run_step edit_any_conf ;;
            0) return ;;
            *) echo "Invalid option."; sleep 1 ;;
        esac
    done
}

timer_dot() {
    local nd next=""
    if nd="$(restart_next)"; then printf -v next " ${DIM}(next %(%a %H:%M)T)${RESET}" "${nd%%;*}"; fi
    if systemctl is-active --quiet "$WORLD_TIMER_NAME" 2>/dev/null; then
        status_row ⏰ "Daily restart:" "${GREEN}ENABLED${RESET}${next}"
    else
        status_row ⏰ "Daily restart:" "${RED}DISABLED${RESET}"
    fi
}

render_menu() {
    box_title "AZEROTHCORE - WORLDSERVER CONTROL"
    status_dot worldserver "$WORLD_SESSION"
    autostart_dot "$WORLD_SERVICE_NAME"
    timer_dot
    status_row 📂 "Session:" "${CYAN}${WORLD_SESSION}${RESET}"
    acore_version_dot
    hr

    menu_section "$COLOR_SERVER" "⚙️  SERVER CONTROL"
    echo -e "  ${COLOR_SERVER}[1]${RESET}  🚀  Start server               ${COLOR_SERVER}[2]${RESET}  🔄  Restart server"
    echo -e "  ${COLOR_SERVER}[3]${RESET}  🛑  Stop server                ${COLOR_SERVER}[4]${RESET}  💥  ${RED}Kill server (force)${RESET}"
    echo -e "  ${COLOR_SERVER}[5]${RESET}  🧿  Reload config"

    menu_section "$COLOR_LOGS" "📄  LOGS & CONSOLE"
    echo -e "  ${COLOR_LOGS}[6]${RESET}  💾  Save world                 ${COLOR_LOGS}[7]${RESET}  🖥️  World console"

    menu_section "$COLOR_TOOLS" "🗄️  TOOLS"
    echo -e "  ${COLOR_TOOLS}[8]${RESET}  🚀  Autostart                  ${COLOR_TOOLS}[9]${RESET}  ⏰  Daily restart timer"
    echo -e "  ${COLOR_TOOLS}[10]${RESET} 🛠️  Build tools                ${COLOR_TOOLS}[11]${RESET} 👤  Delete account"
    echo -e "  ${COLOR_TOOLS}[12]${RESET} 🐬  Character DB console"

    menu_section "$COLOR_CONFIG" "📝  CONFIG & MAINTENANCE"
    echo -e "  ${COLOR_CONFIG}[13]${RESET} 📝  Config & maintenance       ${COLOR_CONFIG}[14]${RESET} ⬇️  Update Control scripts"

    menu_section "$COLOR_EXIT" "⏻  POWER & EXIT"
    echo -e "  ${COLOR_EXIT}[15]${RESET} 🔁  Reboot LXC                 ${COLOR_EXIT}[0]${RESET}  🚪  Exit menu"
    echo ""
    menu_footer
}

menu() {
    MENU_RUNNING=1
    clear
    while true; do
        draw_menu render_menu
        echo ""
        read -t 60 -rp "🔹  Select an option (0-15): " choice; rc=$?
        [ "$rc" -gt 128 ] && continue
        case "$choice" in
            1) run_step start_world ;;
            2) run_step restart_world ;;
            3) run_step stop_world ;;
            4) run_step kill_world ;;
            5) run_step reload_world ;;
            6) run_step save_world ;;
            7) clear; tmx attach -t "$WORLD_SESSION" 2>/dev/null || { echo "No active worldserver tmux session."; wait_for_user; } ;;
            8) run_step autostart_world ;;
            9) restart_timer ;;
            10) build_menu "Pull git updates (core + Playerbots)" world-only static pull_updates ;;
            11) run_step delete_account ;;
            12) clear; char_db_console; wait_for_user ;;
            13) config_menu ;;
            14) run_step update_control ;;
            15) run_step reboot_lxc worldserver "$WORLD_SESSION" "server shutdown 30" ;;
            0) clear; echo -e "${GREEN}👋  Worldserver menu closed.${RESET}"; exit 0 ;;
            *) echo "Invalid option."; sleep 1 ;;
        esac
    done
}

case "${1:-menu}" in
    start) wait_for_login_db; start_world ;;  # boot/scripted start: auth DB may lag
    stop) stop_world ;;
    restart) restart_world ;;
    status) server_status worldserver "$WORLD_SESSION" ;;
    update) update_control ;;
    menu) menu ;;
    *) echo "Usage: $0 [menu|start|stop|restart|status|update]"; exit 1 ;;
esac
