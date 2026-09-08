#!/usr/bin/env bash

# ==================================================
# AZEROTHCORE AUTH TOOLS
# Account, GM-level and AUTO_INCREMENT management plus the realmlist and MOTD
# tables - all in the auth database. Launched from auth-menu.sh:
#   auth-tools.sh accounts   -> account menu
#   auth-tools.sh realms     -> realmlist & MOTD menu
#   auth-tools.sh            -> small top menu (direct invocation only)
# (vendored from InnControl scripts/auth/08_account_manager.sh +
#  06_realmlist_motd_manager.sh; 09_db_autoincrement_manager.sh folded in)
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

# Realm/MOTD menus expect this exact prompt (overrides common.sh's wait_for_user).
wait_for_user() {
    echo ""
    echo -e "${CYAN}↩️  Press [ENTER] to continue...${NC}"
    read -r
}

# mysql_auth (runs a query as the LoginDatabaseInfo user) and read_login_database
# (parses authserver.conf into DB_HOST..DB_NAME) both come from common-ops.sh.

escape_sql() {
    printf "%s" "$1" | sed "s/'/''/g"
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
        mysql_auth --batch --skip-column-names -e "
            SELECT id, username, expansion, locked
            FROM account
            WHERE id=$input
            LIMIT 1;
        "
    else
        upper=$(echo "$input" | tr '[:lower:]' '[:upper:]' | xargs)
        escaped=$(escape_sql "$upper")

        mysql_auth --batch --skip-column-names -e "
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

    max_id=$(mysql_auth -N -s -e "SELECT IFNULL(MAX(id),0) FROM account WHERE id < 10000;")

    if [[ -z "$max_id" || "$max_id" == "NULL" ]]; then
        echo "1"
    else
        echo $((max_id + 1))
    fi
}

account_id_exists() {
    local account_id="$1"
    local count

    count=$(mysql_auth -N -s -e "SELECT COUNT(*) FROM account WHERE id=$account_id;")
    [ "$count" -gt 0 ]
}

account_name_exists() {
    local account_name="$1"
    local account_name_escaped
    local count

    account_name_escaped=$(escape_sql "$account_name")
    count=$(mysql_auth -N -s -e "SELECT COUNT(*) FROM account WHERE username='$account_name_escaped';")

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

    if mysql_auth -e "$sql_query"; then
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

    if mysql_auth -e "
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

    if mysql_auth -e "
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

    name_exists=$(mysql_auth -N -s -e "
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

    if mysql_auth -e "
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

    result=$(mysql_auth --batch --skip-column-names -e "
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

    realm_list=$(mysql_auth --batch --skip-column-names -e "
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

    count=$(mysql_auth -N -s -e "
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

    mysql_auth -e "$sql"
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
        realm_label=$(mysql_auth -N -s -e "SELECT name FROM realmlist WHERE id=$realm_id LIMIT 1;")
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

    row=$(mysql_auth --batch --skip-column-names -e "
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

    ban=$(mysql_auth --batch --skip-column-names -e "
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

    if mysql_auth -e "DELETE FROM account WHERE id=$account_id; DELETE FROM account_access WHERE id=$account_id;"; then
        echo -e "${GREEN}✅ Account deleted:${NC} [$account_id] $account_name"
    else
        echo -e "${RED}❌ Failed to delete account.${NC}"
        return 1
    fi
}

# --------------------------------------------------
# Account AUTO_INCREMENT (folded in from InnControl
# scripts/auth/09_db_autoincrement_manager.sh). Uses mysql_auth / DB_* from
# common-ops.sh; errors return, never exit.
# --------------------------------------------------
set_account_auto_increment() {
    local current_max current_auto min_allowed startpoint confirm_low confirm new_auto create_sql extra

    echo -e "${CYAN}==================================================${NC}"
    echo -e "${CYAN}        ACCOUNT AUTO_INCREMENT MANAGER            ${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo ""

    if ! mysql_auth -N -s -e "SELECT 1;" >/dev/null 2>&1; then
        echo -e "${RED}❌ MySQL connection failed:${NC} $DB_NAME @ $DB_HOST:$DB_PORT ($DB_USER)"
        return 1
    fi

    if [ "$(mysql_auth -N -s -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB_NAME' AND TABLE_NAME='account';" 2>/dev/null)" != "1" ]; then
        echo -e "${RED}❌ Table not found:${NC} $DB_NAME.account"
        return 1
    fi

    extra=$(mysql_auth -N -s -e "SELECT EXTRA FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='$DB_NAME' AND TABLE_NAME='account' AND COLUMN_NAME='id';" 2>/dev/null)
    if [[ "$extra" != *auto_increment* ]]; then
        echo -e "${RED}❌ Column is not AUTO_INCREMENT:${NC} $DB_NAME.account.id"
        return 1
    fi

    current_max=$(mysql_auth -N -s -e "SELECT IFNULL(MAX(\`id\`),0) FROM \`account\`;" 2>/dev/null)
    create_sql=$(mysql_auth -N -B -e "SHOW CREATE TABLE \`account\`;" 2>/dev/null)
    current_auto=$(echo "$create_sql" | grep -o "AUTO_INCREMENT=[0-9]*" | head -n 1 | cut -d'=' -f2)
    [ -z "$current_max" ] && current_max=0
    [ -z "$current_auto" ] && current_auto=0
    min_allowed=$((current_max + 1))

    echo -e "Auth database:            ${GREEN}${DB_NAME}${NC} @ ${DB_HOST}:${DB_PORT}"
    echo -e "Table:                    ${GREEN}account${NC}"
    echo -e "ID column:                ${GREEN}id${NC}"
    echo -e "Highest current ID:       ${GREEN}${current_max}${NC}"
    echo -e "Current AUTO_INCREMENT:   ${GREEN}${current_auto}${NC}"
    echo -e "Minimum useful value:     ${GREEN}${min_allowed}${NC}"
    echo ""
    echo -e "${YELLOW}💡 Recommended:${NC}"
    echo "   10000 if you want manually created accounts to stay below 10000"
    echo "   and automatically created accounts to start at 10000+."
    echo ""

    read -p "🔹  New account AUTO_INCREMENT value [10000]: " startpoint
    startpoint="${startpoint:-10000}"
    if [[ ! "$startpoint" =~ ^[0-9]+$ ]] || [ "$startpoint" -lt 1 ]; then
        echo -e "${RED}❌ Invalid value:${NC} $startpoint"
        return 1
    fi

    if [ "$startpoint" -lt "$min_allowed" ]; then
        echo ""
        echo -e "${YELLOW}⚠️  Value is below MAX(id)+1 - MySQL will use at least ${min_allowed}.${NC}"
        read -p "❓ Continue anyway? (y/n): " confirm_low
        [[ "$confirm_low" =~ ^[JjYy]$ ]] || { echo -e "${YELLOW}👋 Operation cancelled.${NC}"; return 0; }
    fi

    echo ""
    echo "SQL:  ALTER TABLE \`$DB_NAME\`.\`account\` AUTO_INCREMENT = $startpoint;"
    read -p "❓ Set AUTO_INCREMENT now? (y/n): " confirm
    [[ "$confirm" =~ ^[JjYy]$ ]] || { echo -e "${YELLOW}👋 Operation cancelled.${NC}"; return 0; }

    if ! mysql_auth -e "ALTER TABLE \`$DB_NAME\`.\`account\` AUTO_INCREMENT = $startpoint;"; then
        echo -e "${RED}❌ Failed to set AUTO_INCREMENT.${NC}"
        return 1
    fi

    new_auto=$(mysql_auth -N -B -e "SHOW CREATE TABLE \`account\`;" 2>/dev/null \
        | grep -o "AUTO_INCREMENT=[0-9]*" | head -n 1 | cut -d'=' -f2)
    echo ""
    echo -e "${GREEN}✅ AUTO_INCREMENT updated.${NC}  ${current_auto} → ${new_auto:-?}  (requested ${startpoint})"
    if [ -n "$new_auto" ] && [ "$new_auto" -lt "$startpoint" ]; then
        echo -e "${YELLOW}⚠️  Reported value is lower than requested - check with:${NC}"
        echo "   SHOW CREATE TABLE \`$DB_NAME\`.\`account\`\\G"
    fi
}
# ================================================================
# Account menu
# ================================================================
account_menu() {
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
    echo -e "  ${RED}[5]${NC}  🗑️  Delete account"
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
            delete_account_flow
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

    rows=$(mysql_auth --batch --skip-column-names -e "
        SELECT id, name, address, localAddress, localSubnetMask, port, icon, flag, timezone, allowedSecurityLevel, gamebuild
        FROM realmlist
        ORDER BY id;
    ")

    if [ -z "$rows" ]; then
        echo -e "${YELLOW}ℹ️  No realms found.${NC}"
        echo "--------------------------------------------------------------------------------"
        return
    fi

    printf " %-4s %-18s %-10s %-22s %-22s %-6s %-17s %-5s %-4s %-7s\n" \
        "ID" "Name" "Type" "Address" "LocalAddress" "Port" "Flag" "TZ" "GM" "Build"
    echo "--------------------------------------------------------------------------------"

    while IFS=$'\t' read -r id name address local_address netmask port icon flag timezone security build; do
        realm_type=$(get_realm_type_name "$icon")
        cidr=$(mask_to_cidr "$netmask")
        local_display="${local_address}${cidr}"
        flag=$(realm_flag_names "$flag")

        printf " %-4s %-18s %-10s %-22s %-22s %-6s %-17s %-5s %-4s %-7s\n" \
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

    rows=$(mysql_auth --batch --skip-column-names -e "
        SELECT id, name, address, localAddress, localSubnetMask, port, icon, flag, timezone, allowedSecurityLevel, gamebuild
        FROM realmlist
        ORDER BY id;
    ")

    if [ -z "$rows" ]; then
        echo -e "${YELLOW}ℹ️  No realms found.${NC}"
        echo "--------------------------------------------------------------------------------------------"
        return
    fi

    printf " %-4s %-18s %-10s %-22s %-22s %-6s %-17s %-5s %-4s %-7s %-8s\n" \
        "ID" "Name" "Type" "Address" "LocalAddress" "Port" "Flag" "TZ" "GM" "Build" "Status"
    echo "--------------------------------------------------------------------------------------------"

    while IFS=$'\t' read -r id name address local_address netmask port icon flag timezone security build; do
        realm_type=$(get_realm_type_name "$icon")
        cidr=$(mask_to_cidr "$netmask")
        local_display="${local_address}${cidr}"
        flag=$(realm_flag_names "$flag")
        status=$(check_realm_online "$address" "$port")

        if [ "$status" = "ONLINE" ]; then
            status="${GREEN}ONLINE${NC}"
        else
            status="${RED}OFFLINE${NC}"
        fi

        printf " %-4s %-18s %-10s %-22s %-22s %-6s %-17s %-5s %-4s %-7s " \
            "$id" "$name" "$realm_type" "$address" "$local_display" "$port" "$flag" "$timezone" "$security" "$build"
        echo -e "$status"
    done <<< "$rows"

    echo "-------------------------------------------------------------------------------------------------------"
}

get_next_realm_id() {
    local max_id
    max_id=$(mysql_auth -N -s -e "SELECT IFNULL(MAX(id),0) FROM realmlist;")
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

    existing_row=$(mysql_auth --batch --skip-column-names -e "
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
    echo -e "${YELLOW}💡 flag:${NC} 0=None, 1=Invalid, 2=Offline, 4=Build, 8=Medium, 16=Medium, 32=New, 64=Recommended, 128=Full"
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

    if mysql_auth -e "$sql_query"; then
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

    realm_name=$(mysql_auth -N -s -e "SELECT name FROM realmlist WHERE id=$delete_id LIMIT 1;")

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

    if mysql_auth -e "DELETE FROM realmlist WHERE id=$delete_id;"; then
        mysql_auth -e "DELETE FROM motd WHERE realmid=$delete_id;" 2>/dev/null
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
    if ! mysql_auth -N -s -e "SHOW TABLES LIKE 'motd';" | grep -q "^motd$"; then
        echo -e "${YELLOW}⚠️  Table 'motd' does not exist.${NC}"
        read -p "❓ Create table now? (y/n): " CONFIRM

        if [[ "$CONFIRM" =~ ^[JjYy]$ ]]; then
            if mysql_auth -e "
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

    mysql_auth --batch --skip-column-names -e "
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

    result=$(mysql_auth --batch --skip-column-names -e "
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
        realm_exists=$(mysql_auth -N -s -e "SELECT COUNT(*) FROM realmlist WHERE id=$realm_id;")

        if [ "$realm_exists" -eq 0 ]; then
            echo -e "${RED}❌ Realm ID does not exist:${NC} $realm_id"
            return 1
        fi
    fi

    return 0
}

get_current_motd() {
    local realm_id="$1"

    mysql_auth -N -s -e "
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

    if mysql_auth -e "
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

    motd_exists=$(mysql_auth -N -s -e "SELECT COUNT(*) FROM motd WHERE realmid=$realm_id;")

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

    if mysql_auth -e "DELETE FROM motd WHERE realmid=$realm_id;"; then
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
# ================================================================
# Realmlist & MOTD menu
# ================================================================
realm_motd_menu() {
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
# Entry point
# ==================================================

if ! read_login_database; then
    echo -e "${RED}❌ Could not read LoginDatabaseInfo from authserver.conf.${NC}"
    echo "   $AUTH_CONF"
    exit 1
fi

case "${1:-}" in
    accounts)
        check_python3
        account_menu
        ;;
    realms|motd)
        realm_motd_menu
        ;;
    autoincrement)
        set_account_auto_increment
        pause_menu
        ;;
    *)
        while true; do
            clear
            echo -e "${CYAN}==================================================${NC}"
            echo -e "${CYAN}        AZEROTHCORE AUTH TOOLS                    ${NC}"
            echo -e "${CYAN}==================================================${NC}"
            echo ""
            echo -e "${GREEN}✅ Auth database:${NC} $DB_NAME @ $DB_HOST:$DB_PORT"
            echo ""
            echo "--------------------------------------------------"
            echo -e "  ${GREEN}[1]${NC}  👤  Account management"
            echo -e "  ${GREEN}[2]${NC}  🌍  Realmlist & MOTD"
            echo -e "  ${CYAN}[0]${NC}  🚪  Exit"
            echo "--------------------------------------------------"
            read -p "Select option [0]: " MAIN_OPTION
            MAIN_OPTION=${MAIN_OPTION:-0}
            case "$MAIN_OPTION" in
                1) check_python3 && account_menu ;;
                2) realm_motd_menu ;;
                0) exit 0 ;;
                *) echo -e "${RED}❌ Invalid option.${NC}"; sleep 1 ;;
            esac
        done
        ;;
esac

exit 0
