# InnCore Installer

Scripts to set up an AzerothCore WotLK server on a Debian 13 LXC.

The main script is [`Azerothcore/acore-install.sh`](Azerothcore/acore-install.sh).
It has a menu:

| Menu | What it does |
|------|--------------|
| 1 | Basic System: base packages, admin user, MOTD, SSH hardening, Fail2Ban |
| 2 | Authserver: build only |
| 3 | Worldserver: build only (includes the Playerbots module) |
| 4 | Bothserver: Auth + World on the same LXC |
| 5 | Control: install the `authmenu` / `worldmenu` management menus |
| 6 | MySQL: install and tune MySQL on its own |

Run menu 1 first. Then 2, 3, or 4. Menu 5 installs Control later for a server
that is already built; menus 2-4 offer it right away.

Menu 1 disables root login over SSH and locks the root password. Make sure you
can log in as the admin user it creates (and use `sudo`) before you close the
root session.

## Requirements

- A fresh Debian 13 LXC, logged in as `root`.
- Free disk space: about 20 GB for Auth, 45 GB for World, 60 GB for both.
  The script checks and warns before it builds.

## Install

The script needs the `Control/` folder sitting next to it, which the
`Azerothcore/` folder already gives you. Clone into `/opt`:

```bash
apt update && apt install -y git
git clone https://github.com/Marschux/InnCore-Installer.git /opt/inncore-installer
cd /opt/inncore-installer/Azerothcore
chmod +x acore-install.sh Control/*.sh
./acore-install.sh
```

To open the menu again later:

```bash
cd /opt/inncore-installer/Azerothcore && ./acore-install.sh
```


## Control menus

After a build you get `authmenu` and/or `worldmenu`. Start them as root or with
`sudo` — they switch to the server user themselves.

`authmenu` / `worldmenu` also take a subcommand: `start`, `stop`, `restart`,
`status`, and `update` (pull + reinstall the Control scripts from the repo
checkout). No argument opens the menu.

The `Branch:` row also shows the AzerothCore checkout's current commit, and an
`Update:` row says how far behind origin it is. The check is a background `git fetch` at most
every 6 hours (`ACORE_UPDATE_MAX_AGE` in `control.conf`), cached in
`.update-check` - the menu itself never waits on the network. A failed check
reads as "update state unknown"; the reason is in `.update-check.log`.

Each Control directory has a `control.conf` written by the installer. It only
holds what differs per box: `ACORE_DIR`, `SERVER_USER`, `CONTROL_SOURCE_DIR`,
`CONTROL_TMUX_L` and the menu path. The standard paths, tmux session and
service names default in `common.sh`. To change one (e.g. `WORLD_CONF` or
`AUTH_SESSION`), add it to `control.conf`.

```text
Control/
├── common.sh                  defaults, colours, UI frames, server control
├── common-ops.sh              build menu, auth-DB, values merge/apply, restart schedule
├── auth-menu.sh               authmenu
├── auth-tools.sh              accounts, GM levels, AUTO_INCREMENT, realmlist + MOTD
├── world-menu.sh              worldmenu
├── world-restart-runner.sh    daily-restart scheduler (systemd service)
├── test-restart-schedule.sh   self-check for the restart time maths
└── values/                    short config summaries you edit in the menu
    ├── values_auth.conf
    ├── values_world.conf
    └── values_playerbots.conf
```

The files in `values/` are a short list of the settings you actually change.
Edit one in the menu and pick "Apply": each setting is copied into the real
config file (a timestamped backup is made first). Settings that don't exist in
the target are skipped and listed. Changes take effect on the next server
restart. "Update Control scripts" merges new template versions in: new keys
appear, and every value you changed keeps your value.

The auth menu can edit `authserver.conf` directly; the world menu has "Edit any
.conf" for `worldserver.conf` and any module config.

### Starting the Authserver the first time

1. `Config & maintenance` → check `values_auth.conf` (the installer already
   wrote the real database password into `LoginDatabaseInfo`), then `Apply`.
2. `Start server` → the console opens. The server asks whether to create the
   `acore_auth` database, say yes. Wait until it prints "Added realm ...", then
   press `Ctrl-B` then `D` to leave the console.
3. Optional: turn on `Autostart`.

### Starting the Worldserver the first time

1. `Config & maintenance` → edit and apply `values_world.conf` and
   `values_playerbots.conf`. The installer already wrote the real password
   into every `*DatabaseInfo` line (three in `worldserver.conf`, plus
   `PlayerbotsDatabaseInfo` in `playerbots.conf` and the matching summaries);
   applying a summary that still carries the `password` placeholder is
   skipped with a warning. If Auth and World are on different machines, the
   installer asked for the auth server's IP (and its `acore` password) and
   already wrote both into `LoginDatabaseInfo`.
2. Bot count: you set it yourself with `Playerbots.MinRandomBots` /
   `Playerbots.MaxRandomBots`. A fresh `playerbots.conf` uses the module's
   default (500); `values_playerbots.conf` ships with 2000-3000, so only
   apply that once the server has booted. Every increase generates the new bot
   characters during that boot, so raise it in steps (a few hundred at a time,
   restart in between).
3. `Start server` → the console opens. Confirm creating `acore_world`,
   `acore_characters` and `acore_playerbots`, then `Ctrl-B` then `D`.
4. If a start hangs at `Waiting for N characters loading into database` (bot
   count raised too far in one step): leave the console, `Kill server` (type
   `KILL`), lower `Playerbots.MaxRandomBots`, then `Start server` again. A
   plain kill+restart at the high count hangs the same way.
5. Optional: `Autostart` and the `Daily restart timer`. The daily restart warns
   players in-game, shuts the worldserver down cleanly, then reboots the LXC.
