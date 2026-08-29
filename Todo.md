# Todo / Findings

Aus zwei kompletten Testbench-Durchläufen (echter Build, Debian 13).

## Offen

### 1. Priority-Warnung des worldserver
Beim Start (Autostart oder als non-root) meldet der worldserver
„Can't set process priority class, error: Permission denied".
`AmbientCapabilities=CAP_SYS_NICE` ist in der Autostart-Unit gesetzt und kommt
auch beim Prozess an (CapAmb 0x800000 verifiziert) — die Meldung bleibt.
worldserver versucht wohl RT-Scheduling (`LimitRTPRIO=` nötig) oder negativen
nice (`LimitNICE=`). **Rein kosmetisch**, läuft normal weiter.
**Fix-Optionen:** `LimitNICE=-10` + `LimitRTPRIO=10` in die Unit, oder
`Process.Priority = 0` in `values/values_world.conf`.

### 2. `update_control` / `CONTROL_SOURCE_DIR` robuster machen
`update_control` liest die neuen Skripte aus dem Repo-Checkout
(`CONTROL_SOURCE_DIR`). Läuft das Menü als SERVER_USER und liegt der Checkout in
einem 700-Home, schlägt es fehl. Es gibt jetzt eine Warnung beim Install, aber
sauberer wäre: bei Install die Skript-Quellen zusätzlich nach `$target/.src/`
kopieren und `update_control` von dort ziehen (dann checkout-unabhängig), bzw.
`update_control` macht selbst `git -C <checkout> pull` + Copy.

### 3. Doku-Überschneidung `README.md` ↔ `Azerothcore/install.md`
Root-`README.md` (Deutsch) und `Azerothcore/install.md` (Englisch) beschreiben
beide Menü / Usage / First-Start, teils mit abweichenden Pfaden
(`/opt/wowserver-install` vs `/opt/wowserver-install/Azerothcore`,
`cp install.sh` vs voller Clone). Eine als Kurzverweis auf die andere machen,
oder klar aufteilen (README = Einstieg, install.md = Details).

### 4. `run_worldserver` Schritt 3: `conf/dist/config.sh` vs `conf/config.sh`
`sed` setzt `OSDISTRO` in `conf/dist/config.sh`, aber `acore.sh` liest zur
Laufzeit `conf/config.sh` und meldet
„NOTICE: file <.../conf/config.sh> not found, we use default configuration only".
Build lief trotzdem durch (dist-Datei reicht für install-deps). Prüfen ob das
für andere `acore.sh`-Schritte relevant ist, ggf. `cp conf/dist/config.sh
conf/config.sh` nach dem `sed`.

### 5. `values/*.conf` einmal vollständig gegen AC-Defaults gegenprüfen
AC-Startup validiert selbst und meldet Fehler — bisher nur `CharactersPerRealm`
aufgefallen (gefixt: 50→10). Trotzdem einmal alle Keys/Werte gegen die aktuellen
`.conf.dist` + AC-Validatoren durchgehen (aus InnControl übernommen, dort ggf.
weitere veraltete Werte).

## Erledigt

- [x] Step-Nummerierung `run_basic_system` fortlaufend (7 = Lock root, auth
      Final = 8, world Final = 9).
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
- [x] Warnung wenn SERVER_USER `CONTROL_SOURCE_DIR` nicht lesen kann
      (siehe Offen #3 für die volle Lösung).
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
