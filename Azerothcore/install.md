# install.sh: Combined Install Script

Mirrors the guides in this repo step by step, with a menu:

| Choice | Installation | Guide / Repo |
|------|--------------|--------------|
| 1 | Basic System | `1 - defaultfiles/Guide Basic System.md` |
| 2 | Authserver | `2 - Authserver/Guide Authserver.md` - build + InnControl scripts |
| 3 | Worldserver | `3 - Worldserver/Guide Worldserver.md` - build + InnControl scripts |
| 4 | Bothserver | Auth + World in sequence, one LXC - build + InnControl scripts |
| 5 | Authscript | [ACore InnControl](https://gitlab.com/grassnotfound/acore-inncontrol) - Auth only, scripts only |
| 6 | Worldscripts | [ACore InnControl](https://gitlab.com/grassnotfound/acore-inncontrol) - World only, scripts only |
| 7 | Both Scripts | [ACore InnControl](https://gitlab.com/grassnotfound/acore-inncontrol) - Auth + World, scripts only |
| 8 | Update | git pull this repo + optionally update InnControl |
| 9 | Delete | remove installed management scripts, or this install.sh itself |

## Usage

A fresh LXC is logged in as root, so no `sudo` yet (that only exists once
Basic System installed it):

#### First Time
```bash
apt update && apt install -y git
cd /opt
git clone https://gitlab.com/grassnotfound/wow-privatserver-installscript.git
cd wow-privatserver-installscript/Azerothcore
chmod +x install.sh
./install.sh
```

#### Reopen
```
cd /opt/wow-privatserver-installscript/Azerothcore
./install.sh
```

## Prerequisites

- Fresh Debian 13 LXC, root or passwordless `sudo`
- 2/3/4 require Basic System (1) to have run first
- 5/6/7 require the matching build (2/3/4) to have run first


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