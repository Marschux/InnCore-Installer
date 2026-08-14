# Installpunkt 3: Worldserver

## Ziel

Worldserver von AzerothCore mit Playerbots kompilieren, installieren und vorbereiten.

## Voraussetzungen

- Installpunkt 1 wurde erfolgreich abgeschlossen.
- Genügend CPU und RAM während des Build-Prozesses.
- Optional: eigener WoW-3.3.5a-Client für die Clientdaten.

## Ablauf

1. Systempakete aktualisieren.
2. Installationsbenutzer abfragen.
3. Installationspfad abfragen, Standard: `/opt/ac-worldserver`.
4. Zielordner anlegen und Besitzer setzen.
5. AzerothCore-Playerbots-Repository klonen:
   - Repository: `mod-playerbots/azerothcore-wotlk`
   - Branch: `Playerbot`
6. Modul `mod-playerbots` in den Modulordner klonen.
7. Distribution erkennen und in `conf/dist/config.sh` eintragen.
8. AzerothCore-Abhängigkeiten mit `./acore.sh install-deps` installieren.
9. Build-Ordner erstellen und öffnen.
10. CMake konfigurieren:
    - Installationsziel: `env/dist`
    - `APPS_BUILD=world-only`
    - `SCRIPTS=static`
    - `TOOLS_BUILD=none`
11. Vor dem Build Proxmox-Ressourcen hochskalieren.
12. Mit allen verfügbaren CPUs kompilieren.
13. Worldserver installieren.
14. Proxmox-Ressourcen wieder zurückskalieren.
15. Clientdaten bereitstellen oder Download durch `acore.sh client-data` auswählen.
16. `worldserver.conf` aus der Vorlage erzeugen.
17. `AllowTwoSide.WhoList = 1` ergänzen.
18. `playerbots.conf` aus der Vorlage erzeugen.
19. MySQL-Konfiguration für AzerothCore anlegen und MySQL neu starten.
20. Hardwarepassende MySQL-Vorlage auswählen und in `mysqld.cnf` eintragen.
21. Slow-Query-Log anlegen und Berechtigungen setzen.
22. MySQL neu starten.
23. Passwort für den MySQL-Benutzer `acore` abfragen.
24. Datenbankbenutzer `acore` für `localhost` und `%` anlegen.
25. Datenbankrechte vergeben.
26. Worldserver-Verwaltungsskripte installieren.
27. Passwörter in `values_world.conf` und `values_playerbots.conf` eintragen.
28. Für den ersten Start auf `worldmenu` und die separate Startanleitung verweisen.

## Manuelle Eingaben

- Benutzer für den Installationsordner
- Installationspfad
- Proxmox-Ressourcen vor und nach dem Build
- Clientdaten oder Auswahl eines Downloads
- Hardwarepassende MySQL-Konfiguration
- MySQL-Passwort für `acore`
- Passwörter in den World- und Playerbot-Konfigurationen

## Ergebnis

- Worldserver mit Playerbots ist unter `/opt/ac-worldserver` gebaut und installiert.
- Clientdaten und Konfigurationen sind vorhanden.
- MySQL-Benutzer `acore` ist vorbereitet.
- `worldmenu` ist installiert.
