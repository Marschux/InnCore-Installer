# Installpunkt 9: Delete

## Ziel

Installierte Verwaltungsskripte oder das lokale `install.sh` entfernen.

## Auswahl

1. Authserver-Verwaltungsskripte löschen
2. Worldserver-Verwaltungsskripte löschen
3. Beide Verwaltungsskripte löschen
4. Dieses `install.sh` löschen

## Ablauf Verwaltungsskripte

1. Zielpfad abfragen.
2. Existenz des Zielpfads prüfen.
3. Vor der Löschung eine eindeutige Bestätigung verlangen.
4. Verwaltungsordner löschen.
5. Zugehörige Datei unter `/etc/sudoers.d/` löschen.
6. Benutzer für die Bash-Konfiguration abfragen.
7. Nur den passenden InnControl-Aliasblock aus `.bashrc` entfernen.

## Ablauf install.sh

1. Vor der Löschung eine eindeutige Bestätigung verlangen.
2. Einen eventuell vorhandenen temporären Klon `/tmp/acore-inncontrol` entfernen.
3. Nur die aktuelle `install.sh` löschen.
4. Andere Guides und Vorlagen im Repository erhalten.

## Sicherheitsanforderungen

- Niemals ohne ausdrückliche Bestätigung löschen.
- Zielpfad vor der Löschung anzeigen.
- Keine Datenbanken oder AzerothCore-Serverordner löschen.
- Keine fremden Bash-Aliasblöcke verändern.

## Ergebnis

- Nur die ausdrücklich ausgewählten Verwaltungsskripte oder das Installscript sind entfernt.
