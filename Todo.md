# -------------------------------------------------------- #
#                         Offen                            #
# -------------------------------------------------------- #

## Control-Umbau: Push (nächste Session)

8 ungepushte Commits (e531d08 .. HEAD). Bench-Verifikation auf testbench_1
durch (2026-09-04), siehe Erledigt. Nur noch:

- [ ] `git push` (nach ausdrücklicher Ansage)

## Optional / danach

- [ ] `acore-install.sh` auditieren - beim Bench-Lauf aufgefallen: das Script
      schreibt das abgefragte acore-DB-Passwort NIE in authserver.conf /
      worldserver.conf (die bleiben auf `.dist`-Default `acore;acore`), obwohl
      setup_database den MySQL-User mit dem echten PW anlegt. Frische Installation
      kann sich so nie an die DB verbinden bis man die confs von Hand editiert
      oder "apply values" fährt. Nicht im Control-Umbau, aber echter Bug.
- [ ] worldserver wurde nicht gestartet (acore_world/-characters-Import gespart,
      ~10 min). server_start/-stop-Pfad ist geteilt und wurde über den
      authserver live getestet; reiner worldserver-Start bleibt ungetestet.

## Verworfen (nicht machen)

- `show_auth_status` -> `status_dot`: ändert Optik von vendored Code für ~15 Z., lohnt nicht
- `validate_number` `exit 1` mitten im Flow -> `return 1`: 1:1 InnControl, niedrige Prio


# -------------------------------------------------------- #
#                        Erledigt                          #
# -------------------------------------------------------- #

## 2026-09-03 - Control/ Umbau + Aufräumen (nur bash -n geprüft, ungepusht)

Ausgangslage: Control/ hatte 10 Skripte ohne erkennbare Gruppierung, common.sh
war eine 794-Zeilen-Grabbelkiste.

- e531d08  auth-Skripte geprefixt (account-manager -> auth-account-manager etc.),
           db-autoincrement.sh als Funktion `set_account_auto_increment()` in den
           Account-Manager gefoldet (~130 Z. dupliziertes DB-Plumbing weg)
- 85ae67d  common.sh -> Loader + 5 lib-*.sh; clean-build.sh -> `clean_build()`
- 55e0e8f  5 lib-*.sh auf 2 zusammengefasst: common.sh (config, Farben, UI-Frames,
           Server-Control) + common-ops.sh (build, DB, values, restart-schedule);
           Aufrufer unverändert (`source common.sh`)
- e99260f  auth-account-manager.sh + auth-realm-manager.sh -> eine `auth-tools.sh`
           (account_menu / realm_motd_menu, Dispatcher `auth-tools.sh accounts|realms`).
           Nebeneffekt: auth-menu.sh sortiert jetzt vor auth-tools.sh
- 1e410f3  toter Code raus: `srp6_hex`, `list_table` aus common-ops.sh (null Aufrufer)
- 3db7521  `realm_header` 15s Datei-Cache (lief vorher bei jedem 60s-Repaint eine
           Live-DB-Query), Query-Body in `_realm_header_query`
- (HEAD)   auth-tools.sh: eigenes mysql_exec/read_login_db_info raus, nutzt
           mysql_auth/read_login_database aus common-ops.sh (43 Call-Sites, -32 Z.)

Endstand Control/: auth-menu.sh, auth-tools.sh, common.sh, common-ops.sh,
world-menu.sh, world-restart-runner.sh, values/

InnControl-1:1-Diffbarkeit für die vendored Skripte ist damit weg - bewusst,
siehe Memory (User bevorzugt Konsolidierung).

## 2026-09-04 - Bench-Verifikation auf testbench_1 (voller Menü-4-Lauf)

testbench_1 frisch zurückgesetzt (Disk auf 100G), Menü 1 + 4 (Bothserver)
komplett durch: Auth + World (Playerbot-Branch) gebaut, Client-Data geladen,
Control (both) installiert. acore-DB-PW von Hand auf conf-Default `acore`
gesetzt (s.o. acore-install.sh-Bug). authserver einmal gestartet -> acore_auth
angelegt. Alles über die Menüs per tmux getrieben:

- [x] authmenu Status-Screen (common.sh->common-ops.sh), Branch-Zeile `master`
- [x] realm_header 15s-Cache: sofort-Repaint = mtime unverändert (Cache-Hit),
      nach 16s = neu geschrieben
- [x] Account mgmt: Add (SRP6/python3 + DB-Insert), Show, Edit (pw/expansion/
      username inkl. Pflicht-PW-Reset), Set GM level (account_access), AUTO_INCREMENT
      (2->10000), Delete (account + account_access weg) - alle gegen DB geprüft
- [x] Realm mgmt: realmlist add/update (id 2), show-with-status, delete;
      MOTD manual + nano edit + list + delete - alle gegen `motd`/`realmlist` geprüft
- [x] Header-Zeilen "acore_auth @ 127.0.0.1:3306" befüllt (read_login_database beim
      Entry-Point). worldmenu [11] Delete account: WORLD_CONF-Fallback greift,
      kein `set -u`-Tod
- [x] clean_build "CLEAN" in authmenu (11->0) UND worldmenu (21G->0), Source bleibt
- [x] worldmenu Daily restart: enable -> `azerothcore-world-restart.service` läuft,
      world-restart-runner.sh sourcet common.sh sauber, loggt "Next restart at 04:00";
      disable -> inactive
- [x] Update Control scripts (in-menu): CONTROL_SOURCE_DIR auf non-git /opt/ctl-src
      mit neuer Datei + künstlich veralteter auth-menu.sh -> neue Datei kommt an,
      alte überschrieben, Re-exec sauber. `worldmenu update` von CLI ebenso.
      Readability-Guard (Source in 700-Home) meldet sauber statt Crash
- [x] Datei-Sortierung: `ls Control/*.sh` -> auth-menu.sh vor auth-tools.sh

Bench danach: authserver gestoppt (sauber, Queue drained), restart-service
gestoppt, alle tmux-Sockets gekillt, control.conf zurückgesetzt, /opt/ctl-src weg.
MySQL läuft noch. Wartet auf Snapshot-Rollback. Push noch offen.
