################################################################################
#                                                                              #
#    AZEROTHCORE & SECURITY SETUP - DEBIAN 13 (BARE-METAL LXC)                 #
#    ----------------------------------------------------------                 #
#    Goal: System preparation, user security and Fail2Ban                       #
#                                                                              #
################################################################################


# ==============================================================================
# 0. Proxmox: LXC autostart + WoW-Bridge network
# ==============================================================================
# Do this once in the Proxmox web UI, before starting/entering the LXC:
# - Options > Start at boot: Yes
# - Network: add a second interface (net1) on vmbr_wow ("WoW-Bridge"),
#   static IP in 10.20.10.0/24
# - Notes: paste the HTML block from this LXC's "LXC Notes <Name>.md" into
#   Summary > Notes
# - Snapshot: create one named "Fresh_Install" before continuing


# ==============================================================================
# 1. System update and base packages, including Fail2Ban
# ==============================================================================
apt update && apt full-upgrade -y
### ------------------------------ insert text ------------------------------ ###
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
### -------------------------------- end text ------------------------------- ###

timedatectl set-timezone Europe/Berlin


# ==============================================================================
# 2. Create and authorize the admin user
# ==============================================================================
# If "admin" already exists (e.g. re-running after an interrupted attempt),
# skip adduser - it would otherwise fail with "user already exists".
adduser admin --gecos ""
usermod -aG sudo admin


# ==============================================================================
# 3. SSH security: disable root login
# ==============================================================================
sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config

systemctl enable ssh
systemctl restart ssh


# ==============================================================================
# 4. Configure Fail2Ban for SSH
# ==============================================================================
### ------------------------------ insert text ------------------------------ ###
cat << 'EOF' > /etc/fail2ban/jail.d/ssh.local
[sshd]
enabled  = true
port     = ssh
backend  = systemd
maxretry = 5
bantime  = 600
findtime = 600
EOF
### -------------------------------- end text ------------------------------- ###

systemctl enable fail2ban
systemctl restart fail2ban

# Give the socket a moment to come up before querying it.
sleep 2
fail2ban-client status


# ==============================================================================
# 5. Appearance and comfort for root and admin
# ==============================================================================

# Adjust container name, color and icon before using this section.
# Insert MOTD files here before continuing.

cat /dev/null > /etc/motd

chmod +x /usr/local/bin/dynamic-motd.sh

echo "/usr/local/bin/dynamic-motd.sh" >> ~/.bashrc
echo "/usr/local/bin/dynamic-motd.sh" >> /home/admin/.bashrc

# ==============================================================================
# 6. Install Patchmon bot
# ==============================================================================
# Insert Patchmon bot installation steps here.


# ==============================================================================
# 7. Final step: lock root password
# ==============================================================================
# Setup is almost finished.
# Before locking root, test SSH login as "admin" in a new terminal window.
# If "sudo -i" works as admin, run:

passwd -l root

exit

# ==============================================================================
# 8. Log in again as admin
# ==============================================================================
# Root is locked and the previous session already exited. Log back in as
# "admin" now (SSH or Proxmox console) - this is the regular user from here on.

ssh admin@<LXC-IP>

# The dynamic MOTD banner from step 5 should appear automatically on login.
# If it doesn't (e.g. re-attaching to an existing shell instead of a fresh
# login), source it manually:

source ~/.bashrc

# Update this LXC's "LXC Notes <Name>.md" now that Basic System is complete.