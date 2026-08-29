# install.sh: Combined Install Script

Mirrors the guides in this repo step by step, with a menu:

| Choice | Installation | Scope |
|------|--------------|-------|
| 1 | Basic System | System preparation and security |
| 2 | Authserver | Build only |
| 3 | Worldserver | Build only |
| 4 | Bothserver | Auth + World on one shared LXC - optional |
| 5 | Control | Custom management menus for Auth and Worldserver |

## Usage

A fresh LXC is logged in as root, so no `sudo` yet (that only exists once
Basic System installed it):

#### First Time
```bash
apt update && apt install -y git
git clone git@gitlab.com:grassnotfound/WoW-Privatserver-Installscript.git /opt/wowserver-install
cd /opt/wowserver-install/Azerothcore
chmod +x install.sh
./install.sh
```

#### Reopen
```
cd /opt/wowserver-install/Azerothcore
./install.sh
```

## Prerequisites

- Fresh Debian 13 LXC, root or passwordless `sudo`
- Disk: Auth ~20 GB, World ~45 GB (RelWithDebInfo build tree + client data),
  Both on one LXC ~60 GB. The script checks free space before each build and
  warns if it is short.
- 2/3/4 require Basic System (1) to have run first
- Install item 1 collects the base data at the start and then sets up the
  Debian base system, the administrator, the dynamic MOTD, SSH and Fail2Ban.
- Your own installations, services and project-specific adjustments are
  deliberately not prescribed and must be added after the base system.


## Control/ layout

```text
Control/
├── common.sh              shared helpers (status, server control, apply_values)
├── auth-menu.sh            authmenu
├── world-menu.sh           worldmenu
├── clean-build.sh          build-dir cleaner (only <ACORE_DIR>/build)
└── values/                 curated config summaries
    ├── values_auth.conf
    ├── values_world.conf
    └── values_playerbots.conf
```

`values/*.conf` are curated summaries of the real config files. Edit one in the
menu, then "Apply": every key that also exists in the target config is written
there in place (verbatim value, timestamped backup first); keys not in the
target are reported and skipped. Copied on install, never overwritten by
"Update Control scripts", so operator edits survive an update. The world menu's
"Edit any .conf" also covers `worldserver.conf` plus any module conf.

## First start via `authmenu` / `worldmenu`

The Control menus are offered at the end of items 2/3/4 (or install later via
item 5). Run `authmenu` / `worldmenu` (as root or `sudo`; the menu re-execs as
the server owner). The initial bring-up is not automated:

### Authserver

1. `[12] Config` → `[1]` edit `values_auth.conf`: set the real password in
   `LoginDatabaseInfo` → back → `[2]` apply → answer restart **yes**.
2. `[6] Auth console`: the server asks to create `acore_auth` → **yes**, wait
   for "Added realm ...", then detach with `Ctrl-B` then `D`.
3. Optional: `[8] Autostart` → enable.

### Worldserver

1. `[14] Config` → edit + apply `values_world.conf` (`[1]`/`[2]`) and
   `values_playerbots.conf` (`[3]`/`[4]`). Point the three `*DatabaseInfo`
   lines at the auth LXC / real password; `LoginDatabaseInfo` is **not**
   127.0.0.1 on a split setup.
2. `[1] Start server`, then `[8] World console`: confirm creating
   `acore_world` / `acore_characters` / `acore_playerbots`.
3. **Known Playerbots quirk:** the first start hangs at
   `Waiting for N characters loading into database`. Detach, then
   `[3] Kill server` (type `KILL`) → `[1] Start server` again. The second
   start finishes the character creation and comes up normally.
4. Optional: `[10] Autostart`, `[11] Daily restart timer`.
