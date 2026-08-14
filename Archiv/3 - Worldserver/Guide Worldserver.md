################################################################################
#                                                                              #
#                    AZEROTHCORE - WORLDSERVER SETUP                          #
#                                                                              #
################################################################################

# ==============================================================================
# 1. Update system packages
# ==============================================================================
sudo apt update && sudo apt full-upgrade -y


# ==============================================================================
# 2. Clone source code and Playerbots module
# ==============================================================================
sudo mkdir -p /opt/ac-worldserver
sudo chown admin:admin /opt/ac-worldserver

cd /opt/ac-worldserver
git clone https://github.com/mod-playerbots/azerothcore-wotlk.git --branch=Playerbot .

cd /opt/ac-worldserver/modules
git clone https://github.com/mod-playerbots/mod-playerbots.git --branch=master


# ==============================================================================
# 3. Install dependencies
# ==============================================================================
# Adjust the distro if needed, for example to "ubuntu".
sed -i 's/^#\s*OSDISTRO=.*/OSDISTRO="debian"/' /opt/ac-worldserver/conf/dist/config.sh

cd /opt/ac-worldserver
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
# This configures the build for the worldserver including scripts.
cmake ../ \
  -DCMAKE_INSTALL_PREFIX=/opt/ac-worldserver/env/dist \
  -DAPPS_BUILD=world-only \
  -DSCRIPTS=static \
  -DTOOLS_BUILD=none

# Adjust Proxmox resources afterwards if needed.

# ==============================================================================
# 6. Build and install
# ==============================================================================
# Use "-j $(nproc)" to use all available CPU cores.
make -j "$(nproc)"
make install

# Adjust Proxmox resources afterwards if needed.

# ==============================================================================
# 7. Extract client data
# ==============================================================================
# This starts the assistant, which either extracts maps/vmaps/mmaps/DBCs from
# an original 3.3.5a game client already placed on this LXC, or - if you
# don't have one - downloads a pre-extracted data.zip with the same output
# instead. Choose whichever applies when the assistant prompts.
cd /opt/ac-worldserver
./acore.sh client-data


# ==============================================================================
# 8. Folder structure and config files
# ==============================================================================
# Copy default templates (.dist) to active configuration files.
cp /opt/ac-worldserver/env/dist/etc/worldserver.conf.dist /opt/ac-worldserver/env/dist/etc/worldserver.conf

echo -e "\nAllowTwoSide.WhoList = 1" >> /opt/ac-worldserver/env/dist/etc/worldserver.conf

# Copy the Playerbots module config.
cp /opt/ac-worldserver/env/dist/etc/modules/playerbots.conf.dist /opt/ac-worldserver/env/dist/etc/modules/playerbots.conf


# ==============================================================================
# 9. MySQL 8.4 configuration
# ==============================================================================
# Write base MySQL config directly with tee.
### ------------------------------ insert text ------------------------------ ###
sudo tee /etc/mysql/mysql.conf.d/acore_limits.cnf > /dev/null << 'EOF'
[mysqld]
bind-address            = 0.0.0.0
mysqlx-bind-address     = 0.0.0.0
disable_log_bin
mysql_native_password   = ON
EOF
### -------------------------------- end text ------------------------------- ###

sudo systemctl restart mysql


# ==============================================================================
# 10. Hardware-specific MySQL tuning
# ==============================================================================
# Apply the InnoDB/connection tuning matched to this LXC's cores/RAM.
# Template: "3 - Worldserver/Realm Settings/mysqld/<Realm>.cnf"
#
# Auth+World on the SAME LXC (Bothserver, or Worldserver added onto an
# existing Authserver): Authserver's step 9 already appended its own
# InnoDB/connection tuning to this same mysqld.cnf. Both templates set
# overlapping keys (innodb_buffer_pool_size, max_connections,
# table_open_cache, tmp_table_size, ...) - MySQL applies the LAST occurrence
# of a duplicated key, so blindly appending this template on top would
# silently discard the Auth tuning rather than combine with it. Replace the
# existing Auth block with one combined block sized for this LXC's full
# hardware instead of appending a second, competing block.

# sudo nano /etc/mysql/mysql.conf.d/mysqld.cnf

sudo mkdir -p /var/log/mysql
sudo touch /var/log/mysql/slow.log
sudo chown mysql:mysql /var/log/mysql/slow.log

sudo systemctl restart mysql


# ==============================================================================
# 11. Create databases and MySQL user
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
# 12. Install management scripts
# ==============================================================================
# Not part of this repo - same pattern as "5 - Modules/" for AzerothCore
# modules. Follow that repo's "Guide Install.md" (world section):
# https://gitlab.com/grassnotfound/acore-inncontrol
#
# Note: that guide's step 2 has you set the same DB_PASS from step 11 above
# into values_world.conf's LoginDatabaseInfo/WorldDatabaseInfo/CharacterDatabaseInfo
# and values_playerbots.conf's PlayerbotsDatabaseInfo - it does not reuse it automatically.


# ==============================================================================
# 13. Final start
# ==============================================================================
# The "worldmenu" alias was just added to ~/.bashrc by step 12's InnControl
# install - it's not active in this shell yet. Source it (or re-login):

source ~/.bashrc

worldmenu

# Recommended menu flow:
# 12       Pull Git updates          
# 12       Build worldserver         
# 12       Clean build directory     
# 19       Edit values_world.conf
# 20       Patch worldserver.conf, do NOT restart yet
# 23       Edit values_playerbots.conf
# 24       Patch playerbots.conf, do NOT restart yet

# ----------------- Snapshot ----------------- #

# 10       Enable autostart             
# 11       Enable daily restart           
# 1        Start Server
# 9        Open Tmux Session and confirm Database creation, wait for playerbots creation
# 5        Kill Server, when creating characters (stucking)
# 1        Start Server
# 9        Login Tmux and look at buildup bots

# FINISHED
# FINISHED
# FINISHED