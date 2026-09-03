#!/usr/bin/env bash
#
# Auth-database access: LoginDatabaseInfo parsing, mysql wrappers, RBAC and
# SRP6 helpers. Sourced via common.sh.

# Links RBAC permission 195 to every "Two side ..." permission in the auth DB.
# The AllowTwoSide.Interaction.* flags in worldserver.conf alone do NOT enable
# cross-faction group/guild/chat - the DB permission has to be linked too.
apply_two_side_rbac() {
    mysql_auth -N -s -e "SHOW TABLES LIKE 'rbac_permissions';" 2>/dev/null | grep -q rbac_permissions \
        || { echo "rbac_permissions not found - start the authserver once so it creates the schema."; return 1; }
    mysql_auth -e "INSERT IGNORE INTO rbac_linked_permissions (id, linkedId)
                   SELECT 195, id FROM rbac_permissions WHERE name LIKE 'Two side %';" || return 1
    local n
    n="$(mysql_auth -N -s -e "SELECT COUNT(*) FROM rbac_linked_permissions WHERE id=195;")"
    echo "Cross-faction RBAC applied: permission 195 links ${n} two-side permission(s)."
    echo "Restart the worldserver (or '.reload rbac' in its console) to load it."
}

# SRP6 salt + verifier for an AzerothCore account, printed as "SALT VERIFIER"
# (uppercase hex). Lets the menu create/repair accounts straight in the auth DB
# without a running worldserver console.
srp6_hex() {   # srp6_hex <user> <pass>
    command -v python3 >/dev/null 2>&1 || { echo "python3 is required for account passwords." >&2; return 1; }
    python3 - "$1" "$2" <<'PY'
import os, hashlib, sys
u, p = sys.argv[1].upper(), sys.argv[2].upper()
N = int("894B645E89E1535BBDAD5B8B290650530801B18EBFBF5E8FAB3C82872A3E9BB7", 16)
salt = os.urandom(32)
h2 = hashlib.sha1(salt + hashlib.sha1(f"{u}:{p}".encode()).digest()).digest()
v = pow(7, int.from_bytes(h2, "little"), N)
print(salt.hex().upper(), v.to_bytes(32, "little").hex().upper())
PY
}

# Reads LoginDatabaseInfo (host;port;user;pass;db). The auth menu passes
# authserver.conf via $AUTH_CONF; the world menu has no $AUTH_CONF, so fall back
# to worldserver.conf ($WORLD_CONF) which carries the same line pointing at the
# auth DB. Without the fallback `worldmenu -> Delete account` died on `set -u`.
read_login_database() {
    local conf="${1:-}" line
    [ -n "$conf" ] || conf="${AUTH_CONF:-}"
    [ -n "$conf" ] || conf="${WORLD_CONF:-}"
    [ -n "$conf" ] && [ -f "$conf" ] || return 1
    line=$(grep -E '^[[:space:]]*LoginDatabaseInfo[[:space:]]*=' "$conf" | tail -n 1)
    line=$(echo "$line" | cut -d= -f2- | cut -d# -f1 | xargs | sed 's/^"//;s/"$//')
    IFS=';' read -r DB_HOST DB_PORT DB_USER DB_PASS DB_NAME <<< "$line"
    [ -n "${DB_HOST:-}" ] && [ -n "${DB_PORT:-}" ] && [ -n "${DB_USER:-}" ] && [ -n "${DB_NAME:-}" ]
}

mysql_auth() {
    read_login_database || { echo "Could not read LoginDatabaseInfo."; return 1; }
    MYSQL_PWD="$DB_PASS" mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" "$DB_NAME" "$@"
}

# Run a SELECT and print it as a table, or "(none)" when it returns no rows
# (mysql --table prints nothing at all on an empty result).
list_table() {
    local out
    out="$(mysql_auth --batch --table -e "$1" 2>&1)"
    [ -n "$out" ] && printf '%s\n' "$out" || echo "(none)"
}
