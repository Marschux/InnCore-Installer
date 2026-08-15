# WoW Privatserver Installscript

Install scripts for WoW private server cores.

Currently covers:

- [`Azerothcore/`](Azerothcore/) - combined install script for AzerothCore WotLK (Authserver/Worldserver/Bothserver), see `Azerothcore/install.md`

Die Control-Menüs gehören direkt zur AzerothCore-Installation und liegen unter
`Azerothcore/Control/`.

## Verwendung

Das Script wird auf einem frischen Debian-13-LXC als `root` ausgeführt. Die
eigenen Vorbereitungen des LXC, zum Beispiel Netzwerk, Notizen und Snapshot,
sollten vorher abgeschlossen sein.

### Erstmalige Installation

Das Repository wird direkt in den vorgesehenen Installationsordner geklont.

```bash
apt update && apt install -y git
git clone git@gitlab.com:grassnotfound/WoW-Privatserver-Installscript.git /opt/wowserver-install
cd /opt/wowserver-install/Azerothcore
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
cd /opt/wowserver-install/Azerothcore
./install.sh
```

Nach dem Basic System können die weiteren Menüpunkte für Authserver oder
Worldserver ausgeführt werden. Bothserver ist nur erforderlich, wenn Auth- und
Worldserver auf derselben LXC betrieben werden sollen. Die Control-Menüs können am Ende
der jeweiligen Serverinstallation optional eingerichtet oder später über
Menüpunkt 5 installiert werden.

Eigene Installationen, Dienste und projektspezifische Anpassungen müssen nach
dem Basissystem ergänzt werden.

Die detaillierte Übersicht befindet sich in
[`Azerothcore/install.md`](Azerothcore/install.md).
