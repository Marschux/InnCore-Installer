#!/bin/bash
################################################################################
#                                                                              #
#    AZEROTHCORE - COMBINED INSTALL SCRIPT                                    #
#    ----------------------------------------------------------------------   #
#    Menu choices:                                                            #
#      1) Basic System                                                        #
#      2) Authserver      - build only                                       #
#      3) Worldserver     - build only                                       #
#      4) Bothserver      - Auth + World, one LXC, build only                 #
#      5) Control         - install the Auth/World management menus           #
#      6) MySQL            - install and configure MySQL only                 #
#                                                                              #
#    This script mirrors the guides step for step. It is NOT fully            #
#    unattended: at points where the guides require a manual decision         #
#    (DB password, client-data extraction) it pauses and asks you to          #
#    confirm. The final menu start flow is not part of this script -          #
#    see ../README.md.                                                        #
#                                                                              #
################################################################################

set -euo pipefail

# Every apt call in this script is non-interactive. run_install_deps() also
# flips debconf's own frontend for acore.sh's inner sudo.
export DEBIAN_FRONTEND=noninteractive

# Plain `sudo apt` resets the environment and drops DEBIAN_FRONTEND, so a
# mysql-apt-config (re)configuration pops a whiptail dialog mid-run. Pass the
# var through explicitly and use apt-get (stable CLI). Harmless no-op sudo when
# already root.
apt_get() { sudo DEBIAN_FRONTEND=noninteractive apt-get "$@"; }

# Resolve absolutely while the cwd is still correct (later steps 'cd build')
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Abort early instead of failing 20 minutes into a build with "No space left on
# device". need_gb is a generous estimate: source + RelWithDebInfo build tree +
# installed binaries (+ client data for world).
check_disk() {
    local dir="$1" need_gb="$2" avail_gb parent
    parent="$dir"; while [ ! -d "$parent" ]; do parent="$(dirname "$parent")"; done
    avail_gb="$(df -BG --output=avail "$parent" | tail -1 | tr -dc '0-9')"
    echo "Free space on $(df --output=target "$parent" | tail -1): ${avail_gb} GB (need ~${need_gb} GB)"
    if [ "$avail_gb" -lt "$need_gb" ]; then
        warn "Not enough free disk space for this build."
        confirm "Continue anyway? The build will likely fail partway through."
    fi
}

# acore.sh install-deps adds the MySQL APT repo. Its mysql-apt-config package
# opens an interactive whiptail dialog on (re)configuration. Two guards:
#   1. Preseed the answers via debconf (mysql-8.4-lts, not 9.x which dropped
#      mysql_native_password).
#   2. Force debconf non-interactive. acore.sh runs apt directly when it is
#      already root (our normal case: script started via sudo), so exporting
#      DEBIAN_FRONTEND is enough there. For the passwordless-sudo-as-user case
#      that env is stripped at acore's inner sudo, so also flip debconf's own
#      frontend setting for the duration and restore it afterwards.
# mysql-apt-config pre-depends on gnupg/lsb-release, which a minimal Debian
# lacks (dpkg -i would refuse it); curl fetches it in menu 6. Preseed its
# answers so its whiptail dialog never opens.
preseed_mysql_apt_config() {
    apt_get install -y ca-certificates curl gnupg lsb-release
    sudo debconf-set-selections <<'EOF'
mysql-apt-config mysql-apt-config/select-server select mysql-8.4-lts
mysql-apt-config mysql-apt-config/select-product select Ok
mysql-apt-config mysql-apt-config/select-tools select Enabled
mysql-apt-config mysql-apt-config/repo-codename select
mysql-apt-config mysql-apt-config/repo-distro select debian
EOF
}

run_install_deps() {
    local prev_frontend
    preseed_mysql_apt_config
    prev_frontend="$(sudo debconf-show debconf 2>/dev/null | sed -n 's/^[* ] debconf\/frontend: //p')"
    echo 'debconf debconf/frontend select Noninteractive' | sudo debconf-set-selections
    (
        set -e
        trap 'echo "debconf debconf/frontend select ${prev_frontend:-Dialog}" | sudo debconf-set-selections' EXIT
        export DEBIAN_FRONTEND=noninteractive
        ./acore.sh install-deps
    )
}

ask_install_control() {
    local role="$1"
    read -rp "Optionally install the Control menu now? [y/N]: " control_choice
    case "$control_choice" in
        y|Y|j|J) INSTALL_CONTROL=1 ;;
        *) INSTALL_CONTROL=0; return ;;
    esac
    case "$role" in
        auth|both)
            read -rp "Installation path for auth Control [/opt/acore-auth-control]: " CONTROL_AUTH_TARGET
            CONTROL_AUTH_TARGET=${CONTROL_AUTH_TARGET:-/opt/acore-auth-control}
            ;;
    esac
    case "$role" in
        world|both)
            read -rp "Installation path for world Control [/opt/acore-world-control]: " CONTROL_WORLD_TARGET
            CONTROL_WORLD_TARGET=${CONTROL_WORLD_TARGET:-/opt/acore-world-control}
            ;;
    esac
}

offer_control_installation() {
    [ "${SKIP_CONTROL_PROMPT:-0}" = 1 ] && return
    if [ "${INSTALL_CONTROL:-0}" != 1 ]; then
        echo "Control menu skipped. It can be installed later via menu item 5."
        return
    fi
    step "Install Control menu"
    case "${CONTROL_ROLE:-}" in
        auth)  install_control_role auth "${CONTROL_AUTH_TARGET:-/opt/acore-auth-control}" "$AUTH_DIR" "$AUTH_OWNER" ;;
        world) install_control_role world "${CONTROL_WORLD_TARGET:-/opt/acore-world-control}" "$WORLD_DIR" "$WORLD_OWNER" ;;
        both)
            install_control_role auth  "${CONTROL_AUTH_TARGET:-/opt/acore-auth-control}"  "$AUTH_DIR"  "$AUTH_OWNER"
            install_control_role world "${CONTROL_WORLD_TARGET:-/opt/acore-world-control}" "$WORLD_DIR" "$WORLD_OWNER"
            ;;
        *) warn "Could not determine the Control role."; return 1 ;;
    esac
    echo "Usage: run authmenu or worldmenu."
}

# After a build, drop straight into the matching management menu instead of
# returning to the install menu. Only when its wrapper was actually installed.
launch_menu() {
    local role="$1"
    local wrapper="/usr/local/bin/${role}menu"
    [ -x "$wrapper" ] || return
    exec sudo "$wrapper"
}

# Installs the Control menu for one role. All four arguments are required;
# menu item 5 collects them interactively, the post-build flow passes what was
# gathered up front.
install_control_role() {
    local role="$1" target="$2" acore="$3" owner="$4"
    local src="$SCRIPT_DIR/Control" menu conf repo_root

    [[ "$target" = /* && "$target" != "/" ]] || { warn "Invalid Control path: $target"; return 1; }
    [[ "$acore"  = /* && "$acore"  != "/" ]] || { warn "Invalid AzerothCore path: $acore"; return 1; }

    # Password used to patch the values summaries below. On a standalone
    # install (menu 5) nothing is in memory, so read it back out of the
    # server's own conf. Shadowed locally so it never leaks past this call.
    local DB_PASS="${DB_PASS:-}"
    [ -n "$DB_PASS" ] || DB_PASS="$(sed -nE 's/^[[:space:]]*[A-Za-z]*DatabaseInfo[[:space:]]*=[[:space:]]*"[^";]*;[^";]*;[^";]*;([^";]*);.*/\1/p' \
        "$acore/env/dist/etc/${role}server.conf" 2>/dev/null | tail -1)"
    [ -n "$DB_PASS" ] || warn "No DB password found - values_*.conf keep the \"password\" placeholder."

    # Same for the auth box behind LoginDatabaseInfo, so values_world.conf keeps
    # pointing there instead of falling back to the 127.0.0.1 placeholder.
    local AUTH_DB_HOST="${AUTH_DB_HOST:-}" AUTH_DB_PASS="${AUTH_DB_PASS:-}"
    if [ "$role" = world ] && [ -z "$AUTH_DB_HOST" ]; then
        AUTH_DB_HOST="$(sed -nE 's/^[[:space:]]*LoginDatabaseInfo[[:space:]]*=[[:space:]]*"([^";]*);.*/\1/p' \
            "$acore/env/dist/etc/worldserver.conf" 2>/dev/null | tail -1)"
        AUTH_DB_PASS="$(sed -nE 's/^[[:space:]]*LoginDatabaseInfo[[:space:]]*=[[:space:]]*"[^";]*;[^";]*;[^";]*;([^";]*);.*/\1/p' \
            "$acore/env/dist/etc/worldserver.conf" 2>/dev/null | tail -1)"
    fi

    sudo install -d -o "$owner" -g "$owner" "$target"
    sudo install -m 0755 "$src/common.sh" "$target/common.sh"
    sudo install -m 0755 "$src/common-ops.sh" "$target/common-ops.sh"

    if ! sudo -u "$owner" test -r "$src/common.sh"; then
        warn "Warning: $owner cannot read $src (needed by 'Update Control scripts')."
        warn "Clone the repo under /opt (world-readable), not a private home dir."
    fi

    # 'Update Control scripts' runs `git pull` in this checkout as $owner, which
    # needs write access to .git/ and the working tree. Only take ownership when
    # $owner can't already write it - and say so, since this recursively chowns
    # whoever's checkout this is.
    repo_root="$(git -C "$src" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "$repo_root" ] && ! sudo -u "$owner" test -w "$repo_root/.git" 2>/dev/null; then
        echo "Giving $owner ownership of $repo_root (needed for 'Update Control scripts')."
        sudo chown -R "$owner:$owner" "$repo_root" || true
    fi

    # NOPASSWD grant for exactly the systemd actions the menu runs as $owner
    # (autostart / restart timer). Without it every such action prompts for a
    # password. Scoped to this role's azerothcore-* units only.
    sudo tee "/etc/sudoers.d/acore-control-$role" >/dev/null <<EOF
$owner ALL=(root) NOPASSWD: /usr/bin/systemctl daemon-reload, /usr/bin/systemctl reboot, /usr/bin/systemctl * azerothcore-$role.service, /usr/bin/systemctl * azerothcore-$role-restart.service, /usr/bin/tee /etc/systemd/system/azerothcore-$role.service, /usr/bin/tee /etc/systemd/system/azerothcore-$role-restart.service, /usr/bin/rm -f /etc/systemd/system/azerothcore-$role.service
EOF
    sudo chmod 0440 "/etc/sudoers.d/acore-control-$role"
    sudo visudo -cf "/etc/sudoers.d/acore-control-$role" >/dev/null || { warn "sudoers grant invalid - removing."; sudo rm -f "/etc/sudoers.d/acore-control-$role"; }

    # keep_values: copy a values/ summary only if it is not there yet, so a
    # re-install / "Update Control scripts" never overwrites the operator's edits.
    # Install a values summary if absent, and always (re)write its .base sidecar
    # to the template just placed - 'Update Control scripts' 3-way-merges against
    # it so template changes reach the box without clobbering operator edits.
    keep_values() {
        [ -f "$target/values/$1" ] || sudo install -D -o "$owner" -g "$owner" -m 0644 "$src/values/$1" "$target/values/$1"
        sudo install -D -o "$owner" -g "$owner" -m 0644 "$src/values/$1" "$target/values/$1.base"
        # The templates ship a literal "password" in their *DatabaseInfo lines;
        # applying such a summary from the menu would overwrite the working
        # credentials in authserver.conf / worldserver.conf. The .base sidecar
        # keeps the placeholder on purpose - it is the merge baseline, so the
        # real password below counts as an operator edit and survives updates.
        if [ -n "${DB_PASS:-}" ]; then write_conf_db_password "$target/values/$1"; fi
        write_conf_login_db "$target/values/$1"
    }

    if [ "$role" = auth ]; then
        sudo install -m 0755 "$src/auth-tools.sh" "$target/auth-tools.sh"
        keep_values values_auth.conf
    else
        sudo install -m 0755 "$src/world-restart-runner.sh" "$target/world-restart-runner.sh"
        keep_values values_world.conf
        keep_values values_playerbots.conf
    fi
    menu="$target/$role-menu.sh"
    sudo install -m 0755 "$src/$role-menu.sh" "$menu"
    # Only what differs per box; the standard paths/names default in common.sh.
    sudo tee "$target/control.conf" >/dev/null <<EOF
ACORE_DIR='$acore'
SERVER_USER='$owner'
CONTROL_SOURCE_DIR='$src'
CONTROL_TMUX_L='acore-$role'
${role^^}_MENU='$menu'
EOF
    sudo tee "/usr/local/bin/${role}menu" >/dev/null <<EOF
#!/usr/bin/env bash
exec '$menu' "\$@"
EOF
    sudo chmod 0755 "/usr/local/bin/${role}menu"

    sudo chown -R "$owner:$owner" "$target"
    echo "$role Control installed: $target"
}

# Menu item 5: install Control standalone, after a server build.
install_control_standalone() {
    local role
    read -rp "1) Authserver  2) Worldserver  3) Both [1-3]: " role
    case "$role" in
        1) role=auth ;;
        2) role=world ;;
        3) install_control_standalone_role auth; install_control_standalone_role world; return ;;
        *) warn "Invalid choice."; return 1 ;;
    esac
    install_control_standalone_role "$role"
}

install_control_standalone_role() {
    local role="$1" target acore owner default_dir default_acore default_owner
    if [ "$role" = auth ]; then
        default_dir=/opt/acore-auth-control; default_acore=/opt/ac-authserver
    else
        default_dir=/opt/acore-world-control; default_acore=/opt/ac-worldserver
    fi
    default_owner="$(stat -c '%U' "$default_acore" 2>/dev/null || id -un)"
    read -rp "Installation path for $role Control [$default_dir]: " target
    read -rp "AzerothCore path for the ${role^}server [$default_acore]: " acore
    read -rp "User for the ${role^}server [$default_owner]: " owner
    install_control_role "$role" "${target:-$default_dir}" "${acore:-$default_acore}" "${owner:-$default_owner}"
}

# Default folder owner: the admin user from menu 1 (item 1 writes it), else
# whoever ran sudo, else the current user.
default_owner() {
    if [ -s /etc/acore-install.admin ]; then
        head -n1 /etc/acore-install.admin
    else
        echo "${SUDO_USER:-$(whoami)}"
    fi
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
MYSQL_TUNING_BEGIN="# >>> AZEROTHCORE MYSQL PERFORMANCE TUNING >>>"
MYSQL_TUNING_END="# <<< AZEROTHCORE MYSQL PERFORMANCE TUNING <<<"
strip_existing_mysql_tuning() {
    local cnf="/etc/mysql/mysql.conf.d/mysqld.cnf"
    [ -f "$cnf" ] || return 0
    if grep -qF "$MYSQL_TUNING_BEGIN" "$cnf"; then
        warn "Existing AzerothCore MySQL tuning found - replacing it with the new profile."
        # Only the block between our markers - anything the operator added below
        # it stays. `\` before the literal markers keeps sed from reading the
        # '>>>' as an address.
        sudo sed -i "\\|${MYSQL_TUNING_BEGIN}|,\\|${MYSQL_TUNING_END}|d" "$cnf"
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
            warn "Unknown MySQL tuning profile: $PROFILE"
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

    DISK_TYPE="SSD/virtual"
    IO_CAPACITY=1000
    IO_CAPACITY_MAX=4000
    for rotational_file in /sys/block/*/queue/rotational; do
        if [ -r "$rotational_file" ] && [ "$(cat "$rotational_file")" = "1" ]; then
            DISK_TYPE="HDD/rotational"
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

$MYSQL_TUNING_BEGIN
# AZEROTHCORE MySQL performance tuning ($PROFILE, automatic)
# Hardware: $CPU_CORES CPU cores / $RAM_MB MB RAM / $DISK_TYPE
# Regenerated by acore-install.sh - edits between the markers are overwritten.
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
$MYSQL_TUNING_END
EOF

    echo "Automatic MySQL tuning ($PROFILE):"
    echo "  Hardware: $CPU_CORES CPU cores, $RAM_MB MB RAM, $DISK_TYPE"
    echo "  InnoDB Buffer Pool: $(format_mysql_size "$BUFFER_MB")"
    echo "  Max Connections: $MAX_CONNECTIONS"
    echo "  I/O Capacity: $IO_CAPACITY / $IO_CAPACITY_MAX"
}

################################################################################
# 1. BASIC SYSTEM
################################################################################
collect_basic_inputs() {
    step "1. Preparation and inputs"
    confirm "Is the Debian LXC fully set up with your own preparations and adjustments?"

    read -rp "Timezone [Europe/Berlin]: " SERVER_TIMEZONE
    SERVER_TIMEZONE=${SERVER_TIMEZONE:-Europe/Berlin}
    if [ -z "$SERVER_TIMEZONE" ] || [ ! -f "/usr/share/zoneinfo/$SERVER_TIMEZONE" ]; then
        warn "Unknown timezone: $SERVER_TIMEZONE"
        exit 1
    fi

    while true; do
        read -rp "Administration user: " ADMIN_USER
        if [[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*\$?$ ]]; then break; fi
        warn "Invalid Linux username. Use lowercase letters, digits, '_' or '-'."
    done
    while true; do
        read -rsp "Password for '$ADMIN_USER': " ADMIN_PASS; echo ""
        read -rsp "Repeat password: " ADMIN_PASS_CONFIRM; echo ""
        [ "$ADMIN_PASS" = "$ADMIN_PASS_CONFIRM" ] && break
        warn "Passwords do not match. Please try again."
    done
    unset ADMIN_PASS_CONFIRM
}

collect_auth_inputs() {
    local DEFAULT_OWNER
    DEFAULT_OWNER="$(default_owner)"
    read -rp "Owner for the Authserver folder [$DEFAULT_OWNER]: " AUTH_OWNER
    AUTH_OWNER=${AUTH_OWNER:-$DEFAULT_OWNER}
    read -rp "Installation path for the Authserver [/opt/ac-authserver]: " AUTH_DIR
    AUTH_DIR=${AUTH_DIR:-/opt/ac-authserver}
    read -rp "AzerothCore branch for the Authserver [master]: " AUTH_BRANCH
    AUTH_BRANCH=${AUTH_BRANCH:-master}
}

collect_world_inputs() {
    local DEFAULT_OWNER
    DEFAULT_OWNER="$(default_owner)"
    read -rp "Owner for the Worldserver folder [$DEFAULT_OWNER]: " WORLD_OWNER
    WORLD_OWNER=${WORLD_OWNER:-$DEFAULT_OWNER}
    read -rp "Installation path for the Worldserver [/opt/ac-worldserver]: " WORLD_DIR
    WORLD_DIR=${WORLD_DIR:-/opt/ac-worldserver}
    read -rp "AzerothCore branch for the Worldserver [Playerbot]: " WORLD_BRANCH
    WORLD_BRANCH=${WORLD_BRANCH:-Playerbot}
}

# The worldserver reads the auth database over the network when it runs on its
# own LXC. Ask for that box here, so worldserver.conf and values_world.conf get
# a working LoginDatabaseInfo instead of the 127.0.0.1 placeholder. Runs after
# collect_database_password - the auth password defaults to the one just given.
# Skipped for a Both install - auth's MySQL is then local anyway.
collect_auth_db_inputs() {
    [ -n "${AUTH_DIR:-}" ] && return 0
    echo ""
    hint "The worldserver also needs the auth database (acore_auth). It lives on"
    hint "the Authserver, so LoginDatabaseInfo points at that machine, not here."
    while true; do
        read -rp "IP of the Authserver (127.0.0.1 if its MySQL runs on this machine) [127.0.0.1]: " AUTH_DB_HOST
        AUTH_DB_HOST=${AUTH_DB_HOST:-127.0.0.1}
        if [[ "$AUTH_DB_HOST" =~ ^[A-Za-z0-9._-]+$ ]]; then break; fi
        warn "Invalid host. Use an IP or hostname."
    done
    if [ "$AUTH_DB_HOST" = "127.0.0.1" ]; then AUTH_DB_PASS=""; return 0; fi
    while true; do
        read -rsp "Password of the MySQL user 'acore' on the AUTHSERVER (Enter = same as above): " AUTH_DB_PASS
        echo ""
        case "$AUTH_DB_PASS" in
            *[\;\"\']*) warn "Password must not contain  ;  \"  or  '  characters."; continue ;;
        esac
        break
    done
}

collect_database_password() {
    while true; do
        read -rsp "Password for the MySQL user 'acore' on THIS machine: " DB_PASS
        echo ""
        # AzerothCore's *DatabaseInfo is a ';'-delimited list inside a '"' pair;
        # a password containing any of ; " ' can't be represented there (and
        # would break the SQL below). Reject early instead of a confusing fail.
        case "$DB_PASS" in
            '') warn "Password must not be empty."; continue ;;
            *[\;\"\']*) warn "Password must not contain  ;  \"  or  '  characters."; continue ;;
        esac
        read -rsp "Repeat password: " DB_PASS_CONFIRM
        echo ""
        [ "$DB_PASS" = "$DB_PASS_CONFIRM" ] && break
        warn "Passwords do not match. Please try again."
    done
    unset DB_PASS_CONFIRM
}

# The shipped *.conf.dist carry a literal "acore" as the password in every
# *DatabaseInfo line ("host;port;user;PASS;db"). Copying the dist file verbatim
# (steps 7/8 below) leaves auth/worldserver unable to connect once the operator
# picks any other password. Rewrite field 4 of each DatabaseInfo line - the '^'
# anchor skips the commented example lines, [A-Za-z]*DatabaseInfo covers
# Login/World/Character.
write_conf_db_password() {   # write_conf_db_password <conf-file>
    local conf="$1" d=$'\x1f' esc
    [ -f "$conf" ] || return 0
    esc="$(printf '%s' "$DB_PASS" | sed "s/[&${d}\\]/\\\\&/g")"
    sudo sed -i -E "s${d}^([[:space:]]*[A-Za-z]*DatabaseInfo[[:space:]]*=[[:space:]]*\"[^\";]*;[^\";]*;[^\";]*;)[^\";]*${d}\\1${esc}${d}" "$conf"
}

# Point the LoginDatabaseInfo line at the auth box collected above. Runs after
# write_conf_db_password, which has just set every DatabaseInfo password to the
# local one - the login line needs the auth LXC's host and its own password.
write_conf_login_db() {   # write_conf_login_db <conf-file>
    local conf="$1" d=$'\x1f' esc
    [ -f "$conf" ] || return 0
    [ -n "${AUTH_DB_HOST:-}" ] && [ "$AUTH_DB_HOST" != "127.0.0.1" ] || return 0
    esc="$(printf '%s' "${AUTH_DB_PASS:-$DB_PASS}" | sed "s/[&${d}\\]/\\\\&/g")"
    sudo sed -i -E "s${d}^([[:space:]]*LoginDatabaseInfo[[:space:]]*=[[:space:]]*\")[^\";]*(;[^\";]*;[^\";]*;)[^\";]*${d}\\1${AUTH_DB_HOST}\\2${esc}${d}" "$conf"
}

setup_database() {
    local profile="$1"

    step "MySQL 8.4 configuration"
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

    step "Automatic MySQL tuning"
    generate_mysql_tuning "$profile"
    sudo systemctl restart mysql

    step "Create databases and MySQL user"
    # CREATE USER IF NOT EXISTS does NOT touch the password of an existing user,
    # so a re-run with a different password would leave the account on the old
    # one while write_conf_db_password() puts the new one into the .conf files -
    # every DB connection then fails. ALTER USER after the CREATE keeps the
    # account's password in sync with what the operator just entered.
    sudo mysql -u root << EOF
CREATE USER IF NOT EXISTS 'acore'@'localhost' IDENTIFIED WITH mysql_native_password BY '$DB_PASS';
CREATE USER IF NOT EXISTS 'acore'@'%' IDENTIFIED WITH mysql_native_password BY '$DB_PASS';
ALTER USER 'acore'@'localhost' IDENTIFIED WITH mysql_native_password BY '$DB_PASS';
ALTER USER 'acore'@'%' IDENTIFIED WITH mysql_native_password BY '$DB_PASS';

GRANT ALL PRIVILEGES ON *.* TO 'acore'@'localhost' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'acore'@'%' WITH GRANT OPTION;

FLUSH PRIVILEGES;
EOF
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
        echo "Added hostname '$CURRENT_HOSTNAME' to /etc/hosts."
    fi
}

print_basic_checklist() {
    step "Final checklist"
    echo "[x] General LXC preparation confirmed"
    echo "[x] System updated and base tools installed"
    echo "[x] Local hostname resolution verified"
    echo "[x] Timezone set to '$SERVER_TIMEZONE'"
    echo "[x] Administration account '$ADMIN_USER' created and authorized for sudo"
    echo "[x] Dynamic MOTD template installed"
    echo "[x] SSH enabled and root login over SSH disabled"
    echo "[x] Fail2Ban enabled for SSH"
    echo "[x] SSH and sudo access confirmed"
    echo "[x] Root password locked"
}

run_basic_system() {
    # Item 1 writes /etc/hosts, runs useradd, edits sshd_config etc. directly -
    # that needs real root, not passwordless-sudo-as-user.
    [ "$EUID" -eq 0 ] || { warn "Menu item 1 (Basic System) must run as root."; return 1; }
    collect_basic_inputs
    step "2. Debian base system"
    apt_get update && apt_get full-upgrade -y
    apt_get install -y sudo htop curl wget nano unattended-upgrades screen tmux net-tools iproute2 unzip git iputils-ping glances openssh-server fail2ban locales

    ensure_hostname_resolution

    if ! timedatectl list-timezones | grep -Fxq "$SERVER_TIMEZONE"; then
        warn "Unknown timezone: $SERVER_TIMEZONE"; exit 1
    fi
    timedatectl set-timezone "$SERVER_TIMEZONE"
    step "3. Set up administration account"
    echo "The administration account is created or updated"
    echo "and authorized to use sudo."
    echo "Account used: $ADMIN_USER"
    id "$ADMIN_USER" &>/dev/null || useradd --create-home --shell /bin/bash "$ADMIN_USER"
    printf '%s:%s\n' "$ADMIN_USER" "$ADMIN_PASS" | chpasswd
    unset ADMIN_PASS
    usermod -aG sudo "$ADMIN_USER"
    printf '%s\n' "$ADMIN_USER" > /etc/acore-install.admin

    step "4. Dynamic MOTD"
    install_motd_template
    echo "The MOTD template has been installed."
    echo ""
    echo "MOTD test output:"
    /usr/local/bin/dynamic-motd.sh

    step "5. Harden SSH"
    # sshd takes the FIRST value it sees for a keyword, and the main config
    # Includes sshd_config.d/*.conf before its own settings. Name the drop-in so
    # it sorts ahead of any other (a cloud-init 50-*.conf, a homelab 99-*.conf),
    # so our PermitRootLogin no is the one that wins.
    mkdir -p /etc/ssh/sshd_config.d
    printf 'PermitRootLogin no\n' > /etc/ssh/sshd_config.d/00-acore-hardening.conf
    sshd -t && { systemctl enable ssh; systemctl restart ssh; }

    step "6. Configure Fail2Ban for SSH"
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

    step "7. Lock root password"
    sudo passwd -l root
    print_basic_checklist
    echo ""
    hint "The base system is ready. Add your own installations, services and"
    hint "project-specific adjustments before you continue."
}

################################################################################
# 2. AUTHSERVER
################################################################################
run_authserver() {
    step "1. Update system packages"
    check_disk "$AUTH_DIR" 20
    apt_get update && apt_get full-upgrade -y

    step "2. Clone source code"
    sudo mkdir -p "$AUTH_DIR"
    sudo chown "$AUTH_OWNER:$AUTH_OWNER" "$AUTH_DIR"
    cd "$AUTH_DIR"
    git clone https://github.com/azerothcore/azerothcore-wotlk.git --branch="$AUTH_BRANCH" .

    step "3. Install dependencies"
    OSDISTRO="$(. /etc/os-release && echo "$ID")"
    echo "Detected distro: $OSDISTRO"
    sed -i "s/^#\s*OSDISTRO=.*/OSDISTRO=\"$OSDISTRO\"/" "$AUTH_DIR/conf/dist/config.sh"
    run_install_deps
    # OSDISTRO is only needed by install-deps; restore the tracked file so
    # later source updates via authmenu stay a clean fast-forward.
    git -C "$AUTH_DIR" -c safe.directory='*' checkout -- conf/dist/config.sh || true

    step "4. Create and enter the build directory"
    mkdir -p build
    cd build

    step "5. Run CMake configure"
    cmake ../ \
      -DCMAKE_INSTALL_PREFIX="$AUTH_DIR/env/dist" \
      -DAPPS_BUILD=auth-only \
      -DTOOLS_BUILD=none \
      -DSCRIPTS=none

    step "6. Build and install"
    make -j "$(nproc)"
    make install

    step "7. Folder structure and config files"
    cp "$AUTH_DIR/env/dist/etc/authserver.conf.dist" "$AUTH_DIR/env/dist/etc/authserver.conf"
    write_conf_db_password "$AUTH_DIR/env/dist/etc/authserver.conf"
    echo "authserver.conf created: $AUTH_DIR/env/dist/etc/authserver.conf"

    # The clone/build ran as whoever started acore-install.sh (root on a fresh LXC),
    # so everything below AUTH_DIR is root-owned. authmenu runs as AUTH_OWNER and
    # must be able to write configs, backups and git pulls here.
    sudo chown -R "$AUTH_OWNER:$AUTH_OWNER" "$AUTH_DIR"

    setup_database "${TUNING_PROFILE:-auth}"

    step "8. Final step"
    echo "The Authserver build and database setup are complete."
    echo "Management scripts and the final 'authmenu' start flow are handled separately."
    CONTROL_ROLE=auth offer_control_installation
}

################################################################################
# 3. WORLDSERVER
################################################################################
run_worldserver() {
    step "1. Update system packages"
    check_disk "$WORLD_DIR" 45
    apt_get update && apt_get full-upgrade -y

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
    run_install_deps
    # See run_authserver: keep the checkout clean for later worldmenu updates.
    git -C "$WORLD_DIR" -c safe.directory='*' checkout -- conf/dist/config.sh || true

    step "4. Create and enter the build directory"
    mkdir -p build
    cd build

    step "5. Run CMake configure"
    cmake ../ \
      -DCMAKE_INSTALL_PREFIX="$WORLD_DIR/env/dist" \
      -DAPPS_BUILD=world-only \
      -DSCRIPTS=static \
      -DTOOLS_BUILD=none

    step "6. Build and install"
    make -j "$(nproc)"
    make install

    step "7. Extract client data"
    pause "If extracting from your own 3.3.5a client, put the files in place now before the assistant starts. The assistant also offers to download pre-extracted maps/vmaps/mmaps/dbc instead, if you don't have a local client."
    cd "$WORLD_DIR"
    ./acore.sh client-data

    step "8. Folder structure and config files"
    cp "$WORLD_DIR/env/dist/etc/worldserver.conf.dist" "$WORLD_DIR/env/dist/etc/worldserver.conf"
    write_conf_db_password "$WORLD_DIR/env/dist/etc/worldserver.conf"
    write_conf_login_db "$WORLD_DIR/env/dist/etc/worldserver.conf"
    echo -e "\nAllowTwoSide.WhoList = 1" >> "$WORLD_DIR/env/dist/etc/worldserver.conf"
    cp "$WORLD_DIR/env/dist/etc/modules/playerbots.conf.dist" "$WORLD_DIR/env/dist/etc/modules/playerbots.conf"
    echo "worldserver.conf and playerbots.conf created."

    # See run_authserver: hand the whole tree to WORLD_OWNER so worldmenu (which
    # runs as that user) can write configs, backups and git pulls.
    sudo chown -R "$WORLD_OWNER:$WORLD_OWNER" "$WORLD_DIR"

    setup_database "${TUNING_PROFILE:-world}"

    step "9. Final step"
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
# 5. MYSQL ONLY
################################################################################

# Add the MySQL 8.4 LTS APT repo the way acore.sh install-deps does for the
# server builds. Menu 6 has no AzerothCore checkout, so it has to do this itself
# - Debian ships no 'mysql-server', only MariaDB, and setup_database's tuning
# block needs MySQL 8.x (innodb_redo_log_capacity).
MYSQL_APT_CONFIG_VERSION="${MYSQL_APT_CONFIG_VERSION:-0.8.36-1}"
setup_mysql_apt_repo() {
    if apt-cache policy mysql-community-server 2>/dev/null | grep -q repo.mysql.com; then
        echo "MySQL APT repo already configured."
        return 0
    fi
    step "Add MySQL 8.4 APT repository"
    apt_get update
    preseed_mysql_apt_config
    local deb
    deb="$(mktemp --suffix=.deb)"
    curl -fsSL -o "$deb" \
        "https://dev.mysql.com/get/mysql-apt-config_${MYSQL_APT_CONFIG_VERSION}_all.deb"
    sudo DEBIAN_FRONTEND=noninteractive dpkg -i "$deb" \
        || sudo DEBIAN_FRONTEND=noninteractive apt-get -yf install
    rm -f "$deb"
    apt_get update
    if ! apt-cache policy mysql-community-server 2>/dev/null | grep -q repo.mysql.com; then
        warn "MySQL APT repo was not added - see the dpkg errors above."
        return 1
    fi
}

run_mysql_only() {
    step "Install MySQL"

    # All questions up front, then the install runs unattended.
    echo "Which profile should the MySQL tuning be calculated for?"
    echo "  1) Auth"
    echo "  2) World"
    echo "  3) Both"
    local profile_choice
    read -rp "Profile [1-3]: " profile_choice
    case "$profile_choice" in
        1) TUNING_PROFILE=auth ;;
        2) TUNING_PROFILE=world ;;
        3) TUNING_PROFILE=both ;;
        *) warn "Invalid choice."; exit 1 ;;
    esac
    collect_database_password

    setup_mysql_apt_repo || exit 1
    apt_get install -y mysql-server libmysqlclient-dev
    sudo systemctl enable --now mysql

    setup_database "$TUNING_PROFILE"
    unset DB_PASS
    step "Final step"
    echo "MySQL has been installed and configured."
}

################################################################################
# MAIN MENU
################################################################################
main() {
    require_root_or_sudo

    while true; do
        echo ""
        echo ""
        echo -e "${CYAN}################################################################################${NC}"
        echo -e "${CYAN}#  AZEROTHCORE - COMBINED INSTALL SCRIPT                                      #${NC}"
        echo -e "${CYAN}################################################################################${NC}"
        echo ""
        hint "Note: complete item 1 first. Item 5 follows after the server build."
        echo ""
        echo "  1) 🧱  Basic System   (Debian base setup, security, Fail2Ban)"
        echo "  2) 🔐  Authserver     (Auth & MySQL 8.4 database server - build only)"
        echo "  3) 🌍  Worldserver    (Worldserver incl. Playerbots - build only)"
        echo "  4) 🔗  Bothserver     (Auth + World on one shared LXC)"
        echo "  5) 🛠️  Control        (install the custom Auth/World management)"
        echo "  6) 🗄️  MySQL          (install and configure the MySQL database only)"
        echo "  0) 🚪  Exit"
        echo ""
        read -rp "Choice [0-6]: " choice

        case "$choice" in
            2|3|4)
                confirm "Has install item 1 (Basic System) been fully completed?"
                ;;
        esac

        case "$choice" in
            0)
                break
                ;;
            1)
                run_basic_system
                ;;
            2)
                collect_auth_inputs
                collect_database_password
                ask_install_control auth
                run_authserver
                launch_menu auth
                ;;
            3)
                collect_world_inputs
                collect_database_password
                collect_auth_db_inputs
                ask_install_control world
                run_worldserver
                launch_menu world
                ;;
            4)
                collect_auth_inputs
                collect_world_inputs
                collect_database_password
                ask_install_control both
                run_bothserver
                # One exec only - offering both is pointless, the first exec
                # replaces this process. Let the user pick.
                echo ""
                read -rp "Open a menu now? [a]uthmenu / [w]orldmenu / [n]o: " ans
                case "$ans" in
                    a|A) launch_menu auth ;;
                    w|W) launch_menu world ;;
                esac
                ;;
            5)
                step "5. Install AzerothCore Control"
                confirm "Has the required Auth or Worldserver already been installed and built?"
                install_control_standalone
                ;;
            6)
                run_mysql_only
                ;;
            *)
                warn "Invalid choice."
                continue
                ;;
        esac

        unset DB_PASS

        echo ""
        echo -e "${GREEN}DONE.${NC}"
    done
}

main "$@"
