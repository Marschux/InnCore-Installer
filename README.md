# WoW Private Server Install Script

Install scripts for WoW private server cores.

Currently: [`Azerothcore/`](Azerothcore/) – combined install script for
AzerothCore WotLK incl. Control menus (`Azerothcore/Control/`).

| Menu | Installation | Scope |
|------|--------------|-------|
| 1 | Basic System | Base system + hardening (prerequisite for 2/3/4) |
| 2 | Authserver | build only |
| 3 | Worldserver | build only |
| 4 | Bothserver | Auth + World on one LXC |
| 5 | Control | management menus `authmenu` / `worldmenu` |

## Usage

On a fresh Debian 13 LXC as `root`. Finish your own LXC preparation (network,
notes, snapshot) beforehand.

Disk: Auth ~20 GB, World ~45 GB, Bothserver ~60 GB. The script checks free space
before each build and warns.

### First-time installation

`acore-install.sh` **with** the `Control/` folder next to it – easiest is to
clone the whole `Azerothcore/` folder:

```bash
apt update && apt install -y git
git clone git@gitlab.com:grassnotfound/WoW-Privatserver-Installscript.git /tmp/wpi
sudo cp -r /tmp/wpi/Azerothcore /opt/wowserver-install
rm -rf /tmp/wpi
chmod +x /opt/wowserver-install/acore-install.sh /opt/wowserver-install/Control/*.sh
cd /opt/wowserver-install
./acore-install.sh
```

`/opt` deliberately, not `/root` – Basic System locks root and creates `admin`;
a checkout under `/root` (mode 700) would then be unreachable for `admin`. The
folder must be readable by the later server owner (`chmod -R a+rX`), otherwise
"Update Control scripts" cannot read the checkout.

### Order

1. `1) Basic System` – asks for everything (timezone, admin user + password) up
   front, then sets up the base system, MOTD, SSH and Fail2Ban.
   **Before** the root password is locked, test SSH login as `admin` + `sudo -i`
   in a second terminal.
2. Then add your own installations / services / adjustments.
3. `2) Authserver` / `3) Worldserver` (or `4) Bothserver`). The Control menu is
   offered optionally at the end of each, or later via `5) Control`.

Re-open the script: `cd /opt/wowserver-install && ./acore-install.sh`

## Control menus

```text
Control/
├── common.sh              shared helpers (status, server control, apply_values)
├── auth-menu.sh           authmenu
├── world-menu.sh          worldmenu
├── clean-build.sh         clear the build directory
└── values/                curated config summaries
    ├── values_auth.conf
    ├── values_world.conf
    └── values_playerbots.conf
```

`values/*.conf` are curated extracts of the real config files. Edit one in the
menu, then "Apply": every key that also exists in the target is replaced there
(value verbatim, timestamped backup first); unknown keys are reported and
skipped. Copied on install, never overwritten by "Update Control scripts". The
world menu can also edit `worldserver.conf` and any module config via
"Edit any .conf".

Start `authmenu` / `worldmenu` as root or with `sudo` (the menu re-execs as the
server owner).

### First start – Authserver

1. `Config` → edit `values_auth.conf`: real password in `LoginDatabaseInfo` →
   back → Apply → restart **yes**.
2. `Auth console`: the server asks to create `acore_auth` → **yes**, wait for
   "Added realm …", then `Ctrl-B` `D` to detach.
3. Optionally enable `Autostart`.

### First start – Worldserver

1. `Config` → edit + apply `values_world.conf` and `values_playerbots.conf`.
   Point the three `*DatabaseInfo` lines at the auth LXC / real password
   (`LoginDatabaseInfo` is **not** 127.0.0.1 on a split setup).
2. `Start server`, then `World console`: confirm creating `acore_world` /
   `acore_characters` / `acore_playerbots`.
3. **Playerbots quirk:** the first start hangs at
   `Waiting for N characters loading into database`. Detach, `Kill server`
   (type `KILL`) → `Start server` again. The second start runs through normally.
4. Optionally `Autostart`, `Daily restart timer`.
