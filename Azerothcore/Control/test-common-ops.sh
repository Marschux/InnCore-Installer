#!/usr/bin/env bash
#
# Self-check for the pure logic in common-ops.sh: the daily-restart time maths
# (restart_next / restart_is_skipped) and the values 3-way merge (merge_values).
# No framework, no network, no server. Run: bash test-common-ops.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

# Point the conf paths at a scratch dir before sourcing (the file reads them at
# load time), then pull in just the helpers.
SCRIPT_DIR="$(mktemp -d)"
trap 'rm -rf "$SCRIPT_DIR"' EXIT
RESTART_TIMES_CONF="$SCRIPT_DIR/restart_times.conf"
RESTART_SKIP_CONF="$SCRIPT_DIR/restart_skip.conf"
# shellcheck source=common-ops.sh
source ./common-ops.sh
# From common.sh, which needs a control.conf.
require_path() { [ -e "$1" ]; }
DIM='' GREEN='' YELLOW='' RESET=''

pass=0 fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1: got [$2] want [$3]"; fi; }
field() { echo "$1" | cut -d';' -f"$2"; }

now="$(date +%s)"; today="$(date +%F)"
: > "$RESTART_TIMES_CONF"; : > "$RESTART_SKIP_CONF"

# no times configured -> restart_next reports failure
restart_next >/dev/null; chk "empty -> rc1" "$?" "1"

# a slot later today -> that slot, today
future="$(date -d "@$((now + 3600))" +%H:%M)"
echo "$future;15" > "$RESTART_TIMES_CONF"
out="$(restart_next)"
chk "future today: time"  "$(field "$out" 2)" "$future"
chk "future today: lead"  "$(field "$out" 3)" "15"
chk "future today: epoch" "$(field "$out" 1)" "$(date -d "$today $future" +%s)"

# a slot already past today -> same slot tomorrow
past="$(date -d "@$((now - 3600))" +%H:%M)"
echo "$past;10" > "$RESTART_TIMES_CONF"
chk "past -> tomorrow" "$(field "$(restart_next)" 1)" "$(date -d "tomorrow $past" +%s)"

# several slots -> the soonest future one wins
t_far="$(date -d "@$((now + 7200))" +%H:%M)"; t_near="$(date -d "@$((now + 1800))" +%H:%M)"
printf '%s;5\n%s;5\n' "$t_far" "$t_near" > "$RESTART_TIMES_CONF"
chk "soonest of many" "$(field "$(restart_next)" 2)" "$t_near"

# next occurrence skipped for the whole day -> jump to the day after
echo "$past;10" > "$RESTART_TIMES_CONF"
date -d tomorrow +%F > "$RESTART_SKIP_CONF"
chk "skip whole day" "$(field "$(restart_next)" 1)" "$(date -d "$(date -d '+2 days' +%F) $past" +%s)"

# only that one slot skipped (date;HH:MM) -> same effect here
printf '%s;%s\n' "$(date -d tomorrow +%F)" "$past" > "$RESTART_SKIP_CONF"
chk "skip single slot" "$(field "$(restart_next)" 1)" "$(date -d "$(date -d '+2 days' +%F) $past" +%s)"

# restart_is_skipped, direct
printf '# a comment\n2030-01-01\n2030-02-02;08:00\n' > "$RESTART_SKIP_CONF"
restart_is_skipped 2030-01-01 05:00; chk "whole day skipped"  "$?" "0"
restart_is_skipped 2030-02-02 08:00; chk "exact slot skipped" "$?" "0"
restart_is_skipped 2030-02-02 09:00; chk "other slot ok"      "$?" "1"
restart_is_skipped 2030-03-03 00:00; chk "date not listed"    "$?" "1"

# malformed lines are ignored, the valid one still wins
printf 'not-a-time;x\n25:99;5\n%s;5\n' "$past" > "$RESTART_TIMES_CONF"
: > "$RESTART_SKIP_CONF"
chk "garbage tolerated" "$(field "$(restart_next)" 2)" "$past"

# merge_values: template wins unless the operator changed a key away from the
# baseline; extras survive at the end, comments after values are ignored.
d="$SCRIPT_DIR/m"; mkdir -p "$d"
printf '# head
A = 1
B = "x # y"  # c
C = 3
New = n
' > "$d/tpl"
printf 'A = 1
B = "x # y"
C = 3
Retired = 5
' > "$d/dst.base"
printf 'A = 2
B = "x # y" # mine
C = 3
Retired = 5
Mine = 7
' > "$d/dst"
merge_values "$d/tpl" "$d/dst" >/dev/null
chk "merge result" "$(cat "$d/dst")" "$(printf '# head
A = 2
B = "x # y"  # c
C = 3
New = n

# --- keys not in the template ---
Mine = 7')"
chk "merge base" "$(cat "$d/dst.base")" "$(cat "$d/tpl")"

# read_db_info: last uncommented match wins, quotes / comment / CR stripped,
# a missing key fails.
c="$SCRIPT_DIR/db.conf"
printf '#LoginDatabaseInfo = "x;1;x;x;x"
LoginDatabaseInfo = "old;1;u;p;d"
  LoginDatabaseInfo   =   "10.0.0.5;3307;acore;s3cr3t;acore_auth"  # note\r
WorldDatabaseInfo = "h;2;u;p;w"
' > "$c"
read_db_info LoginDatabaseInfo "$c"; chk "dbinfo rc" "$?" "0"
chk "dbinfo fields" "$DB_HOST|$DB_PORT|$DB_USER|$DB_PASS|$DB_NAME" "10.0.0.5|3307|acore|s3cr3t|acore_auth"
read_db_info CharacterDatabaseInfo "$c"; chk "dbinfo missing" "$?" "1"
# no conf argument on a world-only box: AUTH_CONF is set but absent -> WORLD_CONF
DB_HOST=""; AUTH_CONF="$SCRIPT_DIR/nope.conf" WORLD_CONF="$c" read_db_info LoginDatabaseInfo
chk "dbinfo world fallback" "$?|$DB_HOST" "0|10.0.0.5"
AUTH_CONF="$SCRIPT_DIR/nope.conf" WORLD_CONF="$SCRIPT_DIR/nope2.conf" read_db_info LoginDatabaseInfo
chk "dbinfo none exists" "$?" "1"

# apply_values: column-0 keys replaced (all duplicates), commented / indented
# lines untouched, AiPlayerbot <-> Playerbots alias, placeholders and unknown
# keys skipped, special characters written verbatim, CRLF summary tolerated.
t="$SCRIPT_DIR/target.conf"; v="$SCRIPT_DIR/summary.conf"
printf 'A = old\n# A = c\n  A = i\nA=dup\nAiPlayerbot.F = 1\nP = x\nK = 1\n' > "$t"
printf 'A = v&/|"q" # note\r\nPlayerbots.F = 2\r\n# skip\r\nP = password\r\nZ = 9\r\n' > "$v"
apply_values "$v" "$t" >/dev/null
chk "apply result" "$(cat "$t")" "$(printf 'A = v&/|"q"\n# A = c\n  A = i\nA = v&/|"q"\nAiPlayerbot.F = 2\nP = x\nK = 1')"
chk "apply backup" "$(cat "$t".bak.*)" "$(printf 'A = old\n# A = c\n  A = i\nA=dup\nAiPlayerbot.F = 1\nP = x\nK = 1')"

# escape_sql doubles single quotes.
chk "escape_sql" "$(escape_sql "O'Neil''s")" "O''Neil''''s"

# realmlist decoders from common.sh (sourcing it needs a control.conf, so pull
# just the two functions).
eval "$(sed -n '/^realm_flag_names()/,/^}/p;/^realm_type_name()/,/^}/p' common.sh)"
realm_flag_names r 0;   chk "flag 0"   "$r" "Online"
realm_flag_names r 2;   chk "flag 2"   "$r" "Offline"
realm_flag_names r 34;  chk "flag 34"  "$r" "New"
realm_flag_names r 65;  chk "flag 65"  "$r" "Invalid+Recommended"
realm_flag_names r 256; chk "flag 256" "$r" "256"
realm_flag_names r x;   chk "flag x"   "$r" "x"
realm_type_name r 4;    chk "icon 4"   "$r" "Normal"
realm_type_name r 8;    chk "icon 8"   "$r" "RP PvP"
realm_type_name r 99;   chk "icon 99"  "$r" "Unknown"
# caller vars named like a helper's former locals must still receive the result
realm_flag_names f 2;   chk "flag into f" "$f" "Offline"
realm_type_name t 1;    chk "type into t" "$t" "PvP"

echo "---"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
