#!/bin/bash
################################################################################
#                                                                              #
#    AZEROTHCORE - COMBINED INSTALL SCRIPT                                    #
#    ----------------------------------------------------------------------   #
#    Menu choices:                                                            #
#      1) Basic System   (see "Guide Basic System.md")                       #
#      2) Authserver      - build only (see "2 - Authserver/Guide Authserver.md") #
#      3) Worldserver     - build only (see "3 - Worldserver/Guide Worldserver.md") #
#      4) Bothserver      - Auth + World, one LXC, build only #
#                                                                              #
#    This script mirrors the guides step for step. It is NOT fully           #
#    unattended: at points where the guides require a manual decision        #
#    (DB password, client-data extraction, and hardware-specific tuning)     #
#    files, verifying SSH login) it pauses and asks you to confirm before    #
#    continuing. Automatic MySQL tuning and the final menu start flow are    #
#    flow are intentionally NOT part of this script - see install.md.       #
#                                                                              #
################################################################################

set -euo pipefail

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

pause() {
    echo -e "${CYAN}>> $1${NC}"
    read -rp "   Press Enter to continue... " _
}

confirm() {
    echo -e "${CYAN}>> $1${NC}"
    local ans
    while true; do
        read -rp "   Type 'yes' to confirm when ready: " ans
        [ "$ans" = "yes" ] && break
    done
}

step() {
    echo ""
    echo -e "${GREEN}==============================================================================${NC}"
    echo -e "${GREEN} $1${NC}"
    echo -e "${GREEN}==============================================================================${NC}"
}

warn() {
    echo -e "${RED}$1${NC}"
}

hint() {
    echo -e "${YELLOW}$1${NC}"
}

offer_control_installation() {
    [ "${SKIP_CONTROL_PROMPT:-0}" = 1 ] && return
    echo ""
    read -rp "Control-Menü jetzt optional installieren? [y/N]: " control_choice
    case "$control_choice" in
        y|Y|j|J)
            step "Control-Menü installieren"
            case "${CONTROL_ROLE:-}" in
                auth) CONTROL_ACTION=install CONTROL_ROLE=auth CONTROL_AUTH_DIR="$AUTH_DIR" CONTROL_AUTH_OWNER="$AUTH_OWNER" bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/Control/install.sh" ;;
                world) CONTROL_ACTION=install CONTROL_ROLE=world CONTROL_WORLD_DIR="$WORLD_DIR" CONTROL_WORLD_OWNER="$WORLD_OWNER" bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/Control/install.sh" ;;
                both) CONTROL_ACTION=install CONTROL_ROLE=both CONTROL_AUTH_DIR="$AUTH_DIR" CONTROL_AUTH_OWNER="$AUTH_OWNER" CONTROL_WORLD_DIR="$WORLD_DIR" CONTROL_WORLD_OWNER="$WORLD_OWNER" bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/Control/install.sh" ;;
                *) warn "Control-Rolle konnte nicht bestimmt werden."; return 1 ;;
            esac
            ;;
        *) echo "Control-Menü wird übersprungen. Es kann später über Menüpunkt 5 installiert werden." ;;
    esac
}

require_root_or_sudo() {
    if [ "$EUID" -ne 0 ] && ! sudo -n true 2>/dev/null; then
        warn "This script needs root or passwordless sudo for most steps."
    fi
}

# Auth's and World's mysqld.cnf tuning blocks both use overlapping keys. If
# Auth and World end up on the same LXC, a leftover block from an earlier run
# would silently coexist with a newly generated one. Remove any previous block
# before writing the new hardware-based profile.
strip_existing_mysql_tuning() {
    local cnf="/etc/mysql/mysql.conf.d/mysqld.cnf"
    if [ -f "$cnf" ] && grep -q "MYSQL PERFORMANCE TUNING - AZEROTHCORE" "$cnf"; then
        warn "Vorhandenes AzerothCore-MySQL-Tuning gefunden - der alte Block wird durch das automatisch berechnete Profil ersetzt."
        # Delete from the marker to end of file. A harmless leftover blank
        # line/divider comment right before it may remain - MySQL ignores both.
        sudo sed -i '/MYSQL PERFORMANCE TUNING - AZEROTHCORE/,$d' "$cnf"
    fi
}

format_mysql_size() {
    local SIZE_MB="$1"
    if [ "$SIZE_MB" -ge 1024 ]; then
        echo "$((SIZE_MB / 1024))G"
    else
        echo "${SIZE_MB}M"
    fi
}

generate_mysql_tuning() {
    local PROFILE="$1"
    local CPU_CORES RAM_MB BUFFER_PERCENT BUFFER_MB LOG_BUFFER_MB REDO_MB
    local TMP_MB MAX_CONNECTIONS THREAD_CACHE TABLE_CACHE DEFINITION_CACHE
    local IO_CAPACITY IO_CAPACITY_MAX BUFFER_INSTANCES DISK_TYPE

    CPU_CORES="$(nproc)"
    RAM_MB="$(awk '/MemTotal:/ { printf "%d", $2 / 1024 }' /proc/meminfo)"
    [ "$RAM_MB" -lt 1024 ] && RAM_MB=1024

    case "$PROFILE" in
        auth)
            BUFFER_PERCENT=25
            LOG_BUFFER_MB=16
            TMP_MB=32
            MAX_CONNECTIONS=$((80 + CPU_CORES * 10))
            ;;
        world)
            BUFFER_PERCENT=50
            LOG_BUFFER_MB=64
            TMP_MB=128
            MAX_CONNECTIONS=$((120 + CPU_CORES * 20))
            ;;
        both)
            BUFFER_PERCENT=50
            LOG_BUFFER_MB=64
            TMP_MB=128
            MAX_CONNECTIONS=$((160 + CPU_CORES * 25))
            ;;
        *)
            warn "Unbekanntes MySQL-Tuningprofil: $PROFILE"
            exit 1
            ;;
    esac

    BUFFER_MB=$((RAM_MB * BUFFER_PERCENT / 100))
    [ "$BUFFER_MB" -lt 512 ] && BUFFER_MB=512
    REDO_MB=$((BUFFER_MB / 4))
    [ "$REDO_MB" -lt 256 ] && REDO_MB=256
    [ "$REDO_MB" -gt 2048 ] && REDO_MB=2048

    if [ "$BUFFER_MB" -le 2048 ]; then
        BUFFER_INSTANCES=1
    elif [ "$BUFFER_MB" -le 4096 ]; then
        BUFFER_INSTANCES=2
    elif [ "$BUFFER_MB" -le 8192 ]; then
        BUFFER_INSTANCES=4
    else
        BUFFER_INSTANCES=8
    fi

    [ "$MAX_CONNECTIONS" -lt 80 ] && MAX_CONNECTIONS=80
    THREAD_CACHE=$((CPU_CORES * 16))
    [ "$THREAD_CACHE" -lt 32 ] && THREAD_CACHE=32
    [ "$THREAD_CACHE" -gt 100 ] && THREAD_CACHE=100
    TABLE_CACHE=$((RAM_MB / 4))
    [ "$TABLE_CACHE" -lt 1024 ] && TABLE_CACHE=1024
    [ "$TABLE_CACHE" -gt 8192 ] && TABLE_CACHE=8192
    DEFINITION_CACHE=$((TABLE_CACHE / 2))
    [ "$TMP_MB" -gt $((RAM_MB / 16)) ] && TMP_MB=$((RAM_MB / 16))
    [ "$TMP_MB" -lt 32 ] && TMP_MB=32

    DISK_TYPE="SSD/virtuell"
    IO_CAPACITY=1000
    IO_CAPACITY_MAX=4000
    for rotational_file in /sys/block/*/queue/rotational; do
        if [ -r "$rotational_file" ] && [ "$(cat "$rotational_file")" = "1" ]; then
            DISK_TYPE="HDD/rotierend"
            IO_CAPACITY=200
            IO_CAPACITY_MAX=800
            break
        fi
    done

    sudo mkdir -p /var/log/mysql
    sudo touch /var/log/mysql/slow.log
    sudo chown mysql:mysql /var/log/mysql/slow.log
    strip_existing_mysql_tuning
    sudo tee -a /etc/mysql/mysql.conf.d/mysqld.cnf > /dev/null << EOF

# ==================================================
# MYSQL PERFORMANCE TUNING - AZEROTHCORE ($PROFILE, automatisch)
# Hardware: $CPU_CORES CPU-Kerne / $RAM_MB MB RAM / $DISK_TYPE
# ==================================================
innodb_buffer_pool_size = $(format_mysql_size "$BUFFER_MB")
innodb_buffer_pool_instances = $BUFFER_INSTANCES
innodb_log_buffer_size = $(format_mysql_size "$LOG_BUFFER_MB")
innodb_redo_log_capacity = $(format_mysql_size "$REDO_MB")
innodb_io_capacity = $IO_CAPACITY
innodb_io_capacity_max = $IO_CAPACITY_MAX
innodb_lock_wait_timeout = 50
innodb_deadlock_detect = ON
innodb_flush_log_at_trx_commit = 2
transaction_isolation = READ-COMMITTED
skip-log-bin
tmp_table_size = $(format_mysql_size "$TMP_MB")
max_heap_table_size = $(format_mysql_size "$TMP_MB")
max_connections = $MAX_CONNECTIONS
thread_cache_size = $THREAD_CACHE
table_open_cache = $TABLE_CACHE
table_definition_cache = $DEFINITION_CACHE
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 1
log_queries_not_using_indexes = 0

# END MYSQL PERFORMANCE TUNING - AZEROTHCORE
EOF

    echo "Automatisches MySQL-Tuning ($PROFILE):"
    echo "  Hardware: $CPU_CORES CPU-Kerne, $RAM_MB MB RAM, $DISK_TYPE"
    echo "  InnoDB Buffer Pool: $(format_mysql_size "$BUFFER_MB")"
    echo "  Max Connections: $MAX_CONNECTIONS"
    echo "  I/O Capacity: $IO_CAPACITY / $IO_CAPACITY_MAX"
}

################################################################################
# 1. BASIC SYSTEM
################################################################################
collect_basic_inputs() {
    step "1. Vorbereitung und Eingaben"
    confirm "Ist das Debian-LXC mit deinen eigenen Vorbereitungen und Anpassungen fertig eingerichtet?"

    echo "Bitte die Zeitzone über das folgende Menü auswählen:"
    SERVER_TIMEZONE="$(tzselect)"
    if [ -z "$SERVER_TIMEZONE" ]; then
        warn "Keine Zeitzone ausgewählt."
        exit 1
    fi

    while true; do
        read -rp "Administrationsbenutzer: " ADMIN_USER
        if [[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*\$?$ ]]; then break; fi
        warn "Ungültiger Linux-Benutzername. Verwende Kleinbuchstaben, Zahlen, '_' oder '-'."
    done
    while true; do
        read -rsp "Passwort für '$ADMIN_USER': " ADMIN_PASS; echo ""
        read -rsp "Passwort wiederholen: " ADMIN_PASS_CONFIRM; echo ""
        [ "$ADMIN_PASS" = "$ADMIN_PASS_CONFIRM" ] && break
        warn "Die Passwörter stimmen nicht überein. Bitte erneut eingeben."
    done
    unset ADMIN_PASS_CONFIRM
}

collect_auth_inputs() {
    local DEFAULT_OWNER
    DEFAULT_OWNER="${SUDO_USER:-$(whoami)}"
    read -rp "Besitzer für den Authserver-Ordner [$DEFAULT_OWNER]: " AUTH_OWNER
    AUTH_OWNER=${AUTH_OWNER:-$DEFAULT_OWNER}
    read -rp "Installationspfad für den Authserver [/opt/ac-authserver]: " AUTH_DIR
    AUTH_DIR=${AUTH_DIR:-/opt/ac-authserver}
    read -rp "AzerothCore-Branch für den Authserver [master]: " AUTH_BRANCH
    AUTH_BRANCH=${AUTH_BRANCH:-master}
}

collect_world_inputs() {
    local DEFAULT_OWNER
    DEFAULT_OWNER="${SUDO_USER:-$(whoami)}"
    read -rp "Besitzer für den Worldserver-Ordner [$DEFAULT_OWNER]: " WORLD_OWNER
    WORLD_OWNER=${WORLD_OWNER:-$DEFAULT_OWNER}
    read -rp "Installationspfad für den Worldserver [/opt/ac-worldserver]: " WORLD_DIR
    WORLD_DIR=${WORLD_DIR:-/opt/ac-worldserver}
    read -rp "AzerothCore-Branch für den Worldserver [Playerbot]: " WORLD_BRANCH
    WORLD_BRANCH=${WORLD_BRANCH:-Playerbot}
}

collect_database_password() {
    while true; do
        read -rsp "Passwort für den MySQL-Benutzer 'acore': " DB_PASS
        echo ""
        read -rsp "Passwort wiederholen: " DB_PASS_CONFIRM
        echo ""
        [ "$DB_PASS" = "$DB_PASS_CONFIRM" ] && break
        warn "Die Passwörter stimmen nicht überein. Bitte erneut eingeben."
    done
    unset DB_PASS_CONFIRM
}

install_motd_template() {
    sudo tee /usr/local/bin/dynamic-motd.sh > /dev/null << 'EOF'
#!/usr/bin/env bash
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
USER_NAME=$(whoami); HOST_NAME=$(hostname | tr '[:lower:]' '[:upper:]')
OS_NAME=$(grep '^PRETTY_NAME=' /etc/os-release | cut -d'"' -f2)
UPTIME=$(uptime -p | sed 's/up //'); LOAD=$(cut -d' ' -f1-3 /proc/loadavg)
MEM_USED=$(free -h | awk '/^Mem:/ {print $3}'); MEM_TOTAL=$(free -h | awk '/^Mem:/ {print $2}')
SWAP_USED=$(free -h | awk '/^Swap:/ {print $3}'); SWAP_TOTAL=$(free -h | awk '/^Swap:/ {print $2}')
DISK_USED=$(df -h / | awk 'NR==2 {print $3}'); DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')
IP_ADDR=$(hostname -I | awk '{print $1}'); CORES=$(nproc)
[ "$SWAP_TOTAL" = "0B" ] || [ -z "$SWAP_TOTAL" ] && SWAP_DISPLAY="None" || SWAP_DISPLAY="${SWAP_USED} / ${SWAP_TOTAL}"
echo; echo -e "  🌐   ${YELLOW}${HOST_NAME}${NC}"; echo -e "${YELLOW}------------------------------------------------------------${NC}"; echo
echo -e "${GREEN}  👤  User:    ${NC}${USER_NAME}"; echo -e "${GREEN}  🐧  OS:      ${NC}${OS_NAME}"; echo -e "${GREEN}  🔢  IP:      ${NC}${IP_ADDR}"
echo -e "${GREEN}  🕒  Uptime:  ${NC}${UPTIME}"; echo -e "${GREEN}  🧠  Cores:   ${NC}${CORES}"; echo -e "${GREEN}  📊  Load:    ${NC}${LOAD}"
echo -e "${GREEN}  💾  Memory:  ${NC}${MEM_USED} / ${MEM_TOTAL}"; echo -e "${GREEN}  🔄  Swap:    ${NC}${SWAP_DISPLAY}"; echo -e "${GREEN}  💽  Disk:    ${NC}${DISK_USED} / ${DISK_TOTAL}"; echo
EOF
    sudo chmod +x /usr/local/bin/dynamic-motd.sh
    sudo tee /etc/profile.d/dynamic-motd.sh > /dev/null << 'EOF'
#!/usr/bin/env bash
[ -x /usr/local/bin/dynamic-motd.sh ] && /usr/local/bin/dynamic-motd.sh
EOF
    sudo chmod +x /etc/profile.d/dynamic-motd.sh
    sudo truncate -s 0 /etc/motd
}

ensure_hostname_resolution() {
    local CURRENT_HOSTNAME
    CURRENT_HOSTNAME="$(hostname)"
    if ! awk -v hostname="$CURRENT_HOSTNAME" \
        '$1 ~ /^127\./ { for (i = 2; i <= NF; i++) if ($i == hostname) found = 1 } END { exit !found }' \
        /etc/hosts; then
        printf '127.0.1.1\t%s\n' "$CURRENT_HOSTNAME" >> /etc/hosts
        echo "Hostname '$CURRENT_HOSTNAME' in /etc/hosts ergänzt."
    fi
}

print_basic_checklist() {
    step "Abschluss-Checkliste"
    echo "[x] Allgemeine Vorbereitung des LXC bestätigt"
    echo "[x] System aktualisiert und Basiswerkzeuge installiert"
    echo "[x] Lokale Hostname-Auflösung geprüft"
    echo "[x] Zeitzone auf '$SERVER_TIMEZONE' gesetzt"
    echo "[x] Administrationskonto '$ADMIN_USER' eingerichtet und für sudo autorisiert"
    echo "[x] Dynamisches MOTD-Template installiert"
    echo "[x] SSH aktiviert und Root-Login per SSH deaktiviert"
    echo "[x] Fail2Ban für SSH aktiviert"
    echo "[x] SSH- und sudo-Zugang bestätigt"
    echo "[x] Root-Passwort gesperrt"
}

run_basic_system() {
    collect_basic_inputs
    step "2. Debian-Grundsystem"
    apt update && apt full-upgrade -y
    apt install -y sudo htop curl wget nano unattended-upgrades screen tmux net-tools iproute2 unzip git iputils-ping glances openssh-server fail2ban locales

    ensure_hostname_resolution

    if ! timedatectl list-timezones | grep -Fxq "$SERVER_TIMEZONE"; then
        warn "Unbekannte Zeitzone: $SERVER_TIMEZONE"; exit 1
    fi
    timedatectl set-timezone "$SERVER_TIMEZONE"
    step "3. Administrationskonto einrichten"
    echo "Das Administrationskonto wird angelegt beziehungsweise aktualisiert"
    echo "und für die Verwendung von sudo freigeschaltet."
    echo "Verwendeter Account: $ADMIN_USER"
    id "$ADMIN_USER" &>/dev/null || useradd --create-home --shell /bin/bash "$ADMIN_USER"
    printf '%s:%s\n' "$ADMIN_USER" "$ADMIN_PASS" | chpasswd
    unset ADMIN_PASS
    usermod -aG sudo "$ADMIN_USER"

    step "4. Dynamisches MOTD"
    install_motd_template
    echo "Das MOTD-Template wurde installiert."
    echo ""
    echo "Testausgabe des MOTD:"
    /usr/local/bin/dynamic-motd.sh

    step "5. SSH absichern"
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    systemctl enable ssh; systemctl restart ssh

    step "6. Fail2Ban für SSH konfigurieren"
    cat << 'EOF' > /etc/fail2ban/jail.d/ssh.local
[sshd]
enabled  = true
port     = ssh
backend  = systemd
maxretry = 5
bantime  = 600
findtime = 600
EOF
    systemctl enable fail2ban; systemctl restart fail2ban; sleep 2; fail2ban-client status

    step "7. Zugang testen"
    echo "Öffne ein NEUES Terminal und teste die SSH-Anmeldung als '$ADMIN_USER'."
    echo "Prüfe außerdem, ob 'sudo -i' funktioniert."
    pause "Erst nach erfolgreichem SSH- und sudo-Test fortfahren."

    step "8. Root-Passwort sperren"
    sudo passwd -l root
    print_basic_checklist
    echo ""
    hint "Das Basissystem ist vorbereitet. Ergänze das System jetzt noch um deine eigenen"
    hint "Installationen, Dienste und projektspezifischen Anpassungen, bevor du fortfährst."
}

################################################################################
# 2. AUTHSERVER
################################################################################
run_authserver() {
    step "1. Update system packages"
    sudo apt update && sudo apt full-upgrade -y

    step "2. Clone source code"
    sudo mkdir -p "$AUTH_DIR"
    sudo chown "$AUTH_OWNER:$AUTH_OWNER" "$AUTH_DIR"
    cd "$AUTH_DIR"
    git clone https://github.com/azerothcore/azerothcore-wotlk.git --branch="$AUTH_BRANCH" .

    step "3. Install dependencies"
    OSDISTRO="$(. /etc/os-release && echo "$ID")"
    echo "Detected distro: $OSDISTRO"
    sed -i "s/^#\s*OSDISTRO=.*/OSDISTRO=\"$OSDISTRO\"/" "$AUTH_DIR/conf/dist/config.sh"
    ./acore.sh install-deps

    step "4. Create and enter the build directory"
    mkdir -p build
    cd build

    step "5. Run CMake configure"
    cmake ../ \
      -DCMAKE_INSTALL_PREFIX="$AUTH_DIR/env/dist" \
      -DAPPS_BUILD=auth-only \
      -DTOOLS_BUILD=none \
      -DSCRIPTS=none
    confirm "Scale up Proxmox resources (CPU/RAM) for this LXC now, then confirm."

    step "6. Build and install"
    make -j "$(nproc)"
    make install
    confirm "Scale Proxmox resources back down now, then confirm."

    step "7. Folder structure and config files"
    cp "$AUTH_DIR/env/dist/etc/authserver.conf.dist" "$AUTH_DIR/env/dist/etc/authserver.conf"
    echo "authserver.conf created: $AUTH_DIR/env/dist/etc/authserver.conf"

    step "8. MySQL 8.4 configuration"
    sudo tee /etc/mysql/mysql.conf.d/azcore_limits.cnf > /dev/null << 'EOF'
[mysqld]
bind-address            = 0.0.0.0
mysqlx-bind-address     = 0.0.0.0
disable_log_bin
mysql_native_password   = ON
EOF
    echo "MySQL config written: /etc/mysql/mysql.conf.d/azcore_limits.cnf"
    sudo systemctl restart mysql
    echo "MySQL restarted."

    step "9. Automatisches MySQL-Tuning"
    generate_mysql_tuning "${TUNING_PROFILE:-auth}"
    sudo systemctl restart mysql

    step "10. Create databases and MySQL user"
    sudo mysql -u root << EOF
CREATE USER IF NOT EXISTS 'acore'@'localhost' IDENTIFIED WITH mysql_native_password BY '$DB_PASS';
CREATE USER IF NOT EXISTS 'acore'@'%' IDENTIFIED WITH mysql_native_password BY '$DB_PASS';

GRANT ALL PRIVILEGES ON *.* TO 'acore'@'localhost' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'acore'@'%' WITH GRANT OPTION;

FLUSH PRIVILEGES;
EOF
    step "11. Final step"
    echo "The Authserver build and database setup are complete."
    echo "Management scripts and the final 'authmenu' start flow are handled separately."
    CONTROL_ROLE=auth offer_control_installation
}

################################################################################
# 3. WORLDSERVER
################################################################################
run_worldserver() {
    step "1. Update system packages"
    sudo apt update && sudo apt full-upgrade -y

    step "2. Clone source code and Playerbots module"
    sudo mkdir -p "$WORLD_DIR"
    sudo chown "$WORLD_OWNER:$WORLD_OWNER" "$WORLD_DIR"

    cd "$WORLD_DIR"
    git clone https://github.com/mod-playerbots/azerothcore-wotlk.git --branch="$WORLD_BRANCH" .

    cd "$WORLD_DIR/modules"
    git clone https://github.com/mod-playerbots/mod-playerbots.git --branch=master

    step "3. Install dependencies"
    OSDISTRO="$(. /etc/os-release && echo "$ID")"
    echo "Detected distro: $OSDISTRO"
    sed -i "s/^#\s*OSDISTRO=.*/OSDISTRO=\"$OSDISTRO\"/" "$WORLD_DIR/conf/dist/config.sh"
    cd "$WORLD_DIR"
    ./acore.sh install-deps

    step "4. Create and enter the build directory"
    mkdir -p build
    cd build

    step "5. Run CMake configure"
    cmake ../ \
      -DCMAKE_INSTALL_PREFIX="$WORLD_DIR/env/dist" \
      -DAPPS_BUILD=world-only \
      -DSCRIPTS=static \
      -DTOOLS_BUILD=none
    confirm "Scale up Proxmox resources (CPU/RAM) for this LXC now, then confirm."

    step "6. Build and install"
    make -j "$(nproc)"
    make install
    confirm "Scale Proxmox resources back down now, then confirm."

    step "7. Extract client data"
    pause "If extracting from your own 3.3.5a client, put the files in place now before the assistant starts. The assistant also offers to download pre-extracted maps/vmaps/mmaps/dbc instead, if you don't have a local client."
    cd "$WORLD_DIR"
    ./acore.sh client-data

    step "8. Folder structure and config files"
    cp "$WORLD_DIR/env/dist/etc/worldserver.conf.dist" "$WORLD_DIR/env/dist/etc/worldserver.conf"
    echo -e "\nAllowTwoSide.WhoList = 1" >> "$WORLD_DIR/env/dist/etc/worldserver.conf"
    cp "$WORLD_DIR/env/dist/etc/modules/playerbots.conf.dist" "$WORLD_DIR/env/dist/etc/modules/playerbots.conf"
    echo "worldserver.conf and playerbots.conf created."

    step "9. MySQL 8.4 configuration"
    sudo tee /etc/mysql/mysql.conf.d/acore_limits.cnf > /dev/null << 'EOF'
[mysqld]
bind-address            = 0.0.0.0
mysqlx-bind-address     = 0.0.0.0
disable_log_bin
mysql_native_password   = ON
EOF
    echo "MySQL config written: /etc/mysql/mysql.conf.d/acore_limits.cnf"
    sudo systemctl restart mysql
    echo "MySQL restarted."

    step "10. Automatisches MySQL-Tuning"
    generate_mysql_tuning "${TUNING_PROFILE:-world}"
    sudo mkdir -p /var/log/mysql
    sudo touch /var/log/mysql/slow.log
    sudo chown mysql:mysql /var/log/mysql/slow.log
    sudo systemctl restart mysql

    step "11. Create databases and MySQL user"
    sudo mysql -u root << EOF
CREATE USER IF NOT EXISTS 'acore'@'localhost' IDENTIFIED WITH mysql_native_password BY '$DB_PASS';
CREATE USER IF NOT EXISTS 'acore'@'%' IDENTIFIED WITH mysql_native_password BY '$DB_PASS';

GRANT ALL PRIVILEGES ON *.* TO 'acore'@'localhost' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'acore'@'%' WITH GRANT OPTION;

FLUSH PRIVILEGES;
EOF
    step "12. Final step"
    echo "The Worldserver build and database setup are complete."
    echo "Management scripts and the final 'worldmenu' start flow are handled separately."
    CONTROL_ROLE=world offer_control_installation
}

################################################################################
# 4. BOTHSERVER (Auth + World on one LXC)
################################################################################
run_bothserver() {
    TUNING_PROFILE=both
    SKIP_CONTROL_PROMPT=1
    step "Bothserver: Authserver"
    run_authserver
    step "Bothserver: Worldserver"
    run_worldserver
    unset SKIP_CONTROL_PROMPT
    unset TUNING_PROFILE
    CONTROL_ROLE=both offer_control_installation
}


################################################################################
# MAIN MENU
################################################################################
main() {
    require_root_or_sudo

    echo ""
    echo ""
    echo -e "${CYAN}################################################################################${NC}"
    echo -e "${CYAN}#  AZEROTHCORE - COMBINED INSTALL SCRIPT                                      #${NC}"
    echo -e "${CYAN}################################################################################${NC}"
    echo ""
    echo "  1) 🧱  Basic System   (Debian base setup, security, Fail2Ban)"
    echo "  2) 🔐  Authserver     (Auth & MySQL 8.4 database server - build only)"
    echo "  3) 🌍  Worldserver    (Worldserver incl. Playerbots - build only)"
    echo "  4) 🔗  Bothserver     (Auth + World auf einer gemeinsamen LXC)"
    echo "  5) 🛠️  Control        (eigene Auth-/Worldserver-Verwaltung installieren)"
    echo ""
    warn "Hinweis: Punkt 1 zuerst abschließen. Punkt 5 folgt nach dem Server-Build."
    echo ""
    read -rp "Choice [1-5]: " choice

    case "$choice" in
        2|3|4)
            confirm "Wurde Installpunkt 1 (Basic System) vollständig abgeschlossen?"
            ;;
    esac

    case "$choice" in
        1)
            run_basic_system
            ;;
        2)
            collect_auth_inputs
            collect_database_password
            run_authserver
            ;;
        3)
            collect_world_inputs
            collect_database_password
            run_worldserver
            ;;
        4)
            collect_auth_inputs
            collect_world_inputs
            collect_database_password
            run_bothserver
            ;;
        5)
            step "5. AzerothCore Control installieren"
            confirm "Wurde der benötigte Auth- oder Worldserver bereits installiert und gebaut?"
            bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/Control/install.sh"
            ;;
        *) warn "Invalid choice."; exit 1 ;;
    esac

    unset DB_PASS

    echo ""
    echo -e "${GREEN}DONE.${NC}"
}

main "$@"
