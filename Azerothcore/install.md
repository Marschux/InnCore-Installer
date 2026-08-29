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
- 2/3/4 require Basic System (1) to have run first
- Install item 1 collects the base data at the start and then sets up the
  Debian base system, the administrator, the dynamic MOTD, SSH and Fail2Ban.
- Your own installations, services and project-specific adjustments are
  deliberately not prescribed and must be added after the base system.


## Intentionally not part of the script

**Start flow via `authmenu` / `worldmenu`** (after 5/6/7)

`source ~/.bashrc` (or re-login) so the alias is active, then:

`authmenu`:
```
8        Pull Git updates
8        Build authserver
8        Clean build directory
15       Edit values_auth.conf
16       Apply auth config patch and restart
5        Accept build database (acore_auth), going out with CTRL+B then D
9        Apply Two-Side RBAC permissions
9        Increment change for Bots

----------------- Snapshot -----------------

7        Enable authserver autostart
17       Manage realmlist & MOTD
18       Open account manager

```

`worldmenu`:
```

The Control installation is offered optionally at the end of install items
2, 3 and 4. Menu item 5 remains available as a later option.
12       Pull Git updates
12       Build worldserver
12       Clean build directory
19       Edit values_world.conf
20       Patch worldserver.conf, do NOT restart yet
23       Edit values_playerbots.conf
24       Patch playerbots.conf, do NOT restart yet

----------------- Snapshot -----------------

10       Enable autostart
11       Enable daily restart
1        Start Server
9        Open Tmux Session and confirm Database creation, wait for playerbots creation
5        Kill Server, when creating characters (stucking)
1        Start Server
9        Login Tmux and look at buildup bots
```
