# WoW Private Server Install Script

Scripts to set up an AzerothCore WotLK server on a Debian 13 LXC.

The main script is [`acore-install.sh`](acore-install.sh). It has a menu:

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

Clone into `/opt`. The script needs the `Control/` folder sitting next to it,
which the repo layout already gives you:

```bash
apt update && apt install -y git
git clone https://gitlab.com/grassnotfound/WoW-Privatserver-Installscript.git /opt/wowserver-install
cd /opt/wowserver-install
chmod +x acore-install.sh Control/*.sh
./acore-install.sh
```

To open the menu again later:

```bash
cd /opt/wowserver-install && ./acore-install.sh
```


## Control menus

After a build you get `authmenu` and/or `worldmenu`. Start them as root or with
`sudo` — they switch to the server user themselves.

```text
Control/
├── common.sh        shared code (status, start/stop, apply_values)
├── auth-menu.sh      authmenu
├── world-menu.sh     worldmenu
├── clean-build.sh    wipes the build directory
└── values/           short config summaries you edit in the menu
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

1. `Config` → edit `values_auth.conf`, put the real database password into
   `LoginDatabaseInfo`, go back, `Apply`, say yes to the restart.
2. `Auth console` → the server asks whether to create the `acore_auth`
   database, say yes. Wait until it prints "Added realm ...", then press
   `Ctrl-B` then `D` to leave the console.
3. Optional: turn on `Autostart`.

### Starting the Worldserver the first time

1. `Config` → edit and apply `values_world.conf` and `values_playerbots.conf`.
   The three `*DatabaseInfo` lines need the auth server's address and the real
   password. If Auth and World are on different machines, `LoginDatabaseInfo`
   is not `127.0.0.1`.
2. `Start server`, then `World console` → confirm creating `acore_world`,
   `acore_characters` and `acore_playerbots`.
3. The first start gets stuck at
   `Waiting for N characters loading into database`. This is a known
   Playerbots issue. Leave the console, use `Kill server` (type `KILL`), then
   `Start server` again. The second start finishes normally.
4. Optional: `Autostart` and the `Daily restart timer`.
