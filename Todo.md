# -------------------------------------------------------- #
#                         Offen                            #
# -------------------------------------------------------- #

## Control-Umbau: Bench-Verifikation + Push (nächste Session)

8 ungepushte Commits (e531d08 .. HEAD, plus Todo-Commit 1055a70).
Alles nur `bash -n` / `declare -F`-Diff geprüft, NICHTS auf der Bench gelaufen.
Erst benchen, dann pushen.

Auf testbench_2, frische Auth- + World-Installation (oder `*menu update` auf
bestehender):

- [ ] `authmenu` startet, Status-Screen rendert (common.sh -> common-ops.sh Kette),
      Branch-Zeile, `realm_header` (15s-Cache - 2x hintereinander öffnen, 2. sofort da)
- [ ] `authmenu` -> [8] Account management (== `auth-tools.sh accounts`):
      Show / Add / Edit (pw+expansion+username) / Set GM level / AUTO_INCREMENT / Delete
- [ ] `authmenu` -> [9] Realm management (== `auth-tools.sh realms`):
      [1] Realmlist add-or-update / delete / show-with-status
      [2] MOTD list / edit (nano UND manual) / delete
- [ ] auth-tools.sh nutzt jetzt `mysql_auth` / `read_login_database` aus common-ops.sh
      statt eigenem mysql_exec -> DB-Zugriff testen, Header-Zeilen "$DB_NAME @ host:port"
      müssen befüllt sein (Globals werden beim Start gesetzt)
- [ ] `authmenu` / `worldmenu` -> Build tools -> Clean build directory
      (neuer `clean_build` in common-ops.sh, aus clean-build.sh gefoldet) - "type CLEAN"
- [ ] `worldmenu` -> Daily restart scheduler enable/disable, `world-restart-runner.sh`
      startet (sourcet common.sh -> alle Libs)
- [ ] `authmenu update` aus älterem Checkout-Stand: neue Dateien kommen an, Menü
      re-exect sauber. Alte Dateien bleiben als toter Clutter liegen (ok):
      auth-account-manager.sh, auth-realm-manager.sh, db-autoincrement.sh,
      clean-build.sh, lib-ui/server/build/db/config.sh
- [ ] Datei-Sortierung: `ls Azerothcore/Control/*.sh` -> auth-menu.sh vor auth-tools.sh
- [ ] Wenn alles grün: `git push`

## Optional / danach

- [ ] `acore-install.sh` auditieren (im Control-Umbau nicht angefasst, kein akuter
      Schmerz - nur wenn Lust)

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
