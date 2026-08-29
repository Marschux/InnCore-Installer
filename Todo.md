# Todo / Findings

Aufgefallen beim Testbench-Durchlauf.

## Erledigt

- [x] `run_basic_system` Step-Nummerierung 6→8 → jetzt fortlaufend (7 = Lock
      root; auth Final = 8, world Final = 9).
- [x] `mysql-apt-config` whiptail → `preseed_mysql_apt()` (debconf-set-selections)
      vor beiden `acore.sh install-deps`. (Preseed-Wirkung noch nicht auf
      frischer Box verifiziert.)
- [x] Control sudoers-Grant → `install_control_role` schreibt
      `/etc/sudoers.d/acore-control-{auth,world}` (NOPASSWD, auf die
      azerothcore-*-Units + Unit-Datei tee/rm beschränkt), mit `visudo -c`.
      Getestet: Autostart an/aus ohne Passwortabfrage.
- [x] world-menu + auth-menu: **Force-Kill** (`[3] Kill server`, "KILL"-Confirm,
      `server_kill` in common.sh: TERM → 5s → KILL → tmux kill-session).
      Menüs renummeriert (world 0-14, auth 0-12). Getestet.
- [x] Leere Account/Realm-Liste → `list_table()` in common.sh, gibt "(none)".
- [x] `install_control_role`: warnt wenn SERVER_USER `CONTROL_SOURCE_DIR` nicht
      lesen kann (Checkout in privatem Home statt /opt).
- [x] Server-Tree nach Build `chown -R OWNER` (Backups/git schreibbar).
- [x] `apply_values`: schreibt Werte verbatim (Quote-Bug behoben).
- [x] `values_world.conf`: `InstantLogout` (ungültig) raus, `CharactersPerRealm`
      50→10 (AC-Validator).

- [x] geteilter tmux-Server bei Autostart → `tmx() = tmux -L $CONTROL_TMUX_L`
      (acore-auth / acore-world) in common.sh + Menüs, Socket in control.conf.
      Reboot-Test: jeder Server jetzt in eigener cgroup, `systemctl stop
      azerothcore-world` lässt authserver laufen.

- [x] Priority-Warnung → `AmbientCapabilities=CAP_SYS_NICE` in beiden
      Autostart-Units (greift bei neu geschriebenen Units).
- [x] values_*.conf gegen AC-Validatoren: authserver.conf + playerbots.conf
      sauber, worldserver.conf nur `CharactersPerRealm` (gefixt). AC-Startup
      validiert selbst und meldet — reicht als Prüfung.
- [x] mod-playerbots-1.-Start-Hänger → in install.md dokumentiert (Kill → Start).

## Offen

- [ ] **`preseed_mysql_apt` reicht NICHT.** Fresh-Test: die 3 debconf-Werte
      sind zwar vorbelegt (Dialog zeigt "Currently selected: mysql-8.4-lts"),
      aber der whiptail-Dialog erscheint trotzdem, weil `DEBIAN_FRONTEND=
      noninteractive` acore.sh's inneres `sudo apt` nicht erreicht.
      Fix: um den `install-deps`-Aufruf `DEBIAN_FRONTEND=noninteractive` in
      `/etc/environment` schreiben (PAM/pam_env liest das bei jedem `sudo`),
      danach wieder entfernen. Manuell im Dialog: Taste `O` (springt auf "Ok")
      dann Enter.
