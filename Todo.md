# -------------------------------------------------------- #
#                         Offen                            #
# -------------------------------------------------------- #

## Playerbots first-start guard (committed, ungepusht)

worldmenu [1] Start erkennt kalten Bot-Pool + hohe MaxRandomBots und bietet an,
Min/MaxRandomBots für den ersten Boot auf 50 zu deckeln (cap-and-tell, kein
Auto-Restore). values_playerbots.conf 2000/3000 -> 150/200. README Schritt 1+3
angepasst. Auf testbench_1 alle 3 Guard-Pfade getestet (warm=kein Prompt,
kalt+Y=cap, kalt+n=unverändert).

- [ ] `git push` (nach ausdrücklicher Ansage)

## Verworfen (nicht machen)

- `show_auth_status` -> `status_dot`: ändert Optik von vendored Code für ~15 Z., lohnt nicht
- `validate_number` `exit 1` mitten im Flow -> `return 1`: 1:1 InnControl, niedrige Prio
- Playerbots-Guard voll-automatisch (DB-Vorabanlegen + wait-for-ready + Auto-Restore):
  zu viel Code, cap-and-tell reicht


# -------------------------------------------------------- #
#                        Erledigt                          #
# -------------------------------------------------------- #

## 2026-09-04 - Bench-Verifikation testbench_1 + Fixes (gepusht bis 5038106)

- Control-Umbau (e531d08..e114c04): voller Menü-1+4-Lauf auf testbench_1,
  authmenu/worldmenu Render, realm_header-Cache, Account-/Realm-/MOTD-Mgmt gegen
  DB, clean_build, daily-restart service+runner, Update-Flow, Datei-Sortierung.
- 5038106  acore-install.sh: DB-Passwort wird jetzt in die confs geschrieben
  (`write_conf_db_password`), `collect_database_password` lehnt `; " '` ab.
- worldserver-Erststart nachgeholt: dabei mod-playerbots-Hang bei
  "Waiting for N characters loading into database" gefunden -> Playerbots-Guard
  (s.o. Offen).
