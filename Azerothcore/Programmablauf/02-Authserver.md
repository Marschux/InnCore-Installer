################################################################################
#                                                                              #
#            AZEROTHCORE - AUTH & MYSQL 8.4 DATABASE SERVER                   #
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
#   2) 🔐 Authserver

# Vor dem Start fragt das Script einmalig ab, ob Installpunkt 1 (Basic System)
# vollständig abgeschlossen wurde. Mit yes bestätigen.

# Danach werden alle Authserver-Angaben gesammelt:
#   - Besitzer des Installationsordners
#   - Installationspfad (Standard: /opt/ac-authserver)
#   - AzerothCore-Branch (Standard: master)
#   - MySQL-Passwort für den Benutzer acore, inklusive Wiederholung
#
# Die Distribution wird automatisch aus /etc/os-release erkannt.

# Vor dem Build müssen für das LXC ausreichend CPU und RAM bereitgestellt
# werden. Das Script fordert vor und nach dem Build eine Bestätigung an.


# ==============================================================================
# 1. Systempakete aktualisieren
# ==============================================================================
sudo apt update && sudo apt full-upgrade -y


# ==============================================================================
# 2. Quellcode klonen
# ==============================================================================
# Die zuvor abgefragten Werte werden hier verwendet. Standardwerte:
#   Besitzer: aktueller sudo-/Login-Benutzer
#   Pfad:     /opt/ac-authserver

sudo mkdir -p /opt/ac-authserver
sudo chown <owner>:<owner> /opt/ac-authserver
cd /opt/ac-authserver

git clone https://github.com/azerothcore/azerothcore-wotlk.git --branch=master .


# ==============================================================================
# 3. Abhängigkeiten installieren
# ==============================================================================
# Die Distribution wird aus /etc/os-release erkannt und in der AzerothCore-
# Konfiguration gesetzt.

OSDISTRO="<erkannte-distribution>"
sed -i "s/^#\s*OSDISTRO=.*/OSDISTRO=\"$OSDISTRO\"/" conf/dist/config.sh
./acore.sh install-deps


# ==============================================================================
# 4. Build-Verzeichnis erstellen
# ==============================================================================
mkdir -p build
cd build


# ==============================================================================
# 5. CMake konfigurieren
# ==============================================================================
# Der Authserver wird ohne Worldserver und ohne zusätzliche Scripts gebaut.

cmake ../ \
  -DCMAKE_INSTALL_PREFIX=/opt/ac-authserver/env/dist \
  -DAPPS_BUILD=auth-only \
  -DTOOLS_BUILD=none \
  -DSCRIPTS=none

# Danach Ressourcen im Proxmox-LXC hochskalieren und im Script bestätigen.


# ==============================================================================
# 6. Kompilieren und installieren
# ==============================================================================
make -j "$(nproc)"
make install

# Danach Ressourcen im Proxmox-LXC wieder zurückskalieren und bestätigen.


# ==============================================================================
# 7. Ordnerstruktur und Konfiguration
# ==============================================================================
# Die aktive Konfiguration wird aus der mitgelieferten Vorlage erzeugt:

cp /opt/ac-authserver/env/dist/etc/authserver.conf.dist \
   /opt/ac-authserver/env/dist/etc/authserver.conf


# ==============================================================================
# 8. MySQL-8.4-Grundkonfiguration
# ==============================================================================
sudo tee /etc/mysql/mysql.conf.d/azcore_limits.cnf > /dev/null << 'EOF'
[mysqld]
bind-address            = 0.0.0.0
mysqlx-bind-address     = 0.0.0.0
disable_log_bin
mysql_native_password   = ON
EOF

sudo systemctl restart mysql


# ==============================================================================
# 9. Automatisches hardwareabhängiges MySQL-Tuning
# ==============================================================================
# Das Script erkennt CPU-Kerne, RAM und Datenträgertyp automatisch. Daraus wird
# ein konservatives Authserver-Profil berechnet und in folgende Datei geschrieben:

/etc/mysql/mysql.conf.d/mysqld.cnf

# Unter anderem werden Buffer Pool, Log Buffer, Redo Log, Verbindungen,
# Tabellen-Cache, temporäre Tabellen und I/O-Kapazität berechnet. Die Werte
# werden danach im Terminal angezeigt und MySQL wird neu gestartet.

sudo systemctl restart mysql


# ==============================================================================
# 10. Datenbanken und MySQL-Benutzer anlegen
# ==============================================================================
# Das Script fragt das Passwort verdeckt ab und legt den Benutzer acore für
# localhost und entfernte Verbindungen an:

CREATE USER IF NOT EXISTS 'acore'@'localhost' IDENTIFIED WITH mysql_native_password BY '<DB_PASS>';
CREATE USER IF NOT EXISTS 'acore'@'%' IDENTIFIED WITH mysql_native_password BY '<DB_PASS>';

GRANT ALL PRIVILEGES ON *.* TO 'acore'@'localhost' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'acore'@'%' WITH GRANT OPTION;

FLUSH PRIVILEGES;


# ==============================================================================
# 11. Abschluss
# ==============================================================================
# Das Script meldet den erfolgreichen Abschluss von Build und Datenbanksetup.
# Verwaltungsskripte sowie der spätere authmenu-Startablauf sind nicht Teil
# dieses Installationspunkts und werden separat behandelt.
