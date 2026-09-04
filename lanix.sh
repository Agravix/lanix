#!/usr/bin/env bash

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

WG_DIR="/etc/wireguard"
WG_IFACE="wg0"
SERVER_CONF="${WG_DIR}/${WG_IFACE}.conf"
CLIENTS_DIR="${WG_DIR}/clients"
ENV_FILE="${WG_DIR}/lanix.env"
COUNTER_FILE="${WG_DIR}/.lanix_next_ip"
INSTALL_PATH="/usr/local/bin/lanix"

DEFAULT_PORT="51820"
DEFAULT_SUBNET="10.10.10"

need_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}This tool must be run as root.${NC}"
        echo -e "Run it with: ${YELLOW}sudo lanix${NC} (or sudo bash $0)"
        exit 1
    fi
}

press_enter() {
    echo
    read -rp "$(echo -e "${DIM}Press Enter to return to the menu...${NC}")" _
}

banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    cat <<'EOF'
██╗      █████╗ ███╗   ██╗██╗██╗  ██╗
██║     ██╔══██╗████╗  ██║██║╚██╗██╔╝
██║     ███████║██╔██╗ ██║██║ ╚███╔╝
██║     ██╔══██║██║╚██╗██║██║ ██╔██╗
███████╗██║  ██║██║ ╚████║██║██╔╝ ██╗
╚══════╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝╚═╝  ╚═╝
EOF
    echo -e "${NC}${MAGENTA}${BOLD}       WireGuard VPN Network Manager${NC}"
    echo -e "${DIM}                Made by Agravix${NC}"
    echo -e "${BLUE}------------------------------------------------------------${NC}"
}

load_env() {
    if [[ -f "$ENV_FILE" ]]; then
        source "$ENV_FILE"
    else
        WG_PORT="$DEFAULT_PORT"
        WG_SUBNET="$DEFAULT_SUBNET"
    fi
}

save_env() {
    cat > "$ENV_FILE" <<EOF
WG_PORT="${WG_PORT}"
WG_SUBNET="${WG_SUBNET}"
EOF
}

is_installed() {
    [[ -f "$SERVER_CONF" ]]
}

detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v yum >/dev/null 2>&1; then
        echo "yum"
    else
        echo "unknown"
    fi
}

install_dependencies() {
    echo -e "${YELLOW}Installing dependencies (wireguard, qrencode, curl, iptables)...${NC}"
    local pm
    pm="$(detect_pkg_manager)"
    case "$pm" in
        apt)
            apt-get update -y
            apt-get install -y wireguard wireguard-tools qrencode curl iptables
            ;;
        dnf)
            dnf install -y epel-release 2>/dev/null
            dnf install -y wireguard-tools qrencode curl iptables
            ;;
        yum)
            yum install -y epel-release 2>/dev/null
            yum install -y wireguard-tools qrencode curl iptables
            ;;
        *)
            echo -e "${RED}Unsupported distro. Install wireguard-tools and qrencode manually.${NC}"
            exit 1
            ;;
    esac
    echo -e "${GREEN}Dependencies installed.${NC}"
}

get_public_ip() {
    local ip
    ip="$(curl -s -4 --max-time 5 ifconfig.me || curl -s -4 --max-time 5 icanhazip.com)"
    ip="$(echo "$ip" | tr -d '[:space:]')"
    if [[ -z "$ip" ]]; then
        read -rp "Could not auto-detect the server's public IP. Enter it manually: " ip
    fi
    echo "$ip"
}

self_install() {
    local src
    src="$(readlink -f "$0")"
    if [[ "$src" != "$INSTALL_PATH" ]]; then
        cp "$src" "$INSTALL_PATH"
        chmod +x "$INSTALL_PATH"
        echo -e "${GREEN}Lanix installed as a system command.${NC}"
        echo -e "From now on just run: ${BOLD}sudo lanix${NC}"
    fi
}

self_uninstall_binary() {
    [[ -f "$INSTALL_PATH" ]] && rm -f "$INSTALL_PATH"
}

next_ip_octet() {
    local n
    if [[ -f "$COUNTER_FILE" ]]; then
        n="$(cat "$COUNTER_FILE")"
    else
        n=2
    fi
    echo "$n" > "$COUNTER_FILE"
    echo "$n"
}

bump_counter() {
    echo "$(( $1 + 1 ))" > "$COUNTER_FILE"
}

setup_server() {
    if is_installed; then
        echo -e "${YELLOW}A WireGuard server is already configured here.${NC}"
        read -rp "Reset and reconfigure from scratch? [y/N]: " ans
        if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
            return
        fi
        systemctl stop "wg-quick@${WG_IFACE}" 2>/dev/null
        rm -rf "$WG_DIR"
    fi

    install_dependencies
    mkdir -p "$WG_DIR" "$CLIENTS_DIR"
    chmod 700 "$WG_DIR"

    echo
    read -rp "UDP port for WireGuard [default: ${DEFAULT_PORT}]: " port_in
    WG_PORT="${port_in:-$DEFAULT_PORT}"

    read -rp "Internal subnet [default: ${DEFAULT_SUBNET} -> ${DEFAULT_SUBNET}.0/24]: " subnet_in
    WG_SUBNET="${subnet_in:-$DEFAULT_SUBNET}"
    save_env

    echo
    SERVER_PUBLIC_IP="$(get_public_ip)"
    echo -e "${GREEN}Server public IP: ${SERVER_PUBLIC_IP}${NC}"
    echo "$SERVER_PUBLIC_IP" > "${WG_DIR}/.server_public_ip"

    umask 077
    wg genkey | tee "${WG_DIR}/server_private.key" | wg pubkey > "${WG_DIR}/server_public.key"
    SERVER_PRIV="$(cat "${WG_DIR}/server_private.key")"

    cat > "$SERVER_CONF" <<EOF
[Interface]
Address = ${WG_SUBNET}.1/24
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT
SaveConfig = false

EOF
    chmod 600 "$SERVER_CONF"

    sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1

    systemctl enable "wg-quick@${WG_IFACE}" >/dev/null 2>&1
    systemctl start "wg-quick@${WG_IFACE}"

    echo -e "${GREEN}WireGuard server is up and running.${NC}"
    echo -e "${YELLOW}Note: if your VPS has a cloud firewall (Security Group / Cloud Firewall),${NC}"
    echo -e "${YELLOW}make sure UDP port ${WG_PORT} is open there too.${NC}"

    echo
    read -rp "How many users do you want to add now? (enter a number, or 0 to skip): " count
    if [[ "$count" =~ ^[0-9]+$ ]] && [[ "$count" -gt 0 ]]; then
        for ((i=1; i<=count; i++)); do
            read -rp "Name for user #${i}: " uname
            while [[ -z "$uname" ]]; do
                read -rp "Name cannot be empty. Name for user #${i}: " uname
            done
            add_client "$uname"
        done
    fi
}

add_client() {
    local name="$1"
    load_env

    if [[ -z "$name" ]]; then
        echo -e "${RED}A name is required.${NC}"
        return 1
    fi

    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo -e "${RED}Invalid name. Use only letters, numbers, dashes and underscores.${NC}"
        return 1
    fi

    if [[ -d "${CLIENTS_DIR}/${name}" ]]; then
        echo -e "${RED}A user named '${name}' already exists.${NC}"
        return 1
    fi

    if ! is_installed; then
        echo -e "${RED}Server is not set up yet. Run 'lanix install' first.${NC}"
        return 1
    fi

    mkdir -p "${CLIENTS_DIR}/${name}"
    umask 077
    wg genkey | tee "${CLIENTS_DIR}/${name}/private.key" | wg pubkey > "${CLIENTS_DIR}/${name}/public.key"

    local client_priv client_pub octet client_ip server_pub server_ip server_port
    client_priv="$(cat "${CLIENTS_DIR}/${name}/private.key")"
    client_pub="$(cat "${CLIENTS_DIR}/${name}/public.key")"
    octet="$(next_ip_octet)"
    client_ip="${WG_SUBNET}.${octet}"
    bump_counter "$octet"

    server_pub="$(cat "${WG_DIR}/server_public.key")"
    server_ip="$(cat "${WG_DIR}/.server_public_ip")"
    server_port="$WG_PORT"

    echo "$client_ip" > "${CLIENTS_DIR}/${name}/ip.txt"

    cat > "${CLIENTS_DIR}/${name}/${name}.conf" <<EOF
[Interface]
PrivateKey = ${client_priv}
Address = ${client_ip}/32
DNS = 1.1.1.1

[Peer]
PublicKey = ${server_pub}
Endpoint = ${server_ip}:${server_port}
AllowedIPs = ${WG_SUBNET}.0/24
PersistentKeepalive = 25
EOF
    chmod 600 "${CLIENTS_DIR}/${name}/${name}.conf"

    {
        echo "[Peer]"
        echo "PublicKey = ${client_pub}"
        echo "AllowedIPs = ${client_ip}/32"
        echo
    } >> "$SERVER_CONF"

    wg syncconf "$WG_IFACE" <(wg-quick strip "$WG_IFACE") 2>/dev/null

    echo -e "${GREEN}User '${name}' created with internal IP ${client_ip}.${NC}"
}

remove_client() {
    local name="$1"
    if [[ -z "$name" ]]; then
        echo -e "${RED}A name is required.${NC}"
        return 1
    fi
    if [[ ! -d "${CLIENTS_DIR}/${name}" ]]; then
        echo -e "${RED}No user named '${name}' was found.${NC}"
        return 1
    fi

    local pub
    pub="$(cat "${CLIENTS_DIR}/${name}/public.key" 2>/dev/null)"

    if [[ -n "$pub" ]]; then
        awk -v key="$pub" '
            BEGIN{hold=0; buffer=""; skip=0}
            /^\[Peer\]/{ if(hold==1 && skip==0) printf "%s", buffer; hold=1; buffer=$0"\n"; skip=0; next }
            hold==1 {
                buffer = buffer $0 "\n"
                if ($0 ~ key) { skip=1 }
                if ($0 == "") { if(skip==0) printf "%s", buffer; hold=0; buffer=""; skip=0 }
                next
            }
            { print }
            END { if (hold==1 && skip==0) printf "%s", buffer }
        ' "$SERVER_CONF" > "${SERVER_CONF}.tmp" && mv "${SERVER_CONF}.tmp" "$SERVER_CONF"
    fi

    rm -rf "${CLIENTS_DIR}/${name}"
    wg syncconf "$WG_IFACE" <(wg-quick strip "$WG_IFACE") 2>/dev/null

    echo -e "${GREEN}User '${name}' removed.${NC}"
}

list_clients() {
    if [[ ! -d "$CLIENTS_DIR" ]] || [[ -z "$(ls -A "$CLIENTS_DIR" 2>/dev/null)" ]]; then
        echo -e "${YELLOW}No users yet.${NC}"
        return
    fi
    printf "%-20s %-20s\n" "NAME" "INTERNAL IP"
    for d in "$CLIENTS_DIR"/*/; do
        name="$(basename "$d")"
        ip="$(cat "${d}ip.txt" 2>/dev/null)"
        printf "%-20s %-20s\n" "$name" "$ip"
    done
}

show_client() {
    local name="$1"
    local conf="${CLIENTS_DIR}/${name}/${name}.conf"
    if [[ -z "$name" ]] || [[ ! -f "$conf" ]]; then
        echo -e "${RED}No such user.${NC}"
        return 1
    fi
    echo -e "${BOLD}Config file (${name}.conf):${NC}"
    echo -e "${CYAN}------------------------------------------------------------${NC}"
    cat "$conf"
    echo -e "${CYAN}------------------------------------------------------------${NC}"
    if command -v qrencode >/dev/null 2>&1; then
        echo
        echo -e "${BOLD}QR Code (scan with the WireGuard app on Android/iOS):${NC}"
        qrencode -t ansiutf8 < "$conf"
    fi
    echo
    echo -e "${DIM}File path on server: ${conf}${NC}"
}

show_status() {
    if ! is_installed; then
        echo -e "${RED}Server is not set up yet.${NC}"
        return
    fi
    echo -e "${BOLD}Service status:${NC}"
    systemctl status "wg-quick@${WG_IFACE}" --no-pager -l | head -n 6
    echo
    echo -e "${BOLD}Live peer status (wg show):${NC}"
    echo -e "${CYAN}------------------------------------------------------------${NC}"
    wg show "$WG_IFACE"
}

client_guide() {
    load_env
    local server_ip="-"
    [[ -f "${WG_DIR}/.server_public_ip" ]] && server_ip="$(cat "${WG_DIR}/.server_public_ip")"

    echo -e "${BOLD}${MAGENTA}Client connection guide${NC}"
    echo -e "${DIM}(Server IP: ${server_ip} | Port: ${WG_PORT:-$DEFAULT_PORT} | Subnet: ${WG_SUBNET:-$DEFAULT_SUBNET}.0/24)${NC}"
    echo -e "${BLUE}============================================================${NC}"

    echo -e "${GREEN}${BOLD}1) Linux:${NC}"
    cat <<'EOF'
   sudo apt install wireguard -y
   sudo cp userX.conf /etc/wireguard/wg0.conf
   sudo wg-quick up wg0
   sudo systemctl enable wg-quick@wg0
EOF

    echo -e "${GREEN}${BOLD}2) Windows:${NC}"
    cat <<'EOF'
   1. Download and install the official WireGuard app from wireguard.com/install
   2. Click "Import tunnel(s) from file" and select userX.conf
   3. Click "Activate" to connect
EOF

    echo -e "${GREEN}${BOLD}3) Android / iOS:${NC}"
    cat <<'EOF'
   1. Install the WireGuard app from the Play Store / App Store
   2. Tap "+" then "Scan from QR code"
   3. Scan the QR code for that user (see "Show a user" in the menu)
   4. Turn the tunnel on
EOF

    echo -e "${YELLOW}${BOLD}Important notes:${NC}"
    cat <<EOF
   - Each connected user gets an internal IP like ${WG_SUBNET:-$DEFAULT_SUBNET}.2, .3, etc.
     (see "List users" in the menu).
   - Connect to other peers directly by their internal IP
     (e.g. ${WG_SUBNET:-$DEFAULT_SUBNET}.2), since broadcast/discovery
     packets usually don't cross the VPN tunnel.
   - Make sure UDP port ${WG_PORT:-$DEFAULT_PORT} is open in your VPS
     provider's cloud firewall/security group, not just the OS firewall.
   - If an application is blocked by the local firewall, allow traffic on
     the WireGuard interface (wg0) too.
EOF
}

full_uninstall() {
    echo -e "${RED}${BOLD}Warning: this will remove the entire network, all users, and Lanix itself.${NC}"
    read -rp "Type YES to confirm: " confirm
    if [[ "$confirm" != "YES" ]]; then
        echo -e "${YELLOW}Cancelled.${NC}"
        return
    fi

    systemctl stop "wg-quick@${WG_IFACE}" 2>/dev/null
    systemctl disable "wg-quick@${WG_IFACE}" 2>/dev/null
    rm -rf "$WG_DIR"

    read -rp "Also remove the wireguard/qrencode packages? [y/N]: " rmpkg
    if [[ "$rmpkg" == "y" || "$rmpkg" == "Y" ]]; then
        local pm
        pm="$(detect_pkg_manager)"
        case "$pm" in
            apt) apt-get remove -y wireguard wireguard-tools qrencode ;;
            dnf) dnf remove -y wireguard-tools qrencode ;;
            yum) yum remove -y wireguard-tools qrencode ;;
        esac
    fi

    self_uninstall_binary
    echo -e "${GREEN}Everything has been removed. Goodbye!${NC}"
}

print_usage() {
    echo -e "${BOLD}Lanix${NC} - WireGuard VPN Network Manager"
    echo -e "${DIM}Made by Agravix${NC}"
    echo
    echo "Usage:"
    echo "  lanix                 open the interactive menu"
    echo "  lanix install         install dependencies and set up the server"
    echo "  lanix install-cmd     install just the 'lanix' command (no server setup)"
    echo "  lanix add <name>      add a new user"
    echo "  lanix remove <name>   remove a user"
    echo "  lanix list            list all users and their internal IPs"
    echo "  lanix show <name>     show a user's config file and QR code"
    echo "  lanix status          show service and peer status"
    echo "  lanix guide           show the client connection guide"
    echo "  lanix uninstall       remove Lanix and WireGuard entirely"
}

is_self_installed() {
    [[ -f "$INSTALL_PATH" ]]
}

menu_install_to_system() {
    banner
    self_install
    press_enter
}

menu_setup_server() {
    banner
    setup_server
    press_enter
}

menu_add() {
    banner
    read -rp "Name for the new user: " name
    add_client "$name"
    press_enter
}

menu_remove() {
    banner
    if [[ -d "$CLIENTS_DIR" ]] && [[ -n "$(ls -A "$CLIENTS_DIR" 2>/dev/null)" ]]; then
        echo -e "${DIM}Existing users: $(ls "$CLIENTS_DIR" | tr '\n' ' ')${NC}"
        echo
    fi
    read -rp "Name of the user to remove: " name
    remove_client "$name"
    press_enter
}

menu_list() {
    banner
    echo -e "${BOLD}Registered users:${NC}"
    echo -e "${BLUE}------------------------------------------------------------${NC}"
    list_clients
    press_enter
}

menu_show() {
    banner
    if [[ -d "$CLIENTS_DIR" ]] && [[ -n "$(ls -A "$CLIENTS_DIR" 2>/dev/null)" ]]; then
        echo -e "${DIM}Existing users: $(ls "$CLIENTS_DIR" | tr '\n' ' ')${NC}"
        echo
    fi
    read -rp "Name of the user to show: " name
    show_client "$name"
    press_enter
}

menu_status() {
    banner
    show_status
    press_enter
}

menu_guide() {
    banner
    client_guide
    press_enter
}

menu_uninstall() {
    banner
    full_uninstall
    press_enter
    exit 0
}

build_menu() {
    MENU_LABELS=()
    MENU_ACTIONS=()

    if ! is_self_installed; then
        MENU_LABELS+=("Install Lanix to system (enables the 'lanix' command)")
        MENU_ACTIONS+=("menu_install_to_system")
    fi

    MENU_LABELS+=("Set up / reset the WireGuard server")
    MENU_ACTIONS+=("menu_setup_server")

    MENU_LABELS+=("Add a new user")
    MENU_ACTIONS+=("menu_add")

    MENU_LABELS+=("List users and their IPs")
    MENU_ACTIONS+=("menu_list")

    MENU_LABELS+=("Show a user's config (file + QR code)")
    MENU_ACTIONS+=("menu_show")

    MENU_LABELS+=("Remove a user")
    MENU_ACTIONS+=("menu_remove")

    MENU_LABELS+=("WireGuard service status")
    MENU_ACTIONS+=("menu_status")

    MENU_LABELS+=("Client connection guide (Linux / Windows / Android / iOS)")
    MENU_ACTIONS+=("menu_guide")

    MENU_LABELS+=("Fully remove Lanix and WireGuard from this server")
    MENU_ACTIONS+=("menu_uninstall")
}

main_menu() {
    while true; do
        banner
        load_env
        build_menu

        if is_self_installed; then
            echo -e " Lanix command: ${GREEN}installed${NC} (run with 'sudo lanix')"
        else
            echo -e " Lanix command: ${YELLOW}not installed yet${NC}"
        fi
        if is_installed; then
            echo -e " WireGuard server: ${GREEN}configured and running${NC}"
        else
            echo -e " WireGuard server: ${RED}not set up${NC}"
        fi
        echo -e "${BLUE}------------------------------------------------------------${NC}"

        local i=1
        for label in "${MENU_LABELS[@]}"; do
            echo -e " ${BOLD}${i})${NC} ${label}"
            ((i++))
        done
        echo -e " ${BOLD}0)${NC} Exit"
        echo -e "${BLUE}------------------------------------------------------------${NC}"

        read -rp "Choose an option: " choice

        if [[ "$choice" == "0" ]]; then
            echo -e "${GREEN}Goodbye!${NC}"
            exit 0
        elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 )) && (( choice <= ${#MENU_ACTIONS[@]} )); then
            "${MENU_ACTIONS[$((choice-1))]}"
        else
            echo -e "${RED}Invalid option.${NC}"
            sleep 1
        fi
    done
}

need_root
load_env

case "$1" in
    install)
        setup_server
        if ! is_self_installed; then
            self_install
        fi
        ;;
    install-cmd)
        if is_self_installed; then
            echo -e "${YELLOW}Lanix is already installed as a system command.${NC}"
        else
            self_install
        fi
        ;;
    add)
        add_client "$2"
        ;;
    remove)
        remove_client "$2"
        ;;
    list)
        list_clients
        ;;
    show)
        show_client "$2"
        ;;
    status)
        show_status
        ;;
    guide)
        client_guide
        ;;
    uninstall)
        full_uninstall
        ;;
    -h|--help)
        print_usage
        ;;
    "")
        main_menu
        ;;
    *)
        echo -e "${RED}Unknown command: $1${NC}"
        print_usage
        exit 1
        ;;
esac
