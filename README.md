<div align="center">

# InnCore Installer

**AzerothCore WotLK with Playerbots on a Debian 13 LXC - installer plus management menus.**

[![Debian 13](https://img.shields.io/badge/Debian-13_trixie-A81D33?logo=debian&logoColor=white)](https://www.debian.org/) [![AzerothCore](https://img.shields.io/badge/AzerothCore-WotLK_3.3.5a-1f6feb)](https://www.azerothcore.org/) [![Playerbots](https://img.shields.io/badge/mod--playerbots-included-6f42c1)](https://github.com/mod-playerbots/mod-playerbots) [![MySQL 8.4](https://img.shields.io/badge/MySQL-8.4_LTS-4479A1?logo=mysql&logoColor=white)](https://dev.mysql.com/) [![Bash](https://img.shields.io/badge/Bash-scripts-4EAA25?logo=gnubash&logoColor=white)](Azerothcore/acore-install.sh) [![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue)](LICENSE)

[Install](#install) · [Control menus](#control-menus) · [First start](#first-start)

</div>

---

| Menu | What it does |
|------|--------------|
| 1 | Basic System: packages, admin user, MOTD, SSH hardening, Fail2Ban |
| 2 | Authserver: build + MySQL |
| 3 | Worldserver: build + MySQL, includes Playerbots |
| 4 | Bothserver: Auth + World on one LXC |
| 5 | Control: install `authmenu` / `worldmenu` for an already built server |
| 6 | MySQL only |

Run menu 1 first, then 2, 3 or 4 (they offer Control right away). Menu 1 disables
root SSH login and locks the root password - check that the new admin user can
log in and `sudo` before closing the root session.

## Install

Fresh Debian 13 LXC as `root`. Disk: ~20 GB Auth, ~45 GB World, ~60 GB both.

```bash
apt update && apt install -y git
git clone https://github.com/Marschux/InnCore-Installer.git /opt/inncore-installer
cd /opt/inncore-installer/Azerothcore
chmod +x acore-install.sh Control/*.sh
./acore-install.sh
```

## Control menus

`authmenu` / `worldmenu` (as root or with `sudo`, they switch to the server user).
Subcommands: `start`, `stop`, `restart`, `status`, `update`; no argument opens the
menu. The header shows the checkout's branch and how far it is behind origin
(background `git fetch`, at most every 6 h).

- `control.conf` holds only the per-box values (`ACORE_DIR`, `SERVER_USER`, ...).
  Standard paths and names default in `common.sh`; override any of them in
  `control.conf`.
- `values/*.conf` are short summaries of the settings you usually change.
  "Apply" writes them into the real config (with backup) and takes effect on the
  next restart. "Update Control scripts" merges template changes and keeps your
  values.

## First start

**Authserver:** apply `values_auth.conf` → `Start server` → the console opens and
asks to create `acore_auth`, say yes → `Ctrl-B` `D` to leave. Optional: `Autostart`.

**Worldserver:**

1. Apply `values_world.conf`. The installer already wrote the DB passwords (and
   the auth server's IP if it runs elsewhere).
2. `Start server` → confirm creating `acore_world`, `acore_characters`,
   `acore_playerbots` → `Ctrl-B` `D`.
3. Bots: a fresh `playerbots.conf` runs 500; `values_playerbots.conf` ships
   2000-3000. Raise `Playerbots.Min/MaxRandomBots` in steps of a few hundred,
   restarting in between - new bots are generated at boot.
4. Hangs at `Waiting for N characters loading into database`? `Kill server`,
   lower `Playerbots.MaxRandomBots`, start again.
5. Optional: `Autostart`, `Daily restart timer` (warns players, clean shutdown,
   reboots the LXC).

## License

[GPL-3.0](LICENSE). AzerothCore and mod-playerbots, which the installer
downloads, keep their own licenses.
