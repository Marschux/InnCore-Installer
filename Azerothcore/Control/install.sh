#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'

ask_default() { local prompt="$1" default="$2" value; read -rp "$prompt [$default]: " value; printf '%s' "${value:-$default}"; }
require_absolute() { [[ "$1" = /* && "$1" != "/" ]] || { echo "Invalid absolute path: $1"; exit 1; }; }

install_role() {
    local role="$1" default_dir default_acore default_owner target acore owner auth_menu world_menu
    if [ "$role" = auth ]; then
        default_dir=/opt/acore-auth-control
        default_acore=/opt/ac-authserver
        default_owner="$(stat -c '%U' "$default_acore" 2>/dev/null || id -un)"
        target="$(ask_default "Installation path for auth Control" "${CONTROL_AUTH_TARGET:-$default_dir}")"
        acore="$(ask_default "AzerothCore path for the Authserver" "${CONTROL_AUTH_DIR:-$default_acore}")"
        owner="$(ask_default "User for the Authserver" "${CONTROL_AUTH_OWNER:-$default_owner}")"
    else
        default_dir=/opt/acore-world-control
        default_acore=/opt/ac-worldserver
        default_owner="$(stat -c '%U' "$default_acore" 2>/dev/null || id -un)"
        target="$(ask_default "Installation path for world Control" "${CONTROL_WORLD_TARGET:-$default_dir}")"
        acore="$(ask_default "AzerothCore path for the Worldserver" "${CONTROL_WORLD_DIR:-$default_acore}")"
        owner="$(ask_default "User for the Worldserver" "${CONTROL_WORLD_OWNER:-$default_owner}")"
    fi
    require_absolute "$target"; require_absolute "$acore"
    sudo install -d -o "$owner" -g "$owner" "$target"
    sudo install -m 0755 "$SCRIPT_DIR/common.sh" "$target/common.sh"
    sudo install -m 0755 "$SCRIPT_DIR/clean-build.sh" "$target/clean-build.sh"
    if [ "$role" = auth ]; then
        sudo install -m 0755 "$SCRIPT_DIR/auth-menu.sh" "$target/auth-menu.sh"
        auth_menu="$target/auth-menu.sh"
        sudo tee "$target/control.conf" >/dev/null <<EOF
ACORE_DIR='$acore'
SERVER_USER='$owner'
CONTROL_SOURCE_DIR='$SCRIPT_DIR'
AUTH_MENU='$auth_menu'
AUTH_ENGINE="\$ACORE_DIR/apps/startup-scripts/src/run-engine"
AUTH_BINARY="\$ACORE_DIR/env/dist/bin/authserver"
AUTH_CONF="\$ACORE_DIR/env/dist/etc/authserver.conf"
AUTH_SESSION='auth-session'
AUTH_SERVICE_NAME='azerothcore-auth.service'
EOF
        sudo tee /usr/local/bin/authmenu >/dev/null <<EOF
#!/usr/bin/env bash
exec '$auth_menu' "\$@"
EOF
        sudo chmod 0755 /usr/local/bin/authmenu
    else
        sudo install -m 0755 "$SCRIPT_DIR/world-menu.sh" "$target/world-menu.sh"
        world_menu="$target/world-menu.sh"
        sudo tee "$target/control.conf" >/dev/null <<EOF
ACORE_DIR='$acore'
SERVER_USER='$owner'
CONTROL_SOURCE_DIR='$SCRIPT_DIR'
WORLD_MENU='$world_menu'
WORLD_ENGINE="\$ACORE_DIR/apps/startup-scripts/src/run-engine"
WORLD_BINARY="\$ACORE_DIR/env/dist/bin/worldserver"
WORLD_CONF="\$ACORE_DIR/env/dist/etc/worldserver.conf"
PLAYERBOTS_CONF="\$ACORE_DIR/env/dist/etc/modules/playerbots.conf"
WORLD_SESSION='world-session'
WORLD_SERVICE_NAME='azerothcore-world.service'
WORLD_TIMER_NAME='azerothcore-world-restart.timer'
EOF
        sudo install -o "$owner" -g "$owner" -m 0644 /dev/null "$target/worldserver.overrides.conf"
        sudo install -o "$owner" -g "$owner" -m 0644 /dev/null "$target/playerbots.overrides.conf"
        sudo tee /usr/local/bin/worldmenu >/dev/null <<EOF
#!/usr/bin/env bash
exec '$world_menu' "\$@"
EOF
        sudo chmod 0755 /usr/local/bin/worldmenu
    fi
    sudo chown -R "$owner:$owner" "$target"
    if [ "${CONTROL_ACTION:-install}" = update ]; then
        echo -e "${GREEN}$role Control updated: $target${NC}"
    else
        echo -e "${GREEN}$role Control installed: $target${NC}"
    fi
}

echo -e "${CYAN}=== Install AzerothCore Control ===${NC}"
echo "The files come exclusively from this repository; InnControl is not used."
if [ -n "${CONTROL_ROLE:-}" ]; then
    case "$CONTROL_ROLE" in
        auth) choice=1 ;;
        world) choice=2 ;;
        both) choice=3 ;;
        *) echo "Invalid CONTROL_ROLE: $CONTROL_ROLE"; exit 1 ;;
    esac
else
    read -rp "1) Authserver  2) Worldserver  3) Both [1-3]: " choice
fi
case "$choice" in
    1) install_role auth ;;
    2) install_role world ;;
    3) install_role auth; install_role world ;;
    *) echo "Invalid choice."; exit 1 ;;
esac
echo -e "${YELLOW}Usage: run authmenu or worldmenu.${NC}"
