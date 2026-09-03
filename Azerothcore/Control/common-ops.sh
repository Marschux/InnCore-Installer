#!/usr/bin/env bash
#
# Control toolkit, part 2: the rarely-used helpers - git update / build /
# build-tree cleanup / script self-update, auth-DB access (accounts, RBAC,
# SRP6), the values-summary merge / apply, .conf editor and the daily-restart
# schedule. Sourced by common.sh; never sourced directly.

# --- git update, build, clean, script self-update -------------------------

# Bring a checkout to the tip of its current branch. Fast-forward if possible;
# otherwise show what is in the way and offer a hard reset (git pull --ff-only
# just fails silently on local changes / diverged history).
git_update() {   # git_update <repo-dir>
    local dir="$1" branch
    [ -d "$dir/.git" ] || { echo "Not a git checkout: $dir"; return 1; }
    branch="$(gitq "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    [ -n "$branch" ] && [ "$branch" != HEAD ] || { echo "Could not determine branch in $dir"; return 1; }
    # A half-finished merge or rebase from a previous aborted run blocks every
    # git operation below with an unhelpful error.
    gitq "$dir" merge --abort >/dev/null 2>&1 || true
    gitq "$dir" rebase --abort >/dev/null 2>&1 || true
    echo "Fetching origin ($branch) for $dir ..."
    gitq "$dir" fetch --prune origin || { echo "fetch failed."; return 1; }
    local dirty=0
    gitq "$dir" diff --quiet && gitq "$dir" diff --cached --quiet || dirty=1
    if [ "$dirty" -eq 0 ] && gitq "$dir" merge --ff-only "origin/$branch" >/dev/null 2>&1; then
        echo "Updated to origin/$branch (fast-forward)."
        return 0
    fi
    echo ""
    echo "Cannot update cleanly (uncommitted changes and/or diverged history):"
    gitq "$dir" status --short
    echo ""
    read -rp "Discard ALL local changes and hard-reset to origin/$branch? [y/N]: " a
    case "$a" in
        y|Y|j|J)
            gitq "$dir" reset --hard "origin/$branch" && gitq "$dir" clean -fd \
                && echo "Reset to origin/$branch." ;;
        *) echo "Left $dir unchanged." ;;
    esac
}

current_branch() {
    local b
    b="$(git_owner rev-parse --abbrev-ref HEAD 2>/dev/null)"
    { [ -n "$b" ] && [ "$b" != HEAD ] && echo "$b"; } || echo unknown
}

# Refresh the installed Control scripts from the repo checkout (CONTROL_SOURCE_DIR).
# Pulls first when the checkout is a git repo. Fails loudly with the fix when the
# checkout is not readable by the server user (e.g. cloned into a 700 home).
update_control_scripts() {   # update_control_scripts <menu-basename>
    local src="$CONTROL_SOURCE_DIR" f
    if [ "${MENU_RUNNING:-0}" = 1 ]; then submenu_title "⬇️  UPDATE CONTROL SCRIPTS" "$COLOR_CONFIG"; fi
    if [ ! -r "$src/common.sh" ]; then
        echo "Cannot read the repo checkout at:"
        echo "  $src"
        echo "Re-clone it somewhere $USER can read (e.g. under /opt, then"
        echo "'sudo chmod -R a+rX <dir>') and set CONTROL_SOURCE_DIR in"
        echo "  $SCRIPT_DIR/control.conf"
        return 1
    fi
    if gitq "$src" rev-parse --git-dir >/dev/null 2>&1; then
        local branch remote
        branch="$(gitq "$src" rev-parse --abbrev-ref HEAD 2>/dev/null)"
        remote="$(gitq "$src" remote get-url origin 2>/dev/null)"
        echo "Fetching $branch from ${remote:-origin} ..."
        # This checkout is only a distribution point - force it to match the
        # remote so line-ending churn or a stray edit can't block the update.
        if gitq "$src" fetch --prune origin "$branch"; then
            gitq "$src" reset --hard "origin/$branch" \
                && gitq "$src" clean -fd \
                || echo "!! reset failed - installing the files as they are on disk."
        else
            echo "!! git fetch failed - installing the files as they are on disk."
        fi
    else
        echo "!! $src is not a git checkout - installing whatever files are there."
    fi
    # $SCRIPT_DIR is owned by the server user (this menu runs as them), no sudo.
    # Copy every .sh the repo Control dir carries so new helper scripts arrive
    # without a code change here (the other role's menu file is harmless clutter).
    local f n=0
    for f in "$src"/*.sh; do
        [ -f "$f" ] || continue
        if install -m 0755 "$f" "$SCRIPT_DIR/$(basename "$f")"; then n=$((n + 1)); fi
    done
    echo "Control scripts updated from $src ($n files)"
    # Values summaries: 3-way merge against a stored baseline so template changes
    # (new keys, changed defaults, reworded comments) come through, while any key
    # the operator actually tuned keeps its value.
    local tpl dst
    mkdir -p "$SCRIPT_DIR/values"
    for tpl in "$src"/values/*.conf; do
        [ -f "$tpl" ] || continue
        dst="$SCRIPT_DIR/values/$(basename "$tpl")"
        merge_values "$tpl" "$dst" || true
    done
    # Called from inside the menu: the running process still holds the old code,
    # so offer to re-exec. Called as `authmenu update` from a shell: just return.
    [ "${MENU_RUNNING:-0}" = 1 ] || return 0
    echo ""
    read -rp "Restart the menu now to load the new version? [Y/n]: " a
    case "$a" in n|N|no|NO) return 0 ;; *) exec "$SCRIPT_DIR/$1" ;; esac
}

# Records / reports the source commit that was last built, so the build menu can
# say whether a rebuild is due. Keyed per repo basename, stored next to the menu.
build_state_file() { echo "$SCRIPT_DIR/.built-commit.$(basename "$1")"; }

build_hint() {   # build_hint <repo-dir>
    local head built
    head="$(gitq "$1" rev-parse HEAD 2>/dev/null || true)"
    [ -n "$head" ] || return 0
    built=""
    if [ -f "$(build_state_file "$1")" ]; then
        built="$(tr -d '[:space:]' < "$(build_state_file "$1")" 2>/dev/null || true)"
    fi
    if [ -z "$built" ]; then
        echo -e "  ${DIM}Source @ ${head:0:9} - no build recorded yet.${RESET}"
    elif [ "$head" = "$built" ]; then
        echo -e "  ${DIM}Source @ ${head:0:9} - matches last build.${RESET}"
    else
        echo -e "  ${YELLOW}Source @ ${head:0:9} - last build was ${built:0:9}, rebuild recommended.${RESET}"
    fi
}

safe_build() {   # safe_build <build-dir> <repo-dir> <apps-build> <scripts>
    local dir="$1" repo="${2:-}" apps="${3:-all}" scripts="${4:-static}"
    require_path "$repo" || return 1
    run_as_owner mkdir -p "$dir" || return 1
    # No configured build tree (fresh box or after 'Clean build directory') -
    # run CMake first, same flags the installer used.
    if [ ! -f "$dir/CMakeCache.txt" ]; then
        echo "No build tree yet - running CMake configure ($apps, scripts=$scripts)..."
        run_as_owner bash -c "cd '$dir' && cmake '$repo' \
            -DCMAKE_INSTALL_PREFIX='$repo/env/dist' \
            -DCMAKE_BUILD_TYPE=RelWithDebInfo \
            -DAPPS_BUILD='$apps' \
            -DTOOLS_BUILD=none \
            -DSCRIPTS='$scripts' \
            -DMODULES=static" \
            || { echo "CMake configure failed."; return 1; }
    fi
    run_as_owner bash -c "cd '$dir' && make -j \"\$(nproc)\" && make install" || return 1
    if [ -n "$repo" ]; then gitq "$repo" rev-parse HEAD 2>/dev/null > "$(build_state_file "$repo")" || true; fi
    return 0
}

# Wipe only <acore-dir>/build, after a typed confirmation. Source and Control
# scripts outside build are untouched. (Folded in from the old clean-build.sh.)
clean_build() {   # clean_build <acore-dir>
    local acore="${1:-}" build confirmation
    case "$acore" in
        ''|/) echo "Invalid AzerothCore path."; return 1 ;;
        /*) ;;
        *) echo "The AzerothCore path must be absolute."; return 1 ;;
    esac
    [ -d "$acore" ] || { echo "AzerothCore directory not found: $acore"; return 1; }
    build="$acore/build"

    if [ ! -d "$build" ]; then
        run_as_owner mkdir -p "$build" && echo "Build directory created: $build"
        return 0
    fi

    echo "Only this directory will be cleaned:"
    echo "  $build"
    echo "Source code and Control scripts outside of build are kept."
    read -rp "Type exactly CLEAN to continue: " confirmation
    [ "$confirmation" = CLEAN ] || { echo "Aborted."; return 0; }

    run_as_owner find "$build" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    echo "Build directory cleaned successfully."
}

# --- auth-database access (accounts, RBAC, SRP6) -------------------------

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

# --- autostart unit, restart schedule, values merge / .conf editor ------

# Enable/disable a boot autostart oneshot that drives one role's menu wrapper.
# Shared by auth and world - only the unit name, description and wrapper differ.
autostart_toggle() {   # autostart_toggle <service> <description> <menu-wrapper> [after-units]
    local svc="$1" desc="$2" wrapper="$3" after="${4:-network-online.target mysql.service mysqld.service}" c state
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        state="${GREEN}ENABLED${RESET}  - the server starts automatically on LXC boot"
    elif [ -f "/etc/systemd/system/$svc" ]; then
        state="${YELLOW}unit present but DISABLED${RESET}"
    else
        state="${RED}DISABLED${RESET} - no automatic start on boot"
    fi
    submenu_title "🚀  AUTOSTART" "$COLOR_TOOLS"
    echo -e "  Service:  ${CYAN}${svc}${RESET}"
    echo -e "  Status:   ${state}"
    echo ""
    echo -e "  ${COLOR_TOOLS}[1]${RESET}  Enable autostart on boot"
    echo -e "  ${COLOR_TOOLS}[2]${RESET}  Disable autostart"
    echo -e "  ${COLOR_TOOLS}[0]${RESET}  Back"
    echo ""; menu_footer
    read -rp "🔹  Choice [0-2]: " c
    case "$c" in
        1)
            # Probe with a call the installed sudoers grant actually allows
            # (daemon-reload is idempotent). `systemctl --version` is NOT in the
            # grant, so probing with it always failed and blocked enabling.
            sudo -n systemctl daemon-reload >/dev/null 2>&1 \
                || { echo "Passwordless sudo for systemctl is not set up - re-run the installer."; return 1; }
            sudo tee "/etc/systemd/system/$svc" >/dev/null <<EOF
[Unit]
Description=$desc
Wants=network-online.target
After=$after

[Service]
Type=oneshot
User=$SERVER_USER
Group=$SERVER_USER
WorkingDirectory=$ACORE_DIR
RemainAfterExit=yes
KillMode=none
ExecStartPre=/bin/sleep 10
ExecStart=$wrapper start
ExecStop=$wrapper stop
TimeoutStartSec=180
TimeoutStopSec=240

[Install]
WantedBy=multi-user.target
EOF
            sudo systemctl daemon-reload
            sudo systemctl enable "$svc" >/dev/null 2>&1 \
                && echo "Autostart enabled (the running server was not touched)."
            ;;
        2)
            sudo systemctl disable "$svc" 2>/dev/null || true
            sudo rm -f "/etc/systemd/system/$svc"
            sudo systemctl daemon-reload
            sudo systemctl reset-failed "$svc" 2>/dev/null || true
            echo "Autostart disabled."
            ;;
        *) echo "Nothing changed." ;;
    esac
}

# --- Daily restart schedule (worldserver) -----------------------------------
# restart_times.conf : one "HH:MM;LEAD_MINUTES" per line (LEAD = in-game warning)
# restart_skip.conf  : "YYYY-MM-DD" (whole day) or "YYYY-MM-DD;HH:MM" (one slot)
RESTART_TIMES_CONF="${RESTART_TIMES_CONF:-${SCRIPT_DIR:-.}/restart_times.conf}"
RESTART_SKIP_CONF="${RESTART_SKIP_CONF:-${SCRIPT_DIR:-.}/restart_skip.conf}"

restart_is_skipped() {   # restart_is_skipped <YYYY-MM-DD> <HH:MM>
    local d="$1" t="$2" ed et
    [ -s "$RESTART_SKIP_CONF" ] || return 1
    while IFS=';' read -r ed et || [ -n "$ed" ]; do
        ed="$(printf '%s' "$ed" | xargs)"; et="$(printf '%s' "$et" | xargs)"
        [ -n "$ed" ] || continue
        [ "${ed#\#}" = "$ed" ] || continue
        [ "$ed" = "$d" ] || continue
        [ -z "$et" ] && return 0
        [ "$et" = "$t" ] && return 0
    done < "$RESTART_SKIP_CONF"
    return 1
}

# Echoes "EPOCH;HH:MM;LEAD" of the soonest non-skipped restart, or nothing.
restart_next() {
    [ -s "$RESTART_TIMES_CONF" ] || return 1
    local now next=0 nt="" nl="" t l day dd ce
    now="$(date +%s)"
    while IFS=';' read -r t l || [ -n "$t" ]; do
        t="$(printf '%s' "$t" | xargs)"; l="$(printf '%s' "$l" | xargs)"
        [[ "$t" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || continue
        [[ "$l" =~ ^[0-9]+$ ]] || continue
        for day in $(seq 0 60); do
            dd="$(date -d "+$day days" +%Y-%m-%d)"
            ce="$(date -d "$dd $t" +%s 2>/dev/null)" || continue
            [ "$ce" -le "$now" ] && continue
            restart_is_skipped "$dd" "$t" && continue
            if [ "$next" -eq 0 ] || [ "$ce" -lt "$next" ]; then next="$ce"; nt="$t"; nl="$l"; fi
            break
        done
    done < "$RESTART_TIMES_CONF"
    [ "$next" -eq 0 ] && return 1
    printf '%s;%s;%s\n' "$next" "$nt" "$nl"
}

# The RHS of a "key = value" line: everything after the first '=', with a
# trailing " # comment" and surrounding whitespace stripped (space-guarded so a
# '#' inside a quoted value survives).
_val_of() { printf '%s' "${1#*=}" | sed -E 's/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//'; }
_key_line() { grep -E "^[[:space:]]*$1[[:space:]]*=" "$2" 2>/dev/null | tail -1; }

# 3-way merge: <template> is authoritative for layout, comments and defaults;
# <dst> keeps the operator's value for any key they changed away from the
# baseline (<dst>.base, the template as it was at the last merge). New keys
# appear, retired keys vanish, operator-added extras are kept at the end.
merge_values() {   # merge_values <template> <dst>
    local tpl="$1" dst="$2" out line key tval bval dval kept=0 base
    base="${dst}.base"
    if [ ! -f "$dst" ]; then
        install -m 0644 "$tpl" "$dst"; cp "$tpl" "$base"
        echo "  + $(basename "$dst") (new)"; return 0
    fi
    # First run under this scheme: no baseline yet - assume dst started from a
    # matching template, i.e. any difference now is an operator change.
    [ -f "$base" ] || cp "$tpl" "$base"
    out="$(mktemp)" || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|\#*) printf '%s\n' "$line" >> "$out"; continue ;;
        esac
        key="$(printf '%s' "${line%%=*}" | xargs)"
        [ -n "$key" ] || { printf '%s\n' "$line" >> "$out"; continue; }
        tval="$(_val_of "$line")"
        bval="$(_key_line "$key" "$base")"; [ -n "$bval" ] && bval="$(_val_of "$bval")"
        dval="$(_key_line "$key" "$dst")"
        if [ -z "$dval" ]; then
            printf '%s\n' "$line" >> "$out"                 # brand-new key
        else
            dval="$(_val_of "$dval")"
            if [ "$dval" = "$bval" ] || [ "$dval" = "$tval" ]; then
                printf '%s\n' "$line" >> "$out"             # untouched -> take template
            else
                printf '%s = %s\n' "$key" "$dval" >> "$out" # operator-tuned -> keep value
                kept=$((kept + 1))
            fi
        fi
    done < "$tpl"
    # Operator-added keys the template never had: keep them at the end.
    local extra=0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|\#*) continue ;; esac
        key="$(printf '%s' "${line%%=*}" | xargs)"
        [ -n "$key" ] || continue
        if [ -z "$(_key_line "$key" "$tpl")" ]; then
            if [ "$extra" -eq 0 ]; then printf '\n# --- keys not in the template ---\n' >> "$out"; fi
            printf '%s\n' "$line" >> "$out"; extra=$((extra + 1))
        fi
    done < "$dst"
    cat "$out" > "$dst"; rm -f "$out"
    cp "$tpl" "$base"
    echo "  ~ $(basename "$dst") merged (kept $kept operator value(s)${extra:+, $extra extra})"
    return 0
}

# Apply a flat "key = value" summary into a real .conf: every key that already
# exists in the target is replaced in place, unknown keys are reported and
# skipped. A timestamped backup of the target is written first.
apply_values() {
    local values="$1" target="$2" backup key value ek ev
    local d=$'\x1f'   # sed delimiter - a byte that can't occur in a .conf value
    require_path "$values" || return 1
    require_path "$target" || return 1

    backup="${target}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$target" "$backup" || { echo "Backup failed."; return 1; }
    echo -e "${DIM}Backup: $backup${RESET}"
    echo ""

    while IFS='=' read -r key value || [ -n "$key" ]; do
        key="$(echo "$key" | xargs 2>/dev/null)"
        [[ -z "$key" || "$key" == \#* ]] && continue
        # Value is written verbatim: the summary file is the source of truth for
        # quoting. Only strip a trailing " # comment" (space-guarded so a '#'
        # inside a quoted value or password survives) and surrounding whitespace.
        value="$(printf '%s' "$value" | sed -E 's/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
        # Guard against applying an unedited summary: the shipped *DatabaseInfo
        # lines carry a literal "password" placeholder, and writing that over a
        # working config silently breaks every DB connection.
        case "$value" in
            *";password;"*|*";CHANGEME;"*|'"password"'|password|CHANGEME)
                echo -e "  ${YELLOW}– skipped (edit the summary first, still a placeholder):${RESET} $key"
                continue ;;
        esac
        ek="$(printf '%s' "$key"   | sed 's/[][\\/.^$*+?{}|()]/\\&/g')"
        ev="$(printf '%s' "$value" | sed "s/[\\\\${d}&]/\\\\&/g")"
        if grep -qE "^${ek}[[:space:]]*=" "$target"; then
            sed -i -E "s${d}^${ek}[[:space:]]*=.*${d}${key} = ${ev}${d}" "$target"
            echo -e "  ${GREEN}✓${RESET} $key = $value"
        else
            echo -e "  ${YELLOW}– skipped (not in target):${RESET} $key"
        fi
    done < <(sed 's/\r$//' "$values")
    echo ""
    echo -e "${GREEN}$target updated.${RESET}"
}

# Pick and edit any .conf under the AzerothCore etc tree (worldserver.conf plus
# every module conf) - covers plugins added later that ship their own conf.
edit_any_conf() {
    local dir="$ACORE_DIR/env/dist/etc" files sel i=1 f
    mapfile -t files < <(find "$dir" -maxdepth 2 -name '*.conf' ! -name '*.conf.dist' 2>/dev/null | sort)
    [ "${#files[@]}" -gt 0 ] || { echo "No .conf files found under $dir"; return 1; }
    for f in "${files[@]}"; do printf '  %2d) %s\n' "$i" "${f#"$dir"/}"; i=$((i + 1)); done
    read -rp "Choice [1-${#files[@]}]: " sel
    [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#files[@]}" ] || { echo "Invalid choice."; return 1; }
    "${EDITOR:-nano}" "${files[$((sel - 1))]}"
}
