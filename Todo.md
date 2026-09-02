# -------------------------------------------------------- #
#                         Offen                            #
# -------------------------------------------------------- #

## Review 2026-09-02 - Live-Lauf auf KI-Testbench-1 (Menue 1 -> 4 -> 5, +Menues)

Status je Punkt: [BESTAETIGT] = im echten Lauf reproduziert, [WIDERLEGT] = im
Lauf ok, [OFFEN] = noch nicht erreicht.

Kurzfassung:
- Menue 1 (Basic System): sauber durch.
- Menue 4 (Bothserver): Auth+World gebaut, MySQL 8.4 installiert+getunt,
  Client-Data geladen, Control fuer beide Rollen installiert. EIN Blocker:
  mysql-apt-config-Dialog (s.u.) - musste von Hand geklickt werden.
- Alle Control-Menue-Funktionen durchgetestet (Liste "laufen, OK" unten).
- HOCH-Bugs bestaetigt: Autostart (sudoers-Probe), reexec_as_owner-Guard,
  account-manager [1] Show (mute_reason), world [11] Delete account (AUTH_CONF).
- MITTEL bestaetigt: world-restart-runner Respawn-Loop, apply_values
  Platzhalter-Falle.
- Widerlegt: mysqld.cnf-Header, root-auth, AllowTwoSide-Duplikat,
  Server.log-Appender-Level, build_hint-Hash, First-Start-Hang.

Bench danach: alle Prozesse gestoppt, tmux gekillt, restart-Unit disabled,
MySQL laeuft noch, 57G frei. Snapshot-Rollback macht der User.

### NEU [BESTAETIGT] mysql-apt-config whiptail-Dialog blockiert unattended-Install
- Beim echten Lauf kam der interaktive "Configuring mysql-apt-config"-Dialog
  (Produkt/Version/Ok) hoch und musste von Hand durchgeklickt werden -
  mehrfach (Erstinstall 0.8.36, dann Upgrade auf 0.8.40 in world step 1).
- Ursache: Script setzt `export DEBIAN_FRONTEND=noninteractive` (Zeile 28),
  wickelt apt danach aber in `sudo apt ...` -> sudo env_reset strippt die
  Variable wieder. `run_install_deps` umgeht das nur fuer den
  `./acore.sh install-deps`-Aufruf (persistenter debconf-Frontend-Flip + trap
  restore). Die blanken `sudo apt update && sudo apt full-upgrade -y` in
  run_authserver/run_worldserver step 1 haben KEINEN Schutz -> Dialog bei jedem
  mysql-apt-config-Upgrade.
- Preseed-Werte selbst greifen (Dialog zeigte "Currently selected: mysql-8.4-lts").
- Fix: `sudo -E apt ...` bzw. `sudo DEBIAN_FRONTEND=noninteractive apt ...`
  ueberall, oder `Defaults env_keep += "DEBIAN_FRONTEND"`, oder mysql-apt-config
  nach erstem Setup `apt-mark hold`.

### acore-install.sh - Bugs

- [HOCH] Menue 6 (MySQL only): `apt install -y mysql-server`
  - Das MySQL-8.4-APT-Repo wird nur von `acore.sh install-deps` (Menue 2/3/4 via
    run_install_deps) eingerichtet. Menue 6 macht das nie -> auf Debian 13 gibt
    es kein `mysql-server` (Debian liefert MariaDB/`default-mysql-server`).
    Installation schlaegt fehl oder zieht das Falsche.
  - Ausserdem fehlt der debconf-Preseed fuer mysql-apt-config -> interaktiver
    whiptail-Dialog.
  - Fix: in run_mysql_only denselben Repo/Preseed-Weg wie run_install_deps gehen,
    oder Menue 6 auf "nur bei bereits vorhandenem MySQL" beschraenken.

- [WIDERLEGT] generate_mysql_tuning haengt Tuning-Block per `tee -a` an
  /etc/mysql/mysql.conf.d/mysqld.cnf an. Oracles mysql-community-server-core
  liefert diese Datei MIT `[mysqld]`-Sektion mit -> Block landet korrekt
  darunter, mysql startet (`systemctl is-active mysql` = active). Werte
  plausibel (both-Profil: buffer_pool 4G, redo 1G, max_connections 310).
  Kein Fix noetig. (Sauberer waere trotzdem eigene Datei, aber kein Bug.)

- [WIDERLEGT] `sudo mysql -u root` (setup_database): root@localhost = auth_socket
  nach dem Install -> `sudo mysql -u root` laeuft ohne -p. acore@localhost/%
  mit mysql_native_password angelegt. Alles ok.

- [MITTEL] strip_existing_mysql_tuning: `sed -i '/MARKER/,$d'` loescht ab
  Markerzeile bis Dateiende -> alles was der Operator unterhalb des Blocks in
  mysqld.cnf haette, ist weg. Zusaetzlich bleiben die Leerzeile + `# ===`-Divider
  oberhalb des Markers stehen und sammeln sich bei jedem Re-Run an.

- [MITTEL, teil-BESTAETIGT] run_basic_system nutzt `apt`, schreibt /etc/hosts,
  timedatectl, useradd, sed /etc/ssh/... teils OHNE sudo - setzt EUID 0 voraus.
  Im Lauf als root (sudo ./acore-install.sh) alles ok. Bricht aber, wenn jemand
  als non-root mit passwortlosem sudo startet. require_root_or_sudo warnt nur.
  -> Item 1 entweder Root erzwingen oder konsequent sudo.

- [NIEDRIG, im Lauf ok] SSH-Hardening: `sed 's/^#*PermitRootLogin.*/...`
  fasst Drop-ins unter /etc/ssh/sshd_config.d/ nicht an. Auf der Bench lag dort
  schon `PermitRootLogin no` (99-homelab.conf) -> `sshd -T` = no, ok. Latentes
  Risiko wenn ein Drop-in `yes` haette.

- [NIEDRIG] Keine Idempotenz: `git clone ... .` in bereits vorhandenes
  AUTH_DIR/WORLD_DIR/modules schlaegt fehl, set -e bricht ab. Re-Run nicht
  moeglich ohne manuelles Aufraeumen.

- [WIDERLEGT] run_worldserver haengt `AllowTwoSide.WhoList = 1` per `>>` an.
  `.dist` enthaelt den Key NICHT (auch nicht auskommentiert) -> genau eine
  Zeile, kein Duplikat. Landet zwar nach dem schliessenden ###-Banner (haesslich
  aber gueltig). Kein Bug.

- [NIEDRIG] Bothserver: offer_menu_launch wird 2x aufgerufen (auth, world). Der
  erste `exec sudo authmenu` ersetzt den Prozess -> world-Menue-Frage kommt nie.

- [MITTEL, BESTAETIGT auf Bench] install_control_role: `repo_root="$(git -C ...
  rev-parse --show-toplevel)"` + `sudo chown -R "$owner:$owner" "$repo_root"`
  chownt den KOMPLETTEN Repo-Checkout rekursiv auf den Server-User. Im Test lag
  der Checkout in /home/agent -> danach gehoerte /home/agent/WoW-Privatserver-
  Installscript komplett acoreadmin. Wenn der Checkout dem Admin gehoert der nur
  installiert, ist das ueberraschend. Nur chownen was noetig ist, oder warnen.

- [NIEDRIG, BESTAETIGT auf Bench] install_control_role warnt (korrekt), wenn der
  Repo-Checkout in einem 700-Home liegt: "acoreadmin cannot read .../Control
  (needed by 'Update Control scripts')". Onboarding legt Repos aber genau nach
  /home/agent/ -> "Update Control scripts" aus dem Menue wuerde spaeter failen.
  Doku/Env-Konflikt: README sagt /opt, Onboarding sagt /home/agent.

### Control-Scripts - Bugs

- [HOCH, BESTAETIGT auf Bench] common.sh autostart_toggle Option 1: Probe
  `sudo -n systemctl --version` schlaegt IMMER fehl, weil die installierte
  sudoers-Datei (/etc/sudoers.d/acore-control-<role>) nur ganz bestimmte
  systemctl-Aufrufe freigibt - `systemctl --version` ist nicht dabei.
  Im Live-Test: authmenu -> [6] Autostart -> [1] Enable ->
  "Passwordless sudo for systemctl is not set up - re-run the installer."
  Gegenprobe: `sudo -n systemctl daemon-reload` = rc 0 (erlaubt),
  `sudo -n systemctl --version` = "sudo: a password is required".
  -> Autostart ist so wie installiert komplett unbenutzbar. Auth UND world.
  Fix: Probe entfernen oder gegen einen erlaubten Aufruf testen
  (z.B. `sudo -n systemctl daemon-reload`).

- [HOCH, BESTAETIGT auf Bench] reexec_as_owner (common.sh) reexect NUR wenn als
  root gestartet (`[ "$(id -u)" -eq 0 ]`). Wird authmenu/worldmenu von einem
  Nicht-root-Nicht-Owner gestartet (z.B. ein Admin der nicht SERVER_USER ist),
  passiert KEIN reexec und kein Fehler -> das Menue laeuft als der falsche User:
  Server starten unter falscher UID, tmux-Session auf einem Socket den der Owner
  nicht sieht (status_dot zeigt wirres 🟠), Auth.log/Server.log fuer den
  Serverprozess nicht schreibbar (mode 664, owner=SERVER_USER) -> server_stop
  meldet dann faelschlich "log does not show the database pools closing".
  README sagt "als root oder mit sudo" - nichts erzwingt es.
  Fix: Guard `[ id -u = 0 ] || [ id -un = SERVER_USER ] || { echo "..."; exit 1; }`.
  (Beim sauberen Lauf via `sudo authmenu` -> reexec auf acoreadmin: alles ok,
   "✅ Authserver stopped, database queue drained.")

- [MITTEL] world-menu.sh kill_world / auth-menu.sh kill_auth:
  `[ "$c" = KILL ] && server_kill ... || echo "Cancelled."`
  Wenn server_kill den Prozess nicht totkriegt (return 1), laeuft der
  `|| echo "Cancelled."`-Zweig -> zeigt faelschlich "Cancelled." obwohl gekillt
  wurde. `if`-Konstrukt statt `&& ... ||`.
  (Happy-Path auf Bench getestet: KILL tippen -> "authserver force-stopped",
   Prozess weg. Nur der Fehlerpfad ist das Problem.)

- [BESTAETIGT auf Bench, OK] Auth-Menue Start/Stop/Restart/Kill komplett
  durchgetestet (als `sudo authmenu`): alle 4 funktionieren, Prozess + tmux
  sauber. Neue InnControl-Ausgabe erscheint korrekt
  ("🚀 Starting authserver via run-engine...", "✅ ... database queue drained.",
   "🔄 Restarting...", "✅ ... restart completed."). Erst-Start legt acore_auth
  an (Konsole-Prompt "create it? yes"), Migrationen laufen, Realm wird angelegt.

- [HOCH, BESTAETIGT auf Bench] account-manager.sh [1] Show account KAPUTT:
  SELECT fragt Spalte `mute_reason` aus `account` - die Spalte heisst aber
  `mutereason` (ohne Unterstrich) im aktuellen AC-Schema. Folge:
  "ERROR 1054 Unknown column 'mute_reason'" und danach faelschlich
  "❌ Account not found.". Betrifft account-manager.sh Zeilen ~781, ~806, ~818,
  ~843 (Variable + SELECT + read + printf). NICHT aus InnControl uebernommen -
  Repo-Eigenbau (Commit 52d0434). InnControl 08_account_manager.sh hat kein
  mute_reason. Fix: `mute_reason` -> `mutereason` an allen 4 Stellen.

- [HOCH, BESTAETIGT auf Bench] world-menu.sh [11] Delete account KAPUTT:
  "common.sh: line 645: AUTH_CONF: unbound variable / Could not read
  LoginDatabaseInfo." common.sh read_login_database() liest hart aus
  `$AUTH_CONF`, das aber nur in der auth-control.conf gesetzt ist. Die
  world-control.conf hat nur WORLD_CONF. Auf einer World-only-Box gibt es gar
  keine authserver.conf. -> Feature komplett tot. Auch mysql_auth (common.sh)
  ist damit im world-Menue unbrauchbar.
  Fix: read_login_database Conf-Pfad als Parameter, world liest LoginDatabaseInfo
  aus WORLD_CONF (worldserver.conf hat die Zeile auch).

- [MITTEL, BESTAETIGT auf Bench] world-restart-runner.sh Respawn-Loop:
  Alle Restart-Zeiten loeschen waehrend Scheduler enabled -> runner
  "No restart times configured - nothing to do." -> exit 0 -> Restart=always
  (RestartSec=60) -> systemd startet ihn im Minutentakt neu (restart counter
  1,2,3...). Menue/timer_dot zeigt "inactive" (is-active waehrend `activating`
  = false), obwohl die Unit in einer Respawn-Schleife haengt. Erst [6] Disable
  stoppt es. Fix: leere Konfig -> lange schlafen statt exit, oder Unit
  Type=oneshot ohne Restart=always, oder beim Zeiten-Loeschen auto-disablen.

- [MITTEL, BESTAETIGT auf Bench] apply_values Platzhalter-Falle: die
  ausgelieferten values_auth/values_world/values_playerbots.conf enthalten in
  den *DatabaseInfo-Zeilen den Literal-Platzhalter `;password;`. "Apply" ohne
  vorher zu editieren schreibt `password` woertlich in die echte .conf und
  killt damit still ALLE DB-Verbindungen (im Test 3x reproduziert: auth, world,
  playerbots). Timestamped Backup wird zwar angelegt. README sagt "erst
  editieren" - aber kein Guard/keine Warnung. Fix: apply_values skippt/warnt bei
  offensichtlichen Platzhaltern (`password`, `CHANGEME`...), oder die Summaries
  kommentieren die Credential-Zeile aus.

- [MITTEL] common.sh apply_values: sed-Delimiter `@` - Werte mit `@` (z.B.
  Mailadressen) wuerden sed brechen. Aktuell kein betroffener Key, aber fragil.

- [NIEDRIG] restart_timer (world-menu.sh): Lead-Minuten nur `^[0-9]+$`, keine
  Range-Pruefung. InnControl validate_minutes verlangt 1..1440.

- [BESTAETIGT auf Bench, OK] Folgende Control-Funktionen getestet, laufen:
  * account-manager: Add / Edit (pw, expansion, username) / Set GM level /
    AUTO_INCREMENT (db-autoincrement.sh) / Delete  -- nur [1] Show ist kaputt
  * realm-manager: Realmlist Add/Delete/Show, MOTD Add/Edit/Show/Delete
  * auth Config: apply_values (values_auth), Cross-faction (two-side) RBAC
    ("permission 195 links 8 two-side permission(s)")
  * world Config: apply values_world, apply values_playerbots, Edit any .conf
  * world Daily-Restart-Timer: Zeit hinzufuegen, Enable (systemd-Unit angelegt,
    runner rechnet "Next restart at 06:00" korrekt), Disable
  * world Character DB console (oeffnet acore_characters via mysql)
  * world/auth Start/Stop/Restart/Kill (alle 4, neue Ausgabe)
  * build_hint "Source @ 148372800" ist KEIN Bug - der HEAD-SHA faengt
    tatsaechlich mit 9 Ziffern an (git log --oneline zeigt dasselbe)

- [NIEDRIG, BESTAETIGT] "Update Control scripts" (auth [11] / world [14]) failt
  wenn Repo in /home/agent liegt - auch NACH dem chown durch install_control_role,
  weil /home/agent selbst 700 ist (kein Traverse fuer acoreadmin). Meldung ist
  klar ("Re-clone somewhere ... can read, e.g. /opt"). Env-Konflikt mit
  Onboarding (/home/agent). Kein Crash.

### Abweichungen von InnControl (Funktion/Logik prüfen)

- Autostart-Unit (common.sh autostart_toggle) vs InnControl 02_autostart.sh:
  - ExecStartPre sleep 5  (InnControl: 10)
  - TimeoutStartSec 120 / TimeoutStopSec 180  (InnControl: 180 / 240)
  - `After=` ohne `mysqld.service`-Alias (InnControl hat beide)
  - KillMode=none: gleich OK

- server_start (common.sh) startet run-engine EINMAL direkt; InnControl wickelt
  es in `while true; do ... sleep 5; done` in der tmux-Session (Auto-Restart bei
  Crash). BEWUSST anders gelassen (deine Ansage "nur Ausgabe angleichen") -
  hier nur als Merker, falls Crash-Recovery doch gewuenscht.

- server_start setzt kein `RUN_ENGINE_SESSION_NAME` (InnControl exportiert es).
  Vermutlich egal wegen `--session-manager none`, kurz gegenchecken.

- Daily-Restart: repo = long-running systemd-Service (Type=simple,
  Restart=always) + world-restart-runner.sh; InnControl = wow-restart-timer.service
  + 04_worldserver_restart_cron.sh. Funktional aehnlich, aber andere
  Unit-Namen/Struktur - pruefen ob gewollt.

- reboot: repo `sudo systemctl reboot` (sudoers-konform), InnControl `sudo /sbin/reboot`.
  repo in sich konsistent, OK.

- [WIDERLEGT] Server.log/Auth.log Appender-Level: server_stop greppt nach
  "Closing down DatabasePool" + "All connections on DatabasePool .* closed".
  Dist `Appender.Server=2,5,0` / `Appender.Auth=2,5,0` schreiben diese Zeilen
  trotzdem (Live-Test: World-Restart -> "💾 Writing pending database queries"
  + "✅ Worldserver stopped, database queue drained." korrekt erkannt).

- [BESTAETIGT auf Bench, OK] World-Menue Start/Stop/Restart/Kill (als
  `sudo worldmenu`): alle 4 ok, neue InnControl-Ausgabe korrekt inkl.
  "🛑 Sending shutdown (30s notice)" (Extraktion aus shutdown_command klappt),
  "...still shutting down (30s)", Drain-Erkennung, Clean-Shutdown-Verify.
  Kill: "🧨 EMERGENCY STOP..." / "✅ Emergency stop completed."

- [NICHT REPRODUZIERT] README-Hinweis "First-Start-Hang bei 'Waiting for N
  characters loading into database'": im Test 500/500 Bots sauber eingeloggt,
  Server kam hoch, kein Hang. Ggf. version-/timingabhaengig oder gefixt -
  README-Passus evtl. entschaerfen.

- [Doku] README World-Abschnitt sagt "three *DatabaseInfo lines" - es sind 4
  (playerbots.conf hat PlayerbotsDatabaseInfo separat). values_playerbots.conf
  deckt es ab, aber die README-Zahl stimmt nicht.

### Noch offen / manuell

- Menue 6 (MySQL only) auf FRISCHER Bench testen (MySQL war hier schon da) -
  siehe HOCH-Finding zu `apt install mysql-server`.
- Menue 5 (Control standalone) separat - im Bothserver-Lauf schon inline
  mit-installiert und getestet, expliziter Aufruf offen.
- Config-Menue: values_*.conf editieren + "Apply" -> .conf durchtesten
  (apply_values / merge_values).


# -------------------------------------------------------- #
#                        Erledigt                          #
# -------------------------------------------------------- #

- Start/Stop/Restart/Kill: Ausgabe der server_*-Funktionen in common.sh an
  InnControl 01_startstop.sh angeglichen (Emoji/Farben/Meldungsfluss)
