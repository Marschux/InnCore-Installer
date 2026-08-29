#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

update_control() {
    require_path "$CONTROL_SOURCE_DIR/common.sh"
    sudo install -m 0755 "$CONTROL_SOURCE_DIR/common.sh" "$SCRIPT_DIR/common.sh"
    sudo install -m 0755 "$CONTROL_SOURCE_DIR/auth-menu.sh" "$SCRIPT_DIR/auth-menu.sh"
    sudo install -m 0755 "$CONTROL_SOURCE_DIR/clean-build.sh" "$SCRIPT_DIR/clean-build.sh"
    sudo chown "$SERVER_USER:$SERVER_USER" "$SCRIPT_DIR"/*.sh
    echo "Auth Control scripts updated."
}

AUTH_ENGINE="${AUTH_ENGINE:-$ACORE_DIR/apps/startup-scripts/src/run-engine}"
AUTH_BINARY="${AUTH_BINARY:-$ACORE_DIR/env/dist/bin/authserver}"
AUTH_CONF="${AUTH_CONF:-$ACORE_DIR/env/dist/etc/authserver.conf}"
AUTH_SESSION="${AUTH_SESSION:-auth-session}"
AUTH_SERVICE_NAME="${AUTH_SERVICE_NAME:-azerothcore-auth.service}"

start_auth() {
    server_start authserver "$AUTH_ENGINE" "$AUTH_BINARY" "$AUTH_CONF" "$AUTH_SESSION"
    return $?
    require_path "$AUTH_ENGINE" || return 0
    require_path "$AUTH_BINARY" || return 0
    require_path "$AUTH_CONF" || return 0
    if tmux has-session -t "$AUTH_SESSION" 2>/dev/null; then echo "Authserver is already running."; return; fi
    tmux new-session -d -s "$AUTH_SESSION" "cd '$ACORE_DIR' && '$AUTH_ENGINE' start '$AUTH_BINARY' --server-config '$AUTH_CONF' --session-manager none"
    echo "Authserver started."
}

stop_auth() {
    server_stop authserver "$AUTH_SESSION" "" 120
    return $?
    if pgrep -x authserver >/dev/null 2>&1; then
        pkill -TERM -x authserver
        for _ in $(seq 1 60); do pgrep -x authserver >/dev/null 2>&1 || break; sleep 1; done
    fi
    tmux kill-session -t "$AUTH_SESSION" 2>/dev/null || true
    pgrep -x authserver >/dev/null 2>&1 && { echo "Authserver not responding; no automatic KILL."; return 1; }
    echo "Authserver stopped."
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
        clear; echo "=== Account management ==="; echo "1) List accounts"; echo "2) Delete account"; echo "0) Back"; read -rp "Choice: " choice
        case "$choice" in
            1) mysql_auth --batch --table -e 'SELECT id, username, expansion, locked FROM account ORDER BY id;' ;;
            2) read -rp "Account ID to delete: " id; [[ "$id" =~ ^[0-9]+$ ]] || { echo "Invalid ID."; pause_control; continue; }; read -rp "Type DELETE to confirm: " confirm; [ "$confirm" = DELETE ] && mysql_auth -e "DELETE FROM account WHERE id=$id; DELETE FROM account_access WHERE id=$id;" ;;
            0) return ;;
        esac
        pause_control
    done
}

realm_menu() {
    while true; do
        clear; echo "=== Realm management ==="; echo "1) List realms"; echo "2) Change realm address"; echo "0) Back"; read -rp "Choice: " choice
        case "$choice" in
            1) mysql_auth --batch --table -e 'SELECT id, name, address, port, flag, gamebuild FROM realmlist ORDER BY id;' ;;
            2) read -rp "Realm ID: " id; read -rp "New address: " address; [[ "$id" =~ ^[0-9]+$ && "$address" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Invalid input."; pause_control; continue; }; mysql_auth -e "UPDATE realmlist SET address='$address', localAddress='$address' WHERE id=$id;" ;;
            0) return ;;
        esac
        pause_control
    done
}

menu() {
    while true; do
        menu_title "🔐" "AzerothCore Authserver Control" authserver "$AUTH_SESSION"
        menu_section "Server"
        echo "  1) ▶️  Start"; echo "  2) ⏹️  Stop"; echo "  3) 🔄  Restart"; echo "  4) 📊  Status"; echo "  5) ⚙️  Autostart"
        menu_section "Maintenance"
        echo "  6) ⬇️  Update source"; echo "  7) 🔨  Build and install"; echo "  8) 🧹  Clean build"; echo "  9) 📝  Open authserver.conf"
        menu_section "Management"
        echo " 10) 👤  Account management"; echo " 11) 🌐  Realm management"; echo " 12) 🔄  Update Control scripts"; echo "  0) 🚪  Exit"
        echo ""; read -rp "Choice [0-12]: " choice
        case "$choice" in
            1) start_auth ;; 2) stop_auth ;; 3) restart_auth ;; 4) server_status authserver "$AUTH_SESSION" ;; 5) autostart_auth ;; 6) git -C "$ACORE_DIR" pull --ff-only ;; 7) safe_build "$ACORE_DIR/build" ;; 8) "$SCRIPT_DIR/clean-build.sh" "$ACORE_DIR" ;; 9) nano "$AUTH_CONF" ;; 10) account_menu ;; 11) realm_menu ;; 12) update_control ;; 0) return ;; esac
        pause_control
    done
}

case "${1:-menu}" in
    start) start_auth ;; stop) stop_auth ;; restart) restart_auth ;; status) server_status authserver "$AUTH_SESSION" ;; menu) menu ;; *) echo "Usage: $0 [menu|start|stop|restart|status]"; exit 1 ;;
esac
