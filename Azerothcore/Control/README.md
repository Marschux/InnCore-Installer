# AzerothCore Control

Eigene, kleine Steuerungsskripte für die installierten AzerothCore-Server.
Diese Dateien gehören zu diesem Repository und haben keine Abhängigkeit von
InnControl oder einem weiteren Repository.

## Struktur

```text
Control/
├── auth/
├── world/
└── install.sh
```

Die Control-Skripte werden getrennt von den AzerothCore-Quell- und Builddateien
installiert. Der Build-Cleaner darf ausschließlich den exakten Pfad
`<ACORE_DIR>/build` bereinigen.

## Geplante Funktionen

### Authserver

- Start, Stop, Neustart und Status
- Autostart verwalten
- AzerothCore aktualisieren und bauen
- Build-Verzeichnis sicher bereinigen
- `authserver.conf` öffnen
- Accountverwaltung
- Realmverwaltung

### Worldserver

- Start, Stop, Neustart und Status
- Autostart und Neustart-Timer verwalten
- Welt speichern
- AzerothCore und Playerbots aktualisieren und bauen
- Build-Verzeichnis sicher bereinigen
- Accounts löschen
- `worldserver.conf` patchen
- `playerbots.conf` patchen

## Verwendung

Installation über Menüpunkt 5 des Hauptinstallers oder direkt mit:

```bash
bash Control/install.sh
```

Danach werden die Menüs beispielsweise so gestartet:

```bash
/opt/acore-auth-control/auth-menu.sh
/opt/acore-world-control/world-menu.sh
```

Das World-Menü nutzt eigene Override-Dateien für Konfigurationsänderungen.
Nur gültige `key = value`-Zeilen werden in einen markierten Block übernommen;
vorher wird automatisch eine Sicherung der Zielkonfiguration angelegt.
