# -------------------------------------------------------- #
#                         Offen                            #
# -------------------------------------------------------- #

## Review 2026-09-02 - Live-Lauf auf KI-Testbench-1 (Menue 1 -> 4)

Status je Punkt: [BESTAETIGT] = im echten Lauf reproduziert, [WIDERLEGT] = im
Lauf ok, [OFFEN] = noch nicht erreicht.

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

- [NIEDRIG] run_worldserver haengt `AllowTwoSide.WhoList = 1` per `>>` an
  worldserver.conf an, obwohl `.dist` den Key schon (=0) enthaelt -> doppelte
  Zeile. Besser sed-ersetzen.

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

- [MITTEL] world-restart-runner.sh: Wenn restart_next nichts liefert -> `exit 0`,
  aber systemd-Unit hat `Restart=always` (RestartSec=60) -> Service rebootet
  sich alle 60s neu und loggt. Sollte bei leerer Konfig lieber schlafen/idlen
  oder die Unit disabled lassen.

- [NIEDRIG] common.sh apply_values: sed-Delimiter `@` - Werte mit `@` (z.B.
  Mailadressen) wuerden sed brechen. Aktuell kein betroffener Key, aber fragil.

- [NIEDRIG] restart_timer (world-menu.sh): Lead-Minuten nur `^[0-9]+$`, keine
  Range-Pruefung. InnControl validate_minutes verlangt 1..1440.

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

### NEU [zu pruefen] Server.log / Auth.log Appender-Level vs server_stop-Logik
- common.sh server_stop/server_restart greppen Server.log/Auth.log nach
  "Closing down DatabasePool" (Drain-Erkennung) und
  "All connections on DatabasePool .* closed" (Clean-Shutdown-Verify).
- Dist-Default: `Appender.Server=2,5,0,Server.log,w` bzw.
  `Appender.Auth=2,5,0,Auth.log,w` - File-Appender Level 5. Auf der Bench
  standen die Zeilen im Auth.log drin (also Level passt), ABER: mode `w` =
  Truncate bei jedem Start. Bei server_restart wird vor server_start geprueft,
  daher ok. Trotzdem gegenchecken dass die Playerbots-/World-Variante mit
  `Appender.Server=2,5,1` (repo values_world) die Zeilen auch schreibt.
- Worldserver-Test lief noch (DB-Import), Ergebnis nachtragen.

### Noch offen / manuell

- Worldserver-Menue: Start (First-Start-Hang laut README) -> Kill -> Start ->
  Stop/Restart durchtesten. DB-Import lief zuletzt.
- Menue 6 (MySQL only) einzeln testen (siehe HOCH-Finding).
- Menue 5 (Control standalone) - im Bothserver-Lauf schon inline mit-installiert,
  separater Aufruf noch offen.


# -------------------------------------------------------- #
#                        Erledigt                          #
# -------------------------------------------------------- #

- Start/Stop/Restart/Kill: Ausgabe der server_*-Funktionen in common.sh an
  InnControl 01_startstop.sh angeglichen (Emoji/Farben/Meldungsfluss)
