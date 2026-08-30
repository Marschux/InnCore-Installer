# Todo / Findings

Aus zwei kompletten Testbench-Durchläufen (echter Build, Debian 13).

## Offen

## Erledigt

- [x] Aus InnControl übernommen (getestet):
      - **Two-Side RBAC** `apply_two_side_rbac()` → authmenu Config `[4]`:
        verknüpft RBAC-Permission 195 mit allen `Two side %`-Permissions in
        acore_auth (die `AllowTwoSide.*`-Configs allein reichen nicht für
        Cross-Faction). Idempotent.
      - **Robustes git-update** `git_update()` → Build-Tools `[1]`: fetch +
        ff-only; bei dirty tree / diverged → Status zeigen + Hard-Reset auf
        origin/<branch> anbieten (statt stillem Fehlschlag). world zieht auch
        das mod-playerbots-Modul.
      - **LXC-Reboot** `reboot_lxc()` → authmenu `[13]` / worldmenu `[15]`:
        REBOOT-Confirm → graceful `server_stop` → `systemctl reboot` (sudoers
        um `systemctl reboot` erweitert, keine Passwortabfrage).
- [x] Step-Nummerierung `run_basic_system` fortlaufend (7 = Lock root, auth
      Final = 8, world Final = 9).
- [x] Doku-Überschneidung README ↔ install.md: aufgeteilt. README (root, DE) =
      Einstieg + Install-Reihenfolge (ein konsistenter Weg: `Azerothcore/` nach
      `/opt/wowserver-install` kopieren). install.md = Menü-Tabelle,
      Prerequisites, Control-Layout, First-Start. install.md verweist für die
      Install-Schritte auf README.
- [x] `update_control` robuster → `update_control_scripts()` in common.sh:
      `git -C <checkout> pull` (safe.directory='*'), kein `sudo` mehr (SCRIPT_DIR
      gehört dem Menü-User), klare Fehlermeldung mit Fix wenn der Checkout nicht
      lesbar ist. Beide Pfade getestet.
- [x] Priority-Warnung des worldserver → `ProcessPriority = 0` in
      values_world.conf (`ProcessPriority=1` versucht `setpriority(-15)`, was als
      non-root scheitert → ERROR-Zeile). `Nice=-5` in der Autostart-Unit für den
      echten Boost (greift auf sauberem Boot). Getestet: keine ERROR-Zeile mehr.
- [x] `run_worldserver` `conf/config.sh`-NOTICE: harmlos. `acore.sh`
      (`acore_common_loadConfig`) sourced IMMER `conf/dist/config.sh` zuerst
      (das unser `sed` editiert), `conf/config.sh` ist nur optionales Overlay.
      Keine Änderung nötig.
- [x] values-Audit gegen live-.conf: alle Keys aus values_auth/world/playerbots
      existieren im Ziel, 0 Validation-Warnungen beim worldserver-Start.
      Einzig `CharactersPerRealm` war offen (gefixt).
- [x] whiptail-Dialog bei `install-deps` → `run_install_deps()`: debconf-Werte
      preseeden + `debconf/frontend` temporär auf `Noninteractive` (survivt den
      sudo-Boundary, `/etc/environment` tut das auf Debian 13 NICHT) +
      `export DEBIAN_FRONTEND` (deckt den root-Fall ab), danach zurückgesetzt.
      Mechanismus getestet; voller Fresh-Rebuild-Test noch offen.
- [x] Control sudoers-Grant → `install_control_role` schreibt
      `/etc/sudoers.d/acore-control-{auth,world}` (NOPASSWD, nur azerothcore-*-
      Units + Unit-tee/rm), mit `visudo -c`. Getestet: Autostart/Timer ohne
      Passwortabfrage.
- [x] Force-Kill: `[3] Kill server` (KILL-Confirm) in beiden Menüs,
      `server_kill` in common.sh (TERM → 5s → KILL → session). Menüs
      renummeriert (world 0-14, auth 0-12). Getestet inkl. Playerbots-Hänger.
- [x] Leere Account/Realm-Liste → `list_table()` → „(none)".
- [x] Warnung wenn SERVER_USER `CONTROL_SOURCE_DIR` nicht lesen kann.

- [x] Server-Tree nach Build `chown -R OWNER` — Menü kann Backups/git schreiben.
- [x] `apply_values`: Werte verbatim schreiben (Quote-Bug bei inneren Quotes
      behoben, z.B. `Appender.Console`).
- [x] `values/values_world.conf`: ungültiges `InstantLogout` raus,
      `CharactersPerRealm` 50→10.
- [x] geteilter tmux-Server bei Autostart → `tmx() = tmux -L $CONTROL_TMUX_L`
      (acore-auth / acore-world). Reboot-Test: getrennte cgroups, `stop world`
      lässt auth laufen und umgekehrt.
- [x] `check_disk()` vor Auth (~20 GB) / World (~45 GB) Build, warnt + confirm.
      install.md: Disk-Anforderung dokumentiert.
- [x] `Control/install.sh` in `install.sh` eingefaltet (`install_control_role`).
- [x] `values_*.conf` nach `Control/values/`.
- [x] `Control/README.md` gelöscht (doppelt), Struktur + values-Erklärung in
      install.md.
- [x] Alle Control-Abfragen an den Anfang (Owner/Pfad/DB-Passwort/Control-Ziel),
      `CONTROL_ASSUME_DEFAULTS`-Hack entfernt.
- [x] Control-Menüs im InnControl-Look, `reexec_as_owner` (dubious-ownership-Fix).
- [x] Skripte komplett auf Englisch.
- [x] mod-playerbots-1.-Start-Hänger in install.md dokumentiert (Kill → Start).
