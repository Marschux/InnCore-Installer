sudo tee /usr/local/bin/dynamic-motd.sh > /dev/null << 'EOF'
#!/bin/bash

# Empty line at the top
echo ""

# Define colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
YELLOW='\033[0;33m'
PURPLE='\033[0;35m'

GOLD='\033[1;33m'
WHITE='\033[0;37m'
GRAY='\033[1;30m'
NC='\033[0m' # No color / reset

# Collect system data
USER=$(whoami)
HOSTNAME=$(hostname | tr '[:lower:]' '[:upper:]')
OS=$(grep '^PRETTY_NAME=' /etc/os-release | cut -d'"' -f2)
UPTIME=$(uptime -p | sed 's/up //')
LOAD=$(cut -d" " -f1-3 /proc/loadavg)

# Collect memory data
MEM_USED=$(free -h | awk '/^Mem:/ {print $3}')
MEM_TOTAL=$(free -h | awk '/^Mem:/ {print $2}')

# Collect swap data
SWAP_USED=$(free -h | awk '/^Swap:/ {print $3}')
SWAP_TOTAL=$(free -h | awk '/^Swap:/ {print $2}')

# Show "None" if no swap is assigned
if [ "$SWAP_TOTAL" = "0B" ] || [ -z "$SWAP_TOTAL" ]; then
    SWAP_DISPLAY="None"
else
    SWAP_DISPLAY="${SWAP_USED} / ${SWAP_TOTAL}"
fi

# Collect disk and network data
DISK_USED=$(df -h / | awk 'NR==2 {print $3}')
DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')
IP_ADDR=$(hostname -I | awk '{print $1}')

# Set display colors
HEADER=$MAGENTA
INFO=$GREEN

echo -e ""
echo -e "       🔑  ${HEADER}AZEROTHCORE Realm Backup-Server${NC}"
echo -e "${HEADER}─────────────────────────────────────────────────────────${NC}"
echo -e ""
echo -e "${INFO}    👤  User:       ${NC}${USER}"
echo -e "${INFO}    🖥️  OS:         ${NC}${OS}"
echo -e "${INFO}    🌐  IP:         ${NC}${IP_ADDR}"
echo -e "${INFO}    🕒  Uptime:     ${NC}${UPTIME}"
echo -e "${INFO}    📊  Load:       ${NC}${LOAD}"
echo -e "${INFO}    🧠  Memory:     ${NC}${MEM_USED} / ${MEM_TOTAL}"
echo -e "${INFO}    🔄  Swap:       ${NC}${SWAP_DISPLAY}"
echo -e "${INFO}    💾  Disk:       ${NC}${DISK_USED} / ${DISK_TOTAL}"
echo -e ""
echo ""
EOF
