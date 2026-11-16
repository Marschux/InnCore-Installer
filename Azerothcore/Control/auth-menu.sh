#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# git and the tmux session belong to SERVER_USER; re-run as them if invoked as root.
reexec_as_owner "$0" "$@"

# Interactive loop: a single failing status probe must not kill the menu.
set +e


update_control() { update_control_scripts auth-menu.sh; }

start_auth()   { server_start authserver "$AUTH_ENGINE" "$AUTH_BINARY" "$AUTH_CONF" "$AUTH_SESSION"; }
stop_auth()    { server_stop authserver "$AUTH_SESSION" "" 120; }
kill_auth() {
    echo "Force-stop the authserver."
    confirm_word KILL && server_kill authserver "$AUTH_SESSION"
}
restart_auth() { server_restart authserver "$AUTH_ENGINE" "$AUTH_BINARY" "$AUTH_CONF" "$AUTH_SESSION" "" 120; }

autostart_auth() { autostart_toggle "$AUTH_SERVICE_NAME" "AzerothCore Authserver" "$AUTH_MENU"; }

# Account and realm/MOTD management are vendored from InnControl (see
# auth-tools.sh) and keep their exact look and flow.
run_manager() {   # run_manager <script-basename> [args...]
    clear
    local s="$SCRIPT_DIR/$1"
    if [ ! -f "$s" ]; then
        echo "Manager script missing: $s"
        echo "Run 'Update Control scripts' once more to fetch it."
        wait_for_user
        return 1
    fi
    "$s" "${@:2}"
}
account_menu() { run_manager auth-tools.sh accounts; }
realm_menu()   { run_manager auth-tools.sh realms; }

config_menu() {
    while true; do
        submenu_title "📝  CONFIG & MAINTENANCE" "$COLOR_CONFIG"
        menu_section "$COLOR_CONFIG" "🔐  AUTHSERVER"
        echo -e "  ${DIM}values/values_auth.conf  ->  ${AUTH_CONF}${RESET}"
        echo -e "  ${COLOR_CONFIG}[1]${RESET}  ✏️   Edit summary          ${COLOR_CONFIG}[2]${RESET}  ✅  Apply to authserver.conf"

        menu_section "$COLOR_CONFIG" "📄  RAW FILES"
        echo -e "  ${COLOR_CONFIG}[3]${RESET}  🔧  Edit authserver.conf directly"

        menu_section "$COLOR_CONFIG" "🌍  DATABASE"
        echo -e "  ${COLOR_CONFIG}[4]${RESET}  🤝  Apply cross-faction (two-side) RBAC"
        echo -e "  ${COLOR_CONFIG}[5]${RESET}  🧬  Account AUTO_INCREMENT"
        echo ""
        echo -e "  ${COLOR_CONFIG}[0]${RESET}  🚪  Back"
        echo ""; menu_footer
        read -rp "🔹  Choice [0-5]: " choice
        case "$choice" in
            1) "${EDITOR:-nano}" "$SCRIPT_DIR/values/values_auth.conf" ;;
            2) run_step apply_values "$SCRIPT_DIR/values/values_auth.conf" "$AUTH_CONF" ;;
            3) "${EDITOR:-nano}" "$AUTH_CONF" ;;
            4) run_step apply_two_side_rbac ;;
            5) run_manager auth-tools.sh autoincrement ;;
            0) return ;;
            *) echo "Invalid option."; sleep 1 ;;
        esac
    done
}

# Realms registered in acore_auth.realmlist. Silent when the DB is unreachable
# (not created yet, authserver never started) so the header never breaks.
# Cached for 15s: the menu repaints on a 60s timeout and after every action, and
# the realmlist changes rarely; stale-but-instant beats a frozen menu when the
# DB is slow or down.
realm_header() {
    local cache="${TMPDIR:-/tmp}/acore-realmhdr.${CONTROL_TMUX_L:-auth}" mt l
    mt="$(stat -c %Y "$cache" 2>/dev/null)" || mt=0
    if [ $((EPOCHSECONDS - mt)) -ge 15 ]; then
        ( _realm_header_query ) > "$cache" 2>/dev/null || true
    fi
    while IFS= read -r l; do printf '%s\n' "$l"; done < "$cache" 2>/dev/null
}

_realm_header_query() {
    read_login_database >/dev/null 2>&1 || return 0
    local rows id name address port icon flag tz sec
    rows="$(mysql_auth -N -s -e "SELECT id, name, address, port, icon, flag,
                CASE timezone WHEN 1 THEN 'Dev' WHEN 2 THEN 'US' WHEN 3 THEN 'Oceanic'
                              WHEN 4 THEN 'LatAm' WHEN 6 THEN 'Korea' WHEN 8 THEN 'English'
                              WHEN 9 THEN 'German' WHEN 10 THEN 'French' WHEN 11 THEN 'Spanish'
                              WHEN 12 THEN 'Russian' WHEN 14 THEN 'Taiwan' WHEN 16 THEN 'China'
                              WHEN 26 THEN 'Test' WHEN 33 THEN 'Transfer' ELSE CONCAT('tz', timezone) END,
                CASE allowedSecurityLevel WHEN 1 THEN 'Moderator' WHEN 2 THEN 'Gamemaster'
                     WHEN 3 THEN 'Administrator' WHEN 4 THEN 'Console' ELSE 'Player' END
             FROM realmlist ORDER BY id;" 2>/dev/null)"
    [ -n "$rows" ] || return 0
    hr
    printf "  ${DIM}%-3s %-12.12s %-9s %-19.19s %-17s %-9s %s${RESET}\n" \
        ID Name Type Address Flag TZ Security
    # Pad every field to width first, then wrap in colour and emit with echo -e -
    # printf does not expand \033 inside %s arguments, so a coloured %s prints the
    # escape literally.
    local tc fc sc idc namec addrc iconc flagc tzc secc
    while IFS=$'\t' read -r id name address port icon flag tz sec; do
        realm_type_name icon "$icon"
        case "$icon" in PvP) tc=$RED ;; RP) tc=$BLUE ;; "RP PvP") tc=$PURPLE ;; Unknown) tc=$DIM ;; *) tc=$GREEN ;; esac
        realm_flag_names flag "$flag"
        case "$flag" in Online) fc=$GREEN ;; *Offline*|*Invalid*) fc=$RED ;; *Recommended*) fc=$GOLD ;; *New*) fc=$CYAN ;; *) fc=$DIM ;; esac
        case "$sec" in Player) sc=$GREEN ;; Moderator|Gamemaster) sc=$GOLD ;; Administrator|Console) sc=$RED ;; *) sc=$DIM ;; esac
        printf -v idc   '%-3s'     "$id"
        printf -v namec '%-12.12s' "$name"
        printf -v addrc '%-19.19s' "${address}:${port}"
        printf -v iconc '%-9s'     "$icon"
        printf -v flagc '%-17.17s' "$flag"
        printf -v tzc   '%-9s'     "$tz"
        printf -v secc  '%s'       "$sec"
        echo -e "  ${CYAN}${idc}${RESET} ${namec} ${tc}${iconc}${RESET} ${addrc} ${fc}${flagc}${RESET} ${TEAL}${tzc}${RESET} ${sc}${secc}${RESET}"
    done <<< "$rows"
}

render_menu() {
    box_title "AZEROTHCORE - AUTHSERVER CONTROL"
    status_dot authserver "$AUTH_SESSION"
    autostart_dot "$AUTH_SERVICE_NAME"
    status_row 📂 "Session:" "${CYAN}${AUTH_SESSION}${RESET}"
    acore_version_dot
    realm_header
    hr

    menu_section "$COLOR_SERVER" "⚙️  SERVER CONTROL"
    echo -e "  ${COLOR_SERVER}[1]${RESET}  🚀  Start server               ${COLOR_SERVER}[2]${RESET}  🔄  Restart server"
    echo -e "  ${COLOR_SERVER}[3]${RESET}  🛑  Stop server                ${COLOR_SERVER}[4]${RESET}  💥  ${RED}Kill server (force)${RESET}"

    menu_section "$COLOR_LOGS" "📄  CONSOLE"
    echo -e "  ${COLOR_LOGS}[5]${RESET}  🖥️  Auth console"

    menu_section "$COLOR_TOOLS" "🗄️  TOOLS"
    echo -e "  ${COLOR_TOOLS}[6]${RESET}  🚀  Autostart                  ${COLOR_TOOLS}[7]${RESET}  🛠️  Build tools"
    echo -e "  ${COLOR_TOOLS}[8]${RESET}  👤  Account management         ${COLOR_TOOLS}[9]${RESET}  🌍  Realm management"

    menu_section "$COLOR_CONFIG" "📝  CONFIG & MAINTENANCE"
    echo -e "  ${COLOR_CONFIG}[10]${RESET} 📝  Config & maintenance       ${COLOR_CONFIG}[11]${RESET} ⬇️  Update Control scripts"

    menu_section "$COLOR_EXIT" "⏻  POWER & EXIT"
    echo -e "  ${COLOR_EXIT}[12]${RESET} 🔁  Reboot LXC                 ${COLOR_EXIT}[0]${RESET}  🚪  Exit menu"
    echo ""
    menu_footer
}

menu() {
    MENU_RUNNING=1
    clear
    while true; do
        draw_menu render_menu
        echo ""
        read -t 60 -rp "🔹  Select an option (0-12): " choice; rc=$?
        [ "$rc" -gt 128 ] && continue
        case "$choice" in
            1) run_step start_auth ;;
            2) run_step restart_auth ;;
            3) run_step stop_auth ;;
            4) run_step kill_auth ;;
            5) clear; tmx attach -t "$AUTH_SESSION" 2>/dev/null || { echo "No active authserver tmux session."; wait_for_user; } ;;
            6) run_step autostart_auth ;;
            7) build_menu "Pull git updates" auth-only none git_update "$ACORE_DIR" ;;
            8) account_menu ;;
            9) realm_menu ;;
            10) config_menu ;;
            11) run_step update_control ;;
            12) run_step reboot_lxc authserver "$AUTH_SESSION" ;;
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
    update) update_control ;;
    menu) menu ;;
    *) echo "Usage: $0 [menu|start|stop|restart|status|update]"; exit 1 ;;
esac
