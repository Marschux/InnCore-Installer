#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# git and the tmux session belong to SERVER_USER - re-run as them if invoked as root.
reexec_as_owner "$0" "$@"

# Interactive loop: a single failing status probe must not kill the menu.
set +e

WORLD_ENGINE="${WORLD_ENGINE:-$ACORE_DIR/apps/startup-scripts/src/run-engine}"
WORLD_BINARY="${WORLD_BINARY:-$ACORE_DIR/env/dist/bin/worldserver}"
WORLD_CONF="${WORLD_CONF:-$ACORE_DIR/env/dist/etc/worldserver.conf}"
PLAYERBOTS_CONF="${PLAYERBOTS_CONF:-$ACORE_DIR/env/dist/etc/modules/playerbots.conf}"
WORLD_SESSION="${WORLD_SESSION:-world-session}"
WORLD_SERVICE_NAME="${WORLD_SERVICE_NAME:-azerothcore-world.service}"
WORLD_TIMER_NAME="${WORLD_TIMER_NAME:-azerothcore-world-restart.timer}"

update_control() {
    require_path "$CONTROL_SOURCE_DIR/common.sh" || return 1
    sudo install -m 0755 "$CONTROL_SOURCE_DIR/common.sh" "$SCRIPT_DIR/common.sh"
    sudo install -m 0755 "$CONTROL_SOURCE_DIR/world-menu.sh" "$SCRIPT_DIR/world-menu.sh"
    sudo install -m 0755 "$CONTROL_SOURCE_DIR/clean-build.sh" "$SCRIPT_DIR/clean-build.sh"
    sudo chown "$SERVER_USER:$SERVER_USER" "$SCRIPT_DIR"/*.sh
    echo "World Control scripts updated."
}

start_world()   { server_start worldserver "$WORLD_ENGINE" "$WORLD_BINARY" "$WORLD_CONF" "$WORLD_SESSION"; }
stop_world()    { server_stop worldserver "$WORLD_SESSION" "server shutdown 30" 180; }
kill_world() {
    echo -e "${RED}Force-kill discards every character save still queued.${RESET}"
    echo "Use [2] Stop unless the server is genuinely stuck (e.g. hangs on"
    echo "\"Waiting for N characters loading into database\" on a first start)."
    read -rp "Type KILL to confirm: " c
    [ "$c" = KILL ] && server_kill worldserver "$WORLD_SESSION" || echo "Cancelled."
}
restart_world() { server_restart worldserver "$WORLD_ENGINE" "$WORLD_BINARY" "$WORLD_CONF" "$WORLD_SESSION" "server shutdown 30" 180; }
reload_world()  { server_reload worldserver "$WORLD_SESSION"; }

save_world() {
    if tmux has-session -t "$WORLD_SESSION" 2>/dev/null; then
        tmux send-keys -t "$WORLD_SESSION" '.server saveall' Enter
        echo "Save command sent to the Worldserver."
    else
        echo "No active Worldserver tmux session found."
    fi
}

pull_updates() {
    git_owner pull --ff-only
    [ -d "$ACORE_DIR/modules/mod-playerbots/.git" ] && run_as_owner git -C "$ACORE_DIR/modules/mod-playerbots" pull --ff-only
}

autostart_world() {
    echo "1) Enable autostart"; echo "2) Disable autostart"; read -rp "Choice [1-2]: " choice
    case "$choice" in
        1)
            sudo tee "/etc/systemd/system/$WORLD_SERVICE_NAME" >/dev/null <<EOF
[Unit]
Description=AzerothCore Worldserver
After=network-online.target mysql.service

[Service]
Type=oneshot
User=$SERVER_USER
WorkingDirectory=$ACORE_DIR
ExecStart=$WORLD_MENU start
ExecStop=$WORLD_MENU stop
RemainAfterExit=yes
KillMode=mixed
TimeoutStopSec=180

[Install]
WantedBy=multi-user.target
EOF
            sudo systemctl daemon-reload; sudo systemctl enable "$WORLD_SERVICE_NAME"; echo "Autostart enabled." ;;
        2) sudo systemctl disable "$WORLD_SERVICE_NAME" 2>/dev/null || true; sudo rm -f "/etc/systemd/system/$WORLD_SERVICE_NAME"; sudo systemctl daemon-reload; echo "Autostart disabled." ;;
    esac
}

restart_timer() {
    echo "1) Show timer"; echo "2) Enable/change timer"; echo "3) Disable timer"
    read -rp "Choice [1-3]: " choice
    case "$choice" in
        1) systemctl status "$WORLD_TIMER_NAME" --no-pager 2>/dev/null || echo "No timer configured." ;;
        2) read -rp "Daily restart time (HH:MM): " time
           [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "Invalid time."; return; }
           sudo tee "/etc/systemd/system/${WORLD_TIMER_NAME%.timer}.service" >/dev/null <<EOF
[Unit]
Description=AzerothCore Worldserver scheduled restart
[Service]
Type=oneshot
User=$SERVER_USER
ExecStart=$WORLD_MENU restart
EOF
           sudo tee "/etc/systemd/system/$WORLD_TIMER_NAME" >/dev/null <<EOF
[Unit]
Description=AzerothCore Worldserver restart timer
[Timer]
OnCalendar=*-*-* $time:00
Persistent=true
[Install]
WantedBy=timers.target
EOF
           sudo systemctl daemon-reload; sudo systemctl enable --now "$WORLD_TIMER_NAME"; echo "Timer enabled: daily at $time" ;;
        3) sudo systemctl disable --now "$WORLD_TIMER_NAME" 2>/dev/null || true; echo "Timer disabled." ;;
    esac
}

delete_account() {
    read_login_database || { echo "Could not read LoginDatabaseInfo."; return 1; }
    read -rp "Account ID to delete: " id
    [[ "$id" =~ ^[0-9]+$ ]] || { echo "Invalid account ID."; return 1; }
    read -rp "Type DELETE to confirm: " confirm
    [ "$confirm" = DELETE ] && mysql_auth -e "DELETE FROM account WHERE id=$id; DELETE FROM account_access WHERE id=$id;" && echo "Account deleted."
}

apply_world_values() {
    apply_values "$SCRIPT_DIR/values_world.conf" "$WORLD_CONF" || return 1
    echo ""
    read -rp "Restart worldserver now to load the changes? [y/N]: " r
    case "$r" in y|Y|j|J) restart_world ;; *) echo "Not restarted - changes apply on next restart." ;; esac
}

apply_playerbots_values() {
    apply_values "$SCRIPT_DIR/values_playerbots.conf" "$PLAYERBOTS_CONF" || return 1
    echo ""
    read -rp "Restart worldserver now to load the changes? [y/N]: " r
    case "$r" in y|Y|j|J) restart_world ;; *) echo "Not restarted - changes apply on next restart." ;; esac
}

build_menu() {
    while true; do
        clear
        echo -e "${COLOR_BUILD}${BOLD}🛠️  BUILD TOOLS${RESET}"
        echo "----------------------------------------------------------------------------"
        echo -e "  ${COLOR_BUILD}[1]${RESET}  Pull git updates (core + Playerbots)"
        echo -e "  ${COLOR_BUILD}[2]${RESET}  Build and install"
        echo -e "  ${COLOR_BUILD}[3]${RESET}  Clean build directory"
        echo -e "  ${COLOR_BUILD}[0]${RESET}  Back"
        echo "----------------------------------------------------------------------------"
        read -rp "🔹  Choice [0-3]: " choice
        case "$choice" in
            1) run_step pull_updates ;;
            2) run_step safe_build "$ACORE_DIR/build" ;;
            3) run_step "$SCRIPT_DIR/clean-build.sh" "$ACORE_DIR" ;;
            0) return ;;
            *) echo "Invalid option."; sleep 1 ;;
        esac
    done
}

config_menu() {
    while true; do
        clear
        echo -e "${COLOR_CONFIG}${BOLD}📝  CONFIG & MAINTENANCE${RESET}"
        echo "----------------------------------------------------------------------------"
        echo -e "  ${COLOR_CONFIG}[1]${RESET}  Edit values_world.conf (summary)"
        echo -e "  ${COLOR_CONFIG}[2]${RESET}  Apply values_world.conf -> worldserver.conf"
        echo -e "  ${COLOR_CONFIG}[3]${RESET}  Edit values_playerbots.conf (summary)"
        echo -e "  ${COLOR_CONFIG}[4]${RESET}  Apply values_playerbots.conf -> playerbots.conf"
        echo -e "  ${COLOR_CONFIG}[5]${RESET}  Edit any .conf (worldserver + module plugins)"
        echo -e "  ${COLOR_CONFIG}[6]${RESET}  Update Control scripts"
        echo -e "  ${COLOR_CONFIG}[0]${RESET}  Back"
        echo "----------------------------------------------------------------------------"
        read -rp "🔹  Choice [0-6]: " choice
        case "$choice" in
            1) "${EDITOR:-nano}" "$SCRIPT_DIR/values_world.conf" ;;
            2) run_step apply_world_values ;;
            3) "${EDITOR:-nano}" "$SCRIPT_DIR/values_playerbots.conf" ;;
            4) run_step apply_playerbots_values ;;
            5) run_step edit_any_conf ;;
            6) run_step update_control ;;
            0) return ;;
            *) echo "Invalid option."; sleep 1 ;;
        esac
    done
}

timer_dot() {
    if systemctl is-active --quiet "$WORLD_TIMER_NAME" 2>/dev/null; then
        echo -e "$(status_row ⏰ "Daily restart:")${GREEN}ENABLED${RESET}"
    else
        echo -e "$(status_row ⏰ "Daily restart:")${RED}DISABLED${RESET}"
    fi
}

render_menu() {
    box_title "AZEROTHCORE - WORLDSERVER CONTROL"
    status_dot worldserver "$WORLD_SESSION"
    autostart_dot "$WORLD_SERVICE_NAME"
    timer_dot
    echo -e "$(status_row 📂 "Session:")${CYAN}${WORLD_SESSION}${RESET}"
    echo -e "$(status_row 🌿 "Branch:")${CYAN}$(current_branch)${RESET}"
    echo "----------------------------------------------------------------------------"

    menu_section "$COLOR_SERVER" "⚙️  SERVER CONTROL"
    echo -e "  ${COLOR_SERVER}[1]${RESET}  🚀  Start server          ${COLOR_SERVER}[2]${RESET}  🛑  Stop server"
    echo -e "  ${COLOR_SERVER}[3]${RESET}  💥  ${RED}Kill server (force)${RESET}   ${COLOR_SERVER}[4]${RESET}  🔄  Restart server"
    echo -e "  ${COLOR_SERVER}[5]${RESET}  🧿  Reload config         ${COLOR_SERVER}[6]${RESET}  📊  Server status"

    menu_section "$COLOR_LOGS" "📄  LOGS & CONSOLE"
    echo -e "  ${COLOR_LOGS}[7]${RESET}  💾  Save world            ${COLOR_LOGS}[8]${RESET}  🖥️  World console"
    echo -e "  ${COLOR_LOGS}[9]${RESET}  📚  Tmux scrollback"

    menu_section "$COLOR_TOOLS" "🗄️  TOOLS"
    echo -e "  ${COLOR_TOOLS}[10]${RESET} 🚀  Autostart             ${COLOR_TOOLS}[11]${RESET} ⏰  Daily restart timer"
    echo -e "  ${COLOR_TOOLS}[12]${RESET} 🛠️  Build tools           ${COLOR_TOOLS}[13]${RESET} 👤  Delete account"

    menu_section "$COLOR_CONFIG" "📝  CONFIG & MAINTENANCE"
    echo -e "  ${COLOR_CONFIG}[14]${RESET} 📝  Config & Control scripts"

    menu_section "$COLOR_EXIT" "⏻  EXIT"
    echo -e "  ${COLOR_EXIT}[0]${RESET}  🚪  Exit menu"
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${RESET}"
}

menu() {
    clear
    while true; do
        draw_menu render_menu
        echo ""
        read -t 60 -rp "🔹  Select an option (0-14): " choice; rc=$?
        [ "$rc" -gt 128 ] && continue
        case "$choice" in
            1) run_step start_world ;;
            2) run_step stop_world ;;
            3) run_step kill_world ;;
            4) run_step restart_world ;;
            5) run_step reload_world ;;
            6) run_step server_status worldserver "$WORLD_SESSION" ;;
            7) run_step save_world ;;
            8) clear; tmux attach -t "$WORLD_SESSION" 2>/dev/null || { echo "No active worldserver tmux session."; wait_for_user; } ;;
            9) clear; tmux capture-pane -S -100000 -t "$WORLD_SESSION" -p 2>/dev/null || echo "No scrollback available."; wait_for_user ;;
            10) run_step autostart_world ;;
            11) run_step restart_timer ;;
            12) build_menu ;;
            13) run_step delete_account ;;
            14) config_menu ;;
            0) clear; echo -e "${GREEN}👋  Worldserver menu closed.${RESET}"; exit 0 ;;
            *) echo "Invalid option."; sleep 1 ;;
        esac
    done
}

case "${1:-menu}" in
    start) start_world ;;
    stop) stop_world ;;
    restart) restart_world ;;
    status) server_status worldserver "$WORLD_SESSION" ;;
    menu) menu ;;
    *) echo "Usage: $0 [menu|start|stop|restart|status]"; exit 1 ;;
esac
