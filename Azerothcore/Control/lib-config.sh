#!/usr/bin/env bash
#
# Config-side helpers: autostart unit toggle, daily-restart schedule, the
# values-summary 3-way merge / apply, and the free-form .conf editor.
# Sourced via common.sh.

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
