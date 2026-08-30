# WoW Privatserver Installscript

Install-Skripte für WoW-Privatserver-Cores.

Aktuell abgedeckt:

- [`Azerothcore/`](Azerothcore/) – kombiniertes Install-Skript für AzerothCore
  WotLK (Authserver / Worldserver / Bothserver) inkl. Control-Menüs
  (`Azerothcore/Control/`). Menü-Übersicht und First-Start-Ablauf:
  [`Azerothcore/install.md`](Azerothcore/install.md).

## Verwendung

Auf einem frischen Debian-13-LXC als `root`. Eigene LXC-Vorbereitung (Netzwerk,
Notizen, Snapshot) sollte vorher abgeschlossen sein.

### Erstmalige Installation

Benötigt wird `install.sh` **mit** dem `Control/`-Ordner daneben – am
einfachsten den kompletten `Azerothcore/`-Ordner klonen:

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
3. `2) Authserver` / `3) Worldserver` (oder `4) Bothserver`, wenn beide auf
   einer LXC). Das Control-Menü wird am Ende jeweils optional angeboten, oder
   später über `5) Control`.

### Script erneut öffnen

```bash
cd /opt/wowserver-install && ./install.sh
```
