#!/bin/bash

# =========================================================
#  PAQET TUNNEL
# =========================================================

# --- CONFIGURATION ---
PAQET_VERSION="v1.0.0-alpha.15"
PAQET_URL="https://github.com/hanselime/paqet/releases/download/${PAQET_VERSION}/paqet-linux-amd64-${PAQET_VERSION}.tar.gz"
XUI_URL="https://github.com/MHSanaei/3x-ui/releases/download/v2.8.7/x-ui-linux-amd64.tar.gz"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- HELPER FUNCTIONS ---
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

check_root() { if [ "$EUID" -ne 0 ]; then print_error "Please run as root"; fi; }

# --- DOWNLOADER ---
get_file() {
    local name=$1; local url=$2; local dest=$3
    mkdir -p "$(dirname "$dest")"
    echo ""
    echo -e "${YELLOW}>>> Source for $name?${NC}"
    echo "   1) Download from Internet (Default)"
    echo "   2) Use Local File"
    read -p "   Select [1-2] (Enter=1): " choice
    choice=${choice:-1}

    if [ "$choice" == "2" ]; then
        while true; do
            read -p "   Enter full path to file: " localpath
            if [ -f "$localpath" ]; then
                cp "$localpath" "$dest"
                if [ -s "$dest" ]; then
                    print_success "Loaded $name from local file."
                    return 0
                fi
            else
                print_warn "File not found. Try again."
            fi
        done
    else
        print_info "Downloading $name..."
        rm -f "$dest"
        if curl -L --progress-bar --retry 3 --connect-timeout 20 -o "$dest" "$url"; then
            if [ -s "$dest" ] && [ $(stat -c%s "$dest") -gt 1000 ]; then
                print_success "Download complete."
                return 0
            else
                print_error "Download corrupted. Try Option 2."
            fi
        else
            print_error "Download Failed! Check internet or use Option 2."
        fi
    fi
}

# --- DEPENDENCIES ---
install_dependencies() {
    print_info "Installing Dependencies..."
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do sleep 1; done
    PKGS="libpcap-dev iptables-persistent netfilter-persistent curl wget tar openssl net-tools unzip sqlite3 jq bc"
    if ! apt-get install -y $PKGS; then
        print_warn "Apt failed. Switching to Iran mirrors..."
        if grep -q "ubuntu" /etc/os-release; then
             [ ! -f /etc/apt/sources.list.bak ] && cp /etc/apt/sources.list /etc/apt/sources.list.bak
             cat <<EOF > /etc/apt/sources.list
deb http://mirror.aminidc.com/ubuntu/ $(lsb_release -sc) main restricted universe multiverse
deb http://mirror.aminidc.com/ubuntu/ $(lsb_release -sc)-updates main restricted universe multiverse
deb http://mirror.aminidc.com/ubuntu/ $(lsb_release -sc)-backports main restricted universe multiverse
deb http://mirror.aminidc.com/ubuntu/ $(lsb_release -sc)-security main restricted universe multiverse
deb http://mirror.iranserver.com/ubuntu/ $(lsb_release -sc) main restricted universe multiverse
deb http://mirror.iranserver.com/ubuntu/ $(lsb_release -sc)-updates main restricted universe multiverse
EOF
             apt-get update -qq
        fi
        apt-get --fix-broken install -y
        apt-get install -y $PKGS
    fi
}

detect_ip() {
    PUBLIC_IP=$(curl -s --max-time 3 http://api.ipify.org)
    if [[ ! "$PUBLIC_IP" =~ ^[0-9]+\. ]]; then
        DEF_IFACE=$(ip route get 8.8.8.8 | grep -oP 'dev \K\S+')
        PUBLIC_IP=$(ip -4 addr show $DEF_IFACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)
    fi
    [ -z "$PUBLIC_IP" ] && read -p ">>> Enter Public IP Manually: " PUBLIC_IP
    IFACE=$(ip route get 8.8.8.8 | grep -oP 'dev \K\S+')
    GW_IP=$(ip route get 8.8.8.8 | awk '{print $3}')
    GW_MAC=$(ip neigh show $GW_IP | awk '{print $5}' | head -n1)
    [ -z "$GW_MAC" ] && ping -c 1 $GW_IP >/dev/null && GW_MAC=$(ip neigh show $GW_IP | awk '{print $5}' | head -n1)
    print_success "IP: $PUBLIC_IP | IF: $IFACE"
}

setup_firewall_bypass() {
    local port=$1
    iptables -t raw -D PREROUTING -p tcp --dport $port -j NOTRACK 2>/dev/null
    iptables -t raw -A PREROUTING -p tcp --dport $port -j NOTRACK
    iptables -t raw -D OUTPUT -p tcp --sport $port -j NOTRACK 2>/dev/null
    iptables -t raw -A OUTPUT -p tcp --sport $port -j NOTRACK
    netfilter-persistent save >/dev/null 2>&1
}

# =========================================================
#  PAQET SETUP (TUNED: CONN 32 + 2MB BUFFER)
# =========================================================
setup_paqet() {
    print_info "Setting up Paqet ($PAQET_PORT)..."
    cd /root
    if [ ! -f "paqet" ]; then
        get_file "Paqet Binary" "$PAQET_URL" "paqet.tar.gz"
        tar -xzf paqet.tar.gz
        [ -f "paqet_linux_amd64" ] && mv paqet_linux_amd64 paqet
        [ -f "paqet-linux-amd64" ] && mv paqet-linux-amd64 paqet
        chmod +x paqet
    fi
    setup_firewall_bypass "$PAQET_PORT"

    if [ "$ROLE" == "server" ]; then
        cat <<EOF > /root/paqet_server.yaml
role: "server"
log:
  level: "info"
listen:
  addr: ":$PAQET_PORT"
network:
  interface: "$IFACE"
  ipv4:
    addr: "$PUBLIC_IP:$PAQET_PORT"
    router_mac: "$GW_MAC"
  tcp:
    local_flag: ["PA"]
    remote_flag: ["PA"]
transport:
  protocol: "kcp"
  conn: 32
  kcp:
    mode: "fast"
    key: "$KEY"
EOF
        CMD="/root/paqet run -c /root/paqet_server.yaml"
    else
        cat <<EOF > /root/paqet_client.yaml
role: "client"
log:
  level: "info"
socks5:
  - listen: "127.0.0.1:1080"
network:
  interface: "$IFACE"
  ipv4:
    addr: "$PUBLIC_IP:0"
    router_mac: "$GW_MAC"
  tcp:
    local_flag: ["PA"]
    remote_flag: ["PA"]
  pcap:
    sockbuf: 2097152
server:
  addr: "$REMOTE_IP:$PAQET_PORT"
transport:
  protocol: "kcp"
  conn: 32
  kcp:
    mode: "fast"
    key: "$KEY"
EOF
        CMD="/root/paqet run -c /root/paqet_client.yaml"
    fi

    cat <<EOF > /etc/systemd/system/paqet.service
[Unit]
Description=Paqet Service
After=network.target
[Service]
ExecStart=$CMD
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable paqet; systemctl restart paqet
    if [ "$ROLE" == "client" ]; then
        print_info "Waiting for Paqet to initialize..."
        sleep 3
    fi
}

verify_paqet_client() {
    print_info "Verifying Connection..."
    sleep 5
    TUNNEL_IP=$(curl -s --max-time 10 --socks5-hostname 127.0.0.1:1080 http://api.ipify.org)
    if [ -z "$TUNNEL_IP" ]; then
        print_error "Verification Failed! Tunnel is not passing traffic."
    elif [ "$TUNNEL_IP" == "$PUBLIC_IP" ]; then
        print_warn "Connected, but IP matches local ($TUNNEL_IP). Routing issue."
    else
        print_success "TUNNEL CONFIRMED! Traffic exiting via: $TUNNEL_IP"
    fi
}

# =========================================================
#  WATCHDOG SETUP (AUTO-REPAIR)
# =========================================================
setup_watchdog() {
    print_info "Setting up Connection Watchdog..."
    
    # Create Watchdog Script
    cat <<EOF > /usr/local/bin/paqet_watchdog.sh
#!/bin/bash
# Checks Paqet connection. If failed, restarts service.

LOGFILE="/var/log/paqet_watchdog.log"
TARGET="http://api.ipify.org"
PROXY="socks5h://127.0.0.1:1080"

# Check connection with timeout
HTTP_CODE=\$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 --proxy "\$PROXY" "\$TARGET")

if [ "\$HTTP_CODE" != "200" ]; then
    echo "\$(date): Connection Failed (Code: \$HTTP_CODE). Restarting Paqet..." >> \$LOGFILE
    systemctl restart paqet
else
    # Uncomment next line for verbose success logging
    # echo "\$(date): Connection OK." >> \$LOGFILE
    :
fi
EOF
    chmod +x /usr/local/bin/paqet_watchdog.sh

    # Create Systemd Timer (Runs every 30 minutes)
    cat <<EOF > /etc/systemd/system/paqet-watchdog.service
[Unit]
Description=Paqet Connection Watchdog

[Service]
Type=oneshot
ExecStart=/usr/local/bin/paqet_watchdog.sh
EOF

    cat <<EOF > /etc/systemd/system/paqet-watchdog.timer
[Unit]
Description=Run Paqet Watchdog every 30 minutes

[Timer]
OnBootSec=30min
OnUnitActiveSec=30min

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable paqet-watchdog.timer
    systemctl start paqet-watchdog.timer
    print_success "Watchdog Active (Checks every 30 mins)."
}

# =========================================================
#  IRAN-ONLY: X-UI SETUP
# =========================================================
setup_iran_xui() {
    echo ""; echo -e "${CYAN}--- X-UI INSTALLATION ---${NC}"
    echo "1) Install/Update 3X-UI Panel"
    echo "2) Skip (I have it installed or will install later)"
    read -p "Select [1-2]: " XCHOICE
    XCHOICE=${XCHOICE:-2}

    if [ "$XCHOICE" == "1" ]; then
        print_info "Installing X-UI..."
        cd /root
        get_file "X-UI Panel" "$XUI_URL" "x-ui.tar.gz"
        systemctl stop x-ui >/dev/null 2>&1
        rm -rf /usr/local/x-ui
        tar zxf x-ui.tar.gz
        mv x-ui /usr/local/
        chmod +x /usr/local/x-ui/x-ui
        chmod +x /usr/local/x-ui/x-ui.sh
        rm -f /usr/bin/x-ui
        ln -s /usr/local/x-ui/x-ui.sh /usr/bin/x-ui
        cat <<EOF > /etc/systemd/system/x-ui.service
[Unit]
Description=X-UI Service
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/x-ui
ExecStart=/usr/local/x-ui/x-ui
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable x-ui
        systemctl start x-ui
        print_info "Initializing..."
        sleep 5
        print_success "X-UI Installed Successfully."
    else
        print_info "Skipping X-UI installation."
    fi

    echo ""; echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}      IRAN SETUP COMPLETE               ${NC}"
    echo -e "${GREEN}========================================${NC}"
    verify_paqet_client
    echo "----------------------------------------"
    echo -e "1. Paqet Tunnel: Connected to Kharej"
    echo -e "2. X-UI Panel:   http://$PUBLIC_IP:2053"
    echo -e "   Login:        admin / admin"
    echo -e "   Command:      Type ${YELLOW}x-ui${NC} to manage"
    echo ""
    echo -e "${YELLOW}IMPORTANT FINAL STEP:${NC}"
    echo "1. Log into X-UI Panel."
    echo "2. Go to [Panel Settings] -> [Xray Configuration]."
    echo "3. Add outbound (Third Block) to point to Paqet:"
    echo "   - Protocol: socks"
    echo "   - Address:  127.0.0.1"
    echo "   - Port:     1080"
    echo "4. Click Save & Restart Xray."
    echo "5. Create your Inbounds (VMess/VLESS) normally."
    echo -e "${GREEN}========================================${NC}"
}

# =========================================================
#  MAIN EXECUTION
# =========================================================
check_root
clear
echo -e "${CYAN}==========================================================${NC}"
echo -e "${CYAN}   PAQET TUNNEL                                           ${NC}"
echo -e "${CYAN}==========================================================${NC}"
echo "1) Kharej Server (Tunnel Exit)"
echo "2) Iran Server   (Tunnel Entry + Bridge)"
read -p "Select Role [1-2]: " ROLE_NUM

if [ "$ROLE_NUM" == "1" ]; then ROLE="server"; else ROLE="client"; fi

install_dependencies
detect_ip

echo ""; echo -e "${CYAN}--- CONFIGURATION ---${NC}"
read -p "Paqet Port (Press Enter for 8880): " PAQET_PORT; PAQET_PORT=${PAQET_PORT:-8880}

if [ "$ROLE" == "server" ]; then
    KEY=$(openssl rand -hex 16)
else
    echo ""; echo -e "${CYAN}--- KHAREJ DETAILS ---${NC}"
    read -p "Kharej Server IP: " REMOTE_IP
    read -p "Secret Key (from Kharej): " KEY
fi

setup_paqet

if [ "$ROLE" == "server" ]; then
    echo ""; echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}      KHAREJ SETUP COMPLETE             ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "Use these details on Iran Server:"
    echo -e "IP:            ${YELLOW}$PUBLIC_IP${NC}"
    echo -e "Paqet Port:    ${YELLOW}$PAQET_PORT${NC}"
    echo -e "Secret Key:    ${YELLOW}$KEY${NC}"
    echo -e "${GREEN}========================================${NC}"
else
    setup_watchdog
    setup_iran_xui
fi
