################################################################################
#                                                                              #
#    AZEROTHCORE BASIC SYSTEM - DEBIAN 13 (LXC)                               #
#    ------------------------------------------                               #
#    Ziel: Systemvorbereitung, Benutzerabsicherung und Fail2Ban                #
#                                                                              #
################################################################################


# ==============================================================================
# 0. Voraussetzungen und Menüauswahl
# ==============================================================================
# Das Script wird in einem Debian-13-LXC als root gestartet:

cd /opt/wow-privatserver-installscript/Azerothcore
./install.sh

# Im Menü muss zuerst gewählt werden:
#
#   1) 🧱 Basic System
#
# Die Punkte 2, 3 und 4 setzen diesen Installationspunkt voraus. Die eigenen
# Vorbereitungen für das LXC, zum Beispiel Netzwerk, Notizen und Snapshot,
# müssen vor dem Start abgeschlossen sein.


# ==============================================================================
# 1. Benötigte Angaben am Anfang
# ==============================================================================
# Das Script fragt alle Eingaben vor der eigentlichen Installation ab.

# Allgemeine Vorbereitung bestätigen:
#   Ist das Debian-LXC mit den eigenen Vorbereitungen und Anpassungen fertig?
#   Eingabe: yes

# Zeitzone:
#   Die Auswahl erfolgt über das Debian-Menü von tzselect:
#   - Region beziehungsweise Kontinent auswählen
#   - Land beziehungsweise Zeitzone auswählen
#   - Auswahl bestätigen
#
#   Beispiel: Europe -> Germany -> Europe/Berlin
#   Die Auswahl wird anschließend gegen die verfügbaren Systemzeitzonen geprüft.

# Administrationskonto:
#   - Benutzername
#   - Passwort
#   - Passwortwiederholung
#
# Der Account wird im nächsten Schritt angelegt beziehungsweise aktualisiert
# und für die Verwendung von sudo freigeschaltet.


# ==============================================================================
# 2. Systemaktualisierung und Basiswerkzeuge
# ==============================================================================
apt update && apt full-upgrade -y

apt install -y \
  sudo \
  htop \
  curl \
  wget \
  nano \
  unattended-upgrades \
  screen \
  tmux \
  net-tools \
  iproute2 \
  unzip \
  git \
  iputils-ping \
  glances \
  openssh-server \
  fail2ban \
  locales


# ==============================================================================
# 3. Zeitzone, Hostname-Auflösung und Administrationskonto
# ==============================================================================
# Der beim Erstellen des LXC gesetzte Hostname bleibt unverändert.

# Falls der aktuelle Hostname noch nicht lokal aufgelöst werden kann, ergänzt
# das Script in /etc/hosts automatisch eine Zeile wie:

127.0.1.1 <aktueller-hostname>

timedatectl set-timezone <ausgewählte-zeitzone>

# Danach zeigt das Script an, welcher Account verwendet wird:

Verwendeter Account: <Administrationsbenutzer>

# Ist der Benutzer noch nicht vorhanden, wird er angelegt. Existiert er schon,
# wird er weiterverwendet. Anschließend wird das abgefragte Passwort gesetzt
# und der Benutzer der Gruppe sudo hinzugefügt.


# ==============================================================================
# 4. Dynamisches MOTD-Template
# ==============================================================================
# Das Script installiert das dynamische MOTD automatisch. Eine manuelle
# Mehrzeilen-Eingabe ist nicht erforderlich.

# Installierte Dateien:
#   /usr/local/bin/dynamic-motd.sh
#   /etc/profile.d/dynamic-motd.sh

# Das MOTD zeigt bei jeder neuen Anmeldung dynamisch:
#   🌐 Servername
#   👤 Benutzer
#   🐧 Betriebssystem
#   🔢 IP-Adresse
#   🕒 Uptime
#   🧠 CPU-Kerne
#   📊 Load
#   💾 Arbeitsspeicher
#   🔄 Swap
#   💽 Festplattenbelegung

# Die statische MOTD-Datei wird geleert:

truncate -s 0 /etc/motd

# Das Script gibt das neue MOTD anschließend einmal testweise im Terminal aus.
# So können Hostname, IP-Adresse, Systemwerte und Icons direkt kontrolliert
# werden.

/usr/local/bin/dynamic-motd.sh


# ==============================================================================
# 5. SSH absichern
# ==============================================================================
# Root-Login per SSH wird deaktiviert:

PermitRootLogin no

systemctl enable ssh
systemctl restart ssh


# ==============================================================================
# 6. Fail2Ban für SSH konfigurieren
# ==============================================================================
cat << 'EOF' > /etc/fail2ban/jail.d/ssh.local
[sshd]
enabled  = true
port     = ssh
backend  = systemd
maxretry = 5
bantime  = 600
findtime = 600
EOF

systemctl enable fail2ban
systemctl restart fail2ban

# Nach kurzer Wartezeit wird der Fail2Ban-Status angezeigt:

fail2ban-client status


# ==============================================================================
# 7. Zugang testen
# ==============================================================================
# Vor dem Sperren des Root-Passworts öffnet man ein NEUES Terminal und prüft:
#
#   1. SSH-Anmeldung mit dem neuen Administrationskonto
#   2. Erfolgreiche Ausführung von sudo -i
#   3. Erreichbarkeit des LXC über die konfigurierte IP
#
# Das Script wartet auf die Bestätigung, dass diese Tests erfolgreich waren.


# ==============================================================================
# 8. Root-Passwort sperren
# ==============================================================================
# Erst nach dem erfolgreichen Zugangstest wird ausgeführt:

passwd -l root


# ==============================================================================
# 9. Abschluss-Checkliste
# ==============================================================================
# Das Script zeigt am Ende folgende erledigte Punkte an:
#
# [x] Allgemeine Vorbereitung des LXC bestätigt
# [x] System aktualisiert und Basiswerkzeuge installiert
# [x] Lokale Hostname-Auflösung geprüft
# [x] Zeitzone gesetzt
# [x] Administrationskonto eingerichtet und für sudo autorisiert
# [x] Dynamisches MOTD-Template installiert
# [x] SSH aktiviert und Root-Login per SSH deaktiviert
# [x] Fail2Ban für SSH aktiviert
# [x] SSH- und sudo-Zugang bestätigt
# [x] Root-Passwort gesperrt


# ==============================================================================
# 10. Abschluss-Hinweis
# ==============================================================================
# Nach der Checkliste erscheint in Rot:
#
#   Das Basissystem ist vorbereitet. Ergänze das System jetzt noch um deine
#   eigenen Installationen, Dienste und projektspezifischen Anpassungen,
#   bevor du fortfährst.
