# -------------------------------------------------------- #
#                         Offen                            #
# -------------------------------------------------------- #

## Review 2026-09-02 (statisch, nicht auf Testbench ausgefuehrt)

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

- [MITTEL/verifizieren] generate_mysql_tuning haengt den Tuning-Block per
  `tee -a` an /etc/mysql/mysql.conf.d/mysqld.cnf an - OHNE `[mysqld]`-Header.
  - Haengt davon ab ob Oracles mysql-community-server diese Datei mit
    `[mysqld]` anlegt. Wenn nicht (bzw. Datei existiert nicht), erzeugt tee sie
    neu mit Keys ohne Gruppe -> mysqld startet nicht
    ("Found option without preceding group").
  - acore_limits.cnf im selben Verzeichnis hat sein eigenes `[mysqld]`, das
    gilt aber nicht fuer eine andere Datei.
  - Auf Testbench: `cat /etc/mysql/mysql.conf.d/mysqld.cnf` nach install-deps.
  - Sicherer Fix: Tuning in eine eigene Datei mit `[mysqld]`-Header schreiben
    (wie acore_limits.cnf), nicht an mysqld.cnf anhaengen.

- [MITTEL] `sudo mysql -u root` (setup_database) - Root-Auth nach
  noninteractivem install-deps pruefen. mysql-community-server preseedet kein
  Root-Passwort -> je nach Paket leeres PW / auth_socket / Abbruch. Auf
  Testbench verifizieren ob `sudo mysql -u root` ohne -p durchlaeuft.

- [MITTEL] strip_existing_mysql_tuning: `sed -i '/MARKER/,$d'` loescht ab
  Markerzeile bis Dateiende -> alles was der Operator unterhalb des Blocks in
  mysqld.cnf haette, ist weg. Zusaetzlich bleiben die Leerzeile + `# ===`-Divider
  oberhalb des Markers stehen und sammeln sich bei jedem Re-Run an.

- [MITTEL] run_basic_system nutzt `apt`, schreibt /etc/hosts, timedatectl,
  useradd, sed /etc/ssh/... alles OHNE sudo - setzt EUID 0 voraus.
  require_root_or_sudo warnt nur, bricht nicht ab. Menue 2-6 nutzen `sudo`.
  -> Item 1 entweder Root erzwingen oder konsequent sudo.

- [NIEDRIG] SSH-Hardening: `sed 's/^#*PermitRootLogin.*/PermitRootLogin no/'`
  fasst Drop-ins unter /etc/ssh/sshd_config.d/ nicht an (z.B. cloud-init
  `PermitRootLogin yes`), die nach der Hauptdatei gewinnen.

- [NIEDRIG] Keine Idempotenz: `git clone ... .` in bereits vorhandenes
  AUTH_DIR/WORLD_DIR/modules schlaegt fehl, set -e bricht ab. Re-Run nicht
  moeglich ohne manuelles Aufraeumen.

- [NIEDRIG] run_worldserver haengt `AllowTwoSide.WhoList = 1` per `>>` an
  worldserver.conf an, obwohl `.dist` den Key schon (=0) enthaelt -> doppelte
  Zeile. Besser sed-ersetzen.

- [NIEDRIG] Bothserver: offer_menu_launch wird 2x aufgerufen (auth, world). Der
  erste `exec sudo authmenu` ersetzt den Prozess -> world-Menue-Frage kommt nie.

### Control-Scripts - Bugs

- [HOCH] common.sh autostart_toggle Option 1: Probe `sudo -n systemctl --version`
  schlaegt IMMER fehl, weil die installierte sudoers-Datei
  (/etc/sudoers.d/acore-control-<role>) nur ganz bestimmte systemctl-Aufrufe
  freigibt - `systemctl --version` ist nicht dabei. -> Autostart aktivieren
  bricht mit "Passwordless sudo for systemctl is not set up" ab, obwohl die
  eigentlichen Aktionen erlaubt waeren. Betrifft auth UND world.
  Fix: Probe entfernen oder gegen einen tatsaechlich erlaubten Aufruf testen
  (z.B. `sudo -n systemctl daemon-reload --dry-run` bzw. einfach weglassen).

- [MITTEL] world-menu.sh kill_world / auth-menu.sh kill_auth:
  `[ "$c" = KILL ] && server_kill ... || echo "Cancelled."`
  Wenn server_kill den Prozess nicht totkriegt (return 1), laeuft der
  `|| echo "Cancelled."`-Zweig -> zeigt faelschlich "Cancelled." obwohl gekillt
  wurde. `if`-Konstrukt statt `&& ... ||`.

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

### Noch offen / manuell

- Authserver-Menue durchtesten (auf Testbench)
- Nach install-deps auf Testbench pruefen: mysqld.cnf-Inhalt, Root-Auth,
  ob mysql wirklich startet


# -------------------------------------------------------- #
#                        Erledigt                          #
# -------------------------------------------------------- #

- Start/Stop/Restart/Kill: Ausgabe der server_*-Funktionen in common.sh an
  InnControl 01_startstop.sh angeglichen (Emoji/Farben/Meldungsfluss)
