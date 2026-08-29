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

## Offen — sonstiges

- [ ] worldserver Start als non-root admin: "Can't set process priority class,
      Permission denied". Kosmetisch. Ggf. `AmbientCapabilities=CAP_SYS_NICE`
      in der Unit oder in der Doku erwähnen.

- [ ] values_*.conf einmal komplett gegen AC-Config-Validatoren / .dist-Defaults
      gegenprüfen (nicht nur Key-Existenz). `CharactersPerRealm` war so ein Fall.

- [ ] mod-playerbots hängt reproduzierbar beim 1. Start ("Waiting for N
      characters loading into database"). Workaround im Menü: `[3] Kill` →
      `[1] Start`. Bekanntes AC/Playerbots-Verhalten (testing-notes). In
      install.md / Guide dokumentieren.

- [ ] `preseed_mysql_apt` auf frischer Box gegentesten (ob der whiptail-Dialog
      dann wirklich wegbleibt).
