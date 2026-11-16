#!/usr/bin/env bash
#
# Long-running scheduler for the worldserver's daily restart. Started as a
# systemd service (Type=simple, Restart=always) by world-menu.sh -> Daily
# restart timer -> Enable. On each start it computes the next restart from
# restart_times.conf / restart_skip.conf, waits, warns players in-game, hands
# the worldserver a timed `server shutdown`, waits for a clean stop, then
# reboots the LXC. systemd restarts it afterwards and it picks the next slot.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
set +e

SESSION="$WORLD_SESSION"

log() { echo "[$(date '+%F %T')] $*"; }
wait_until() { local t="$1"; while [ "$EPOCHSECONDS" -lt "$t" ]; do sleep 5; done; }

# No times configured: don't exit (Restart=always would respawn us every 60s in
# a tight loop). Sleep, then exit so systemd re-checks in ~an hour, so a time
# added later still gets picked up without a respawn storm.
nd="$(restart_next)" || { log "No restart times configured - sleeping 1h before re-check."; sleep 3600; exit 0; }
IFS=';' read -r target time lead <<< "$nd"
lead_s=$((lead * 60))
now="$EPOCHSECONDS"
warn=$((target - lead_s))
[ "$warn" -lt "$now" ] && warn="$now"

log "Next restart at $time ($(date -d "@$target" '+%F %H:%M')), warning $lead min before."
wait_until "$warn"

if has_session "$SESSION"; then
    tmx send-keys -t "$SESSION" "announce Daily restart in ${lead} minute(s) - please log out at a safe spot." Enter
    tmx send-keys -t "$SESSION" "saveall" Enter
    sleep 1
    tmx send-keys -t "$SESSION" "server shutdown ${lead_s}" Enter
    log "Warned players, queued 'server shutdown ${lead_s}'."
else
    log "No worldserver session - will still reboot at the target time."
fi

wait_until "$target"
log "Target time reached - waiting for a clean worldserver stop."
server_stop worldserver "$SESSION" "" 600 0

log "Rebooting the LXC."
sudo systemctl reboot
