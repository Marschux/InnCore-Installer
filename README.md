# WoW Privatserver Installscript

Install scripts for WoW private server cores, one subfolder per core.

Currently covers:

- [`Azerothcore/`](Azerothcore/) - combined install script for AzerothCore WotLK (Authserver/Worldserver/Bothserver), see `Azerothcore/install.md`

Structured per-core so other cores (e.g. TrinityCore, CMaNGOS) can be added as sibling folders later without touching the AzerothCore install.

## Verwendung

Das Script wird auf einem frischen Debian-13-LXC als `root` ausgeführt. Die
eigenen Vorbereitungen des LXC, zum Beispiel Netzwerk, Notizen und Snapshot,
sollten vorher abgeschlossen sein.

### Erstmalige Installation

```bash
apt update && apt install -y git
cd /opt
git clone https://gitlab.com/grassnotfound/wow-privatserver-installscript.git
cd wow-privatserver-installscript/Azerothcore
chmod +x install.sh
./install.sh
```

Im Menü:

```text
1) Basic System
```

Der erste Installationspunkt fragt alle benötigten Angaben am Anfang ab. Dazu
gehören die Zeitzone sowie Benutzername und Passwort des Administrationskontos.
Der beim Erstellen des LXC gesetzte Hostname bleibt unverändert. Danach läuft
die Einrichtung des Basissystems durch.

Vor dem Sperren des Root-Passworts muss die SSH-Anmeldung mit dem neuen
Administrationskonto und `sudo -i` in einem zweiten Terminal getestet werden.

### Script erneut öffnen

```bash
cd /opt/wow-privatserver-installscript/Azerothcore
./install.sh
```

Nach dem Basic System können die weiteren Menüpunkte für Authserver,
Worldserver oder Bothserver ausgeführt werden. Eigene Installationen, Dienste
und projektspezifische Anpassungen müssen nach dem Basissystem ergänzt werden.

Die detaillierte Übersicht befindet sich in
[`Azerothcore/install.md`](Azerothcore/install.md).
