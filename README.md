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

Run menu 1 first. Then 2, 3, or 4.

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

```text
Control/
├── common.sh                config, colours, UI frames, server control
├── common-ops.sh            build, auth-DB, values merge, restart schedule
├── auth-menu.sh             authmenu
├── auth-tools.sh            accounts, GM levels, AUTO_INCREMENT, realmlist + MOTD
├── world-menu.sh            worldmenu
├── world-restart-runner.sh  daily-restart scheduler (systemd service)
└── values/                  short config summaries you edit in the menu
    ├── values_auth.conf
    ├── values_world.conf
    └── values_playerbots.conf
```

The files in `values/` are a short list of the settings you actually change.
Edit one in the menu and pick "Apply": each setting is copied into the real
config file (a timestamped backup is made first). Settings that don't exist in
the target are skipped and listed. These files are left alone when you update
the Control scripts, so your edits survive.

The world menu also has "Edit any .conf" for `worldserver.conf` and any module
config.

### Starting the Authserver the first time

1. `Config` → check `values_auth.conf` (the installer already wrote the real
   database password into `LoginDatabaseInfo`), go back, `Apply`, say yes to
   the restart.
2. `Auth console` → the server asks whether to create the `acore_auth`
   database, say yes. Wait until it prints "Added realm ...", then press
   `Ctrl-B` then `D` to leave the console.
3. Optional: turn on `Autostart`.

### Starting the Worldserver the first time

1. `Config` → edit and apply `values_world.conf` and `values_playerbots.conf`.
   The installer already wrote the real password into every `*DatabaseInfo`
   line (three in `values_world.conf`, plus `PlayerbotsDatabaseInfo` in
   `values_playerbots.conf`); applying a summary that still carries the
   `password` placeholder is skipped with a warning. If Auth and World are on
   different machines, the installer asked for the auth server's IP (and its
   `acore` password) and already wrote both into `LoginDatabaseInfo`. Leave `AiPlayerbot.Min/MaxRandomBots` small until the server has
   booted once, then raise it in steps (a few hundred at a time, restart in
   between) — every increase generates the new bot characters at that boot.
2. `Start server`, then `World console` → confirm creating `acore_world`,
   `acore_characters` and `acore_playerbots`.
3. mod-playerbots builds its whole bot-character pool synchronously during the
   first world init, and at a high `MaxRandomBots` that reliably hangs at
   `Waiting for N characters loading into database`. `Start server` detects a
   cold pool and offers to cap `Min/MaxRandomBots` at 50 for the first boot —
   say yes; raise it again once the server is up. If you already raised the
   count and a start hangs: leave the console, `Kill server` (type `KILL`),
   lower `AiPlayerbot.MaxRandomBots`, then `Start server` again — a plain
   kill+restart at the high count runs into the same wall.
4. Optional: `Autostart` and the `Daily restart timer`.
