# Installpunkt 5: Authscript

## Ziel

Nur die ACore-InnControl-Verwaltungsskripte für den Authserver installieren.

## Voraussetzungen

- Ein Authserver-Build ist bereits vorhanden.
- Der Benutzer und seine Bash-Konfiguration sind bekannt.

## Ablauf

1. Vorhandenen temporären Ordner `/tmp/acore-inncontrol` entfernen.
2. Repository `grassnotfound/acore-inncontrol` nach `/tmp/acore-inncontrol` klonen.
3. Das Installationsscript mit Rolle `auth` ausführen.
4. Bei Ausführung als Root den tatsächlichen Benutzer über `SUDO_USER` berücksichtigen.
5. MySQL-Passwort in `values_auth.conf` eintragen.

## Ergebnis

- Authserver-Verwaltungsskripte sind installiert.
- Das Kommando `authmenu` steht nach `source ~/.bashrc` oder einer neuen Anmeldung zur Verfügung.
