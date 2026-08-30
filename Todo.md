# Todo / Findings

Aus zwei kompletten Testbench-Durchläufen (echter Build, Debian 13).

## Offen

_(leer)_

## Nicht testbar auf aktueller Testbench

- Basic System (1) frisch: der Basis-Snapshot hat es schon drin (admin,
  root-Lock, MOTD von 2026-08-21). In den zwei früheren Vollläufen auf
  frischer Box verifiziert.

## Erledigt

- [x] `apt full-upgrade` in `run_basic_system` traf den mysql-apt-config-
      whiptail-Dialog, wenn das mysql-Repo schon da war (Basic System nach
      Auth/World erneut, oder Bothserver-Re-Run). Fix: `export
      DEBIAN_FRONTEND=noninteractive` global am Skriptanfang – greift bei
      Ausführung als root (dokumentierter Weg) und auch bei `sudo ./install.sh`
      für alle apt-Aufrufe im Skript. `run_install_deps()` macht zusätzlich den
      debconf/frontend-Flip für acore.sh's inneres sudo. Auf Testbench
      verifiziert: mysql-apt-config 0.8.36→0.8.40 still, ohne Dialog.
- [x] Voller Fresh-Rebuild-Test `run_install_deps()` (2026-08-30, Testbench,
      6 Kerne): Menü 2 komplett durchgelaufen. `mysql-apt-config 0.8.36`
      installierte still `mysql-8.4-lts`, **kein whiptail-Dialog**;
      `debconf/frontend` danach wieder auf `Dialog`. mysql-community-server
      8.4.11, `acore`-User (`mysql_native_password`, beide Hosts, Login ok),
      ein mysqld-Tuning-Block, Control installiert (control.conf/sudoers/
      authmenu ok). Authserver-Erststart: `acore_auth` angelegt, Updates
      appliziert, Realm eingetragen, `authmenu status` = ONLINE.


