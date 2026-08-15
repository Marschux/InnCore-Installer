################################################################################
#                                                                              #
#              AZEROTHCORE - BOTHSERVER IN EINEM LXC                          #
#              Authserver + Worldserver mit Playerbots                        #
#                                                                              #
################################################################################


# ==============================================================================
# 0. Voraussetzungen und Menüauswahl
# ==============================================================================
# Installpunkt 1 (Basic System) muss vorher erfolgreich abgeschlossen sein.
# Das LXC muss ausreichend CPU, RAM und Speicher für beide Server besitzen.

cd /opt/wow-privatserver-installscript/Azerothcore
./install.sh

# Im Menü auswählen:
#
#   4) 🔗 Bothserver

# Vor dem Start fragt das Script einmalig ab, ob Installpunkt 1 (Basic System)
# vollständig abgeschlossen wurde. Mit yes bestätigen. Die Abfrage erscheint
# beim Bothserver nur einmal für den gesamten Ablauf.

# Danach werden vor dem Start alle Werte gesammelt:
#   - Besitzer und Pfad für den Authserver
#   - Authserver-Branch (Standard: master)
#   - Besitzer und Pfad für den Worldserver
#   - Worldserver-Branch (Standard: Playerbot)
#   - ein gemeinsames MySQL-Passwort für den Benutzer acore
#
# Die Distribution wird automatisch erkannt.

# Das Script führt danach zuerst den vollständigen Authserver-Ablauf und direkt
# anschließend den vollständigen Worldserver-Ablauf im selben LXC aus.


# ==============================================================================
# 1. Authserver installieren
# ==============================================================================
# Der Authserver-Ablauf entspricht Installpunkt 2:
#
#   - System aktualisieren
#   - Besitzer und Pfad abfragen
#   - AzerothCore-Authserver aus dem master-Branch klonen
#   - Abhängigkeiten installieren
#   - Authserver mit auth-only konfigurieren, bauen und installieren
#   - authserver.conf erzeugen
#   - MySQL-Grundkonfiguration schreiben
#   - automatisches gemeinsames MySQL-Tuning für die LXC-Hardware erzeugen
#   - MySQL-Benutzer acore anlegen

# Bei den Build-Schritten fordert das Script jeweils die Anpassung der Proxmox-
# Ressourcen an. Der Datenbankbenutzer acore wird für localhost und % angelegt.


# ==============================================================================
# 2. Gemeinsames automatisches MySQL-Tuning
# ==============================================================================
# Authserver und Worldserver verwenden im selben LXC dieselbe Datei:

/etc/mysql/mysql.conf.d/mysqld.cnf

# Das Script erkennt CPU-Kerne, RAM und Datenträgertyp automatisch und erzeugt
# ein gemeinsames Profil für Authserver und Worldserver. Vor dem Schreiben wird
# ein vorhandener AzerothCore-Tuningblock entfernt, damit keine widersprüchlichen
# doppelten Werte bestehen bleiben. Die berechneten Werte werden angezeigt.


# ==============================================================================
# 3. Worldserver installieren
# ==============================================================================
# Der Worldserver-Ablauf entspricht Installpunkt 3:
#
#   - System aktualisieren
#   - Besitzer und Pfad abfragen
#   - Playerbots-AzerothCore aus dem Playerbot-Branch klonen
#   - mod-playerbots klonen
#   - Abhängigkeiten installieren
#   - Worldserver mit static Scripts konfigurieren, bauen und installieren
#   - Clientdaten extrahieren oder herunterladen
#   - worldserver.conf und playerbots.conf erzeugen
#   - AllowTwoSide.WhoList = 1 ergänzen
#   - MySQL-Grundkonfiguration schreiben
#   - automatisches gemeinsames MySQL-Tuning erneut erzeugen
#   - Slow-Query-Log vorbereiten
#   - MySQL-Benutzer acore erneut mit dem gewünschten Passwort anlegen

# Die Clientdaten-Auswahl erfolgt über ./acore.sh client-data. Dafür kann ein
# eigener 3.3.5a-Client verwendet oder ein Download ausgewählt werden.


# ==============================================================================
# 4. Datenbankpasswort
# ==============================================================================
# Authserver und Worldserver fragen das Passwort jeweils separat ab. Für einen
# gemeinsamen LXC sollte dasselbe Passwort für den Benutzer acore verwendet
# werden, damit beide Server auf die Datenbanken zugreifen können.


# ==============================================================================
# 5. Abschluss
# ==============================================================================
# Nach dem Authserver- und Worldserver-Ablauf meldet das Script den Abschluss
# beider Builds und Datenbankvorbereitungen.
#
# Verwaltungsskripte sowie die späteren authmenu- und worldmenu-Startabläufe
# sind nicht Teil dieses Installationspunkts und werden separat behandelt.
