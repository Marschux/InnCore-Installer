# WoW Privatserver Installscript

Install-Skripte für WoW-Privatserver-Cores.

Aktuell: [`Azerothcore/`](Azerothcore/) – kombiniertes Install-Skript für
AzerothCore WotLK inkl. Control-Menüs (`Azerothcore/Control/`).

| Menü | Installation | Umfang |
|------|--------------|--------|
| 1 | Basic System | Grundsystem + Absicherung (Voraussetzung für 2/3/4) |
| 2 | Authserver | nur Build |
| 3 | Worldserver | nur Build |
| 4 | Bothserver | Auth + World auf einer LXC |
| 5 | Control | Management-Menüs `authmenu` / `worldmenu` |

## Verwendung

Auf einem frischen Debian-13-LXC als `root`. Eigene LXC-Vorbereitung (Netzwerk,
Notizen, Snapshot) vorher abschließen.

Platzbedarf: Auth ~20 GB, World ~45 GB, Bothserver ~60 GB. Das Skript prüft vor
jedem Build den freien Platz und warnt.

### Erstmalige Installation

`install.sh` **mit** dem `Control/`-Ordner daneben – am einfachsten den
kompletten `Azerothcore/`-Ordner klonen:

```bash
apt update && apt install -y git
git clone git@gitlab.com:grassnotfound/WoW-Privatserver-Installscript.git /tmp/wpi
sudo cp -r /tmp/wpi/Azerothcore /opt/wowserver-install
rm -rf /tmp/wpi
chmod +x /opt/wowserver-install/install.sh /opt/wowserver-install/Control/*.sh
cd /opt/wowserver-install
./install.sh
```

`/opt` bewusst statt `/root` – Basic System sperrt root und erstellt `admin`;
ein Checkout unter `/root` (Modus 700) wäre danach für `admin` nicht mehr
erreichbar. Der Ordner muss für den späteren Server-Owner lesbar sein
(`chmod -R a+rX`), sonst kann „Update Control scripts" den Checkout nicht lesen.

### Reihenfolge

1. `1) Basic System` – fragt alle Angaben (Zeitzone, Admin-User + Passwort) am
   Anfang ab, richtet dann Grundsystem, MOTD, SSH und Fail2Ban ein.
   **Vor** dem Sperren des Root-Passworts die SSH-Anmeldung als `admin` +
   `sudo -i` in einem zweiten Terminal testen.
2. Danach eigene Installationen / Dienste / Anpassungen ergänzen.
3. `2) Authserver` / `3) Worldserver` (oder `4) Bothserver`). Das Control-Menü
   wird am Ende jeweils optional angeboten, oder später über `5) Control`.

Script erneut öffnen: `cd /opt/wowserver-install && ./install.sh`

## Control-Menüs

```text
Control/
├── common.sh              gemeinsame Helfer (Status, Server-Steuerung, apply_values)
├── auth-menu.sh           authmenu
├── world-menu.sh          worldmenu
├── clean-build.sh         Build-Verzeichnis leeren
└── values/                kuratierte Config-Zusammenfassungen
    ├── values_auth.conf
    ├── values_world.conf
    └── values_playerbots.conf
```

`values/*.conf` sind kuratierte Auszüge der echten Config-Dateien. Im Menü eine
bearbeiten, dann „Apply": jeder Key, der auch im Ziel existiert, wird dort
ersetzt (Wert verbatim, vorher Timestamp-Backup); unbekannte Keys werden
gemeldet und übersprungen. Bei Install kopiert, von „Update Control scripts" nie
überschrieben. Das World-Menü kann über „Edit any .conf" auch `worldserver.conf`
und beliebige Modul-Configs bearbeiten.

`authmenu` / `worldmenu` als root oder `sudo` starten (das Menü re-exect als
Server-Owner).

### Erster Start Authserver

1. `Config` → `values_auth.conf` bearbeiten: echtes Passwort in
   `LoginDatabaseInfo` → zurück → Apply → Restart **ja**.
2. `Auth console`: Server fragt nach `acore_auth` anlegen → **ja**, auf
   „Added realm …" warten, dann `Ctrl-B` `D` zum Ablösen.
3. Optional `Autostart` aktivieren.

### Erster Start Worldserver

1. `Config` → `values_world.conf` und `values_playerbots.conf` bearbeiten +
   applyen. Die drei `*DatabaseInfo`-Zeilen auf die Auth-LXC / echtes Passwort
   zeigen lassen (`LoginDatabaseInfo` ist bei geteiltem Setup **nicht** 127.0.0.1).
2. `Start server`, dann `World console`: Anlegen von `acore_world` /
   `acore_characters` / `acore_playerbots` bestätigen.
3. **Playerbots-Eigenheit:** der erste Start hängt bei
   `Waiting for N characters loading into database`. Ablösen, `Kill server`
   (`KILL` tippen) → `Start server` erneut. Der zweite Start läuft normal durch.
4. Optional `Autostart`, `Daily restart timer`.
