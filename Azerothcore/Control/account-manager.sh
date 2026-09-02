#!/usr/bin/env bash

# ==================================================
# AZEROTHCORE AUTHSERVER ACCOUNT MANAGER
# Add accounts, edit accounts and set GM levels
# directly in the auth database.
# (vendored from InnControl scripts/auth/08_account_manager.sh)
# ==================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
set +eu

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

# Reads LoginDatabaseInfo from authserver.conf and sets:
#   DB_HOST  DB_PORT  DB_USER  DB_PASS  DB_NAME
# Returns 1 on failure (does not exit, let the caller decide).
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

    if [[ ! "$value" =~ ^-?[0-9]+$ ]]; then
        echo -e "${RED}❌ Invalid value for $name:${NC} $value"
        exit 1
    fi
}

check_python3() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo -e "${RED}❌ python3 is required but not installed.${NC}"
        exit 1
    fi
}

calculate_srp6() {
    local username="$1"
    local password="$2"

    python3 - "$username" "$password" <<'PYTHON'
import os
import hashlib
import sys

username = sys.argv[1].upper()
password = sys.argv[2].upper()

g = 7
N = int("894B645E89E1535BBDAD5B8B290650530801B18EBFBF5E8FAB3C82872A3E9BB7", 16)

salt = os.urandom(32)

h1 = hashlib.sha1(f"{username}:{password}".encode("utf-8")).digest()
h2 = hashlib.sha1(salt + h1).digest()

x = int.from_bytes(h2, byteorder="little")
v = pow(g, x, N)

verifier = v.to_bytes(32, byteorder="little")

print(f"{salt.hex().upper()} {verifier.hex().upper()}")
PYTHON
}

pause_menu() {
    echo ""
    read -p "🔹  Press [ENTER] to continue..." _
}

find_account() {
    local input="$1"
    local upper
    local escaped

    if [[ "$input" =~ ^[0-9]+$ ]]; then
        mysql_exec --batch --skip-column-names -e "
            SELECT id, username, expansion, locked
            FROM account
            WHERE id=$input
            LIMIT 1;
        "
    else
        upper=$(echo "$input" | tr '[:lower:]' '[:upper:]' | xargs)
        escaped=$(escape_sql "$upper")

        mysql_exec --batch --skip-column-names -e "
            SELECT id, username, expansion, locked
            FROM account
            WHERE username='$escaped'
            LIMIT 1;
        "
    fi
}

show_auth_status() {
    if tmx has-session -t "$AUTH_SESSION" 2>/dev/null; then
        if pgrep -x "authserver" >/dev/null; then
            echo -e "${GREEN}🟢  Authserver:${NC} ONLINE"
        else
            echo -e "${YELLOW}🟡  Authserver:${NC} tmux active, process missing"
        fi

        echo -e "${CYAN}📂  Session:${NC} $AUTH_SESSION"
    else
        if pgrep -x "authserver" >/dev/null; then
            echo -e "${YELLOW}🟠  Authserver:${NC} process running, tmux missing"
        else
            echo -e "${RED}🔴  Authserver:${NC} OFFLINE"
        fi
    fi
}

# ==================================================
# Add account
# ==================================================

get_next_account_id() {
    local max_id

    max_id=$(mysql_exec -N -s -e "SELECT IFNULL(MAX(id),0) FROM account WHERE id < 10000;")

    if [[ -z "$max_id" || "$max_id" == "NULL" ]]; then
        echo "1"
    else
        echo $((max_id + 1))
    fi
}

account_id_exists() {
    local account_id="$1"
    local count

    count=$(mysql_exec -N -s -e "SELECT COUNT(*) FROM account WHERE id=$account_id;")
    [ "$count" -gt 0 ]
}

account_name_exists() {
    local account_name="$1"
    local account_name_escaped
    local count

    account_name_escaped=$(escape_sql "$account_name")
    count=$(mysql_exec -N -s -e "SELECT COUNT(*) FROM account WHERE username='$account_name_escaped';")

    [ "$count" -gt 0 ]
}

add_account() {
    local acc_id acc_name acc_name_esc acc_pass acc_pass_confirm
    local expansion srp6_values final_salt final_verifier confirm sql_query
    local next_id

    clear
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${CYAN}        ADD ACCOUNT                               ${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo ""

    check_python3

    echo -e "${GREEN}🐬  Auth database:${NC} $DB_NAME @ $DB_HOST:$DB_PORT"
    echo ""

    next_id=$(get_next_account_id)

    echo -e "${YELLOW}💡 Next normal account ID below 10000:${NC} $next_id"
    echo ""

    read -p "🔹  Account ID [$next_id]: " acc_id
    acc_id=${acc_id:-$next_id}
    validate_number "$acc_id" "Account ID"

    if account_id_exists "$acc_id"; then
        echo -e "${RED}❌ Account ID already exists:${NC} $acc_id"
        return 1
    fi

    read -p "🔹  Account name: " acc_name

    if [ -z "$acc_name" ]; then
        echo -e "${RED}❌ Account name must not be empty.${NC}"
        return 1
    fi

    acc_name=$(echo "$acc_name" | tr '[:lower:]' '[:upper:]' | xargs)
    acc_name_esc=$(escape_sql "$acc_name")

    if account_name_exists "$acc_name"; then
        echo -e "${RED}❌ Account name already exists:${NC} $acc_name"
        return 1
    fi

    read -s -p "🔒  Password: " acc_pass
    echo ""

    if [ -z "$acc_pass" ]; then
        echo -e "${RED}❌ Password must not be empty.${NC}"
        return 1
    fi

    read -s -p "🔒  Repeat password: " acc_pass_confirm
    echo ""

    if [ "$acc_pass" != "$acc_pass_confirm" ]; then
        echo -e "${RED}❌ Passwords do not match.${NC}"
        return 1
    fi

    echo ""
    echo -e "${YELLOW}💡 Expansion:${NC} 0=Classic, 1=TBC, 2=WotLK"
    read -p "🔹  Expansion [2]: " expansion
    expansion=${expansion:-2}
    validate_number "$expansion" "Expansion"

    if [ "$expansion" -lt 0 ] || [ "$expansion" -gt 2 ]; then
        echo -e "${RED}❌ Invalid expansion. Allowed values: 0, 1, 2.${NC}"
        return 1
    fi

    echo ""
    echo -e "${CYAN}⚙️  Calculating SRP6 data...${NC}"

    srp6_values=$(calculate_srp6 "$acc_name" "$acc_pass")

    final_salt=$(echo "$srp6_values" | awk '{print $1}')
    final_verifier=$(echo "$srp6_values" | awk '{print $2}')

    if [ -z "$final_salt" ] || [ -z "$final_verifier" ]; then
        echo -e "${RED}❌ SRP6 calculation failed.${NC}"
        return 1
    fi

    echo ""
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${CYAN}        ACCOUNT SUMMARY                           ${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo -e " 🆔  Account ID:  ${GREEN}$acc_id${NC}"
    echo -e " 👤  Username:    ${GREEN}$acc_name${NC}"
    echo -e " 🧩  Expansion:   ${GREEN}$expansion${NC}"
    echo -e " 🐬  Auth DB:     ${GREEN}$DB_NAME @ $DB_HOST:$DB_PORT${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo ""

    read -p "❓ Create this account in the auth database now? (y/n): " confirm

    if [[ ! "$confirm" =~ ^[JjYy]$ ]]; then
        echo -e "${YELLOW}👋 Operation cancelled.${NC}"
        return 0
    fi

    sql_query="
INSERT INTO account
    (id, username, salt, verifier, expansion)
VALUES
    ($acc_id, '$acc_name_esc', UNHEX('$final_salt'), UNHEX('$final_verifier'), $expansion);
"

    if mysql_exec -e "$sql_query"; then
        echo ""
        echo -e "${GREEN}✅ Account created successfully:${NC} $acc_name"
        echo -e "${GREEN}🆔 Account ID:${NC} $acc_id"
    else
        echo ""
        echo -e "${RED}❌ Failed to insert account into auth database.${NC}"
        return 1
    fi
}

# ==================================================
# Edit account
# ==================================================

EDIT_ACCOUNT_ID=""
EDIT_ACCOUNT_USER=""
EDIT_ACCOUNT_EXP=""
EDIT_ACCOUNT_LOCKED=""

load_edit_account_data() {
    local search="$1"
    local data

    data=$(find_account "$search")

    if [ -z "$data" ]; then
        echo -e "${RED}❌ Account not found.${NC}"
        return 1
    fi

    IFS=$'\t' read -r EDIT_ACCOUNT_ID EDIT_ACCOUNT_USER EDIT_ACCOUNT_EXP EDIT_ACCOUNT_LOCKED <<< "$data"

    if [ -z "$EDIT_ACCOUNT_ID" ] || [ -z "$EDIT_ACCOUNT_USER" ]; then
        echo -e "${RED}❌ Could not parse account data.${NC}"
        return 1
    fi
}

show_edit_account_info() {
    clear

    echo -e "${CYAN}==================================================${NC}"
    echo -e "${CYAN}        EDIT ACCOUNT                              ${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo ""
    echo -e "${GREEN}🐬  Auth DB:${NC} $DB_NAME @ $DB_HOST:$DB_PORT"
    echo ""
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${CYAN}        ACCOUNT INFORMATION                       ${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo -e " 🆔  ID:          ${GREEN}$EDIT_ACCOUNT_ID${NC}"
    echo -e " 👤  Username:    ${GREEN}$EDIT_ACCOUNT_USER${NC}"
    echo -e " 🧩  Expansion:   ${GREEN}$EDIT_ACCOUNT_EXP${NC}"
    echo -e " 🔒  Locked:      ${GREEN}${EDIT_ACCOUNT_LOCKED:-0}${NC}"
    echo -e "${CYAN}==================================================${NC}"
}

change_password() {
    local new_pass new_pass_confirm srp6_values final_salt final_verifier

    echo ""

    read -s -p "🔒  New password: " new_pass
    echo ""

    if [ -z "$new_pass" ]; then
        echo -e "${RED}❌ Password must not be empty.${NC}"
        return
    fi

    read -s -p "🔒  Repeat password: " new_pass_confirm
    echo ""

    if [ "$new_pass" != "$new_pass_confirm" ]; then
        echo -e "${RED}❌ Passwords do not match.${NC}"
        return
    fi

    echo ""
    echo -e "${CYAN}⚙️  Calculating new SRP6 data...${NC}"

    srp6_values=$(calculate_srp6 "$EDIT_ACCOUNT_USER" "$new_pass")

    final_salt=$(echo "$srp6_values" | awk '{print $1}')
    final_verifier=$(echo "$srp6_values" | awk '{print $2}')

    if [ -z "$final_salt" ] || [ -z "$final_verifier" ]; then
        echo -e "${RED}❌ SRP6 calculation failed.${NC}"
        return
    fi

    if mysql_exec -e "
        UPDATE account
        SET salt=UNHEX('$final_salt'),
            verifier=UNHEX('$final_verifier'),
            session_key=NULL
        WHERE id=$EDIT_ACCOUNT_ID;
    "; then
        echo -e "${GREEN}✅ Password was changed successfully.${NC}"
    else
        echo -e "${RED}❌ Failed to change password.${NC}"
    fi
}

change_expansion() {
    local new_exp

    echo ""
    echo -e "${YELLOW}💡 Expansion:${NC} 0=Classic, 1=TBC, 2=WotLK"
    read -p "🔹  New expansion [$EDIT_ACCOUNT_EXP]: " new_exp
    new_exp=${new_exp:-$EDIT_ACCOUNT_EXP}

    if [[ ! "$new_exp" =~ ^[0-2]$ ]]; then
        echo -e "${RED}❌ Invalid expansion. Allowed values: 0, 1, 2.${NC}"
        return
    fi

    if mysql_exec -e "
        UPDATE account
        SET expansion=$new_exp
        WHERE id=$EDIT_ACCOUNT_ID;
    "; then
        EDIT_ACCOUNT_EXP="$new_exp"
        echo -e "${GREEN}✅ Expansion was changed successfully.${NC}"
    else
        echo -e "${RED}❌ Failed to change expansion.${NC}"
    fi
}

change_username() {
    local new_name new_name_escaped name_exists confirm

    echo ""
    read -p "🔹  New account name: " new_name

    if [ -z "$new_name" ]; then
        echo -e "${RED}❌ Name must not be empty.${NC}"
        return
    fi

    new_name=$(echo "$new_name" | tr '[:lower:]' '[:upper:]' | xargs)
    new_name_escaped=$(escape_sql "$new_name")

    name_exists=$(mysql_exec -N -s -e "
        SELECT COUNT(*)
        FROM account
        WHERE username='$new_name_escaped'
          AND id<>$EDIT_ACCOUNT_ID;
    ")

    if [ "$name_exists" -gt 0 ]; then
        echo -e "${RED}❌ Account name already exists:${NC} $new_name"
        return
    fi

    echo ""
    echo -e "${YELLOW}⚠️  Username change:${NC} $EDIT_ACCOUNT_USER -> $new_name"
    echo -e "${YELLOW}💡 Note:${NC} After changing the username, the password must be reset because SRP6 depends on the username."
    echo ""
    read -p "❓ Continue? (y/n): " confirm

    if [[ ! "$confirm" =~ ^[JjYy]$ ]]; then
        echo -e "${YELLOW}👋 Operation cancelled.${NC}"
        return
    fi

    if mysql_exec -e "
        UPDATE account
        SET username='$new_name_escaped'
        WHERE id=$EDIT_ACCOUNT_ID;
    "; then
        EDIT_ACCOUNT_USER="$new_name"

        echo -e "${GREEN}✅ Username was changed successfully.${NC}"
        echo ""
        echo -e "${YELLOW}⚠️  Password must now be reset for the new username.${NC}"

        change_password
        load_edit_account_data "$EDIT_ACCOUNT_ID"
    else
        echo -e "${RED}❌ Failed to change username.${NC}"
    fi
}

edit_account() {
    local search

    clear
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${CYAN}        EDIT ACCOUNT                              ${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo ""
    echo -e "${GREEN}🐬  Auth DB:${NC} $DB_NAME @ $DB_HOST:$DB_PORT"
    echo ""

    read -p "🔹  Account name or account ID: " search

    if [ -z "$search" ]; then
        echo -e "${RED}❌ Input must not be empty.${NC}"
        return 1
    fi

    if ! load_edit_account_data "$search"; then
        return 1
    fi

    while true; do
        show_edit_account_info

        echo ""
        echo -e "  ${MAGENTA}[1]${NC} 🔒  Change password"
        echo -e "  ${MAGENTA}[2]${NC} 🧩  Change expansion"
        echo -e "  ${MAGENTA}[3]${NC} 👤  Change username"
        echo -e "  ${CYAN}[0]${NC} ↩️  Back"
        echo ""

        read -p "Select option [0]: " OPTION
        OPTION=${OPTION:-0}

        case "$OPTION" in
            1)
                change_password
                pause_menu
                load_edit_account_data "$EDIT_ACCOUNT_ID"
                ;;

            2)
                change_expansion
                pause_menu
                load_edit_account_data "$EDIT_ACCOUNT_ID"
                ;;

            3)
                change_username
                pause_menu
                load_edit_account_data "$EDIT_ACCOUNT_ID"
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
# Set GM level
# ==================================================

show_account_gm_status() {
    local account_id="$1"
    local result

    result=$(mysql_exec --batch --skip-column-names -e "
        SELECT
            aa.RealmID,
            CASE
                WHEN aa.RealmID = -1 THEN 'All realms'
                ELSE IFNULL(r.name, 'Unknown realm')
            END AS realm_name,
            aa.gmlevel
        FROM account_access aa
        LEFT JOIN realmlist r
            ON r.id = aa.RealmID
        WHERE aa.id=$account_id
        ORDER BY aa.RealmID;
    ")

    if [ -z "$result" ]; then
        echo -e "    ${YELLOW}No GM access entries${NC}"
        return
    fi

    printf "    %-8s %-24s %-8s\n" "RealmID" "Realm name" "Level"
    printf "    %-8s %-24s %-8s\n" "-------" "----------" "-----"

    while IFS=$'\t' read -r realm_id realm_name gm_level; do
        printf "    %-8s %-24.24s %-8s\n" "$realm_id" "$realm_name" "$gm_level"
    done <<< "$result"
}

show_realm_selection() {
    local realm_list

    echo ""
    echo -e "${CYAN}Realm selection:${NC}"
    echo -e "${GREEN}[-1]${NC} All realms"

    realm_list=$(mysql_exec --batch --skip-column-names -e "
        SELECT id, name
        FROM realmlist
        ORDER BY id ASC;
    ")

    while IFS=$'\t' read -r realm_id realm_name; do
        [ -n "$realm_id" ] && echo -e "${GREEN}[$realm_id]${NC} $realm_name"
    done <<< "$realm_list"

    echo ""
}

realm_exists() {
    local realm_id="$1"
    local count

    if [ "$realm_id" = "-1" ]; then
        return 0
    fi

    count=$(mysql_exec -N -s -e "
        SELECT COUNT(*)
        FROM realmlist
        WHERE id=$realm_id;
    ")

    [ "$count" -gt 0 ]
}

set_gm_level() {
    local account_id="$1"
    local gm_level="$2"
    local realm_id="$3"
    local sql

    if [ "$gm_level" = "0" ]; then
        sql="
            DELETE FROM account_access
            WHERE id=$account_id
              AND RealmID=$realm_id;
        "
    else
        sql="
            DELETE FROM account_access
            WHERE id=$account_id
              AND RealmID=$realm_id;

            INSERT INTO account_access (id, gmlevel, RealmID)
            VALUES ($account_id, $gm_level, $realm_id);
        "
    fi

    mysql_exec -e "$sql"
}

set_gm_level_flow() {
    local search_param account_data account_id account_name account_expansion
    local account_confirm gm_level realm_id confirm realm_label

    clear
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${CYAN}        SET GM LEVEL                              ${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo ""
    echo -e "${GREEN}🐬  Auth DB:${NC} $DB_NAME @ $DB_HOST:$DB_PORT"
    echo ""

    read -p "🔹  Account name or account ID: " search_param

    if [ -z "$search_param" ]; then
        echo -e "${RED}❌ Input must not be empty.${NC}"
        return 1
    fi

    account_data=$(find_account "$search_param")

    if [ -z "$account_data" ]; then
        echo -e "${RED}❌ Account not found.${NC}"
        return 1
    fi

    IFS=$'\t' read -r account_id account_name account_expansion _ <<< "$account_data"

    if [ -z "$account_id" ] || [ -z "$account_name" ]; then
        echo -e "${RED}❌ Could not parse account data.${NC}"
        return 1
    fi

    echo ""
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${CYAN}        ACCOUNT FOUND                             ${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo -e " 🆔  ID:          ${GREEN}$account_id${NC}"
    echo -e " 👤  Username:    ${GREEN}$account_name${NC}"
    echo -e " 🧩  Expansion:   ${GREEN}$account_expansion${NC}"
    echo -e " 👑  GM status:"
    show_account_gm_status "$account_id"
    echo -e "${CYAN}==================================================${NC}"
    echo ""

    read -p "❓ Is this the correct account? (y/n): " account_confirm

    if [[ ! "$account_confirm" =~ ^[JjYy]$ ]]; then
        echo -e "${YELLOW}👋 Operation cancelled.${NC}"
        return 0
    fi

    echo ""
    echo -e "${YELLOW}GM levels:${NC}"
    echo "  0 = Player / remove GM access"
    echo "  1 = Moderator / Trial GM"
    echo "  2 = Gamemaster"
    echo "  3 = Administrator"
    echo "  4 = Console (not for accounts; DB/manual only)"
    echo ""

    read -p "🔹  New GM level [0-3]: " gm_level

    if [[ ! "$gm_level" =~ ^[0-3]$ ]]; then
        echo -e "${RED}❌ Invalid GM level. Allowed values: 0, 1, 2, 3.${NC}"
        return 1
    fi

    show_realm_selection

    read -p "🔹  Realm ID [-1]: " realm_id
    realm_id=${realm_id:--1}

    validate_number "$realm_id" "Realm ID"

    if ! realm_exists "$realm_id"; then
        echo -e "${RED}❌ Realm ID does not exist:${NC} $realm_id"
        return 1
    fi

    if [ "$realm_id" = "-1" ]; then
        realm_label="All realms"
    else
        realm_label=$(mysql_exec -N -s -e "SELECT name FROM realmlist WHERE id=$realm_id LIMIT 1;")
    fi

    echo ""
    echo -e "${YELLOW}⚠️  GM level change summary:${NC}"
    echo -e " 👤  Account:  ${GREEN}$account_name${NC}"
    echo -e " 🆔  ID:       ${GREEN}$account_id${NC}"
    echo -e " 👑  Level:    ${GREEN}$gm_level${NC}"
    echo -e " 🌍  Realm:    ${GREEN}$realm_id - $realm_label${NC}"
    echo ""

    read -p "❓ Continue? (y/n): " confirm

    if [[ ! "$confirm" =~ ^[JjYy]$ ]]; then
        echo -e "${YELLOW}👋 Operation cancelled.${NC}"
        return 0
    fi

    if set_gm_level "$account_id" "$gm_level" "$realm_id"; then
        echo ""
        if [ "$gm_level" = "0" ]; then
            echo -e "${GREEN}✅ GM access removed successfully.${NC}"
        else
            echo -e "${GREEN}✅ GM level was set successfully.${NC}"
        fi
    else
        echo ""
        echo -e "${RED}❌ Failed to set GM level.${NC}"
        return 1
    fi

    echo ""
    echo -e "${CYAN}Updated GM status:${NC}"
    show_account_gm_status "$account_id"
}

# ==================================================
# Show account
# ==================================================

show_account_flow() {
    local search where row up
    local id username email reg_mail joindate last_login last_ip failed_logins
    local locked lock_country online expansion mutetime mutereason totaltime
    local ban bd ubd br bby bact

    clear
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${CYAN}        SHOW ACCOUNT                              ${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo ""
    echo -e "${GREEN}🐬  Auth DB:${NC} $DB_NAME @ $DB_HOST:$DB_PORT"
    echo ""

    read -p "🔹  Account name or account ID: " search
    [ -z "$search" ] && { echo -e "${RED}❌ Input must not be empty.${NC}"; return 1; }

    if [[ "$search" =~ ^[0-9]+$ ]]; then
        where="id=$search"
    else
        up=$(printf '%s' "$search" | tr '[:lower:]' '[:upper:]' | xargs)
        up=$(escape_sql "$up")
        where="username='$up'"
    fi

    row=$(mysql_exec --batch --skip-column-names -e "
        SELECT id, username, email, reg_mail, joindate, last_login, last_ip,
               failed_logins, locked, lock_country, online, expansion,
               mutetime, mutereason, totaltime
        FROM account
        WHERE $where
        LIMIT 1;
    ")

    if [ -z "$row" ]; then
        echo -e "${RED}❌ Account not found.${NC}"
        return 1
    fi

    # `read` with a whitespace IFS collapses empty fields (email/last_login are
    # often ''), shifting every column. mapfile -d keeps them.
    local -a f
    mapfile -td $'\t' f < <(printf '%s' "$row")
    id=${f[0]}       username=${f[1]}   email=${f[2]}        reg_mail=${f[3]}
    joindate=${f[4]} last_login=${f[5]} last_ip=${f[6]}      failed_logins=${f[7]}
    locked=${f[8]}   lock_country=${f[9]} online=${f[10]}    expansion=${f[11]}
    mutetime=${f[12]} mutereason=${f[13]} totaltime=${f[14]}

    echo ""
    echo -e "${CYAN}==================================================${NC}"
    printf " %-15s ${GREEN}%s${NC}\n" "🆔  ID:"          "$id"
    printf " %-15s ${GREEN}%s${NC}\n" "👤  Username:"    "$username"
    printf " %-15s %s\n"              "📧  Email:"       "${email:--}"
    printf " %-15s %s\n"              "📧  Reg. email:"  "${reg_mail:--}"
    printf " %-15s %s\n"              "🧩  Expansion:"   "$expansion  (0=Classic 1=TBC 2=WotLK)"
    printf " %-15s %s\n"              "📅  Created:"     "${joindate:--}"
    printf " %-15s %s\n"              "🕑  Last login:"  "${last_login:--}"
    printf " %-15s %s\n"              "🌐  Last IP:"     "${last_ip:--}"
    printf " %-15s %s\n"              "❌  Failed logs:" "${failed_logins:-0}"
    if [ "${locked:-0}" = "1" ]; then
        printf " %-15s ${RED}%s${NC}\n" "🔒  Locked:"   "yes${lock_country:+  (country ${lock_country})}"
    else
        printf " %-15s %s\n"           "🔒  Locked:"   "no"
    fi
    if [ "${online:-0}" = "1" ]; then
        printf " %-15s ${GREEN}%s${NC}\n" "🟢  Online:"  "yes"
    else
        printf " %-15s %s\n"             "⚫  Online:"  "no"
    fi
    printf " %-15s %s\n"              "⏱️  Played:"     "$(( ${totaltime:-0} / 3600 ))h"
    if [ -n "$mutetime" ] && [ "$mutetime" != "0" ]; then
        printf " %-15s ${RED}%s${NC}\n" "🔇  Muted:" "$(date -d "@$mutetime" 2>/dev/null || echo "$mutetime")  (${mutereason:-no reason})"
    fi
    echo -e "${CYAN}==================================================${NC}"
    echo -e " 👑  GM access:"
    show_account_gm_status "$id"
    echo -e "${CYAN}==================================================${NC}"

    ban=$(mysql_exec --batch --skip-column-names -e "
        SELECT bandate, unbandate, banreason, bannedby, active
        FROM account_banned
        WHERE id=$id
        ORDER BY bandate DESC
        LIMIT 1;
    " 2>/dev/null)

    if [ -n "$ban" ]; then
        IFS=$'\t' read -r bd ubd br bby bact <<< "$ban"
        if [ "$bact" = "1" ]; then
            echo -e " 🚫  ${RED}BANNED${NC} by ${bby:-?}  -  ${br:-no reason}"
        else
            echo -e " 🚫  ban history (currently inactive), last by ${bby:-?}"
        fi
    else
        echo -e " ✅  No ban record."
    fi
}

# ==================================================
# Delete account
# ==================================================

delete_account_flow() {
    local search account_data account_id account_name confirm

    clear
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${CYAN}        DELETE ACCOUNT                            ${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo ""
    echo -e "${GREEN}🐬  Auth DB:${NC} $DB_NAME @ $DB_HOST:$DB_PORT"
    echo ""

    read -p "🔹  Account name or account ID: " search
    [ -z "$search" ] && { echo -e "${RED}❌ Input must not be empty.${NC}"; return 1; }

    account_data=$(find_account "$search")
    if [ -z "$account_data" ]; then
        echo -e "${RED}❌ Account not found.${NC}"
        return 1
    fi
    IFS=$'\t' read -r account_id account_name _ _ <<< "$account_data"

    echo ""
    echo -e "${YELLOW}⚠️  About to delete account ${RED}[$account_id] $account_name${NC}"
    echo -e "${YELLOW}   and every account_access (GM) row it owns.${NC}"
    read -p "Type 'DELETE' to confirm: " confirm

    if [ "$confirm" != "DELETE" ]; then
        echo -e "${YELLOW}👋 Operation cancelled.${NC}"
        return 0
    fi

    if mysql_exec -e "DELETE FROM account WHERE id=$account_id; DELETE FROM account_access WHERE id=$account_id;"; then
        echo -e "${GREEN}✅ Account deleted:${NC} [$account_id] $account_name"
    else
        echo -e "${RED}❌ Failed to delete account.${NC}"
        return 1
    fi
}

# ==================================================
# Top-level menu
# ==================================================

if ! read_login_db_info; then
    echo -e "${RED}❌ Could not read LoginDatabaseInfo from authserver.conf.${NC}"
    echo "   $AUTH_CONF"
    exit 1
fi

check_python3

while true; do
    clear

    echo -e "${CYAN}==================================================${NC}"
    echo -e "${CYAN}        AZEROTHCORE ACCOUNT MANAGEMENT            ${NC}"
    echo -e "${CYAN}==================================================${NC}"
    show_auth_status
    echo -e "${CYAN}📄  Config:${NC} ${AUTH_CONF:-unknown}"
    echo "--------------------------------------------------"
    echo -e "  ${GREEN}[1]${NC}  🔍  Show account"
    echo -e "  ${GREEN}[2]${NC}  ➕  Add account"
    echo -e "  ${MAGENTA}[3]${NC}  ✏️  Edit account"
    echo -e "  ${MAGENTA}[4]${NC}  🛡️  Set GM level"
    echo -e "  ${MAGENTA}[5]${NC}  🧬  Account AUTO_INCREMENT"
    echo -e "  ${RED}[6]${NC}  🗑️  Delete account"
    echo ""
    echo -e "  ${CYAN}[0]${NC}  ↩️  Back"
    echo "--------------------------------------------------"

    read -p "Select option [0]: " OPTION
    OPTION=${OPTION:-0}

    case "$OPTION" in
        1)
            clear
            show_account_flow
            pause_menu
            ;;

        2)
            clear
            add_account
            pause_menu
            ;;

        3)
            clear
            edit_account
            pause_menu
            ;;

        4)
            clear
            set_gm_level_flow
            pause_menu
            ;;

        5)
            clear
            "$SCRIPT_DIR/db-autoincrement.sh"
            pause_menu
            ;;

        6)
            clear
            delete_account_flow
            pause_menu
            ;;

        0)
            exit 0
            ;;

        *)
            echo -e "${RED}❌ Invalid option.${NC}"
            sleep 1
            ;;
    esac
done

exit 0
