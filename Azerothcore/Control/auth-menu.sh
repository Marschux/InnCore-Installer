#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# git and the tmux session belong to SERVER_USER - re-run as them if invoked as root.
reexec_as_owner "$0" "$@"

# Interactive loop: a single failing status probe must not kill the menu.
set +e

AUTH_ENGINE="${AUTH_ENGINE:-$ACORE_DIR/apps/startup-scripts/src/run-engine}"
AUTH_BINARY="${AUTH_BINARY:-$ACORE_DIR/env/dist/bin/authserver}"
AUTH_CONF="${AUTH_CONF:-$ACORE_DIR/env/dist/etc/authserver.conf}"
AUTH_SESSION="${AUTH_SESSION:-auth-session}"
AUTH_SERVICE_NAME="${AUTH_SERVICE_NAME:-azerothcore-auth.service}"

update_control() { update_control_scripts auth-menu.sh; }

start_auth()   { server_start authserver "$AUTH_ENGINE" "$AUTH_BINARY" "$AUTH_CONF" "$AUTH_SESSION"; }
stop_auth()    { server_stop authserver "$AUTH_SESSION" "" 120; }
kill_auth() {
    read -rp "Type KILL to force-stop the authserver: " c
    [ "$c" = KILL ] && server_kill authserver "$AUTH_SESSION" || echo "Cancelled."
}
restart_auth() { server_restart authserver "$AUTH_ENGINE" "$AUTH_BINARY" "$AUTH_CONF" "$AUTH_SESSION" "" 120; }

autostart_auth() {
    echo "1) Enable autostart"; echo "2) Disable autostart"; read -rp "Choice [1-2]: " choice
    case "$choice" in
        1)
            sudo tee "/etc/systemd/system/$AUTH_SERVICE_NAME" >/dev/null <<EOF
[Unit]
Description=AzerothCore Authserver
After=network-online.target mysql.service

[Service]
Type=oneshot
User=$SERVER_USER
WorkingDirectory=$ACORE_DIR
ExecStart=$AUTH_MENU start
ExecStop=$AUTH_MENU stop
RemainAfterExit=yes
KillMode=mixed
# Modest priority boost on a clean boot (a tmux server already up on the
# socket keeps its own nice). The server's own ProcessPriority is off in
# values_world.conf so it no longer logs a failed setpriority().
Nice=-5
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF
            sudo systemctl daemon-reload; sudo systemctl enable "$AUTH_SERVICE_NAME"; echo "Autostart enabled." ;;
        2) sudo systemctl disable "$AUTH_SERVICE_NAME" 2>/dev/null || true; sudo rm -f "/etc/systemd/system/$AUTH_SERVICE_NAME"; sudo systemctl daemon-reload; echo "Autostart disabled." ;;
    esac
}

account_menu() {
    while true; do
        submenu_title "👤  ACCOUNT MANAGEMENT" "$COLOR_MANAGE"
        echo -e "  ${COLOR_MANAGE}[1]${RESET}  List accounts"
        echo -e "  ${COLOR_MANAGE}[2]${RESET}  Delete account"
        echo -e "  ${COLOR_MANAGE}[0]${RESET}  Back"
        echo ""; menu_footer
        read -rp "🔹  Choice [0-2]: " choice
        case "$choice" in
            1) list_table 'SELECT id, username, expansion, locked FROM account ORDER BY id;'; wait_for_user ;;
            2) read -rp "Account ID to delete: " id
               if [[ "$id" =~ ^[0-9]+$ ]]; then
                   read -rp "Type DELETE to confirm: " confirm
                   [ "$confirm" = DELETE ] && mysql_auth -e "DELETE FROM account WHERE id=$id; DELETE FROM account_access WHERE id=$id;" && echo "Account deleted."
               else
                   echo "Invalid ID."
               fi
               wait_for_user ;;
            0) return ;;
            *) echo "Invalid option."; sleep 1 ;;
        esac
    done
}

realm_menu() {
    while true; do
        submenu_title "🌍  REALM MANAGEMENT" "$COLOR_MANAGE"
        echo -e "  ${COLOR_MANAGE}[1]${RESET}  List realms"
        echo -e "  ${COLOR_MANAGE}[2]${RESET}  Change realm address"
        echo -e "  ${COLOR_MANAGE}[0]${RESET}  Back"
        echo ""; menu_footer
        read -rp "🔹  Choice [0-2]: " choice
        case "$choice" in
            1) list_table 'SELECT id, name, address, port, flag, gamebuild FROM realmlist ORDER BY id;'; wait_for_user ;;
            2) read -rp "Realm ID: " id; read -rp "New address: " address
               if [[ "$id" =~ ^[0-9]+$ && "$address" =~ ^[A-Za-z0-9._-]+$ ]]; then
                   mysql_auth -e "UPDATE realmlist SET address='$address', localAddress='$address' WHERE id=$id;" && echo "Realm updated."
               else
                   echo "Invalid input."
               fi
               wait_for_user ;;
            0) return ;;
            *) echo "Invalid option."; sleep 1 ;;
        esac
    done
}

apply_auth_values() {
    apply_values "$SCRIPT_DIR/values/values_auth.conf" "$AUTH_CONF" || return 1
    echo ""
    read -rp "Restart authserver now to load the changes? [y/N]: " r
    case "$r" in y|Y|j|J) restart_auth ;; *) echo "Not restarted - changes apply on next restart." ;; esac
}

config_menu() {
    while true; do
        submenu_title "📝  CONFIG & MAINTENANCE" "$COLOR_CONFIG"
        echo -e "  ${COLOR_CONFIG}[1]${RESET}  Edit values_auth.conf (summary)"
        echo -e "  ${COLOR_CONFIG}[2]${RESET}  Apply values_auth.conf -> authserver.conf"
        echo -e "  ${COLOR_CONFIG}[3]${RESET}  Edit authserver.conf (raw)"
        echo -e "  ${COLOR_CONFIG}[4]${RESET}  Apply cross-faction (two-side) RBAC"
        echo -e "  ${COLOR_CONFIG}[5]${RESET}  Update Control scripts"
        echo -e "  ${COLOR_CONFIG}[0]${RESET}  Back"
        echo ""; menu_footer
        read -rp "🔹  Choice [0-5]: " choice
        case "$choice" in
            1) "${EDITOR:-nano}" "$SCRIPT_DIR/values/values_auth.conf" ;;
            2) run_step apply_auth_values ;;
            3) "${EDITOR:-nano}" "$AUTH_CONF" ;;
            4) run_step apply_two_side_rbac ;;
            5) run_step update_control ;;
            0) return ;;
            *) echo "Invalid option."; sleep 1 ;;
        esac
    done
}

build_menu() {
    while true; do
        submenu_title "🛠️  BUILD TOOLS" "$COLOR_BUILD"
        echo -e "  ${COLOR_BUILD}[1]${RESET}  Pull git updates"
        echo -e "  ${COLOR_BUILD}[2]${RESET}  Build and install"
        echo -e "  ${COLOR_BUILD}[3]${RESET}  Clean build directory"
        echo -e "  ${COLOR_BUILD}[0]${RESET}  Back"
        echo ""; menu_footer
        read -rp "🔹  Choice [0-3]: " choice
        case "$choice" in
            1) run_step git_update "$ACORE_DIR" ;;
            2) run_step safe_build "$ACORE_DIR/build" ;;
            3) run_step "$SCRIPT_DIR/clean-build.sh" "$ACORE_DIR" ;;
            0) return ;;
            *) echo "Invalid option."; sleep 1 ;;
        esac
    done
}

render_menu() {
    box_title "AZEROTHCORE - AUTHSERVER CONTROL"
    status_dot authserver "$AUTH_SESSION"
    autostart_dot "$AUTH_SERVICE_NAME"
    echo -e "$(status_row 📂 "Session:")${CYAN}${AUTH_SESSION}${RESET}"
    echo -e "$(status_row 🌿 "Branch:")${CYAN}$(current_branch)${RESET}"
    hr

    menu_section "$COLOR_SERVER" "⚙️  SERVER CONTROL"
    echo -e "  ${COLOR_SERVER}[1]${RESET}  🚀  Start server          ${COLOR_SERVER}[2]${RESET}  🛑  Stop server"
    echo -e "  ${COLOR_SERVER}[3]${RESET}  💥  ${RED}Kill server (force)${RESET}   ${COLOR_SERVER}[4]${RESET}  🔄  Restart server"

    menu_section "$COLOR_LOGS" "📄  CONSOLE"
    echo -e "  ${COLOR_LOGS}[5]${RESET}  🖥️  Auth console"

    menu_section "$COLOR_TOOLS" "🗄️  TOOLS"
    echo -e "  ${COLOR_TOOLS}[6]${RESET}  🚀  Autostart             ${COLOR_TOOLS}[7]${RESET}  🛠️  Build tools"
    echo -e "  ${COLOR_TOOLS}[8]${RESET}  👤  Account management    ${COLOR_TOOLS}[9]${RESET}  🌍  Realm management"

    menu_section "$COLOR_CONFIG" "📝  CONFIG & MAINTENANCE"
    echo -e "  ${COLOR_CONFIG}[10]${RESET} 📝  Config & Control scripts"

    menu_section "$COLOR_EXIT" "⏻  POWER & EXIT"
    echo -e "  ${COLOR_EXIT}[11]${RESET} 🔁  Reboot LXC             ${COLOR_EXIT}[0]${RESET}  🚪  Exit menu"
    echo ""
    menu_footer
}

menu() {
    clear
    while true; do
        draw_menu render_menu
        echo ""
        read -t 60 -rp "🔹  Select an option (0-11): " choice; rc=$?
        [ "$rc" -gt 128 ] && continue
        case "$choice" in
            1) run_step start_auth ;;
            2) run_step stop_auth ;;
            3) run_step kill_auth ;;
            4) run_step restart_auth ;;
            5) clear; tmx attach -t "$AUTH_SESSION" 2>/dev/null || { echo "No active authserver tmux session."; wait_for_user; } ;;
            6) run_step autostart_auth ;;
            7) build_menu ;;
            8) account_menu ;;
            9) realm_menu ;;
            10) config_menu ;;
            11) run_step reboot_lxc authserver "$AUTH_SESSION" ;;
            0) clear; echo -e "${GREEN}👋  Authserver menu closed.${RESET}"; exit 0 ;;
            *) echo "Invalid option."; sleep 1 ;;
        esac
    done
}

case "${1:-menu}" in
    start) start_auth ;;
    stop) stop_auth ;;
    restart) restart_auth ;;
    status) server_status authserver "$AUTH_SESSION" ;;
    menu) menu ;;
    *) echo "Usage: $0 [menu|start|stop|restart|status]"; exit 1 ;;
esac
