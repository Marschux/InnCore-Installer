################################################################################
#                                                                              #
#              AZEROTHCORE - WORLDSERVER MIT PLAYERBOTS                       #
#                                                                              #
################################################################################


# ==============================================================================
# 0. Voraussetzungen und Menüauswahl
# ==============================================================================
# Installpunkt 1 (Basic System) muss vorher erfolgreich abgeschlossen sein.
# Das Script wird als root oder mit passwortlosem sudo gestartet:

cd /opt/wow-privatserver-installscript/Azerothcore
./install.sh

# Im Menü auswählen:
#
#   3) 🌍 Worldserver

# Vor dem Start fragt das Script einmalig ab, ob Installpunkt 1 (Basic System)
# vollständig abgeschlossen wurde. Mit yes bestätigen.

# Danach werden alle Worldserver-Angaben gesammelt:
#   - Besitzer des Installationsordners
#   - Installationspfad (Standard: /opt/ac-worldserver)
#   - AzerothCore-Branch (Standard: Playerbot für den Playerbots-Worldserver)
#   - MySQL-Passwort für den Benutzer acore, inklusive Wiederholung
#
# Die Distribution wird automatisch aus /etc/os-release erkannt.

# Vor dem Build müssen für das LXC ausreichend CPU und RAM bereitgestellt
# werden. Das Script fordert vor und nach dem Build eine Bestätigung an.
# Für die Clientdaten wird ein eigener WoW-3.3.5a-Client empfohlen.


# ==============================================================================
# 1. Systempakete aktualisieren
# ==============================================================================
sudo apt update && sudo apt full-upgrade -y


# ==============================================================================
# 2. Quellcode und Playerbots-Modul klonen
# ==============================================================================
# Die zuvor abgefragten Werte werden hier verwendet. Standardwerte:
#   Besitzer: aktueller sudo-/Login-Benutzer
#   Pfad:     /opt/ac-worldserver

sudo mkdir -p /opt/ac-worldserver
sudo chown <owner>:<owner> /opt/ac-worldserver
cd /opt/ac-worldserver

git clone https://github.com/mod-playerbots/azerothcore-wotlk.git --branch=Playerbot .

cd /opt/ac-worldserver/modules
git clone https://github.com/mod-playerbots/mod-playerbots.git --branch=master


# ==============================================================================
# 3. Abhängigkeiten installieren
# ==============================================================================
# Die Distribution wird aus /etc/os-release erkannt und in der AzerothCore-
# Konfiguration gesetzt.

OSDISTRO="<erkannte-distribution>"
sed -i "s/^#\s*OSDISTRO=.*/OSDISTRO=\"$OSDISTRO\"/" /opt/ac-worldserver/conf/dist/config.sh

cd /opt/ac-worldserver
./acore.sh install-deps


# ==============================================================================
# 4. Build-Verzeichnis erstellen
# ==============================================================================
mkdir -p build
cd build


# ==============================================================================
# 5. CMake konfigurieren
# ==============================================================================
# Der Worldserver wird mit statischen Scripts und ohne zusätzliche Tools gebaut.

cmake ../ \
  -DCMAKE_INSTALL_PREFIX=/opt/ac-worldserver/env/dist \
  -DAPPS_BUILD=world-only \
  -DSCRIPTS=static \
  -DTOOLS_BUILD=none

# Danach Ressourcen im Proxmox-LXC hochskalieren und im Script bestätigen.


# ==============================================================================
# 6. Kompilieren und installieren
# ==============================================================================
make -j "$(nproc)"
make install

# Danach Ressourcen im Proxmox-LXC wieder zurückskalieren und bestätigen.


# ==============================================================================
# 7. Clientdaten bereitstellen
# ==============================================================================
# Das Script startet ./acore.sh client-data. Der Assistent bietet zwei Wege:
#
#   1. Daten aus einem eigenen WoW-3.3.5a-Client extrahieren
#   2. Vorab extrahierte Daten herunterladen
#
# Benötigt werden maps, vmaps, mmaps und DBC-Daten.

cd /opt/ac-worldserver
./acore.sh client-data


# ==============================================================================
# 8. Ordnerstruktur und Konfiguration
# ==============================================================================
# Aktive Konfigurationen aus den Vorlagen erzeugen:

cp /opt/ac-worldserver/env/dist/etc/worldserver.conf.dist \
   /opt/ac-worldserver/env/dist/etc/worldserver.conf

echo -e "\nAllowTwoSide.WhoList = 1" \
  >> /opt/ac-worldserver/env/dist/etc/worldserver.conf

cp /opt/ac-worldserver/env/dist/etc/modules/playerbots.conf.dist \
   /opt/ac-worldserver/env/dist/etc/modules/playerbots.conf


# ==============================================================================
# 9. MySQL-8.4-Grundkonfiguration
# ==============================================================================
sudo tee /etc/mysql/mysql.conf.d/acore_limits.cnf > /dev/null << 'EOF'
[mysqld]
bind-address            = 0.0.0.0
mysqlx-bind-address     = 0.0.0.0
disable_log_bin
mysql_native_password   = ON
EOF

sudo systemctl restart mysql


# ==============================================================================
# 10. Automatisches hardwareabhängiges MySQL-Tuning
# ==============================================================================
# Das Script erkennt CPU-Kerne, RAM und Datenträgertyp automatisch. Daraus wird
# ein großzügigeres Playerbot-Worldserver-Profil berechnet und in folgende Datei
# geschrieben:

/etc/mysql/mysql.conf.d/mysqld.cnf

# Unter anderem werden Buffer Pool, Log Buffer, Redo Log, Verbindungen,
# Tabellen-Cache, temporäre Tabellen und I/O-Kapazität berechnet. Die Werte
# werden danach im Terminal angezeigt und MySQL wird neu gestartet.

sudo mkdir -p /var/log/mysql
sudo touch /var/log/mysql/slow.log
sudo chown mysql:mysql /var/log/mysql/slow.log
sudo systemctl restart mysql


# ==============================================================================
# 11. Datenbanken und MySQL-Benutzer anlegen
# ==============================================================================
# Das Script fragt das Passwort verdeckt ab und legt den Benutzer acore für
# localhost und entfernte Verbindungen an:

CREATE USER IF NOT EXISTS 'acore'@'localhost' IDENTIFIED WITH mysql_native_password BY '<DB_PASS>';
CREATE USER IF NOT EXISTS 'acore'@'%' IDENTIFIED WITH mysql_native_password BY '<DB_PASS>';

GRANT ALL PRIVILEGES ON *.* TO 'acore'@'localhost' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'acore'@'%' WITH GRANT OPTION;

FLUSH PRIVILEGES;


# ==============================================================================
# 12. Abschluss
# ==============================================================================
# Das Script meldet den erfolgreichen Abschluss von Build und Datenbanksetup.
# Verwaltungsskripte sowie der spätere worldmenu-Startablauf sind nicht Teil
# dieses Installationspunkts und werden separat behandelt.
