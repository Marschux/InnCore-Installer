# Installpunkt 2: Authserver

## Ziel

Authserver von AzerothCore kompilieren, installieren und mit den Authserver-Verwaltungsskripten ausstatten.

## Voraussetzungen

- Installpunkt 1 wurde erfolgreich abgeschlossen.
- Debian-System mit funktionierendem `sudo`.
- Genügend CPU und RAM während des Build-Prozesses.

## Ablauf

1. Systempakete aktualisieren.
2. Installationsbenutzer abfragen.
3. Installationspfad abfragen, Standard: `/opt/ac-authserver`.
4. Zielordner anlegen und Besitzer setzen.
5. AzerothCore WotLK aus GitHub klonen:
   - Repository: `azerothcore/azerothcore-wotlk`
   - Branch: `master`
6. Distribution erkennen und in `conf/dist/config.sh` eintragen.
7. AzerothCore-Abhängigkeiten mit `./acore.sh install-deps` installieren.
8. Build-Ordner erstellen und öffnen.
9. CMake konfigurieren:
   - Installationsziel: `env/dist`
   - `APPS_BUILD=auth-only`
   - `TOOLS_BUILD=none`
   - `SCRIPTS=none`
10. Vor dem Build Proxmox-Ressourcen hochskalieren.
11. Mit allen verfügbaren CPUs kompilieren.
12. Authserver installieren.
13. Proxmox-Ressourcen wieder zurückskalieren.
14. `authserver.conf` aus der Vorlage erzeugen.
15. MySQL-Konfiguration für AzerothCore anlegen und MySQL neu starten.
16. Hardwareabhängige MySQL-Vorlage auswählen und in `mysqld.cnf` eintragen.
17. MySQL neu starten.
18. Passwort für den MySQL-Benutzer `acore` abfragen.
19. Datenbankbenutzer `acore` für `localhost` und `%` anlegen.
20. Datenbankrechte vergeben.
21. Authserver-Verwaltungsskripte installieren.
22. Passwort in `values_auth.conf` eintragen.
23. Für den ersten Start auf `authmenu` und die separate Startanleitung verweisen.

## Manuelle Eingaben

- Benutzer für den Installationsordner
- Installationspfad
- Proxmox-Ressourcen vor und nach dem Build
- Hardwarepassende MySQL-Konfiguration
- MySQL-Passwort für `acore`
- Passwort in `values_auth.conf`

## Ergebnis

- Authserver ist unter `/opt/ac-authserver` gebaut und installiert.
- Authserver-Konfiguration ist angelegt.
- MySQL-Benutzer `acore` ist vorbereitet.
- `authmenu` ist installiert.
