```
└── 📁2 - Authserver
    └── 📁Auth Settings
        ├── LXC Notes Authserver.md
        ├── MOTD Authserver.md
        ├── mysqld Authserver.cnf
    ├── aliases.md
    ├── Guide Authserver.md
    └── structure.md
```

The management scripts themselves (`00_auth_menu.sh` etc.) are not part of
this repo - they live in the separate
[ACore InnControl](https://gitlab.com/grassnotfound/acore-inncontrol) repo and
get installed via its `install.sh` (see `Guide Authserver.md`), the same
way `5 - Modules/` only references external AzerothCore modules instead
of containing their code.
