#!/bin/bash
################################################################################
#                                                                              #
#    AZEROTHCORE - COMBINED INSTALL SCRIPT                                    #
#    ----------------------------------------------------------------------   #
#    Menu choices:                                                            #
#      1) Basic System   (see "Guide Basic System.md")                       #
#      2) Authserver      - build + InnControl scripts (see "2 - Authserver/Guide Authserver.md") #
#      3) Worldserver     - build + InnControl scripts (see "3 - Worldserver/Guide Worldserver.md") #
#      4) Bothserver      - Auth + World, one LXC, build + InnControl scripts #
#      5) Authscript      - ACore InnControl management scripts only (Auth)  #
#      6) Worldscripts    - ACore InnControl management scripts only (World) #
#      7) Both Scripts    - ACore InnControl management scripts only, Auth+World #
#                                                                              #
#    This script mirrors the guides step for step. It is NOT fully           #
#    unattended: at points where the guides require a manual decision        #
#    (DB password, client-data extraction, placing MOTD/dynamic-motd        #
#    files, verifying SSH login) it pauses and asks you to confirm before    #
#    continuing. Hardware-specific MySQL tuning and the final menu start     #
#    flow are intentionally NOT part of this script - see install.md.       #
#                                                                              #
################################################################################

set -euo pipefail

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
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

notice() {
    echo ""
    echo -e "${RED}==============================================================================${NC}"
    echo -e "${RED} $1${NC}"
    echo -e "${RED}==============================================================================${NC}"
}

require_root_or_sudo() {
    if [ "$EUID" -ne 0 ] && ! sudo -n true 2>/dev/null; then
        warn "This script needs root or passwordless sudo for most steps."
    fi
}

# Auth's and World's mysqld.cnf tuning templates both append (tee -a) to the
# same file with overlapping keys. If Auth and World end up on the same LXC
# (Bothserver, or one installed after the other), a leftover block from an
# earlier run would silently coexist with a newly pasted one - MySQL then
# just uses whichever occurrence comes last, discarding the other. Strip any
# previous block before the operator pastes a new (ideally combined) one, so
# there's never more than one tuning block active regardless of install order.
strip_existing_mysql_tuning() {
    local cnf="/etc/mysql/mysql.conf.d/mysqld.cnf"
    if [ -f "$cnf" ] && grep -q "MYSQL PERFORMANCE TUNING - AZEROTHCORE" "$cnf"; then
        warn "Found an existing MySQL tuning block (from a previous Auth/World install on this LXC) - removing it now so you can paste a fresh (combined, if co-located) block below instead of appending a duplicate."
        # Delete from the marker to end of file. A harmless leftover blank
        # line/divider comment right before it may remain - MySQL ignores both.
        sudo sed -i '/MYSQL PERFORMANCE TUNING - AZEROTHCORE/,$d' "$cnf"
    fi
}

################################################################################
# 1. BASIC SYSTEM
################################################################################
run_basic_system() {
    step "0. Proxmox: LXC autostart + WoW-Bridge network"
    pause "In the Proxmox web UI: enable 'Start at boot' for this LXC, add the WoW-Bridge (vmbr_wow) network interface with a static 10.20.10.0/24 IP, paste this LXC's 'LXC Notes <Name>.md' HTML block into Summary > Notes, and create a snapshot named 'Fresh_Install', then continue here."

    step "1. System update and base packages, including Fail2Ban"
    apt update && apt full-upgrade -y
    apt install -y \
      sudo \
      htop \
      curl \
      wget \
      nano \
      unattended-upgrades \
      screen \
      tmux \
      net-tools \
      iproute2 \
      unzip \
      git \
      iputils-ping \
      glances \
      openssh-server \
      fail2ban \
      locales

    timedatectl set-timezone Europe/Berlin

    notice "2. Create and authorize the admin user"
    if id admin &>/dev/null; then
        echo "User 'admin' already exists, skipping creation."
    else
        adduser admin --gecos ""
    fi
    usermod -aG sudo admin

    step "3. SSH security: disable root login"
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config

    systemctl enable ssh
    systemctl restart ssh

    step "4. Configure Fail2Ban for SSH"
    cat << 'EOF' > /etc/fail2ban/jail.d/ssh.local
[sshd]
enabled  = true
port     = ssh
backend  = systemd
maxretry = 5
bantime  = 600
findtime = 600
EOF

    systemctl enable fail2ban
    systemctl restart fail2ban
    sleep 2
    fail2ban-client status

    notice "5. Appearance and comfort for root and admin"
    echo "Adjust container name/color/icon in Proxmox now."
    echo "Paste the 'sudo tee ... EOF' block from this LXC's 'MOTD <Name>.md' below, then type 'exit' to continue."
    bash
    cat /dev/null > /etc/motd
    chmod +x /usr/local/bin/dynamic-motd.sh
    echo "/usr/local/bin/dynamic-motd.sh" >> ~/.bashrc
    echo "/usr/local/bin/dynamic-motd.sh" >> /home/admin/.bashrc

    notice "6. Install Patchmon bot"
    echo "Paste/run the Patchmon install command below (if desired), then type 'exit' to continue."
    bash

    notice "7. Final step: lock root password"
    echo "Setup is almost finished."
    echo "Before locking root: test SSH login as 'admin' in a NEW terminal window."
    echo "Verify that 'sudo -i' works as admin."
    pause "Only continue once the admin login and sudo -i are confirmed."

    passwd -l root
    echo ""
    echo "Root password locked."

    notice "8. Log in again as admin"
    echo "Log in again as 'admin' now and update LXC Notes."
}

################################################################################
# 2. AUTHSERVER
################################################################################
run_authserver() {
    step "1. Update system packages"
    sudo apt update && sudo apt full-upgrade -y

    notice "2. Clone source code"
    read -rp "Owner for the auth folder [${SUDO_USER:-$(whoami)}]: " OWNER_USER
    OWNER_USER=${OWNER_USER:-${SUDO_USER:-$(whoami)}}
    read -rp "Install path [/opt/ac-authserver]: " AUTH_DIR
    AUTH_DIR=${AUTH_DIR:-/opt/ac-authserver}
    sudo mkdir -p "$AUTH_DIR"
    sudo chown "$OWNER_USER:$OWNER_USER" "$AUTH_DIR"
    cd "$AUTH_DIR"
    git clone https://github.com/azerothcore/azerothcore-wotlk.git --branch=master .

    step "3. Install dependencies"
    OSDISTRO="$(. /etc/os-release && echo "$ID")"
    echo "Detected distro: $OSDISTRO"
    sed -i "s/^#\s*OSDISTRO=.*/OSDISTRO=\"$OSDISTRO\"/" "$AUTH_DIR/conf/dist/config.sh"
    ./acore.sh install-deps

    step "4. Create and enter the build directory"
    mkdir -p build
    cd build

    notice "5. Run CMake configure"
    cmake ../ \
      -DCMAKE_INSTALL_PREFIX="$AUTH_DIR/env/dist" \
      -DAPPS_BUILD=auth-only \
      -DTOOLS_BUILD=none \
      -DSCRIPTS=none
    confirm "Scale up Proxmox resources (CPU/RAM) for this LXC now, then confirm."

    notice "6. Build and install"
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

    notice "9. Hardware-specific MySQL tuning"
    strip_existing_mysql_tuning
    echo "Match template '2 - Authserver/Auth Settings/mysqld Authserver.cnf' against this LXC's cores/RAM."
    echo "If Worldserver is already on this LXC, size this for the whole box (combined), not Auth alone."
    echo "Edit /etc/mysql/mysql.conf.d/mysqld.cnf below, then type 'exit' to continue."
    bash
    sudo systemctl restart mysql

    notice "10. Create databases and MySQL user"
    read -rsp "Set the DB password for the 'acore' MySQL user: " DB_PASS
    echo ""
    sudo mysql -u root << EOF
CREATE USER IF NOT EXISTS 'acore'@'localhost' IDENTIFIED WITH mysql_native_password BY '$DB_PASS';
CREATE USER IF NOT EXISTS 'acore'@'%' IDENTIFIED WITH mysql_native_password BY '$DB_PASS';

GRANT ALL PRIVILEGES ON *.* TO 'acore'@'localhost' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'acore'@'%' WITH GRANT OPTION;

FLUSH PRIVILEGES;
EOF
    unset DB_PASS

    notice "11. Install management scripts"
    run_authscript

    notice "12. Final start"
    echo "Run 'source ~/.bashrc' (or re-login) so the 'authmenu' alias is active."
    echo "The 'authmenu' start flow is not part of this script - see install.md."
}

################################################################################
# 5. AUTHSCRIPT (management scripts only)
################################################################################
run_authscript() {
    notice "Install management scripts (Authserver)"
    echo "ACore InnControl (separate repo) will be cloned to /tmp/acore-inncontrol and installed."
    rm -rf /tmp/acore-inncontrol
    git clone https://gitlab.com/grassnotfound/acore-inncontrol.git /tmp/acore-inncontrol
    # Only prefix with sudo if we're not root yet - a nested sudo call while
    # already root resets SUDO_USER to "root", breaking InnControl's
    # alias/ownership default for the actual admin user.
    if [ "$EUID" -eq 0 ]; then
        bash /tmp/acore-inncontrol/install.sh auth
    else
        sudo bash /tmp/acore-inncontrol/install.sh auth
    fi
    echo "Set the DB password for the 'acore' MySQL user in values_auth.conf's LoginDatabaseInfo."
}

################################################################################
# 3. WORLDSERVER
################################################################################
run_worldserver() {
    step "1. Update system packages"
    sudo apt update && sudo apt full-upgrade -y

    notice "2. Clone source code and Playerbots module"
    read -rp "Owner for the world folder [${SUDO_USER:-$(whoami)}]: " OWNER_USER
    OWNER_USER=${OWNER_USER:-${SUDO_USER:-$(whoami)}}
    read -rp "Install path [/opt/ac-worldserver]: " WORLD_DIR
    WORLD_DIR=${WORLD_DIR:-/opt/ac-worldserver}
    sudo mkdir -p "$WORLD_DIR"
    sudo chown "$OWNER_USER:$OWNER_USER" "$WORLD_DIR"

    cd "$WORLD_DIR"
    git clone https://github.com/mod-playerbots/azerothcore-wotlk.git --branch=Playerbot .

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

    notice "5. Run CMake configure"
    cmake ../ \
      -DCMAKE_INSTALL_PREFIX="$WORLD_DIR/env/dist" \
      -DAPPS_BUILD=world-only \
      -DSCRIPTS=static \
      -DTOOLS_BUILD=none
    confirm "Scale up Proxmox resources (CPU/RAM) for this LXC now, then confirm."

    notice "6. Build and install"
    make -j "$(nproc)"
    make install
    confirm "Scale Proxmox resources back down now, then confirm."

    notice "7. Extract client data"
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

    notice "10. Hardware-specific MySQL tuning"
    strip_existing_mysql_tuning
    echo "Match template '3 - Worldserver/Realm Settings/mysqld/<Realm>.cnf' against this LXC's cores/RAM."
    echo "If Authserver is already on this LXC, size this for the whole box (combined), not World alone."
    echo "Edit /etc/mysql/mysql.conf.d/mysqld.cnf below, then type 'exit' to continue."
    bash
    sudo mkdir -p /var/log/mysql
    sudo touch /var/log/mysql/slow.log
    sudo chown mysql:mysql /var/log/mysql/slow.log
    sudo systemctl restart mysql

    notice "11. Create databases and MySQL user"
    read -rsp "Set the DB password for the 'acore' MySQL user: " DB_PASS
    echo ""
    sudo mysql -u root << EOF
CREATE USER IF NOT EXISTS 'acore'@'localhost' IDENTIFIED WITH mysql_native_password BY '$DB_PASS';
CREATE USER IF NOT EXISTS 'acore'@'%' IDENTIFIED WITH mysql_native_password BY '$DB_PASS';

GRANT ALL PRIVILEGES ON *.* TO 'acore'@'localhost' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'acore'@'%' WITH GRANT OPTION;

FLUSH PRIVILEGES;
EOF
    unset DB_PASS

    notice "12. Install management scripts"
    run_worldscript

    notice "13. Final start"
    echo "Run 'source ~/.bashrc' (or re-login) so the 'worldmenu' alias is active."
    echo "The 'worldmenu' start flow is not part of this script - see install.md."
}

################################################################################
# 6. WORLDSCRIPTS (management scripts only)
################################################################################
run_worldscript() {
    notice "Install management scripts (Worldserver)"
    echo "ACore InnControl (separate repo) will be cloned to /tmp/acore-inncontrol and installed."
    rm -rf /tmp/acore-inncontrol
    git clone https://gitlab.com/grassnotfound/acore-inncontrol.git /tmp/acore-inncontrol
    # Only prefix with sudo if we're not root yet - a nested sudo call while
    # already root resets SUDO_USER to "root", breaking InnControl's
    # alias/ownership default for the actual admin user.
    if [ "$EUID" -eq 0 ]; then
        bash /tmp/acore-inncontrol/install.sh world
    else
        sudo bash /tmp/acore-inncontrol/install.sh world
    fi
    echo "Set the DB password for the 'acore' MySQL user in values_world.conf's LoginDatabaseInfo/WorldDatabaseInfo/CharacterDatabaseInfo"
    echo "and in values_playerbots.conf's PlayerbotsDatabaseInfo."
}

################################################################################
# 4. BOTHSERVER (Auth + World on one LXC)
################################################################################
run_bothserver() {
    step "Bothserver: Authserver"
    run_authserver
    step "Bothserver: Worldserver"
    run_worldserver
}

################################################################################
# 7. BOTH SCRIPTS (Auth + World management scripts on one LXC)
################################################################################
run_bothscripts() {
    step "Both Scripts: Authscript"
    run_authscript
    step "Both Scripts: Worldscripts"
    run_worldscript
}

################################################################################
# 8. UPDATE (this repo + InnControl management scripts)
################################################################################
run_update() {
    step "Update Installscript repo"
    local REPO_ROOT
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    git -C "$REPO_ROOT" pull

    echo ""
    echo "Also update management scripts (InnControl) for:"
    echo "  [1] auth"
    echo "  [2] world"
    echo "  [3] both"
    echo "  [4] skip"
    read -rp "Select an option [1-4]: " ROLE_SELECTION
    case "$ROLE_SELECTION" in
        1) run_authscript ;;
        2) run_worldscript ;;
        3) run_bothscripts ;;
        4|"") warn "Skipped InnControl update." ;;
        *) warn "Invalid choice, skipped InnControl update." ;;
    esac
}

################################################################################
# 9. DELETE (management scripts)
################################################################################
delete_role() {
    local ROLE="$1"
    local DEST_DIR="/opt/control-$ROLE"
    read -rp "Path of the '$ROLE' management scripts to delete [$DEST_DIR]: " DEST_DIR_INPUT
    DEST_DIR="${DEST_DIR_INPUT:-$DEST_DIR}"

    if [ ! -d "$DEST_DIR" ]; then
        warn "$DEST_DIR does not exist, nothing to delete."
        return 0
    fi

    confirm "This permanently deletes $DEST_DIR (scripts + config, including DB passwords), /etc/sudoers.d/acorecontrol-$ROLE, and the '$ROLE' alias block in ~/.bashrc."

    sudo rm -rf "$DEST_DIR"
    sudo rm -f "/etc/sudoers.d/acorecontrol-$ROLE"

    read -rp "Bashrc of which user should the '$ROLE' alias block be removed from? [${SUDO_USER:-$(whoami)}]: " ALIAS_USER
    ALIAS_USER="${ALIAS_USER:-${SUDO_USER:-$(whoami)}}"
    local USER_HOME
    USER_HOME="$(getent passwd "$ALIAS_USER" | cut -d: -f6)"
    if [ -n "$USER_HOME" ] && [ -f "$USER_HOME/.bashrc" ]; then
        local BEGIN_MARKER="# >>> acorecontrol-$ROLE aliases (managed by install.sh) >>>"
        local END_MARKER="# <<< acorecontrol-$ROLE aliases <<<"
        local STRIPPED
        STRIPPED="$(mktemp)"
        awk -v b="$BEGIN_MARKER" -v e="$END_MARKER" '
            $0==b {skip=1; next}
            $0==e {skip=0; next}
            skip!=1 {print}
        ' "$USER_HOME/.bashrc" > "$STRIPPED"
        sudo cp "$STRIPPED" "$USER_HOME/.bashrc"
        rm -f "$STRIPPED"
        echo "Alias block removed from $USER_HOME/.bashrc."
    fi

    echo "Deleted '$ROLE' management scripts."
}

delete_installscript() {
    local SCRIPT_PATH
    SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

    warn "This permanently deletes $SCRIPT_PATH itself (just this file - guides/templates in this checkout are left in place), plus a leftover /tmp/acore-inncontrol clone if one exists from an interrupted run."
    confirm "Type 'yes' to confirm when ready."

    if [ -d /tmp/acore-inncontrol ]; then
        rm -rf /tmp/acore-inncontrol
        echo "Removed leftover /tmp/acore-inncontrol clone."
    fi

    rm -f "$SCRIPT_PATH"
    echo -e "${GREEN}Removed $SCRIPT_PATH.${NC}"
    exit 0
}

run_delete() {
    echo "Delete management scripts for:"
    echo "  [1] auth"
    echo "  [2] world"
    echo "  [3] both"
    echo "  [4] this install.sh (+ any leftover /tmp/acore-inncontrol clone)"
    read -rp "Select an option [1-4]: " ROLE_SELECTION
    case "$ROLE_SELECTION" in
        1) delete_role "auth" ;;
        2) delete_role "world" ;;
        3) delete_role "auth"; delete_role "world" ;;
        4) delete_installscript ;;
        *) warn "Invalid choice."; exit 1 ;;
    esac
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
    echo "  1) Basic System   (Debian base setup, security, Fail2Ban)"
    echo "  2) Authserver     (Auth & MySQL 8.4 database server - build + InnControl scripts)"
    echo "  3) Worldserver    (Worldserver incl. Playerbots - build + InnControl scripts)"
    echo "  4) Bothserver     (Authserver + Worldserver on this LXC - build + InnControl scripts)"
    echo "  5) Authscript     (ACore InnControl management scripts for Authserver)"
    echo "  6) Worldscripts   (ACore InnControl management scripts for Worldserver)"
    echo "  7) Both Scripts   (ACore InnControl management scripts, Auth + World)"
    echo "  8) Update         (git pull this repo + optionally update InnControl)"
    echo "  9) Delete         (remove installed management scripts, or this install.sh itself)"
    echo ""
    read -rp "Choice [1-9]: " choice

    case "$choice" in
        1) run_basic_system ;;
        2) run_authserver ;;
        3) run_worldserver ;;
        4) run_bothserver ;;
        5) run_authscript ;;
        6) run_worldscript ;;
        7) run_bothscripts ;;
        8) run_update ;;
        9) run_delete ;;
        *) warn "Invalid choice."; exit 1 ;;
    esac

    echo ""
    echo -e "${GREEN}DONE.${NC}"
}

main "$@"
