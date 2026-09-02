# -------------------------------------------------------- #
#                         Offen                            #
# -------------------------------------------------------- #

## Noch zu testen / offen

- Menue 6 (MySQL only) auf FRISCHER Bench: Fix ist drin
  (setup_mysql_apt_repo), aber der Download-Pfad des mysql-apt-config .deb
  wurde noch nicht real getestet (auf der Testbench war das Repo schon da ->
  nur der Skip-Guard lief).
- reexec_as_owner-Warnung: Code-Pfad nur gelesen, nicht live ausgeloest
  (Menue lief im Test immer via `sudo`).
- Menue 4/6 kompletter Neu-Durchlauf mit den Fixes (Build war schon da, daher
  nur Teilpfade getestet).

## Bewusst NICHT geaendert

- git clone in bereits vorhandenes Verzeichnis schlaegt fehl (keine Idempotenz).
  [NIEDRIG] - dokumentiertes Verhalten, Re-Run ist kein Use-Case.
- server_start startet run-engine EINMAL (kein `while true`-Auto-Restart-Wrapper
  wie InnControl). Bewusste Entscheidung ("nur Ausgabe angleichen").
- Daily-Restart = long-running systemd-Service statt InnControls Timer +
  04_worldserver_restart_cron.sh. Andere Struktur, funktional ok.
- Kosmetik: nach Loeschen der letzten Restart-Zeit zeigt der Scheduler jetzt
  "active" (schlaeft 1h) statt "inactive". Kein Loop mehr, akzeptabel.

## Widerlegt (im Live-Lauf ok, kein Bug)

- generate_mysql_tuning / mysqld.cnf-`[mysqld]`-Header (Oracle-Paket liefert ihn)
- `sudo mysql -u root` (root@localhost = auth_socket)
- run_worldserver `AllowTwoSide.WhoList` Duplikat (Key nicht in .dist)
- Server.log/Auth.log Appender-Level (Zeilen werden geschrieben)
- build_hint "Source @ 148372800" (HEAD-SHA faengt echt mit 9 Ziffern an)
- README First-Start-Hang (im Test 500/500 Bots sauber) - Wording entschaerft


# -------------------------------------------------------- #
#                        Erledigt                          #
# -------------------------------------------------------- #

## 2026-09-02 - Bugfixes (auf KI-Testbench-1 gegengetestet)

common.sh:
- autostart_toggle: sudo-Probe `systemctl --version` -> `daemon-reload`
  (--version nie in der sudoers -> Autostart-Enable war IMMER geblockt).
  Live getestet: Enable + Disable funktionieren jetzt.
- Autostart-Unit an InnControl angeglichen: ExecStartPre sleep 5->10,
  TimeoutStartSec 120->180, TimeoutStopSec 180->240, After +mysqld.service.
- reexec_as_owner: Warnung + 2s Pause wenn als Nicht-root-Nicht-SERVER_USER
  gestartet (lief sonst still unter falscher UID).
- read_login_database: Conf-Pfad-Parameter + Fallback AUTH_CONF -> WORLD_CONF.
  Live: world-menu [11] Delete account laeuft jetzt (war `AUTH_CONF: unbound`).
- apply_values: Platzhalter-Guard (`;password;` etc. wird geskippt statt in die
  echte .conf geschrieben) + sed-Delimiter 0x1f statt `@`.
  Live: apply values_world laesst die 3 DatabaseInfo-Zeilen stehen.

acore-install.sh:
- apt_get()-Helper (`sudo DEBIAN_FRONTEND=noninteractive apt-get`) ueberall ->
  mysql-apt-config-whiptail-Dialog kommt nicht mehr.
- Menue 6: setup_mysql_apt_repo() richtet das MySQL-8.4-APT-Repo selbst ein
  (Preseed + .deb + apt update), Guard wenn schon vorhanden.
- strip_existing_mysql_tuning: nur noch Bereich zwischen BEGIN/END-Markern
  (`# >>> AZEROTHCORE MYSQL PERFORMANCE TUNING >>>` .. `<<<`), Alt-Format-
  Fallback. Live: 3x regeneriert -> genau 1 Block, mysql startet.
- run_basic_system: erzwingt echtes root (EUID 0).
- SSH-Hardening: Drop-in /etc/ssh/sshd_config.d/00-acore-hardening.conf statt
  sed am Hauptfile (gewinnt gegen cloud-init-Drop-ins). Live: sshd -t ok.
- install_control_role: Repo-chown nur wenn $owner nicht schon schreiben kann,
  mit Ansage.
- Bothserver: eine Menue-Wahl (a/w/n) statt zweier exec-Aufrufe.

world-menu.sh / auth-menu.sh:
- kill_world / kill_auth: if/else statt `&& server_kill || echo Cancelled`
  (zeigte "Cancelled." auch wenn gekillt). Live beide Pfade getestet.
- restart_timer: Lead-Minuten jetzt 1..1440 validiert.

account-manager.sh:
- [1] Show account war komplett kaputt: Spalte `mute_reason` -> `mutereason`
  (SQL-Error + falsches "not found"). Zusaetzlich Feld-Parsing auf `mapfile -td`
  umgestellt (leere Spalten wie email='' verschoben mit `read` alle folgenden).
  Live: zeigt jetzt korrekte Werte.

world-restart-runner.sh:
- Leere Restart-Konfig -> 1h schlafen statt `exit 0` (Restart=always machte
  sonst einen 60s-Respawn-Loop). Live: NRestarts bleibt 0.

README.md:
- 4 statt 3 DatabaseInfo (playerbots separat), Platzhalter-Hinweis,
  First-Start-Hang-Wording ("can hang" statt "gets stuck").

## Frueher

- Start/Stop/Restart/Kill: Ausgabe der server_*-Funktionen in common.sh an
  InnControl 01_startstop.sh angeglichen (Emoji/Farben/Meldungsfluss).
