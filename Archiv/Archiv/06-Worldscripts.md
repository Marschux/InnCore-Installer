# Installpunkt 6: Worldscripts

## Ziel

Nur die ACore-InnControl-Verwaltungsskripte für den Worldserver installieren.

## Voraussetzungen

- Ein Worldserver-Build ist bereits vorhanden.
- Der Benutzer und seine Bash-Konfiguration sind bekannt.

## Ablauf

1. Vorhandenen temporären Ordner `/tmp/acore-inncontrol` entfernen.
2. Repository `grassnotfound/acore-inncontrol` nach `/tmp/acore-inncontrol` klonen.
3. Das Installationsscript mit Rolle `world` ausführen.
4. Bei Ausführung als Root den tatsächlichen Benutzer über `SUDO_USER` berücksichtigen.
5. Datenbankpasswörter in `values_world.conf` eintragen.
6. Datenbankpasswort in `values_playerbots.conf` eintragen.

## Ergebnis

- Worldserver-Verwaltungsskripte sind installiert.
- Das Kommando `worldmenu` steht nach `source ~/.bashrc` oder einer neuen Anmeldung zur Verfügung.
