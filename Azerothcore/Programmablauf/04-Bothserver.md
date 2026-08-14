# Installpunkt 4: Bothserver

## Ziel

Authserver und Worldserver gemeinsam in einem LXC installieren.

## Voraussetzungen

- Installpunkt 1 wurde erfolgreich abgeschlossen.
- Das LXC verfügt über ausreichend Ressourcen für beide Server.

## Ablauf

1. Den vollständigen Ablauf aus `02-Authserver.md` ausführen.
2. MySQL-Tuning für die gemeinsame Nutzung von Authserver und Worldserver dimensionieren.
3. Den vollständigen Ablauf aus `03-Worldserver.md` ausführen.
4. Bei der Worldserver-Installation das bereits vorhandene MySQL-Tuning berücksichtigen.
5. Beide Verwaltungsskripte installieren.
6. Authserver- und Worldserver-Konfigurationen mit demselben Datenbankpasswort versehen.
7. Startabläufe über `authmenu` und `worldmenu` durchführen.

## Ergebnis

- Authserver und Worldserver laufen im selben LXC.
- MySQL-Tuning berücksichtigt beide Dienste.
- Beide Verwaltungsmenüs sind installiert.
