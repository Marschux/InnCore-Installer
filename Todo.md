# -------------------------------------------------------- #
#                         Offen                            #
# -------------------------------------------------------- #

 - (nichts)


# -------------------------------------------------------- #
#                        Erledigt                          #
# -------------------------------------------------------- #

## 2026-09-02 - Review + Bugfixes (auf Testbenches gegengetestet)

common.sh:
- autostart_toggle: sudo-Probe `systemctl --version` -> `daemon-reload`
  (--version nie in der sudoers -> Autostart-Enable war IMMER geblockt).
  Live: Enable + Disable funktionieren.
- Autostart-Unit an InnControl angeglichen: ExecStartPre sleep 5->10,
  TimeoutStartSec 120->180, TimeoutStopSec 180->240, After +mysqld.service.
- reexec_as_owner: Warnung + 2s Pause wenn als Nicht-root-Nicht-SERVER_USER
  gestartet (lief sonst still unter falscher UID). Live ausgeloest.
- read_login_database: Conf-Pfad-Parameter + Fallback AUTH_CONF -> WORLD_CONF.
  Live: world-menu [11] Delete account laeuft jetzt (war `AUTH_CONF: unbound`).
- apply_values: Platzhalter-Guard (`;password;` wird geskippt statt in die echte
  .conf geschrieben) + sed-Delimiter 0x1f statt `@`. Live gegengetestet.

acore-install.sh:
- apt_get()-Helper (`sudo DEBIAN_FRONTEND=noninteractive apt-get`) ueberall ->
  kein mysql-apt-config-whiptail-Dialog mehr. Live: voller Menue-4-Lauf +
  Menue 6 ohne Dialog.
- Menue 6: setup_mysql_apt_repo() richtet das MySQL-8.4-APT-Repo selbst ein
  (Preseed + .deb + apt update), inkl. lsb-release (fehlt auf minimalem Debian,
  dabei gefunden) + `apt -f install` fallback. Guard wenn Repo schon da.
  Live testbench_2: MySQL 8.4.11 + Tuning + acore-User.
- strip_existing_mysql_tuning: nur noch Bereich zwischen BEGIN/END-Markern,
  Alt-Format-Fallback. Live: mehrfach regeneriert -> genau 1 Block, mysql startet.
- run_basic_system: erzwingt echtes root (EUID 0).
- SSH-Hardening: Drop-in /etc/ssh/sshd_config.d/00-acore-hardening.conf statt
  sed am Hauptfile (gewinnt gegen cloud-init-Drop-ins). Live: sshd -t ok.
- install_control_role: Repo-chown nur wenn $owner nicht schon schreiben kann,
  mit Ansage. Live: agent-Repo wird NICHT rekursiv gechownt.
- Bothserver: eine Menue-Wahl (a/w/n) statt zweier exec-Aufrufe.

world-menu.sh / auth-menu.sh:
- kill_world / kill_auth: if/else statt `&& server_kill || echo Cancelled`
  (zeigte "Cancelled." auch wenn gekillt). Live beide Pfade.
- restart_timer: Lead-Minuten jetzt 1..1440 validiert.

account-manager.sh:
- [1] Show account war komplett kaputt: `mute_reason` -> `mutereason`
  (SQL-Error + falsches "not found") + Feld-Parsing auf `mapfile -td`
  (leere Spalten wie email='' verschoben mit `read` alle folgenden). Live ok.

world-restart-runner.sh:
- Leere Restart-Konfig -> 1h schlafen statt `exit 0` (Restart=always machte
  sonst einen 60s-Respawn-Loop). Live: NRestarts bleibt 0.

README.md:
- 4 statt 3 DatabaseInfo, Platzhalter-Hinweis, First-Start-Hang-Wording.

## Frueher

- Start/Stop/Restart/Kill: Ausgabe der server_*-Funktionen in common.sh an
  InnControl 01_startstop.sh angeglichen (Emoji/Farben/Meldungsfluss).


# -------------------------------------------------------- #
#              Entscheidungen (bewusst so gelassen)        #
# -------------------------------------------------------- #

- git clone in bereits vorhandenes Verzeichnis schlaegt fehl (keine Idempotenz).
  [NIEDRIG] - dokumentiertes Verhalten, Re-Run ist kein Use-Case.
- server_start startet run-engine EINMAL (kein `while true`-Auto-Restart-Wrapper
  wie InnControl). Bewusste Entscheidung ("nur Ausgabe angleichen").
- Daily-Restart = long-running systemd-Service statt InnControls Timer +
  04_worldserver_restart_cron.sh. Andere Struktur, funktional ok.
- Kosmetik: nach Loeschen der letzten Restart-Zeit zeigt der Scheduler "active"
  (schlaeft 1h) statt "inactive". Kein Loop mehr, akzeptabel.


# -------------------------------------------------------- #
#              Widerlegt (im Live-Lauf ok, kein Bug)       #
# -------------------------------------------------------- #

- generate_mysql_tuning / mysqld.cnf-`[mysqld]`-Header (Oracle-Paket liefert ihn)
- `sudo mysql -u root` (root@localhost = auth_socket)
- run_worldserver `AllowTwoSide.WhoList` Duplikat (Key nicht in .dist)
- Server.log/Auth.log Appender-Level (Zeilen werden geschrieben)
- build_hint "Source @ 148372800" (HEAD-SHA faengt echt mit 9 Ziffern an)
- README First-Start-Hang (im Test 500/500 Bots sauber) - Wording entschaerft
