################################################################################
#                                                                              #
#            AZEROTHCORE - AUTH & MYSQL 8.4 DATABASE SERVER SETUP              #
#                                                                              #
################################################################################

# ==============================================================================
# 1. Update system packages
# ==============================================================================
sudo apt update && sudo apt full-upgrade -y


# ==============================================================================
# 2. Clone source code
# ==============================================================================
sudo mkdir -p /opt/ac-authserver
sudo chown admin:admin /opt/ac-authserver
cd /opt/ac-authserver

git clone https://github.com/azerothcore/azerothcore-wotlk.git --branch=master .


# ==============================================================================
# 3. Install dependencies
# ==============================================================================
# Adjust the distro if needed, for example to "ubuntu".
sed -i 's/^#\s*OSDISTRO=.*/OSDISTRO="debian"/' /opt/ac-authserver/conf/dist/config.sh

./acore.sh install-deps


# ==============================================================================
# 4. Create and enter the build directory
# ==============================================================================
# It is strongly recommended to build in a separate "build" directory.
mkdir -p build
cd build


# ==============================================================================
# 5. Run CMake configure
# ==============================================================================
# This configures the build for the authserver only.
cmake ../ \
  -DCMAKE_INSTALL_PREFIX=/opt/ac-authserver/env/dist \
  -DAPPS_BUILD=auth-only \
  -DTOOLS_BUILD=none \
  -DSCRIPTS=none

# Adjust Proxmox resources afterwards if needed.

# ==============================================================================
# 6. Build and install
# ==============================================================================
# Scale up the ressources for this step only for faster finish
# Use "-j $(nproc)" to use all available CPU cores.
make -j "$(nproc)"
make install

# Adjust Proxmox resources afterwards if needed.

# ==============================================================================
# 7. Folder structure and config files
# ==============================================================================
# use the orignal ressources
cp /opt/ac-authserver/env/dist/etc/authserver.conf.dist /opt/ac-authserver/env/dist/etc/authserver.conf


# ==============================================================================
# 8. MySQL 8.4 configuration
# ==============================================================================

### ------------------------------ insert text ------------------------------ ###
sudo tee /etc/mysql/mysql.conf.d/azcore_limits.cnf > /dev/null << 'EOF'
[mysqld]
bind-address            = 0.0.0.0
mysqlx-bind-address     = 0.0.0.0
disable_log_bin
mysql_native_password   = ON
EOF
### -------------------------------- end text ------------------------------- ###

sudo systemctl restart mysql


# ==============================================================================
# 9. Hardware-specific MySQL tuning
# ==============================================================================
# Apply the InnoDB/connection tuning matched to this LXC's cores/RAM.
# Template: "2 - Authserver/Auth Settings/mysqld Authserver.cnf"
#
# If Worldserver gets installed on this SAME LXC later (Bothserver, or
# added manually afterward): its own MySQL tuning step appends to this same
# mysqld.cnf with overlapping keys and would silently override this block
# (MySQL keeps only the last occurrence of a duplicated key). See
# "Guide Worldserver.md" step 10 for the combined-tuning approach.

# sudo nano /etc/mysql/mysql.conf.d/mysqld.cnf

sudo systemctl restart mysql


# ==============================================================================
# 10. Create databases and MySQL user
# ==============================================================================

# Database password.
DB_PASS="CHANGE_THIS_PASSWORD"

### ------------------------------ insert text ------------------------------ ###
sudo mysql -u root << EOF
CREATE USER IF NOT EXISTS 'acore'@'localhost' IDENTIFIED WITH mysql_native_password BY '$DB_PASS';
CREATE USER IF NOT EXISTS 'acore'@'%' IDENTIFIED WITH mysql_native_password BY '$DB_PASS';

GRANT ALL PRIVILEGES ON *.* TO 'acore'@'localhost' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'acore'@'%' WITH GRANT OPTION;

FLUSH PRIVILEGES;
EOF
### -------------------------------- end text ------------------------------- ###


# ==============================================================================
# 11. Install management scripts
# ==============================================================================

# Not part of this repo - same pattern as "5 - Modules/" for AzerothCore
# modules. Follow that repo's "Guide Install.md" (auth section):
# https://gitlab.com/grassnotfound/acore-inncontrol
#
# Note: that guide's step 2 has you set the same DB_PASS from step 10 above
# into values_auth.conf's LoginDatabaseInfo - it does not reuse it automatically.

# ==============================================================================
# 12. Final start
# ==============================================================================
# The "authmenu" alias was just added to ~/.bashrc by step 11's InnControl
# install - it's not active in this shell yet. Source it (or re-login):

source ~/.bashrc

authmenu

# Recommended menu flow:
# 8        Pull Git updates      
# 8        Build authserver      
# 8        Clean build directory 
# 15       Edit values_auth.conf
# 16       Apply auth config patch and restart
# 5        Accept build database (acore_auth), going out with CTRL+B then D
# 9        Apply Two-Side RBAC permissions

# ----------------- Snapshot ----------------- #

# 7        Enable authserver autostart
# 17       Manage realmlist & MOTD
# 18       Open account manager
# 9        Increment change for Bots 

# FINISHED
# FINISHED
# FINISHED