################################################################################
#                                                                              #
#         CUSTOM MOTD INSTALLATION - DEBIAN 13 (TRIXIE)                        #
#         ---------------------------------------------                        #
#                                                                              #
################################################################################

# 1. Create MOTD script
# ---------------------
### ------------------------------ insert text ------------------------------ ###
sudo tee /usr/local/bin/dynamic-motd.sh > /dev/null << 'EOF'
#!/usr/bin/env bash

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

USER_NAME=$(whoami)
HOST_NAME=$(hostname | tr '[:lower:]' '[:upper:]')
OS_NAME=$(grep '^PRETTY_NAME=' /etc/os-release | cut -d'"' -f2)
UPTIME=$(uptime -p | sed 's/up //')
LOAD=$(cut -d' ' -f1-3 /proc/loadavg)
MEM_USED=$(free -h | awk '/^Mem:/ {print $3}')
MEM_TOTAL=$(free -h | awk '/^Mem:/ {print $2}')
SWAP_USED=$(free -h | awk '/^Swap:/ {print $3}')
SWAP_TOTAL=$(free -h | awk '/^Swap:/ {print $2}')
DISK_USED=$(df -h / | awk 'NR==2 {print $3}')
DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')
IP_ADDR=$(hostname -I | awk '{print $1}')
CORES=$(nproc)

if [ "$SWAP_TOTAL" = "0B" ] || [ -z "$SWAP_TOTAL" ]; then
  SWAP_DISPLAY="None"
else
  SWAP_DISPLAY="${SWAP_USED} / ${SWAP_TOTAL}"
fi

echo
echo -e "  🌐   ${YELLOW}${HOST_NAME}${NC}"
echo -e "${YELLOW}------------------------------------------------------------${NC}"
echo
echo -e "${GREEN}  👤  User:    ${NC}${USER_NAME}"
echo -e "${GREEN}  🐧  OS:      ${NC}${OS_NAME}"
echo -e "${GREEN}  🔢  IP:      ${NC}${IP_ADDR}"
echo -e "${GREEN}  🕒  Uptime:  ${NC}${UPTIME}"
echo -e "${GREEN}  🧠  Cores:   ${NC}${CORES}"
echo -e "${GREEN}  📊  Load:    ${NC}${LOAD}"
echo -e "${GREEN}  💾  Memory:  ${NC}${MEM_USED} / ${MEM_TOTAL}"
echo -e "${GREEN}  🔄  Swap:    ${NC}${SWAP_DISPLAY}"
echo -e "${GREEN}  💽  Disk:    ${NC}${DISK_USED} / ${DISK_TOTAL}"
echo
EOF
### -------------------------------- end text ------------------------------- ###

sudo chmod +x /usr/local/bin/dynamic-motd.sh

# 2. Enable MOTD for login shells
# -------------------------------
### ------------------------------ insert text ------------------------------ ###
sudo tee /etc/profile.d/dynamic-motd.sh > /dev/null << 'EOF'
#!/usr/bin/env bash

if [ -x /usr/local/bin/dynamic-motd.sh ]; then
  /usr/local/bin/dynamic-motd.sh
fi
EOF
### -------------------------------- end text ------------------------------- ###

sudo chmod +x /etc/profile.d/dynamic-motd.sh

# 3. Clear default static MOTD
# ---------------------------
sudo truncate -s 0 /etc/motd

# 4. Verification
# ---------------
/usr/local/bin/dynamic-motd.sh