# AzerothCore Control

Small custom control scripts for the installed AzerothCore servers.
These files belong to this repository and have no dependency on
InnControl or any other repository.

## Structure

```text
Control/
├── common.sh          shared helpers (palette, status, server control)
├── auth-menu.sh       authmenu
├── world-menu.sh      worldmenu
└── clean-build.sh     build-dir cleaner
```

The Control scripts are installed separately from the AzerothCore source and
build files. The build cleaner may only clean the exact path
`<ACORE_DIR>/build`.

## Features

### Authserver

- Start, stop, restart and status
- Manage autostart
- Update and build AzerothCore
- Safely clean the build directory
- Open `authserver.conf`
- Account management
- Realm management

### Worldserver

- Start, stop, restart and status
- Manage autostart and restart timer
- Save world
- Update and build AzerothCore and Playerbots
- Safely clean the build directory
- Delete accounts
- Patch `worldserver.conf`
- Patch `playerbots.conf`

## Usage

Installed by `install.sh` (offered at the end of items 2/3/4, or on demand
via menu item 5). The menus are then started, for example, like this:

```bash
/opt/acore-auth-control/auth-menu.sh
/opt/acore-world-control/world-menu.sh
```

The world menu uses dedicated override files for configuration changes.
Only valid `key = value` lines are merged into a marked block; a backup of the
target configuration is created automatically beforehand.
