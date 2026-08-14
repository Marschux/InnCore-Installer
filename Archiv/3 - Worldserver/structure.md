```
└── 📁3 - Worldserver
    └── 📁Realm Settings
        └── 📁LXC Notes
            ├── Alsterwind.md
            ├── Backup-Server.md
            ├── Kiely Bay.md
            ├── Neufinster.md
            ├── PTR-Server.md
        └── 📁MOTD
            ├── Alsterwind.md
            ├── Backup-Server.md
            ├── Kiely Bay.md
            ├── Neufinster.md
            ├── PTR-Server.md
        └── 📁mysqld
            ├── Alsterwind.cnf
            ├── Backup-Server.cnf
            ├── Kiely Bay.cnf
            ├── Neufinster.cnf
            ├── PTR-Server.cnf
    ├── aliases.md
    ├── Guide Worldserver.md
    └── structure.md
```

The management scripts themselves (`00_world_menu.sh` etc.) are not part
of this repo - they live in the separate
[ACore InnControl](https://gitlab.com/grassnotfound/acore-inncontrol) repo and
get installed via its `install.sh` (see `Guide Worldserver.md`), the same
way `5 - Modules/` only references external AzerothCore modules instead
of containing their code.