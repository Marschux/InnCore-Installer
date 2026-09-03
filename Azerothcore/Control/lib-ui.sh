#!/usr/bin/env bash
#
# Menu rendering: frames, prompts, status rows. Sourced via common.sh.

wait_for_user() {
    echo ""
    echo -e "${CYAN}↩  Press [ENTER] to return to the menu...${RESET}"
    read -r _ || true
}

menu_section() {
    echo ""
    echo -e "${1}${BOLD}${2}${RESET}"
}

# Inner width for menu frames: fits the terminal (leaving a 2-col margin),
# clamped so it neither overflows an 80-col console nor sprawls on a wide one.
menu_width() {
    local c
    c="$(tput cols 2>/dev/null || echo 80)"
    c=$((c - 2))
    [ "$c" -gt 79 ] && c=79
    [ "$c" -lt 58 ] && c=58
    echo "$c"
}

box_title() {   # box_title <title> [color]
    local t="$1" c="${2:-$CYAN}" w pad rule tw rest
    w="$(menu_width)"
    rule="$(printf '═%.0s' $(seq 1 "$w"))"
    # Display width. Submenu titles are "<emoji><2 spaces><ASCII text>"; ${#t}
    # miscounts the emoji (bytes under a non-UTF-8 locale, and terminals render
    # these glyphs 1 col wide anyway), so measure only the ASCII tail after the
    # first space (locale-safe) and add 2: one for the emoji, one for that space.
    case "$t" in
        [!$'\x20'-$'\x7e']*) rest="${t#* }"; tw=$(( ${#rest} + 2 )) ;;
        *) tw=${#t} ;;
    esac
    pad=$(( (w - tw) / 2 ))
    printf "${c}╔%s╗${RESET}\n" "$rule"
    printf "${c}║${RESET}%*s${BOLD}${WHITE}%s${RESET}%*s${c}║${RESET}\n" "$pad" "" "$t" "$((w - pad - tw))" ""
    printf "${c}╚%s╝${RESET}\n" "$rule"
}

hr() { printf "${DIM}%s${RESET}\n" "$(printf '─%.0s' $(seq 1 "$(( $(menu_width) + 2 ))"))"; }
menu_footer() { printf "${CYAN}%s${RESET}\n" "$(printf '═%.0s' $(seq 1 "$(( $(menu_width) + 2 ))"))"; }

# Header for a nested submenu: same box as the main screen, tinted to the
# section colour, followed by a blank line.
submenu_title() {   # submenu_title <title> <color>
    clear
    box_title "$1" "$2"
    echo ""
}

# Repaint without a visible clear: cursor home, print the frame with
# erase-to-end-of-line on every row, then erase everything below. Falls back to
# a full clear when the frame no longer fits on screen.
draw_menu() {
    local render_fn="$1" frame term_rows frame_rows
    frame="$($render_fn)"
    term_rows="$(tput lines 2>/dev/null || echo 0)"
    frame_rows="$(printf '%s\n' "$frame" | wc -l)"
    if [ "$term_rows" -gt 0 ] && [ $((frame_rows + 2)) -ge "$term_rows" ]; then
        clear
        printf '%s\n' "$frame"
        return
    fi
    frame="${frame//$'\n'/$'\033[K'$'\n'}"
    printf '\033[H%s\033[K\n\033[0J' "$frame"
}

run_step() {   # run_step "<script or function>" [args...]
    clear
    "$@"
    wait_for_user
}

# Fixed-width label so the status block lines up regardless of icon/word width.
status_row() { printf ' %s  %-15s' "$1" "$2"; }

status_dot() {   # status_dot <process-name> <session>
    local process="$1" session="$2" label
    label="${process^}:"
    if tmx has-session -t "$session" 2>/dev/null; then
        if pgrep -x "$process" >/dev/null 2>&1; then
            echo -e "$(status_row 🟢 "$label")${GREEN}${BOLD}ONLINE${RESET}"
        else
            echo -e "$(status_row 🟡 "$label")${YELLOW}tmux active, process missing${RESET}"
        fi
    else
        if pgrep -x "$process" >/dev/null 2>&1; then
            echo -e "$(status_row 🟠 "$label")${YELLOW}process running, tmux missing${RESET}"
        else
            echo -e "$(status_row 🔴 "$label")${RED}${BOLD}OFFLINE${RESET}"
        fi
    fi
}

autostart_dot() {   # autostart_dot <service-name>
    local svc="$1"
    if [ -z "$svc" ]; then
        echo -e "$(status_row 🚀 "Autostart:")${RED}service name missing${RESET}"
    elif systemctl is-enabled "$svc" >/dev/null 2>&1; then
        echo -e "$(status_row 🚀 "Autostart:")${GREEN}ENABLED${RESET}"
    elif [ -f "/etc/systemd/system/$svc" ]; then
        echo -e "$(status_row 🚀 "Autostart:")${YELLOW}service exists, disabled${RESET}"
    else
        echo -e "$(status_row 🚀 "Autostart:")${RED}DISABLED${RESET}"
    fi
}
