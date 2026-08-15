#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

update_control() {
    require_path "$CONTROL_SOURCE_DIR/common.sh"
    sudo install -m 0755 "$CONTROL_SOURCE_DIR/common.sh" "$SCRIPT_DIR/common.sh"
    sudo install -m 0755 "$CONTROL_SOURCE_DIR/world-menu.sh" "$SCRIPT_DIR/world-menu.sh"
    sudo install -m 0755 "$CONTROL_SOURCE_DIR/clean-build.sh" "$SCRIPT_DIR/clean-build.sh"
    sudo chown "$SERVER_USER:$SERVER_USER" "$SCRIPT_DIR"/*.sh
    echo "World-Control-Skripte aktualisiert."
}

WORLD_ENGINE="${WORLD_ENGINE:-$ACORE_DIR/apps/startup-scripts/src/run-engine}"
WORLD_BINARY="${WORLD_BINARY:-$ACORE_DIR/env/dist/bin/worldserver}"
WORLD_CONF="${WORLD_CONF:-$ACORE_DIR/env/dist/etc/worldserver.conf}"
PLAYERBOTS_CONF="${PLAYERBOTS_CONF:-$ACORE_DIR/env/dist/etc/modules/playerbots.conf}"
WORLD_SESSION="${WORLD_SESSION:-world-session}"
WORLD_SERVICE_NAME="${WORLD_SERVICE_NAME:-azerothcore-world.service}"

start_world() {
    require_path "$WORLD_ENGINE" || return 0
    require_path "$WORLD_BINARY" || return 0
    require_path "$WORLD_CONF" || return 0
    if tmux has-session -t "$WORLD_SESSION" 2>/dev/null; then echo "Worldserver läuft bereits."; return; fi
    tmux new-session -d -s "$WORLD_SESSION" "cd '$ACORE_DIR' && '$WORLD_ENGINE' start '$WORLD_BINARY' --server-config '$WORLD_CONF' --session-manager none"
    echo "Worldserver gestartet."
}

stop_world() {
    if pgrep -x worldserver >/dev/null 2>&1; then
        pkill -TERM -x worldserver
        for _ in $(seq 1 90); do pgrep -x worldserver >/dev/null 2>&1 || break; sleep 1; done
    fi
    tmux kill-session -t "$WORLD_SESSION" 2>/dev/null || true
    pgrep -x worldserver >/dev/null 2>&1 && { echo "Worldserver reagiert nicht; kein automatischer KILL."; return 1; }
    echo "Worldserver gestoppt."
}

restart_world() { stop_world; start_world; }

autostart_world() {
    echo "1) Autostart aktivieren"; echo "2) Autostart deaktivieren"; read -rp "Auswahl [1-2]: " choice
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
TimeoutStopSec=180

[Install]
WantedBy=multi-user.target
EOF
            sudo systemctl daemon-reload; sudo systemctl enable "$WORLD_SERVICE_NAME"; echo "Autostart aktiviert." ;;
        2) sudo systemctl disable "$WORLD_SERVICE_NAME" 2>/dev/null || true; sudo rm -f "/etc/systemd/system/$WORLD_SERVICE_NAME"; sudo systemctl daemon-reload; echo "Autostart deaktiviert." ;;
    esac
}

save_world() {
    if tmux has-session -t "$WORLD_SESSION" 2>/dev/null; then
        tmux send-keys -t "$WORLD_SESSION" '.server saveall' Enter
        echo "Save-Befehl an den Worldserver gesendet."
    else
        echo "Keine aktive Worldserver-tmux-Session gefunden."
    fi
}

delete_account() {
    read_login_database || { echo "LoginDatabaseInfo konnte nicht gelesen werden."; return 1; }
    read -rp "Account-ID zum Löschen: " id
    [[ "$id" =~ ^[0-9]+$ ]] || { echo "Ungültige Account-ID."; return 1; }
    read -rp "Zum Bestätigen DELETE eingeben: " confirm
    [ "$confirm" = DELETE ] && mysql_auth -e "DELETE FROM account WHERE id=$id; DELETE FROM account_access WHERE id=$id;" && echo "Account gelöscht."
}

patch_file() {
    local file="$1" overrides="$2" label="$3" stamp
    require_path "$file"; require_path "$overrides"
    nano "$overrides"
    stamp="$(date +%Y%m%d%H%M%S)"
    cp "$file" "$file.bak.$stamp"
    sed -i '/^# CONTROL PATCH BEGIN$/,/^# CONTROL PATCH END$/d' "$file"
    {
        echo '# CONTROL PATCH BEGIN'
        awk '/^[[:space:]]*[A-Za-z0-9_.-]+[[:space:]]*=/{print}' "$overrides"
        echo '# CONTROL PATCH END'
    } >> "$file"
    echo "$label aktualisiert. Sicherung: $file.bak.$stamp"
}

restart_timer() {
    echo "1) Timer anzeigen"; echo "2) Timer aktivieren/ändern"; echo "3) Timer deaktivieren"
    read -rp "Auswahl [1-3]: " choice
    case "$choice" in
        1) systemctl status "$WORLD_TIMER_NAME" --no-pager 2>/dev/null || echo "Kein Timer eingerichtet." ;;
        2) read -rp "Tägliche Neustartzeit (HH:MM): " time
           [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "Ungültige Uhrzeit."; return; }
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
           sudo systemctl daemon-reload; sudo systemctl enable --now "$WORLD_TIMER_NAME"; echo "Timer aktiviert: täglich um $time" ;;
        3) sudo systemctl disable --now "$WORLD_TIMER_NAME" 2>/dev/null || true; echo "Timer deaktiviert." ;;
    esac
}

menu() {
    while true; do
        menu_title "🌍" "AzerothCore Worldserver Control" worldserver "$WORLD_SESSION"
        menu_section "Server"
        echo "  1) ▶️  Starten"; echo "  2) ⏹️  Stoppen"; echo "  3) 🔄  Neustart"; echo "  4) 📊  Status"; echo "  5) ⚙️  Autostart"; echo "  6) ⏱️  Neustart-Timer"
        menu_section "Welt und Wartung"
        echo "  7) 💾  Welt speichern"; echo "  8) ⬇️  Source und Playerbots aktualisieren"; echo "  9) 🔨  Bauen und installieren"; echo " 10) 🧹  Build bereinigen"
        menu_section "Verwaltung und Konfiguration"
        echo " 11) 👤  Account löschen"; echo " 12) 📝  worldserver.conf patchen"; echo " 13) 📝  playerbots.conf patchen"; echo " 14) 🔄  Control-Skripte aktualisieren"; echo "  0) 🚪  Beenden"
        echo ""; read -rp "Auswahl [0-14]: " choice
        case "$choice" in
            1) start_world ;; 2) stop_world ;; 3) restart_world ;; 4) server_status worldserver "$WORLD_SESSION" ;; 5) autostart_world ;; 6) restart_timer ;; 7) save_world ;; 8) git -C "$ACORE_DIR" pull --ff-only; git -C "$ACORE_DIR/modules/mod-playerbots" pull --ff-only ;; 9) safe_build "$ACORE_DIR/build" ;; 10) "$SCRIPT_DIR/clean-build.sh" "$ACORE_DIR" ;; 11) delete_account ;; 12) patch_file "$WORLD_CONF" "$SCRIPT_DIR/worldserver.overrides.conf" "worldserver.conf" ;; 13) patch_file "$PLAYERBOTS_CONF" "$SCRIPT_DIR/playerbots.overrides.conf" "playerbots.conf" ;; 14) update_control ;; 0) return ;; esac
        pause_control
    done
}

case "${1:-menu}" in
    start) start_world ;; stop) stop_world ;; restart) restart_world ;; status) server_status worldserver "$WORLD_SESSION" ;; menu) menu ;; *) echo "Usage: $0 [menu|start|stop|restart|status]"; exit 1 ;;
esac
