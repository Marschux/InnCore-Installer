#!/usr/bin/env bash

# ==================================================
# AZEROTHCORE AUTHSERVER ACCOUNT AUTO_INCREMENT MANAGER
# Manages AUTO_INCREMENT for auth.account.id.
# (vendored from InnControl scripts/auth/09_db_autoincrement_manager.sh)
# ==================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
set +eu

CYAN='\033[1;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

DB_HOST=""
DB_PORT=""
DB_USER=""
DB_PASS=""
DB_NAME=""

read_login_db_info() {
    local line=""

    if [ ! -f "$AUTH_CONF" ]; then
        echo -e "${RED}❌ authserver.conf not found:${NC}"
        echo "   $AUTH_CONF"
        exit 1
    fi

    line=$(grep -E "^[[:space:]]*LoginDatabaseInfo[[:space:]]*=" "$AUTH_CONF" | tail -n 1)
    line=$(echo "$line" | cut -d'=' -f2- | cut -d'#' -f1 | xargs)
    line=$(echo "$line" | sed 's/^"//;s/"$//')

    IFS=';' read -r DB_HOST DB_PORT DB_USER DB_PASS DB_NAME <<< "$line"

    if [ -z "$DB_HOST" ] || [ -z "$DB_PORT" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASS" ] || [ -z "$DB_NAME" ]; then
        echo -e "${RED}❌ Could not read LoginDatabaseInfo correctly from authserver.conf.${NC}"
        echo "Found line:"
        echo "   $line"
        exit 1
    fi
}

mysql_raw() {
    MYSQL_PWD="$DB_PASS" mysql \
        -h "$DB_HOST" \
        -P "$DB_PORT" \
        -u "$DB_USER" \
        "$@"
}

mysql_db() {
    mysql_raw "$DB_NAME" "$@"
}

mysql_silent_db() {
    mysql_raw -N -s "$DB_NAME" "$@"
}

mysql_silent_info() {
    mysql_raw -N -s information_schema "$@"
}

test_connection() {
    if ! mysql_silent_db -e "SELECT 1;" >/dev/null 2>&1; then
        echo -e "${RED}❌ MySQL connection failed:${NC}"
        echo "   DB:   $DB_NAME"
        echo "   Host: $DB_HOST:$DB_PORT"
        echo "   User: $DB_USER"
        return 1
    fi

    return 0
}

validate_number() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+$ ]]
}

table_exists() {
    local result=""

    result=$(mysql_silent_info -e "
SELECT COUNT(*)
FROM TABLES
WHERE TABLE_SCHEMA='$DB_NAME'
  AND TABLE_NAME='account';
" 2>/dev/null)

    [ "$result" = "1" ]
}

column_is_auto_increment() {
    local result=""

    result=$(mysql_silent_info -e "
SELECT EXTRA
FROM COLUMNS
WHERE TABLE_SCHEMA='$DB_NAME'
  AND TABLE_NAME='account'
  AND COLUMN_NAME='id';
" 2>/dev/null)

    [[ "$result" == *"auto_increment"* ]]
}

get_current_max_id() {
    mysql_silent_db -e "SELECT IFNULL(MAX(\`id\`),0) FROM \`account\`;" 2>/dev/null
}

get_auto_increment_from_create_table() {
    local create_sql=""
    local auto_value=""

    create_sql=$(mysql_db -N -B -e "SHOW CREATE TABLE \`account\`;" 2>/dev/null)

    auto_value=$(echo "$create_sql" \
        | grep -o "AUTO_INCREMENT=[0-9]*" \
        | head -n 1 \
        | cut -d'=' -f2)

    if [ -z "$auto_value" ]; then
        auto_value=0
    fi

    echo "$auto_value"
}

set_account_auto_increment() {
    local current_max
    local current_auto
    local min_allowed
    local startpoint
    local confirm_low
    local confirm
    local new_auto

    clear
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${CYAN}        ACCOUNT AUTO_INCREMENT MANAGER            ${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo ""

    read_login_db_info

    if ! test_connection; then
        return 1
    fi

    if ! table_exists; then
        echo -e "${RED}❌ Table not found:${NC} $DB_NAME.account"
        return 1
    fi

    if ! column_is_auto_increment; then
        echo -e "${RED}❌ Column is not AUTO_INCREMENT:${NC} $DB_NAME.account.id"
        echo ""
        echo "Check manually with:"
        echo "   SHOW COLUMNS FROM $DB_NAME.account LIKE 'id';"
        return 1
    fi

    current_max=$(get_current_max_id)
    current_auto=$(get_auto_increment_from_create_table)

    if [ -z "$current_max" ]; then
        current_max=0
    fi

    if [ -z "$current_auto" ]; then
        current_auto=0
    fi

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

    if [ -z "$startpoint" ]; then
        startpoint="10000"
    fi

    if ! validate_number "$startpoint"; then
        echo -e "${RED}❌ Invalid value:${NC} $startpoint"
        return 1
    fi

    if [ "$startpoint" -lt 1 ]; then
        echo -e "${RED}❌ Value must be at least 1.${NC}"
        return 1
    fi

    if [ "$startpoint" -lt "$min_allowed" ]; then
        echo ""
        echo -e "${YELLOW}⚠️  The value is below MAX(id)+1.${NC}"
        echo -e "${YELLOW}MySQL will effectively use at least ${min_allowed} or ignore the lower value.${NC}"
        echo ""

        read -p "❓ Continue anyway? (y/n): " confirm_low

        if [[ ! "$confirm_low" =~ ^[JjYy]$ ]]; then
            echo -e "${YELLOW}👋 Operation cancelled.${NC}"
            return 0
        fi
    fi

    echo ""
    echo -e "${YELLOW}⚠️  Prepare AUTO_INCREMENT change:${NC}"
    echo -e "Auth database: ${GREEN}$DB_NAME${NC}"
    echo -e "Table:         ${GREEN}account${NC}"
    echo -e "Column:        ${GREEN}id${NC}"
    echo -e "New value:     ${GREEN}$startpoint${NC}"
    echo ""
    echo "SQL:"
    echo "   ALTER TABLE \`$DB_NAME\`.\`account\` AUTO_INCREMENT = $startpoint;"
    echo ""

    read -p "❓ Set AUTO_INCREMENT now? (y/n): " confirm

    if [[ ! "$confirm" =~ ^[JjYy]$ ]]; then
        echo -e "${YELLOW}👋 Operation cancelled.${NC}"
        return 0
    fi

    echo ""

    if mysql_raw -e "ALTER TABLE \`$DB_NAME\`.\`account\` AUTO_INCREMENT = $startpoint;"; then
        sleep 1

        new_auto=$(get_auto_increment_from_create_table)

        echo ""
        echo -e "${GREEN}✅ AUTO_INCREMENT was updated.${NC}"
        echo -e "Previous AUTO_INCREMENT: ${YELLOW}${current_auto}${NC}"
        echo -e "Requested value:         ${YELLOW}${startpoint}${NC}"
        echo -e "Current AUTO_INCREMENT:  ${GREEN}${new_auto}${NC}"

        if [ "$new_auto" -lt "$startpoint" ]; then
            echo ""
            echo -e "${YELLOW}⚠️  Notice:${NC} The reported AUTO_INCREMENT is lower than the requested value."
            echo "Please check manually with:"
            echo "   SHOW CREATE TABLE \`$DB_NAME\`.\`account\`\\G"
        fi
    else
        echo ""
        echo -e "${RED}❌ Failed to set AUTO_INCREMENT.${NC}"
        echo "Test manually:"
        echo "   ALTER TABLE \`$DB_NAME\`.\`account\` AUTO_INCREMENT = $startpoint;"
        return 1
    fi
}

set_account_auto_increment

exit $?
