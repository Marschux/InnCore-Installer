#!/usr/bin/env bash

# ==================================================
# AZEROTHCORE REALMLIST & MOTD MANAGER
# Manages the auth realmlist table and MOTD entries
# stored in the auth database.
# (vendored from InnControl scripts/auth/06_realmlist_motd_manager.sh)
# ==================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
set +eu

EDITOR="${EDITOR:-nano}"

CYAN='\033[1;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
MAGENTA='\033[1;35m'
NC='\033[0m'

DB_HOST=""
DB_PORT=""
DB_USER=""
DB_PASS=""
DB_NAME=""

MOTD_TEXT_RESULT=""

wait_for_user() {
    echo ""
    echo -e "${CYAN}↩️  Press [ENTER] to continue...${NC}"
    read -r
}

pause_menu() {
    wait_for_user
}

mysql_exec() {
    MYSQL_PWD="$DB_PASS" mysql \
        -h "$DB_HOST" \
        -P "$DB_PORT" \
        -u "$DB_USER" \
        "$DB_NAME" \
        "$@"
}

escape_sql() {
    printf "%s" "$1" | sed "s/'/''/g"
}

read_login_db_info() {
    local conf_file="${1:-${AUTH_CONF:-}}"
    local line

    if [ -z "$conf_file" ]; then
        return 1
    fi

    if [ ! -f "$conf_file" ]; then
        return 1
    fi

    line=$(grep -E "^[[:space:]]*LoginDatabaseInfo[[:space:]]*=" "$conf_file" | tail -n 1)
    line=$(echo "$line" | cut -d'=' -f2- | cut -d'#' -f1 | xargs)
    line=$(echo "$line" | sed 's/^"//;s/"$//')

    IFS=';' read -r DB_HOST DB_PORT DB_USER DB_PASS DB_NAME <<< "$line"

    if [ -z "$DB_HOST" ] || [ -z "$DB_PORT" ] || [ -z "$DB_USER" ] || [ -z "$DB_NAME" ]; then
        return 1
    fi
}

validate_number() {
    local value="$1"
    local name="$2"

    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}❌ Invalid value for $name:${NC} $value"
        exit 1
    fi
}

get_realm_type_name() {
    local icon="$1"

    case "$icon" in
        0) echo "Normal" ;;
        1) echo "PvP" ;;
        4) echo "Normal" ;;
        6) echo "RP" ;;
        8) echo "RPPvP" ;;
        *) echo "Unknown" ;;
    esac
}

mask_to_cidr() {
    local mask="$1"
    local a b c d octet cidr=0

    IFS='.' read -r a b c d <<< "$mask"

    if [ -z "$a" ] || [ -z "$b" ] || [ -z "$c" ] || [ -z "$d" ]; then
        echo "?"
        return
    fi

    for octet in "$a" "$b" "$c" "$d"; do
        while [ "$octet" -gt 0 ]; do
            cidr=$((cidr + (octet & 1)))
            octet=$((octet >> 1))
        done
    done

    echo "/$cidr"
}

check_realm_online() {
    local host="$1"
    local port="$2"

    if [ -z "$host" ] || [ -z "$port" ]; then
        echo "UNKNOWN"
        return
    fi

    if timeout 1 bash -c "</dev/tcp/$host/$port" >/dev/null 2>&1 \
        || timeout 1 bash -c "</dev/tcp/$host/$port" >/dev/null 2>&1; then
        echo "ONLINE"
    else
        echo "OFFLINE"
    fi
}

# ==================================================
# Realmlist management
# ==================================================

show_realmlist_table() {
    local rows
    local id name address local_address netmask port icon flag timezone security build realm_type cidr local_display

    echo ""
    echo -e "${MAGENTA}📊  Realmlist table${NC}"
    echo "--------------------------------------------------------------------------------"

    rows=$(mysql_exec --batch --skip-column-names -e "
        SELECT id, name, address, localAddress, localSubnetMask, port, icon, flag, timezone, allowedSecurityLevel, gamebuild
        FROM realmlist
        ORDER BY id;
    ")

    if [ -z "$rows" ]; then
        echo -e "${YELLOW}ℹ️  No realms found.${NC}"
        echo "--------------------------------------------------------------------------------"
        return
    fi

    printf " %-4s %-18s %-10s %-22s %-22s %-6s %-5s %-5s %-4s %-7s\n" \
        "ID" "Name" "Type" "Address" "LocalAddress" "Port" "Flag" "TZ" "GM" "Build"
    echo "--------------------------------------------------------------------------------"

    while IFS=$'\t' read -r id name address local_address netmask port icon flag timezone security build; do
        realm_type=$(get_realm_type_name "$icon")
        cidr=$(mask_to_cidr "$netmask")
        local_display="${local_address}${cidr}"

        printf " %-4s %-18s %-10s %-22s %-22s %-6s %-5s %-5s %-4s %-7s\n" \
            "$id" "$name" "$realm_type" "$address" "$local_display" "$port" "$flag" "$timezone" "$security" "$build"
    done <<< "$rows"

    echo "--------------------------------------------------------------------------------"
}

show_realmlist_table_with_status() {
    local rows
    local id name address local_address netmask port icon flag timezone security build realm_type status cidr local_display

    echo ""
    echo -e "${MAGENTA}📊  Realmlist table${NC}"
    echo "--------------------------------------------------------------------------------------------"

    rows=$(mysql_exec --batch --skip-column-names -e "
        SELECT id, name, address, localAddress, localSubnetMask, port, icon, flag, timezone, allowedSecurityLevel, gamebuild
        FROM realmlist
        ORDER BY id;
    ")

    if [ -z "$rows" ]; then
        echo -e "${YELLOW}ℹ️  No realms found.${NC}"
        echo "--------------------------------------------------------------------------------------------"
        return
    fi

    printf " %-4s %-18s %-10s %-22s %-22s %-6s %-5s %-5s %-4s %-7s %-8s\n" \
        "ID" "Name" "Type" "Address" "LocalAddress" "Port" "Flag" "TZ" "GM" "Build" "Status"
    echo "--------------------------------------------------------------------------------------------"

    while IFS=$'\t' read -r id name address local_address netmask port icon flag timezone security build; do
        realm_type=$(get_realm_type_name "$icon")
        cidr=$(mask_to_cidr "$netmask")
        local_display="${local_address}${cidr}"
        status=$(check_realm_online "$address" "$port")

        if [ "$status" = "ONLINE" ]; then
            status="${GREEN}ONLINE${NC}"
        else
            status="${RED}OFFLINE${NC}"
        fi

        printf " %-4s %-18s %-10s %-22s %-22s %-6s %-5s %-5s %-4s %-7s " \
            "$id" "$name" "$realm_type" "$address" "$local_display" "$port" "$flag" "$timezone" "$security" "$build"
        echo -e "$status"
    done <<< "$rows"

    echo "-------------------------------------------------------------------------------------------------------"
}

get_next_realm_id() {
    local max_id
    max_id=$(mysql_exec -N -s -e "SELECT IFNULL(MAX(id),0) FROM realmlist;")
    echo $((max_id + 1))
}

test_realm_port() {
    local address="$1"
    local port="$2"

    echo ""
    echo -e "${CYAN}🔌  Testing realm connection:${NC} $address:$port"

    if command -v nc >/dev/null 2>&1; then
        if nc -z -w 3 "$address" "$port" >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Port is reachable.${NC}"
        else
            echo -e "${YELLOW}⚠️  Port is not reachable or blocked.${NC}"
        fi
    elif timeout 3 bash -c "</dev/tcp/$address/$port" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Port is reachable.${NC}"
    else
        echo -e "${YELLOW}⚠️  Port is not reachable or blocked.${NC}"
    fi
}

add_or_update_realm() {
    local next_id existing_row
    local realm_id realm_name address local_address netmask port icon flag timezone security build
    local def_name def_address def_local_address def_netmask def_port def_icon def_flag def_timezone def_security def_build
    local realm_name_esc address_esc local_address_esc netmask_esc
    local sql_query
    local confirm

    show_realmlist_table

    next_id=$(get_next_realm_id)

    echo ""
    echo -e "💡  Next free realm ID: ${GREEN}$next_id${NC}"
    echo ""

    read -p "🔹 Realm ID [$next_id]: " realm_id
    realm_id=${realm_id:-$next_id}
    validate_number "$realm_id" "Realm ID"

    existing_row=$(mysql_exec --batch --skip-column-names -e "
        SELECT name, address, localAddress, localSubnetMask, port, icon, flag, timezone, allowedSecurityLevel, gamebuild
        FROM realmlist
        WHERE id=$realm_id
        LIMIT 1;
    ")

    if [ -n "$existing_row" ]; then
        IFS=$'\t' read -r def_name def_address def_local_address def_netmask def_port def_icon def_flag def_timezone def_security def_build <<< "$existing_row"

        echo -e "${YELLOW}⚠️  Realm ID already exists:${NC} $def_name"
        echo "This entry will be updated. Current values are used as defaults:"
        echo "press [ENTER] to keep a value, or type a new one."
        echo ""
    else
        def_name="Realm $realm_id"
        def_address="10.20.10.10"
        def_local_address="192.168.0.10"
        def_netmask="255.255.255.0"
        def_port=8085
        def_icon=0
        def_flag=0
        def_timezone=9
        def_security=0
        def_build=12340
    fi

    read -p "🔹 Realm name [$def_name]: " realm_name
    realm_name=${realm_name:-"$def_name"}

    echo ""
    echo -e "${YELLOW}💡 address:${NC} Public WAN IP, VPN IP or domain for external clients."
    read -p "🔹 Address [$def_address]: " address
    address=${address:-"$def_address"}

    echo ""
    echo -e "${YELLOW}💡 localAddress:${NC} LAN or internal VPN address for local clients."
    read -p "🔹 Local address [$def_local_address]: " local_address
    local_address=${local_address:-"$def_local_address"}

    read -p "🔹 Local subnet mask [$def_netmask]: " netmask
    netmask=${netmask:-"$def_netmask"}

    echo ""
    echo -e "${YELLOW}💡 port:${NC} Worldserver port. Default: 8085."
    read -p "🔹 Port [$def_port]: " port
    port=${port:-$def_port}
    validate_number "$port" "Port"

    echo ""
    echo -e "${YELLOW}💡 icon:${NC} 0=Normal/PvE, 1=PvP, 4=Normal, 6=RP, 8=RP-PvP"
    read -p "🔹 Icon [$def_icon]: " icon
    icon=${icon:-$def_icon}
    validate_number "$icon" "Icon"

    echo ""
    echo -e "${YELLOW}💡 flag:${NC} 0=None, 1=Invalid, 2=Offline, 4=Build, 32=Recommended, 64=New, 128=Full"
    echo -e "${YELLOW}   Note:${NC} the worldserver clears/sets bit 2 itself on start/shutdown."
    read -p "🔹 Flag [$def_flag]: " flag
    flag=${flag:-$def_flag}
    validate_number "$flag" "Flag"

    echo ""
    echo -e "${YELLOW}💡 timezone:${NC} 9=German, 8=English, 10=French, 11=Spanish, 12=Russian, 26=Test Server"
    read -p "🔹 Timezone [$def_timezone]: " timezone
    timezone=${timezone:-$def_timezone}
    validate_number "$timezone" "Timezone"

    echo ""
    echo -e "${YELLOW}💡 allowedSecurityLevel:${NC} 0=Player, 1=Moderator, 2=Gamemaster, 3=Administrator, 4=Console"
    read -p "🔹 Security level [$def_security]: " security
    security=${security:-$def_security}
    validate_number "$security" "Security level"

    echo ""
    echo -e "${YELLOW}💡 gamebuild:${NC} 12340 = WoW 3.3.5a"
    read -p "🔹 Gamebuild [$def_build]: " build
    build=${build:-$def_build}
    validate_number "$build" "Gamebuild"

    echo ""
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${CYAN}        REALM SUMMARY                             ${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo -e " 🆔  Realm ID:           ${GREEN}$realm_id${NC}"
    echo -e " 📛  Name:               ${GREEN}$realm_name${NC}"
    echo -e " 🌐  Address:            ${GREEN}$address${NC}"
    echo -e " 🏠  Local address:      ${GREEN}$local_address${NC}"
    echo -e " 😷  Subnet mask:        ${GREEN}$netmask${NC}"
    echo -e " 🔌  Port:               ${GREEN}$port${NC}"
    echo -e " 🗺️  Icon:               ${GREEN}$icon ($(get_realm_type_name "$icon"))${NC}"
    echo -e " 🚩  Flag:               ${GREEN}$flag${NC}"
    echo -e " 🕒  Timezone:           ${GREEN}$timezone${NC}"
    echo -e " 🔒  Security level:     ${GREEN}$security${NC}"
    echo -e " 🛠️  Gamebuild:          ${GREEN}$build${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo ""

    read -p "❓ Write this realm to the realmlist table? (y/n): " confirm

    if [[ ! "$confirm" =~ ^[JjYy]$ ]]; then
        echo -e "${YELLOW}👋 Operation cancelled. No database changes were made.${NC}"
        return
    fi

    realm_name_esc=$(escape_sql "$realm_name")
    address_esc=$(escape_sql "$address")
    local_address_esc=$(escape_sql "$local_address")
    netmask_esc=$(escape_sql "$netmask")

    sql_query="
        INSERT INTO realmlist
            (id, name, address, localAddress, localSubnetMask, port, icon, flag, timezone, allowedSecurityLevel, population, gamebuild)
        VALUES
            ($realm_id, '$realm_name_esc', '$address_esc', '$local_address_esc', '$netmask_esc', $port, $icon, $flag, $timezone, $security, 0, $build)
        ON DUPLICATE KEY UPDATE
            name='$realm_name_esc',
            address='$address_esc',
            localAddress='$local_address_esc',
            localSubnetMask='$netmask_esc',
            port=$port,
            icon=$icon,
            flag=$flag,
            timezone=$timezone,
            allowedSecurityLevel=$security,
            gamebuild=$build;
    "

    if mysql_exec -e "$sql_query"; then
        echo -e "${GREEN}✅ Realm was added or updated successfully.${NC}"
        test_realm_port "$address" "$port"
    else
        echo -e "${RED}❌ SQL command failed.${NC}"
        exit 1
    fi
}

delete_realm() {
    local delete_id realm_name delete_confirm

    show_realmlist_table

    echo ""
    echo -e "${RED}🔥  DELETE REALM${NC}"
    read -p "🔹 Realm ID to delete: " delete_id

    validate_number "$delete_id" "Realm ID"

    realm_name=$(mysql_exec -N -s -e "SELECT name FROM realmlist WHERE id=$delete_id LIMIT 1;")

    if [ -z "$realm_name" ]; then
        echo -e "${RED}❌ No realm found with ID:${NC} $delete_id"
        exit 1
    fi

    echo ""
    echo -e "${YELLOW}⚠️  Warning:${NC} You are about to delete realm ${RED}[$delete_id] $realm_name${NC}"
    read -p "Type 'DELETE' to confirm: " delete_confirm

    if [ "$delete_confirm" != "DELETE" ]; then
        echo -e "${YELLOW}👋 Delete operation cancelled.${NC}"
        return
    fi

    if mysql_exec -e "DELETE FROM realmlist WHERE id=$delete_id;"; then
        mysql_exec -e "DELETE FROM motd WHERE realmid=$delete_id;" 2>/dev/null
        echo -e "${GREEN}✅ Realm deleted from realmlist:${NC} [$delete_id] $realm_name"
    else
        echo -e "${RED}❌ Failed to delete realm from realmlist.${NC}"
        exit 1
    fi
}

realmlist_menu() {
    while true; do
        clear

        echo -e "${CYAN}==================================================${NC}"
        echo -e "${CYAN}        AZEROTHCORE REALMLIST MANAGER             ${NC}"
        echo -e "${CYAN}==================================================${NC}"
        echo ""
        echo -e "${GREEN}✅ Auth database:${NC} $DB_NAME @ $DB_HOST:$DB_PORT"
        echo ""
        echo "What do you want to do?"
        echo "--------------------------------------------------"
        echo -e "  ${CYAN}[1]${NC} Add or update realm"
        echo -e "  ${CYAN}[2]${NC} Delete realm"
        echo -e "  ${CYAN}[3]${NC} Show realmlist table"
        echo -e "  ${CYAN}[0]${NC} Back"
        echo "--------------------------------------------------"
        read -p "Select option [0]: " option
        option=${option:-0}

        case "$option" in
            1)
                clear
                add_or_update_realm
                wait_for_user
                ;;

            2)
                clear
                delete_realm
                wait_for_user
                ;;

            3)
                clear
                show_realmlist_table_with_status
                wait_for_user
                ;;

            0)
                return 0
                ;;

            *)
                echo -e "${RED}❌ Invalid option.${NC}"
                sleep 1.5
                ;;
        esac
    done
}

# ==================================================
# MOTD management
# ==================================================

ensure_motd_table() {
    if ! mysql_exec -N -s -e "SHOW TABLES LIKE 'motd';" | grep -q "^motd$"; then
        echo -e "${YELLOW}⚠️  Table 'motd' does not exist.${NC}"
        read -p "❓ Create table now? (y/n): " CONFIRM

        if [[ "$CONFIRM" =~ ^[JjYy]$ ]]; then
            if mysql_exec -e "
                CREATE TABLE motd (
                    realmid INT NOT NULL,
                    text LONGTEXT NULL,
                    PRIMARY KEY (realmid)
                );
            "; then
                echo -e "${GREEN}✅ Table 'motd' was created.${NC}"
                sleep 1
            else
                echo -e "${RED}❌ Failed to create table 'motd'.${NC}"
                exit 1
            fi
        else
            echo -e "${RED}❌ Cannot continue without the 'motd' table.${NC}"
            exit 1
        fi
    fi
}

show_realms_compact() {
    echo -e "${GREEN}[-1]${NC} All realms"
    echo -e "${YELLOW}[0]${NC}  Cancel"
    echo "--------------------------------------------------"
    printf " %-6s %-22s %-22s %-6s\n" "ID" "Name" "Address" "Port"
    echo "--------------------------------------------------"

    mysql_exec --batch --skip-column-names -e "
        SELECT id, name, address, port
        FROM realmlist
        ORDER BY id ASC;
    " | while IFS=$'\t' read -r RID RNAME RADDR RPORT; do
        printf " %-6s %-22.22s %-22.22s %-6s\n" \
            "$RID" "$RNAME" "$RADDR" "$RPORT"
    done

    echo "--------------------------------------------------"
}

list_motds() {
    local result

    clear

    echo -e "${CYAN}==================================================${NC}"
    echo -e "${CYAN}        CURRENT MOTD ENTRIES                      ${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo ""

    result=$(mysql_exec --batch --skip-column-names -e "
        SELECT
            m.realmid,
            IFNULL(r.name, 'All realms'),
            IFNULL(r.address, '-'),
            IFNULL(r.port, '-'),
            REPLACE(IFNULL(m.text, ''), CHAR(10), ' ')
        FROM motd m
        LEFT JOIN realmlist r ON r.id = m.realmid
        ORDER BY m.realmid ASC;
    ")

    if [ -z "$result" ]; then
        echo -e "${YELLOW}ℹ️  No MOTD entries found.${NC}"
        return
    fi

    printf " %-8s %-22s %-22s %-6s %s\n" "RealmID" "Name" "Address" "Port" "MOTD"
    echo "------------------------------------------------------------------------------------------------------------"

    while IFS=$'\t' read -r RID RNAME RADDR RPORT MTEXT; do
        printf " %-8s %-22.22s %-22.22s %-6s %s\n" \
            "$RID" "$RNAME" "$RADDR" "$RPORT" "$MTEXT"
    done <<< "$result"
}

validate_realm_id() {
    local realm_id="$1"
    local realm_exists

    if [[ ! "$realm_id" =~ ^-?[0-9]+$ ]]; then
        echo -e "${RED}❌ Invalid realm ID.${NC}"
        return 1
    fi

    if [ "$realm_id" != "-1" ] && [ "$realm_id" != "0" ]; then
        realm_exists=$(mysql_exec -N -s -e "SELECT COUNT(*) FROM realmlist WHERE id=$realm_id;")

        if [ "$realm_exists" -eq 0 ]; then
            echo -e "${RED}❌ Realm ID does not exist:${NC} $realm_id"
            return 1
        fi
    fi

    return 0
}

get_current_motd() {
    local realm_id="$1"

    mysql_exec -N -s -e "
        SELECT IFNULL(text, '')
        FROM motd
        WHERE realmid=$realm_id
        LIMIT 1;
    "
}

read_motd_manual() {
    local motd_text=""

    echo ""
    echo "Enter MOTD text. Multiple lines are supported."
    echo "Finish with a single dot line:"
    echo "   ."
    echo "--------------------------------------------------"

    while IFS= read -r line; do
        [ "$line" = "." ] && break
        motd_text+="$line"$'\n'
    done

    MOTD_TEXT_RESULT="$motd_text"
}

read_motd_nano() {
    local realm_id="$1"
    local tmp_file
    local current_text

    tmp_file=$(mktemp)
    current_text=$(get_current_motd "$realm_id")

    printf "%s" "$current_text" > "$tmp_file"

    "$EDITOR" "$tmp_file" < /dev/tty > /dev/tty

    MOTD_TEXT_RESULT=$(cat "$tmp_file")

    rm -f "$tmp_file"
}

save_motd() {
    local realm_id="$1"
    local motd_text="$2"
    local motd_escaped

    motd_escaped=$(escape_sql "$motd_text")

    if mysql_exec -e "
        INSERT INTO motd (realmid, text)
        VALUES ($realm_id, '$motd_escaped')
        ON DUPLICATE KEY UPDATE text='$motd_escaped';
    "; then
        echo -e "${GREEN}✅ MOTD saved successfully.${NC}"
    else
        echo -e "${RED}❌ Failed to save MOTD.${NC}"
        return 1
    fi
}

edit_motd() {
    local realm_id
    local input_mode
    local motd_text

    clear

    echo -e "${CYAN}==================================================${NC}"
    echo -e "${CYAN}        ADD OR EDIT MOTD                          ${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo ""

    show_realms_compact

    echo ""
    read -p "🔹  Realm ID [-1]: " realm_id
    realm_id=${realm_id:--1}

    if [ "$realm_id" = "0" ]; then
        echo -e "${YELLOW}👋 Operation cancelled.${NC}"
        return
    fi

    if ! validate_realm_id "$realm_id"; then
        return
    fi

    echo ""
    echo "Choose input mode:"
    echo "--------------------------------------------------"
    echo -e "  ${CYAN}[1]${NC} Manual multiline input"
    echo -e "  ${CYAN}[2]${NC} Edit with $EDITOR"
    echo "--------------------------------------------------"
    read -p "Select option [2]: " input_mode
    input_mode=${input_mode:-2}

    MOTD_TEXT_RESULT=""

    case "$input_mode" in
        1)
            read_motd_manual
            motd_text="$MOTD_TEXT_RESULT"
            ;;

        2)
            read_motd_nano "$realm_id"
            motd_text="$MOTD_TEXT_RESULT"
            ;;

        *)
            echo -e "${RED}❌ Invalid input mode.${NC}"
            return
            ;;
    esac

    if [ -z "$motd_text" ]; then
        echo ""
        echo -e "${YELLOW}⚠️  MOTD is empty.${NC}"
        read -p "❓ Save empty MOTD anyway? (y/n): " CONFIRM_EMPTY

        if [[ ! "$CONFIRM_EMPTY" =~ ^[JjYy]$ ]]; then
            echo -e "${YELLOW}👋 Operation cancelled.${NC}"
            return
        fi
    fi

    echo ""
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${CYAN}        MOTD PREVIEW                              ${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo "$motd_text"
    echo -e "${CYAN}==================================================${NC}"
    echo ""

    read -p "❓ Save this MOTD? (y/n): " CONFIRM_SAVE

    if [[ "$CONFIRM_SAVE" =~ ^[JjYy]$ ]]; then
        save_motd "$realm_id" "$motd_text"
    else
        echo -e "${YELLOW}👋 MOTD was not saved.${NC}"
    fi
}

delete_motd() {
    local realm_id
    local motd_exists
    local confirm

    clear

    echo -e "${CYAN}==================================================${NC}"
    echo -e "${CYAN}        DELETE MOTD                               ${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo ""

    list_motds
    echo ""

    read -p "🔹  Realm ID to delete MOTD from: " realm_id

    if ! validate_realm_id "$realm_id"; then
        return
    fi

    if [ "$realm_id" = "0" ]; then
        echo -e "${YELLOW}👋 Operation cancelled.${NC}"
        return
    fi

    motd_exists=$(mysql_exec -N -s -e "SELECT COUNT(*) FROM motd WHERE realmid=$realm_id;")

    if [ "$motd_exists" -eq 0 ]; then
        echo -e "${YELLOW}ℹ️  No MOTD entry found for realm ID:${NC} $realm_id"
        return
    fi

    echo ""
    echo -e "${YELLOW}⚠️  You are about to delete the MOTD for realm ID:${NC} $realm_id"
    read -p "Type 'DELETE' to confirm: " confirm

    if [ "$confirm" != "DELETE" ]; then
        echo -e "${YELLOW}👋 Delete operation cancelled.${NC}"
        return
    fi

    if mysql_exec -e "DELETE FROM motd WHERE realmid=$realm_id;"; then
        echo -e "${GREEN}✅ MOTD deleted successfully.${NC}"
    else
        echo -e "${RED}❌ Failed to delete MOTD.${NC}"
    fi
}

motd_menu() {
    ensure_motd_table

    while true; do
        clear

        echo -e "${CYAN}==================================================${NC}"
        echo -e "${CYAN}        AZEROTHCORE MOTD MANAGER                  ${NC}"
        echo -e "${CYAN}==================================================${NC}"
        echo -e "${GREEN}🐬  Auth DB:${NC} $DB_NAME @ $DB_HOST:$DB_PORT"
        echo "--------------------------------------------------"
        echo -e "  ${GREEN}[1]${NC} Show MOTD entries"
        echo -e "  ${GREEN}[2]${NC} Add or edit MOTD"
        echo -e "  ${RED}[3]${NC} Delete MOTD"
        echo -e "  ${CYAN}[0]${NC} Back"
        echo "--------------------------------------------------"

        read -p "Select option [0]: " OPTION
        OPTION=${OPTION:-0}

        case "$OPTION" in
            1)
                list_motds
                pause_menu
                ;;

            2)
                edit_motd
                pause_menu
                ;;

            3)
                delete_motd
                pause_menu
                ;;

            0)
                return 0
                ;;

            *)
                echo -e "${RED}❌ Invalid option.${NC}"
                sleep 1
                ;;
        esac
    done
}

# ==================================================
# Top-level menu
# ==================================================

if ! read_login_db_info; then
    echo -e "${RED}❌ Could not read LoginDatabaseInfo from authserver.conf.${NC}"
    echo "   $AUTH_CONF"
    exit 1
fi

while true; do
    clear

    echo -e "${CYAN}==================================================${NC}"
    echo -e "${CYAN}        AZEROTHCORE REALMLIST & MOTD MANAGER      ${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo ""
    echo -e "${GREEN}✅ Auth database:${NC} $DB_NAME @ $DB_HOST:$DB_PORT"
    echo ""
    echo "What do you want to manage?"
    echo "--------------------------------------------------"
    echo -e "  ${CYAN}[1]${NC} Realmlist"
    echo -e "  ${CYAN}[2]${NC} MOTD"
    echo -e "  ${CYAN}[0]${NC} Back"
    echo "--------------------------------------------------"
    read -p "Select option [0]: " TOP_OPTION
    TOP_OPTION=${TOP_OPTION:-0}

    case "$TOP_OPTION" in
        1)
            realmlist_menu
            ;;

        2)
            motd_menu
            ;;

        0)
            exit 0
            ;;

        *)
            echo -e "${RED}❌ Invalid option.${NC}"
            sleep 1.5
            ;;
    esac
done

exit 0
