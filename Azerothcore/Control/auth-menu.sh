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

# SQL-quote a value for use inside single quotes.
sqesc() { printf '%s' "$1" | sed "s/'/''/g"; }

# Print "id<TAB>username<TAB>expansion<TAB>locked" for a name or numeric id, or nothing.
acc_find() {
    local q="$1"
    if [[ "$q" =~ ^[0-9]+$ ]]; then
        mysql_auth -N -s -e "SELECT id,username,expansion,locked FROM account WHERE id=$q LIMIT 1;"
    else
        mysql_auth -N -s -e "SELECT id,username,expansion,locked FROM account WHERE username='$(sqesc "${q^^}")' LIMIT 1;"
    fi
}

acc_add() {
    local next u p p2 exp sv salt ver
    next="$(mysql_auth -N -s -e 'SELECT IFNULL(MAX(id),0)+1 FROM account WHERE id<10000;')"
    read -rp "Account name: " u
    [[ "$u" =~ ^[A-Za-z0-9_-]{1,16}$ ]] || { echo "Invalid name (1-16 chars A-Z a-z 0-9 _ -)."; return 1; }
    u="${u^^}"
    [ "$(mysql_auth -N -s -e "SELECT COUNT(*) FROM account WHERE username='$(sqesc "$u")';")" = 0 ] \
        || { echo "Account '$u' already exists."; return 1; }
    read -rsp "Password: " p; echo
    read -rsp "Repeat password: " p2; echo
    [ -n "$p" ] && [ "$p" = "$p2" ] || { echo "Passwords empty or do not match."; return 1; }
    read -rp "Expansion (0=Classic 1=TBC 2=WotLK) [2]: " exp; exp="${exp:-2}"
    [[ "$exp" =~ ^[0-2]$ ]] || { echo "Invalid expansion."; return 1; }
    sv="$(srp6_hex "$u" "$p")" || return 1
    salt="${sv%% *}"; ver="${sv##* }"
    mysql_auth -e "INSERT INTO account (id,username,salt,verifier,expansion)
                   VALUES ($next,'$(sqesc "$u")',UNHEX('$salt'),UNHEX('$ver'),$exp);" \
        && echo "Account '$u' created (id $next, expansion $exp)."
}

acc_passwd() {
    local q row id u sv salt ver p p2
    read -rp "Account name or id: " q
    row="$(acc_find "$q")"; [ -n "$row" ] || { echo "Account not found."; return 1; }
    IFS=$'\t' read -r id u _ _ <<< "$row"
    read -rsp "New password for '$u': " p; echo
    read -rsp "Repeat password: " p2; echo
    [ -n "$p" ] && [ "$p" = "$p2" ] || { echo "Passwords empty or do not match."; return 1; }
    sv="$(srp6_hex "$u" "$p")" || return 1
    salt="${sv%% *}"; ver="${sv##* }"
    mysql_auth -e "UPDATE account SET salt=UNHEX('$salt'),verifier=UNHEX('$ver'),session_key=NULL WHERE id=$id;" \
        && echo "Password changed for '$u'."
}

acc_gm() {
    local q row id u lvl realm
    read -rp "Account name or id: " q
    row="$(acc_find "$q")"; [ -n "$row" ] || { echo "Account not found."; return 1; }
    IFS=$'\t' read -r id u _ _ <<< "$row"
    echo "Current access:"
    list_table "SELECT aa.RealmID, IFNULL(r.name, IF(aa.RealmID=-1,'All realms','?')) AS realm, aa.gmlevel
                FROM account_access aa LEFT JOIN realmlist r ON r.id=aa.RealmID WHERE aa.id=$id ORDER BY aa.RealmID;"
    read -rp "New GM level (0=Player 1=Mod 2=GM 3=Admin): " lvl
    [[ "$lvl" =~ ^[0-3]$ ]] || { echo "Invalid level."; return 1; }
    read -rp "Realm ID (-1 = all realms) [-1]: " realm; realm="${realm:--1}"
    [[ "$realm" =~ ^-?[0-9]+$ ]] || { echo "Invalid realm id."; return 1; }
    if [ "$lvl" = 0 ]; then
        mysql_auth -e "DELETE FROM account_access WHERE id=$id AND RealmID=$realm;" \
            && echo "GM access removed for '$u' on realm $realm."
    else
        mysql_auth -e "DELETE FROM account_access WHERE id=$id AND RealmID=$realm;
                       INSERT INTO account_access (id,gmlevel,RealmID) VALUES ($id,$lvl,$realm);" \
            && echo "GM level $lvl set for '$u' on realm $realm."
    fi
}

acc_delete() {
    local id confirm
    read -rp "Account ID to delete: " id
    [[ "$id" =~ ^[0-9]+$ ]] || { echo "Invalid ID."; return 1; }
    read -rp "Type DELETE to confirm: " confirm
    [ "$confirm" = DELETE ] || { echo "Cancelled."; return 0; }
    mysql_auth -e "DELETE FROM account WHERE id=$id; DELETE FROM account_access WHERE id=$id;" \
        && echo "Account $id deleted."
}

account_menu() {
    while true; do
        submenu_title "👤  ACCOUNT MANAGEMENT" "$COLOR_MANAGE"
        echo -e "  ${COLOR_MANAGE}[1]${RESET}  List accounts"
        echo -e "  ${COLOR_MANAGE}[2]${RESET}  Add account"
        echo -e "  ${COLOR_MANAGE}[3]${RESET}  Change password"
        echo -e "  ${COLOR_MANAGE}[4]${RESET}  Set GM level"
        echo -e "  ${COLOR_MANAGE}[5]${RESET}  Delete account"
        echo -e "  ${COLOR_MANAGE}[0]${RESET}  Back"
        echo ""; menu_footer
        read -rp "🔹  Choice [0-5]: " choice
        case "$choice" in
            1) list_table 'SELECT id, username, expansion, locked, last_login FROM account ORDER BY id;'; wait_for_user ;;
            2) run_step acc_add ;;
            3) run_step acc_passwd ;;
            4) run_step acc_gm ;;
            5) run_step acc_delete ;;
            0) return ;;
            *) echo "Invalid option."; sleep 1 ;;
        esac
    done
}

realm_list_table() {
    list_table "SELECT id, name, address, port,
        CASE icon WHEN 1 THEN 'PvP' WHEN 6 THEN 'RP' WHEN 8 THEN 'RP PvP' ELSE 'Normal' END AS type,
        flag, timezone AS tz,
        CASE allowedSecurityLevel WHEN 1 THEN 'Mod' WHEN 2 THEN 'GM' WHEN 3 THEN 'Admin' ELSE 'Player' END AS security,
        gamebuild AS build
     FROM realmlist ORDER BY id;"
}

realm_add() {
    local id row nm ad la sm pt ic fl tz se gb
    realm_list_table; echo ""
    id="$(mysql_auth -N -s -e 'SELECT IFNULL(MAX(id),0)+1 FROM realmlist;')"
    read -rp "Realm ID [$id]: " id; id="${id:-$id}"
    [[ "$id" =~ ^[0-9]+$ ]] || { echo "Invalid ID."; return 1; }
    row="$(mysql_auth -N -s -e "SELECT name,address,localAddress,localSubnetMask,port,icon,flag,timezone,allowedSecurityLevel,gamebuild FROM realmlist WHERE id=$id LIMIT 1;")"
    if [ -n "$row" ]; then
        IFS=$'\t' read -r nm ad la sm pt ic fl tz se gb <<< "$row"
        echo "Realm $id exists - values shown are the current ones (ENTER keeps them)."
    else
        nm="Realm $id"; ad="127.0.0.1"; la="127.0.0.1"; sm="255.255.255.0"
        pt=8085; ic=0; fl=0; tz=1; se=0; gb=12340
    fi
    local v
    read -rp "Name [$nm]: " v; nm="${v:-$nm}"
    read -rp "Address (WAN IP/domain) [$ad]: " v; ad="${v:-$ad}"
    read -rp "Local address (LAN) [$la]: " v; la="${v:-$la}"
    read -rp "Local subnet mask [$sm]: " v; sm="${v:-$sm}"
    read -rp "Port [$pt]: " v; pt="${v:-$pt}"
    read -rp "Icon (0=Normal 1=PvP 6=RP 8=RP PvP) [$ic]: " v; ic="${v:-$ic}"
    read -rp "Flag (0=None 2=Offline 32=Recommended 64=New) [$fl]: " v; fl="${v:-$fl}"
    read -rp "Timezone (1=Dev 2=US 8=English 9=German 10=French) [$tz]: " v; tz="${v:-$tz}"
    read -rp "Security level (0=Player 1=Mod 2=GM 3=Admin) [$se]: " v; se="${v:-$se}"
    read -rp "Gamebuild (12340 = 3.3.5a) [$gb]: " v; gb="${v:-$gb}"
    [[ "$pt$ic$fl$tz$se$gb" =~ ^[0-9]+$ ]] || { echo "Port/icon/flag/timezone/security/gamebuild must be numeric."; return 1; }
    [[ "$ad" =~ ^[A-Za-z0-9._-]+$ && "$la" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Invalid address."; return 1; }
    mysql_auth -e "INSERT INTO realmlist
        (id,name,address,localAddress,localSubnetMask,port,icon,flag,timezone,allowedSecurityLevel,population,gamebuild)
        VALUES ($id,'$(sqesc "$nm")','$(sqesc "$ad")','$(sqesc "$la")','$(sqesc "$sm")',$pt,$ic,$fl,$tz,$se,0,$gb)
        ON DUPLICATE KEY UPDATE name='$(sqesc "$nm")',address='$(sqesc "$ad")',localAddress='$(sqesc "$la")',
        localSubnetMask='$(sqesc "$sm")',port=$pt,icon=$ic,flag=$fl,timezone=$tz,allowedSecurityLevel=$se,gamebuild=$gb;" \
        && echo "Realm $id '$nm' written. Worldserver needs RealmID = $id in worldserver.conf."
}

realm_delete() {
    local id nm confirm
    realm_list_table; echo ""
    read -rp "Realm ID to delete: " id
    [[ "$id" =~ ^[0-9]+$ ]] || { echo "Invalid ID."; return 1; }
    nm="$(mysql_auth -N -s -e "SELECT name FROM realmlist WHERE id=$id LIMIT 1;")"
    [ -n "$nm" ] || { echo "No realm with id $id."; return 1; }
    read -rp "Type DELETE to remove realm [$id] $nm: " confirm
    [ "$confirm" = DELETE ] || { echo "Cancelled."; return 0; }
    mysql_auth -e "DELETE FROM realmlist WHERE id=$id;" \
        && { mysql_auth -e "DELETE FROM motd WHERE realmid=$id;" 2>/dev/null; echo "Realm $id '$nm' deleted (character DB left untouched)."; }
}

realm_menu() {
    while true; do
        submenu_title "🌍  REALM MANAGEMENT" "$COLOR_MANAGE"
        echo -e "  ${COLOR_MANAGE}[1]${RESET}  List realms"
        echo -e "  ${COLOR_MANAGE}[2]${RESET}  Add / update realm"
        echo -e "  ${COLOR_MANAGE}[3]${RESET}  Delete realm"
        echo -e "  ${COLOR_MANAGE}[0]${RESET}  Back"
        echo ""; menu_footer
        read -rp "🔹  Choice [0-3]: " choice
        case "$choice" in
            1) run_step realm_list_table ;;
            2) run_step realm_add ;;
            3) run_step realm_delete ;;
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
        echo -e "  ${COLOR_CONFIG}[0]${RESET}  Back"
        echo ""; menu_footer
        read -rp "🔹  Choice [0-4]: " choice
        case "$choice" in
            1) "${EDITOR:-nano}" "$SCRIPT_DIR/values/values_auth.conf" ;;
            2) run_step apply_auth_values ;;
            3) "${EDITOR:-nano}" "$AUTH_CONF" ;;
            4) run_step apply_two_side_rbac ;;
            0) return ;;
            *) echo "Invalid option."; sleep 1 ;;
        esac
    done
}

build_menu() {
    while true; do
        submenu_title "🛠  BUILD TOOLS" "$COLOR_BUILD"
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

# Realms registered in acore_auth.realmlist. Silent when the DB is unreachable
# (not created yet, authserver never started) so the header never breaks.
realm_header() {
    read_login_database >/dev/null 2>&1 || return 0
    local rows id name address port icon flag tz sec
    rows="$(mysql_auth -N -s -e "SELECT id, name, address, port,
                CASE icon WHEN 1 THEN 'PvP' WHEN 6 THEN 'RP' WHEN 8 THEN 'RP PvP' ELSE 'Normal' END,
                CASE flag WHEN 0 THEN 'Online' WHEN 1 THEN 'Invalid' WHEN 2 THEN 'Offline'
                          WHEN 4 THEN 'SpecifyBuild' WHEN 32 THEN 'Recommended' WHEN 64 THEN 'New'
                          ELSE CONCAT('flag ', flag) END,
                CASE timezone WHEN 1 THEN 'Development' WHEN 2 THEN 'United States' WHEN 3 THEN 'Oceanic'
                              WHEN 4 THEN 'Latin America' WHEN 6 THEN 'Korea' WHEN 8 THEN 'English'
                              WHEN 9 THEN 'German' WHEN 10 THEN 'French' WHEN 11 THEN 'Spanish'
                              WHEN 12 THEN 'Russian' WHEN 14 THEN 'Taiwan' WHEN 16 THEN 'China'
                              WHEN 26 THEN 'Test Server' WHEN 33 THEN 'Transfer' ELSE CONCAT('tz ', timezone) END,
                CASE allowedSecurityLevel WHEN 1 THEN 'Mod' WHEN 2 THEN 'GM' WHEN 3 THEN 'Admin' ELSE 'Player' END
             FROM realmlist ORDER BY id;" 2>/dev/null)"
    [ -n "$rows" ] || return 0
    echo -e "$(status_row 🌐 "Realms:")"
    printf "     ${DIM}%-3s %-20.20s %-7s %-22.22s %-12s %-13s %s${RESET}\n" \
        ID Name Type Address Flag Timezone Security
    # Pad to width first, then wrap in colour - ANSI bytes must not count toward %-Ns.
    local cell tc fc sc
    while IFS=$'\t' read -r id name address port icon flag tz sec; do
        case "$icon" in PvP) tc=$RED ;; RP) tc=$BLUE ;; "RP PvP") tc=$PURPLE ;; *) tc=$GREEN ;; esac
        case "$flag" in Online) fc=$GREEN ;; Offline|Invalid) fc=$RED ;; Recommended) fc=$GOLD ;; New) fc=$CYAN ;; *) fc=$DIM ;; esac
        case "$sec" in Player) sc=$GREEN ;; Mod|GM) sc=$GOLD ;; Admin) sc=$RED ;; *) sc=$DIM ;; esac
        printf -v cell '%-7s' "$icon";            icon="${tc}${cell}${RESET}"
        printf -v cell '%-12s' "$flag";           flag="${fc}${cell}${RESET}"
        printf -v cell '%-13s' "$tz";             tz="${TEAL}${cell}${RESET}"
        printf -v cell '%s'    "$sec";            sec="${sc}${cell}${RESET}"
        printf "     ${CYAN}%-3s${RESET} %-20.20s %s %-22.22s %s %s %s\n" \
            "$id" "$name" "$icon" "${address}:${port}" "$flag" "$tz" "$sec"
    done <<< "$rows"
}

render_menu() {
    box_title "AZEROTHCORE - AUTHSERVER CONTROL"
    status_dot authserver "$AUTH_SESSION"
    autostart_dot "$AUTH_SERVICE_NAME"
    echo -e "$(status_row 📂 "Session:")${CYAN}${AUTH_SESSION}${RESET}"
    echo -e "$(status_row 🌿 "Branch:")${CYAN}$(current_branch)${RESET}"
    realm_header
    hr

    menu_section "$COLOR_SERVER" "⚙️  SERVER CONTROL"
    echo -e "  ${COLOR_SERVER}[1]${RESET}  🚀  Start server          ${COLOR_SERVER}[2]${RESET}  🔄  Restart server"
    echo -e "  ${COLOR_SERVER}[3]${RESET}  🛑  Stop server           ${COLOR_SERVER}[4]${RESET}  💥  ${RED}Kill server (force)${RESET}"

    menu_section "$COLOR_LOGS" "📄  CONSOLE"
    echo -e "  ${COLOR_LOGS}[5]${RESET}  🖥️  Auth console"

    menu_section "$COLOR_TOOLS" "🗄️  TOOLS"
    echo -e "  ${COLOR_TOOLS}[6]${RESET}  🚀  Autostart             ${COLOR_TOOLS}[7]${RESET}  🛠️  Build tools"
    echo -e "  ${COLOR_TOOLS}[8]${RESET}  👤  Account management    ${COLOR_TOOLS}[9]${RESET}  🌍  Realm management"

    menu_section "$COLOR_CONFIG" "📝  CONFIG & MAINTENANCE"
    echo -e "  ${COLOR_CONFIG}[10]${RESET} 📝  Config & maintenance  ${COLOR_CONFIG}[11]${RESET} ⬇️  Update Control scripts"

    menu_section "$COLOR_EXIT" "⏻  POWER & EXIT"
    echo -e "  ${COLOR_EXIT}[12]${RESET} 🔁  Reboot LXC             ${COLOR_EXIT}[0]${RESET}  🚪  Exit menu"
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
            7) build_menu ;;
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
