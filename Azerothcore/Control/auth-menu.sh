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
    echo "Auth-Control-Skripte aktualisiert."
}

AUTH_ENGINE="${AUTH_ENGINE:-$ACORE_DIR/apps/startup-scripts/src/run-engine}"
AUTH_BINARY="${AUTH_BINARY:-$ACORE_DIR/env/dist/bin/authserver}"
AUTH_CONF="${AUTH_CONF:-$ACORE_DIR/env/dist/etc/authserver.conf}"
AUTH_SESSION="${AUTH_SESSION:-auth-session}"
AUTH_SERVICE_NAME="${AUTH_SERVICE_NAME:-azerothcore-auth.service}"

start_auth() {
    require_path "$AUTH_ENGINE" || return 0
    require_path "$AUTH_BINARY" || return 0
    require_path "$AUTH_CONF" || return 0
    if tmux has-session -t "$AUTH_SESSION" 2>/dev/null; then echo "Authserver läuft bereits."; return; fi
    tmux new-session -d -s "$AUTH_SESSION" "cd '$ACORE_DIR' && '$AUTH_ENGINE' start '$AUTH_BINARY' --server-config '$AUTH_CONF' --session-manager none"
    echo "Authserver gestartet."
}

stop_auth() {
    if pgrep -x authserver >/dev/null 2>&1; then
        pkill -TERM -x authserver
        for _ in $(seq 1 60); do pgrep -x authserver >/dev/null 2>&1 || break; sleep 1; done
    fi
    tmux kill-session -t "$AUTH_SESSION" 2>/dev/null || true
    pgrep -x authserver >/dev/null 2>&1 && { echo "Authserver reagiert nicht; kein automatischer KILL."; return 1; }
    echo "Authserver gestoppt."
}

restart_auth() { stop_auth; start_auth; }

autostart_auth() {
    echo "1) Autostart aktivieren"; echo "2) Autostart deaktivieren"; read -rp "Auswahl [1-2]: " choice
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
            sudo systemctl daemon-reload; sudo systemctl enable "$AUTH_SERVICE_NAME"; echo "Autostart aktiviert." ;;
        2) sudo systemctl disable "$AUTH_SERVICE_NAME" 2>/dev/null || true; sudo rm -f "/etc/systemd/system/$AUTH_SERVICE_NAME"; sudo systemctl daemon-reload; echo "Autostart deaktiviert." ;;
    esac
}

account_menu() {
    while true; do
        clear; echo "=== Accountverwaltung ==="; echo "1) Accounts anzeigen"; echo "2) Account löschen"; echo "0) Zurück"; read -rp "Auswahl: " choice
        case "$choice" in
            1) mysql_auth --batch --table -e 'SELECT id, username, expansion, locked FROM account ORDER BY id;' ;;
            2) read -rp "Account-ID zum Löschen: " id; [[ "$id" =~ ^[0-9]+$ ]] || { echo "Ungültige ID."; pause_control; continue; }; read -rp "Zum Bestätigen DELETE eingeben: " confirm; [ "$confirm" = DELETE ] && mysql_auth -e "DELETE FROM account WHERE id=$id; DELETE FROM account_access WHERE id=$id;" ;;
            0) return ;;
        esac
        pause_control
    done
}

realm_menu() {
    while true; do
        clear; echo "=== Realmverwaltung ==="; echo "1) Realms anzeigen"; echo "2) Realm-Adresse ändern"; echo "0) Zurück"; read -rp "Auswahl: " choice
        case "$choice" in
            1) mysql_auth --batch --table -e 'SELECT id, name, address, port, flag, gamebuild FROM realmlist ORDER BY id;' ;;
            2) read -rp "Realm-ID: " id; read -rp "Neue Adresse: " address; [[ "$id" =~ ^[0-9]+$ && "$address" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Ungültige Eingabe."; pause_control; continue; }; mysql_auth -e "UPDATE realmlist SET address='$address', localAddress='$address' WHERE id=$id;" ;;
            0) return ;;
        esac
        pause_control
    done
}

menu() {
    while true; do
        menu_title "🔐" "AzerothCore Authserver Control" authserver "$AUTH_SESSION"
        menu_section "Server"
        echo "  1) ▶️  Starten"; echo "  2) ⏹️  Stoppen"; echo "  3) 🔄  Neustart"; echo "  4) 📊  Status"; echo "  5) ⚙️  Autostart"
        menu_section "Wartung"
        echo "  6) ⬇️  Source aktualisieren"; echo "  7) 🔨  Bauen und installieren"; echo "  8) 🧹  Build bereinigen"; echo "  9) 📝  authserver.conf öffnen"
        menu_section "Verwaltung"
        echo " 10) 👤  Accountverwaltung"; echo " 11) 🌐  Realmverwaltung"; echo " 12) 🔄  Control-Skripte aktualisieren"; echo "  0) 🚪  Beenden"
        echo ""; read -rp "Auswahl [0-12]: " choice
        case "$choice" in
            1) start_auth ;; 2) stop_auth ;; 3) restart_auth ;; 4) server_status authserver "$AUTH_SESSION" ;; 5) autostart_auth ;; 6) git -C "$ACORE_DIR" pull --ff-only ;; 7) safe_build "$ACORE_DIR/build" ;; 8) "$SCRIPT_DIR/clean-build.sh" "$ACORE_DIR" ;; 9) nano "$AUTH_CONF" ;; 10) account_menu ;; 11) realm_menu ;; 12) update_control ;; 0) return ;; esac
        pause_control
    done
}

case "${1:-menu}" in
    start) start_auth ;; stop) stop_auth ;; restart) restart_auth ;; status) server_status authserver "$AUTH_SESSION" ;; menu) menu ;; *) echo "Usage: $0 [menu|start|stop|restart|status]"; exit 1 ;;
esac
