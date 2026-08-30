# Todo / Findings

Aus zwei kompletten Testbench-Durchläufen (echter Build, Debian 13).

## Offen

_(leer)_

## Erledigt

- [x] Voller Fresh-Rebuild-Test `run_install_deps()` (2026-08-30, Testbench,
      6 Kerne): Menü 2 komplett durchgelaufen. `mysql-apt-config 0.8.36`
      installierte still `mysql-8.4-lts`, **kein whiptail-Dialog**;
      `debconf/frontend` danach wieder auf `Dialog`. mysql-community-server
      8.4.11, `acore`-User (`mysql_native_password`, beide Hosts, Login ok),
      ein mysqld-Tuning-Block, Control installiert (control.conf/sudoers/
      authmenu ok). Authserver-Erststart: `acore_auth` angelegt, Updates
      appliziert, Realm eingetragen, `authmenu status` = ONLINE.


