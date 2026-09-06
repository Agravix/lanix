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

WEB_APP_DIR="/opt/lanix-web"
WEB_ETC_DIR="/etc/lanix-web"
WEB_SERVICE_FILE="/etc/systemd/system/lanix-web.service"
WEB_DEFAULT_PORT="8088"

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

is_valid_ip() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        for octet in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
            if (( octet > 255 )); then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

is_private_ip() {
    local ip="$1"
    [[ "$ip" =~ ^10\. ]] && return 0
    [[ "$ip" =~ ^127\. ]] && return 0
    [[ "$ip" =~ ^169\.254\. ]] && return 0
    [[ "$ip" =~ ^192\.168\. ]] && return 0
    if [[ "$ip" =~ ^172\.([0-9]{1,3})\. ]]; then
        local second="${BASH_REMATCH[1]}"
        if (( second >= 16 && second <= 31 )); then
            return 0
        fi
    fi
    return 1
}

detect_local_public_ip() {
    local ip=""

    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+')"
    if is_valid_ip "$ip" && ! is_private_ip "$ip"; then
        echo "$ip"
        return 0
    fi

    ip="$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) print $i}' | while read -r candidate; do
        if is_valid_ip "$candidate" && ! is_private_ip "$candidate"; then
            echo "$candidate"
            break
        fi
    done)"
    if is_valid_ip "$ip" && ! is_private_ip "$ip"; then
        echo "$ip"
        return 0
    fi

    return 1
}

get_public_ip() {
    local ip=""

    ip="$(detect_local_public_ip)"
    if is_valid_ip "$ip" && ! is_private_ip "$ip"; then
        echo -e "${DIM}Detected public IP directly from this server's network interface: ${ip}${NC}" >&2
        echo "$ip"
        return 0
    fi

    local sources=(
        "https://api.ipify.org"
        "https://ifconfig.me/ip"
        "https://icanhazip.com"
        "https://ipv4.icanhazip.com"
        "https://checkip.amazonaws.com"
    )

    for src in "${sources[@]}"; do
        ip="$(curl -fsS -4 --max-time 3 "$src" 2>/dev/null | tr -d '[:space:]')"
        if is_valid_ip "$ip"; then
            echo "$ip"
            return 0
        fi
    done

    ip=""
    echo -e "${YELLOW}Could not auto-detect the server's public IP (local interface has no public address and external lookup services are unreachable, likely blocked/filtered on this network).${NC}" >&2
    echo -e "${DIM}You can find your VPS's public IP in your hosting provider's control panel.${NC}" >&2
    while ! is_valid_ip "$ip"; do
        read -rp "Enter the server's public IP manually (e.g. 203.0.113.10): " ip
        if ! is_valid_ip "$ip"; then
            echo -e "${RED}That doesn't look like a valid IPv4 address. Try again.${NC}" >&2
        fi
    done
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

self_update() {
    local src
    src="$(readlink -f "$0")"
    if [[ "$src" == "$INSTALL_PATH" ]]; then
        echo -e "${RED}Run this from the downloaded script file, not from the installed 'lanix' command.${NC}"
        echo -e "${DIM}Example: sudo bash /path/to/new-lanix.sh update${NC}"
        return 1
    fi
    cp "$src" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
    echo -e "${GREEN}The 'lanix' command has been updated to this version.${NC}"
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

get_peer_status() {
    local pubkey="$1"
    local now dump line handshake

    if ! is_installed || ! command -v wg >/dev/null 2>&1; then
        echo -e "${DIM}Unknown${NC}"
        return
    fi

    dump="$(wg show "$WG_IFACE" dump 2>/dev/null)"
    if [[ -z "$dump" ]]; then
        echo -e "${DIM}Unknown${NC}"
        return
    fi

    line="$(echo "$dump" | awk -F'\t' -v key="$pubkey" '$1==key {print}')"
    if [[ -z "$line" ]]; then
        echo -e "${DIM}Unknown${NC}"
        return
    fi

    handshake="$(echo "$line" | awk -F'\t' '{print $5}')"

    if [[ -z "$handshake" ]] || [[ "$handshake" == "0" ]]; then
        echo -e "${YELLOW}Never connected${NC}"
        return
    fi

    now="$(date +%s)"
    if (( now - handshake <= 180 )); then
        echo -e "${GREEN}Online${NC}"
    else
        echo -e "${RED}Offline${NC}"
    fi
}

list_clients() {
    if [[ ! -d "$CLIENTS_DIR" ]] || [[ -z "$(ls -A "$CLIENTS_DIR" 2>/dev/null)" ]]; then
        echo -e "${YELLOW}No users yet.${NC}"
        return
    fi
    printf "%-20s %-20s %-s\n" "NAME" "INTERNAL IP" "STATUS"
    for d in "$CLIENTS_DIR"/*/; do
        name="$(basename "$d")"
        ip="$(cat "${d}ip.txt" 2>/dev/null)"
        pubkey="$(cat "${d}public.key" 2>/dev/null)"
        status="$(get_peer_status "$pubkey")"
        printf "%-20s %-20s %b\n" "$name" "$ip" "$status"
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

fix_public_ip() {
    if ! is_installed; then
        echo -e "${RED}Server is not set up yet.${NC}"
        return 1
    fi

    local old_ip=""
    [[ -f "${WG_DIR}/.server_public_ip" ]] && old_ip="$(cat "${WG_DIR}/.server_public_ip")"
    echo -e "${DIM}Currently stored public IP: ${old_ip:-none}${NC}"

    local new_ip
    new_ip="$(get_public_ip)"

    if ! is_valid_ip "$new_ip"; then
        echo -e "${RED}Detection failed and no valid IP was provided. Aborting.${NC}"
        return 1
    fi

    echo "$new_ip" > "${WG_DIR}/.server_public_ip"
    echo -e "${GREEN}Stored public IP updated to: ${new_ip}${NC}"

    if [[ -d "$CLIENTS_DIR" ]] && [[ -n "$(ls -A "$CLIENTS_DIR" 2>/dev/null)" ]]; then
        local updated=0
        for d in "$CLIENTS_DIR"/*/; do
            local name conf
            name="$(basename "$d")"
            conf="${d}${name}.conf"
            if [[ -f "$conf" ]]; then
                sed -i -E "s/^Endpoint = .*:([0-9]+)$/Endpoint = ${new_ip}:\1/" "$conf"
                updated=$((updated + 1))
            fi
        done
        echo -e "${GREEN}Updated the Endpoint line in ${updated} existing user config(s).${NC}"
        echo -e "${YELLOW}Note: users must re-import/replace their .conf file (or scan the new QR code) to pick up the change.${NC}"
    fi
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

write_web_files() {
    mkdir -p "$WEB_APP_DIR/templates" "$WEB_APP_DIR/static/css" "$WEB_APP_DIR/static/js"

    cat > "$WEB_APP_DIR/core.py" <<'LANIXWEB_CORE_PY'
import os
import re
import time
import socket
import shutil
import tempfile
import subprocess

try:
    import requests
except ImportError:
    requests = None

WG_DIR = "/etc/wireguard"
WG_IFACE = "wg0"
SERVER_CONF = os.path.join(WG_DIR, f"{WG_IFACE}.conf")
CLIENTS_DIR = os.path.join(WG_DIR, "clients")
ENV_FILE = os.path.join(WG_DIR, "lanix.env")
COUNTER_FILE = os.path.join(WG_DIR, ".lanix_next_ip")
SERVER_PUBLIC_IP_FILE = os.path.join(WG_DIR, ".server_public_ip")
SERVER_PRIV_FILE = os.path.join(WG_DIR, "server_private.key")
SERVER_PUB_FILE = os.path.join(WG_DIR, "server_public.key")

DEFAULT_PORT = "51820"
DEFAULT_SUBNET = "10.10.10"

IP_RE = re.compile(r"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$")

EXTERNAL_IP_SOURCES = [
    "https://api.ipify.org",
    "https://ifconfig.me/ip",
    "https://icanhazip.com",
    "https://ipv4.icanhazip.com",
    "https://checkip.amazonaws.com",
]


class LanixError(Exception):
    pass


def run(cmd, input_text=None, check=False):
    result = subprocess.run(
        cmd,
        input=input_text,
        capture_output=True,
        text=True,
        check=False,
    )
    if check and result.returncode != 0:
        raise LanixError(result.stderr.strip() or f"Command failed: {' '.join(cmd)}")
    return result


def is_valid_ip(ip):
    if not ip:
        return False
    m = IP_RE.match(ip.strip())
    if not m:
        return False
    return all(0 <= int(g) <= 255 for g in m.groups())


def is_private_ip(ip):
    if ip.startswith("10.") or ip.startswith("127.") or ip.startswith("169.254.") or ip.startswith("192.168."):
        return True
    m = re.match(r"^172\.(\d{1,3})\.", ip)
    if m and 16 <= int(m.group(1)) <= 31:
        return True
    return False


def detect_local_public_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(1)
        s.connect(("1.1.1.1", 80))
        ip = s.getsockname()[0]
        s.close()
        if is_valid_ip(ip) and not is_private_ip(ip):
            return ip
    except OSError:
        pass
    return None


def detect_external_public_ip():
    if requests is None:
        return None
    for url in EXTERNAL_IP_SOURCES:
        try:
            resp = requests.get(url, timeout=3)
            if resp.status_code == 200:
                ip = resp.text.strip()
                if is_valid_ip(ip):
                    return ip
        except Exception:
            continue
    return None


def detect_public_ip():
    ip = detect_local_public_ip()
    if ip:
        return ip, "interface"
    ip = detect_external_public_ip()
    if ip:
        return ip, "external"
    return None, None


def get_stored_public_ip():
    if os.path.isfile(SERVER_PUBLIC_IP_FILE):
        with open(SERVER_PUBLIC_IP_FILE) as f:
            return f.read().strip()
    return None


def set_stored_public_ip(ip):
    os.makedirs(WG_DIR, exist_ok=True)
    with open(SERVER_PUBLIC_IP_FILE, "w") as f:
        f.write(ip.strip() + "\n")


def is_installed():
    return os.path.isfile(SERVER_CONF)


def detect_pkg_manager():
    for mgr in ("apt-get", "dnf", "yum"):
        if shutil.which(mgr):
            return mgr.replace("-get", "")
    return None


def install_dependencies():
    mgr = detect_pkg_manager()
    if mgr == "apt":
        run(["apt-get", "update", "-y"])
        r = run(["apt-get", "install", "-y", "wireguard", "wireguard-tools", "curl", "iptables"], check=True)
    elif mgr in ("dnf", "yum"):
        run([mgr, "install", "-y", "epel-release"])
        r = run([mgr, "install", "-y", "wireguard-tools", "curl", "iptables"], check=True)
    else:
        raise LanixError("Unsupported distro: install wireguard-tools manually.")
    return r


def load_env():
    env = {"WG_PORT": DEFAULT_PORT, "WG_SUBNET": DEFAULT_SUBNET}
    if os.path.isfile(ENV_FILE):
        with open(ENV_FILE) as f:
            for line in f:
                line = line.strip()
                if "=" in line:
                    k, v = line.split("=", 1)
                    env[k.strip()] = v.strip().strip('"')
    return env


def save_env(env):
    os.makedirs(WG_DIR, exist_ok=True)
    with open(ENV_FILE, "w") as f:
        f.write(f'WG_PORT="{env["WG_PORT"]}"\n')
        f.write(f'WG_SUBNET="{env["WG_SUBNET"]}"\n')


def next_ip_octet():
    n = 2
    if os.path.isfile(COUNTER_FILE):
        with open(COUNTER_FILE) as f:
            n = int(f.read().strip() or 2)
    with open(COUNTER_FILE, "w") as f:
        f.write(str(n))
    return n


def bump_counter(n):
    with open(COUNTER_FILE, "w") as f:
        f.write(str(n + 1))


def genkeypair():
    priv = run(["wg", "genkey"], check=True).stdout.strip()
    pub = run(["wg", "pubkey"], input_text=priv + "\n", check=True).stdout.strip()
    return priv, pub


def sync_conf():
    strip = run(["wg-quick", "strip", WG_IFACE])
    if strip.returncode != 0:
        return False
    fd, path = tempfile.mkstemp()
    try:
        with os.fdopen(fd, "w") as f:
            f.write(strip.stdout)
        run(["wg", "syncconf", WG_IFACE, path])
    finally:
        os.unlink(path)
    return True


def setup_server(port=None, subnet=None, public_ip=None):
    if is_installed():
        run(["systemctl", "stop", f"wg-quick@{WG_IFACE}"])
        shutil.rmtree(WG_DIR, ignore_errors=True)

    install_dependencies()
    os.makedirs(WG_DIR, exist_ok=True)
    os.makedirs(CLIENTS_DIR, exist_ok=True)
    os.chmod(WG_DIR, 0o700)

    env = {
        "WG_PORT": str(port or DEFAULT_PORT),
        "WG_SUBNET": subnet or DEFAULT_SUBNET,
    }
    save_env(env)

    if not public_ip:
        public_ip, _ = detect_public_ip()
        if not public_ip:
            raise LanixError("Could not detect the server's public IP automatically; provide it manually.")
    set_stored_public_ip(public_ip)

    old_umask = os.umask(0o077)
    priv, pub = genkeypair()
    os.umask(old_umask)

    with open(SERVER_PRIV_FILE, "w") as f:
        f.write(priv + "\n")
    with open(SERVER_PUB_FILE, "w") as f:
        f.write(pub + "\n")
    os.chmod(SERVER_PRIV_FILE, 0o600)

    conf = f"""[Interface]
Address = {env['WG_SUBNET']}.1/24
ListenPort = {env['WG_PORT']}
PrivateKey = {priv}
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT
SaveConfig = false

"""
    with open(SERVER_CONF, "w") as f:
        f.write(conf)
    os.chmod(SERVER_CONF, 0o600)

    sysctl_conf = "/etc/sysctl.conf"
    lines = []
    if os.path.isfile(sysctl_conf):
        with open(sysctl_conf) as f:
            lines = [l for l in f if "net.ipv4.ip_forward" not in l]
    lines.append("net.ipv4.ip_forward = 1\n")
    with open(sysctl_conf, "w") as f:
        f.writelines(lines)
    run(["sysctl", "-p"])

    run(["systemctl", "enable", f"wg-quick@{WG_IFACE}"])
    r = run(["systemctl", "start", f"wg-quick@{WG_IFACE}"], check=True)
    return {"port": env["WG_PORT"], "subnet": env["WG_SUBNET"], "public_ip": public_ip}


NAME_RE = re.compile(r"^[a-zA-Z0-9_-]+$")


def add_client(name):
    if not name or not NAME_RE.match(name):
        raise LanixError("Invalid name. Use only letters, numbers, dashes and underscores.")
    if not is_installed():
        raise LanixError("Server is not set up yet.")

    client_dir = os.path.join(CLIENTS_DIR, name)
    if os.path.isdir(client_dir):
        raise LanixError(f"A user named '{name}' already exists.")

    env = load_env()
    os.makedirs(client_dir, exist_ok=True)

    old_umask = os.umask(0o077)
    priv, pub = genkeypair()
    os.umask(old_umask)

    with open(os.path.join(client_dir, "private.key"), "w") as f:
        f.write(priv + "\n")
    with open(os.path.join(client_dir, "public.key"), "w") as f:
        f.write(pub + "\n")

    octet = next_ip_octet()
    client_ip = f"{env['WG_SUBNET']}.{octet}"
    bump_counter(octet)

    with open(os.path.join(client_dir, "ip.txt"), "w") as f:
        f.write(client_ip)

    with open(SERVER_PUB_FILE) as f:
        server_pub = f.read().strip()
    server_ip = get_stored_public_ip() or ""

    conf = f"""[Interface]
PrivateKey = {priv}
Address = {client_ip}/32
DNS = 1.1.1.1

[Peer]
PublicKey = {server_pub}
Endpoint = {server_ip}:{env['WG_PORT']}
AllowedIPs = {env['WG_SUBNET']}.0/24
PersistentKeepalive = 25
"""
    conf_path = os.path.join(client_dir, f"{name}.conf")
    with open(conf_path, "w") as f:
        f.write(conf)
    os.chmod(conf_path, 0o600)

    with open(SERVER_CONF, "a") as f:
        f.write(f"[Peer]\nPublicKey = {pub}\nAllowedIPs = {client_ip}/32\n\n")

    sync_conf()
    return {"name": name, "ip": client_ip}


def _remove_peer_block(pubkey):
    if not os.path.isfile(SERVER_CONF):
        return
    with open(SERVER_CONF) as f:
        content = f.read()
    blocks = content.split("\n\n")
    kept = []
    for block in blocks:
        if block.strip().startswith("[Peer]") and pubkey in block:
            continue
        kept.append(block)
    new_content = "\n\n".join(kept)
    if not new_content.endswith("\n"):
        new_content += "\n"
    with open(SERVER_CONF, "w") as f:
        f.write(new_content)


def remove_client(name):
    client_dir = os.path.join(CLIENTS_DIR, name)
    if not os.path.isdir(client_dir):
        raise LanixError(f"No user named '{name}' was found.")

    pub_file = os.path.join(client_dir, "public.key")
    pubkey = None
    if os.path.isfile(pub_file):
        with open(pub_file) as f:
            pubkey = f.read().strip()

    if pubkey:
        _remove_peer_block(pubkey)

    shutil.rmtree(client_dir, ignore_errors=True)
    sync_conf()


def _peer_status_map():
    r = run(["wg", "show", WG_IFACE, "dump"])
    status = {}
    if r.returncode != 0 or not r.stdout.strip():
        return status
    lines = r.stdout.strip().split("\n")[1:]
    now = time.time()
    for line in lines:
        parts = line.split("\t")
        if len(parts) < 5:
            continue
        pubkey = parts[0]
        try:
            handshake = int(parts[4])
        except ValueError:
            handshake = 0
        if handshake == 0:
            status[pubkey] = "never"
        elif now - handshake <= 180:
            status[pubkey] = "online"
        else:
            status[pubkey] = "offline"
    return status


def list_clients():
    if not os.path.isdir(CLIENTS_DIR):
        return []
    status_map = _peer_status_map()
    users = []
    for name in sorted(os.listdir(CLIENTS_DIR)):
        client_dir = os.path.join(CLIENTS_DIR, name)
        if not os.path.isdir(client_dir):
            continue
        ip_file = os.path.join(client_dir, "ip.txt")
        pub_file = os.path.join(client_dir, "public.key")
        ip = ""
        pubkey = ""
        if os.path.isfile(ip_file):
            with open(ip_file) as f:
                ip = f.read().strip()
        if os.path.isfile(pub_file):
            with open(pub_file) as f:
                pubkey = f.read().strip()
        status = status_map.get(pubkey, "unknown")
        users.append({"name": name, "ip": ip, "status": status})
    return users


def get_client_conf_path(name):
    return os.path.join(CLIENTS_DIR, name, f"{name}.conf")


def get_client_conf_text(name):
    path = get_client_conf_path(name)
    if not os.path.isfile(path):
        raise LanixError(f"No user named '{name}' was found.")
    with open(path) as f:
        return f.read()


def get_service_status_text():
    if not is_installed():
        return "Server is not set up yet."
    status = run(["systemctl", "status", f"wg-quick@{WG_IFACE}", "--no-pager", "-l"])
    peers = run(["wg", "show", WG_IFACE])
    return status.stdout + "\n" + peers.stdout


def fix_public_ip(manual_ip=None):
    if not is_installed():
        raise LanixError("Server is not set up yet.")

    if manual_ip:
        if not is_valid_ip(manual_ip):
            raise LanixError("Invalid IPv4 address.")
        new_ip = manual_ip
    else:
        new_ip, _ = detect_public_ip()
        if not new_ip:
            raise LanixError("Automatic detection failed; provide the IP manually.")

    set_stored_public_ip(new_ip)
    env = load_env()

    updated = 0
    if os.path.isdir(CLIENTS_DIR):
        for name in os.listdir(CLIENTS_DIR):
            conf_path = get_client_conf_path(name)
            if os.path.isfile(conf_path):
                with open(conf_path) as f:
                    text = f.read()
                text = re.sub(
                    r"^Endpoint = .*:(\d+)$",
                    f"Endpoint = {new_ip}:\\1",
                    text,
                    flags=re.MULTILINE,
                )
                with open(conf_path, "w") as f:
                    f.write(text)
                updated += 1
    return {"ip": new_ip, "updated_users": updated}


def full_uninstall(remove_packages=False):
    run(["systemctl", "stop", f"wg-quick@{WG_IFACE}"])
    run(["systemctl", "disable", f"wg-quick@{WG_IFACE}"])
    shutil.rmtree(WG_DIR, ignore_errors=True)

    if remove_packages:
        mgr = detect_pkg_manager()
        if mgr == "apt":
            run(["apt-get", "remove", "-y", "wireguard", "wireguard-tools"])
        elif mgr in ("dnf", "yum"):
            run([mgr, "remove", "-y", "wireguard-tools"])


CLIENT_GUIDE = {
    "linux": [
        "sudo apt install wireguard -y",
        "sudo cp <name>.conf /etc/wireguard/wg0.conf",
        "sudo wg-quick up wg0",
        "sudo systemctl enable wg-quick@wg0",
    ],
    "windows": [
        "Install the official app from wireguard.com/install",
        '"Import tunnel(s) from file" and select the .conf file',
        'Click "Activate"',
    ],
    "mobile": [
        "Install the WireGuard app (Play Store / App Store)",
        'Tap "+" then "Scan from QR code"',
        "Scan the QR code shown for that user",
        "Turn the tunnel on",
    ],
}
LANIXWEB_CORE_PY

    cat > "$WEB_APP_DIR/auth.py" <<'LANIXWEB_AUTH_PY'
import os
import json
import secrets
from werkzeug.security import generate_password_hash, check_password_hash

WEBAPP_DIR = "/etc/lanix-web"
AUTH_FILE = os.path.join(WEBAPP_DIR, "auth.json")
SECRET_FILE = os.path.join(WEBAPP_DIR, "secret.key")


def ensure_dir():
    os.makedirs(WEBAPP_DIR, exist_ok=True)
    os.chmod(WEBAPP_DIR, 0o700)


def get_secret_key():
    ensure_dir()
    if os.path.isfile(SECRET_FILE):
        with open(SECRET_FILE) as f:
            return f.read().strip()
    key = secrets.token_hex(32)
    with open(SECRET_FILE, "w") as f:
        f.write(key)
    os.chmod(SECRET_FILE, 0o600)
    return key


def is_configured():
    return os.path.isfile(AUTH_FILE)


def set_credentials(username, password):
    ensure_dir()
    data = {"username": username, "password_hash": generate_password_hash(password)}
    with open(AUTH_FILE, "w") as f:
        json.dump(data, f)
    os.chmod(AUTH_FILE, 0o600)


def get_credentials():
    if not is_configured():
        return None
    with open(AUTH_FILE) as f:
        return json.load(f)


def verify_credentials(username, password):
    data = get_credentials()
    if not data:
        return False
    if data.get("username") != username:
        return False
    return check_password_hash(data.get("password_hash", ""), password)
LANIXWEB_AUTH_PY

    cat > "$WEB_APP_DIR/app.py" <<'LANIXWEB_APP_PY'
import io
import os

from flask import (
    Flask, request, session, redirect, url_for,
    render_template, jsonify, send_file, Response
)

import core
import auth

try:
    import qrcode
except ImportError:
    qrcode = None

app = Flask(__name__)
app.secret_key = auth.get_secret_key()


@app.before_request
def guard():
    open_endpoints = {"login", "static", "setup_account"}
    if request.endpoint in open_endpoints:
        return
    if not auth.is_configured():
        if request.path.startswith("/api/"):
            return jsonify({"error": "account_not_configured"}), 403
        return redirect(url_for("setup_account"))
    if not session.get("logged_in"):
        if request.path.startswith("/api/"):
            return jsonify({"error": "unauthorized"}), 401
        return redirect(url_for("login"))


@app.route("/setup-account", methods=["GET", "POST"])
def setup_account():
    if auth.is_configured():
        return redirect(url_for("login"))
    error = None
    if request.method == "POST":
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "")
        confirm = request.form.get("confirm", "")
        if not username or not password:
            error = "Username and password are required."
        elif password != confirm:
            error = "Passwords do not match."
        elif len(password) < 6:
            error = "Password must be at least 6 characters."
        else:
            auth.set_credentials(username, password)
            session["logged_in"] = True
            session["username"] = username
            return redirect(url_for("index"))
    return render_template("setup_account.html", error=error)


@app.route("/login", methods=["GET", "POST"])
def login():
    if not auth.is_configured():
        return redirect(url_for("setup_account"))
    error = None
    if request.method == "POST":
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "")
        if auth.verify_credentials(username, password):
            session["logged_in"] = True
            session["username"] = username
            return redirect(url_for("index"))
        error = "Invalid username or password."
    return render_template("login.html", error=error)


@app.route("/logout", methods=["POST"])
def logout():
    session.clear()
    return redirect(url_for("login"))


@app.route("/")
def index():
    return render_template("index.html", username=session.get("username", ""))


@app.route("/api/state")
def api_state():
    env = core.load_env()
    installed = core.is_installed()
    users = core.list_clients() if installed else []
    online = sum(1 for u in users if u["status"] == "online")
    return jsonify({
        "installed": installed,
        "port": env.get("WG_PORT"),
        "subnet": env.get("WG_SUBNET"),
        "public_ip": core.get_stored_public_ip(),
        "users_count": len(users),
        "online_count": online,
    })


@app.route("/api/setup", methods=["POST"])
def api_setup():
    data = request.get_json(force=True, silent=True) or {}
    port = data.get("port") or core.DEFAULT_PORT
    subnet = data.get("subnet") or core.DEFAULT_SUBNET
    public_ip = data.get("public_ip") or None
    try:
        result = core.setup_server(port=port, subnet=subnet, public_ip=public_ip)
        return jsonify({"ok": True, **result})
    except core.LanixError as e:
        return jsonify({"ok": False, "error": str(e)}), 400


@app.route("/api/detect-ip")
def api_detect_ip():
    ip, source = core.detect_public_ip()
    return jsonify({"ip": ip, "source": source})


@app.route("/api/fix-ip", methods=["POST"])
def api_fix_ip():
    data = request.get_json(force=True, silent=True) or {}
    manual_ip = data.get("ip") or None
    try:
        result = core.fix_public_ip(manual_ip=manual_ip)
        return jsonify({"ok": True, **result})
    except core.LanixError as e:
        return jsonify({"ok": False, "error": str(e)}), 400


@app.route("/api/users", methods=["GET"])
def api_list_users():
    try:
        return jsonify({"ok": True, "users": core.list_clients()})
    except core.LanixError as e:
        return jsonify({"ok": False, "error": str(e)}), 400


@app.route("/api/users", methods=["POST"])
def api_add_user():
    data = request.get_json(force=True, silent=True) or {}
    name = (data.get("name") or "").strip()
    try:
        result = core.add_client(name)
        return jsonify({"ok": True, **result})
    except core.LanixError as e:
        return jsonify({"ok": False, "error": str(e)}), 400


@app.route("/api/users/<name>", methods=["GET"])
def api_get_user(name):
    try:
        conf = core.get_client_conf_text(name)
        return jsonify({"ok": True, "name": name, "conf": conf})
    except core.LanixError as e:
        return jsonify({"ok": False, "error": str(e)}), 404


@app.route("/api/users/<name>", methods=["DELETE"])
def api_remove_user(name):
    try:
        core.remove_client(name)
        return jsonify({"ok": True})
    except core.LanixError as e:
        return jsonify({"ok": False, "error": str(e)}), 400


@app.route("/api/users/<name>/qr")
def api_user_qr(name):
    if qrcode is None:
        return jsonify({"error": "qrcode library not installed"}), 500
    try:
        conf = core.get_client_conf_text(name)
    except core.LanixError as e:
        return jsonify({"error": str(e)}), 404
    img = qrcode.make(conf)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    buf.seek(0)
    return send_file(buf, mimetype="image/png")


@app.route("/api/users/<name>/download")
def api_user_download(name):
    try:
        conf = core.get_client_conf_text(name)
    except core.LanixError as e:
        return jsonify({"error": str(e)}), 404
    return Response(
        conf,
        mimetype="text/plain",
        headers={"Content-Disposition": f"attachment; filename={name}.conf"},
    )


@app.route("/api/status")
def api_status():
    return jsonify({"ok": True, "text": core.get_service_status_text()})


@app.route("/api/guide")
def api_guide():
    return jsonify(core.CLIENT_GUIDE)


@app.route("/api/uninstall", methods=["POST"])
def api_uninstall():
    data = request.get_json(force=True, silent=True) or {}
    remove_packages = bool(data.get("remove_packages"))
    try:
        core.full_uninstall(remove_packages=remove_packages)
        return jsonify({"ok": True})
    except core.LanixError as e:
        return jsonify({"ok": False, "error": str(e)}), 400


@app.route("/api/account/password", methods=["POST"])
def api_change_password():
    data = request.get_json(force=True, silent=True) or {}
    old = data.get("old_password", "")
    new = data.get("new_password", "")
    username = session.get("username")
    if not auth.verify_credentials(username, old):
        return jsonify({"ok": False, "error": "Current password is incorrect."}), 400
    if len(new) < 6:
        return jsonify({"ok": False, "error": "New password must be at least 6 characters."}), 400
    auth.set_credentials(username, new)
    return jsonify({"ok": True})


if __name__ == "__main__":
    port = int(os.environ.get("LANIX_WEB_PORT", "8088"))
    app.run(host="0.0.0.0", port=port)
LANIXWEB_APP_PY

    cat > "$WEB_APP_DIR/requirements.txt" <<'LANIXWEB_REQUIREMENTS_TXT'
Flask==3.0.3
qrcode[pil]==7.4.2
requests==2.32.3
Werkzeug==3.0.3
LANIXWEB_REQUIREMENTS_TXT

    mkdir -p "$WEB_APP_DIR/templates"
    cat > "$WEB_APP_DIR/templates/login.html" <<'LANIXWEB_TEMPLATES_LOGIN_HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Lanix — Sign in</title>
<link rel="stylesheet" href="{{ url_for('static', filename='css/style.css') }}">
</head>
<body class="auth-body">
  <div class="auth-card">
    <div class="brand">
      <span class="brand-mark">LANIX</span>
      <span class="brand-sub">WireGuard VPN Network Manager</span>
    </div>
    {% if error %}<div class="alert alert-error">{{ error }}</div>{% endif %}
    <form method="POST" class="auth-form">
      <label>Username</label>
      <input type="text" name="username" autocomplete="username" required autofocus>
      <label>Password</label>
      <input type="password" name="password" autocomplete="current-password" required>
      <button type="submit" class="btn btn-primary">Sign in</button>
    </form>
    <div class="auth-footer">Made by Agravix</div>
  </div>
</body>
</html>
LANIXWEB_TEMPLATES_LOGIN_HTML

    mkdir -p "$WEB_APP_DIR/templates"
    cat > "$WEB_APP_DIR/templates/setup_account.html" <<'LANIXWEB_TEMPLATES_SETUP_ACCOUNT_HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Lanix — Create Admin Account</title>
<link rel="stylesheet" href="{{ url_for('static', filename='css/style.css') }}">
</head>
<body class="auth-body">
  <div class="auth-card">
    <div class="brand">
      <span class="brand-mark">LANIX</span>
      <span class="brand-sub">WireGuard VPN Network Manager</span>
    </div>
    <p class="auth-intro">Welcome! Create the admin account for this panel.</p>
    {% if error %}<div class="alert alert-error">{{ error }}</div>{% endif %}
    <form method="POST" class="auth-form">
      <label>Username</label>
      <input type="text" name="username" autocomplete="username" required autofocus>
      <label>Password</label>
      <input type="password" name="password" autocomplete="new-password" required>
      <label>Confirm password</label>
      <input type="password" name="confirm" autocomplete="new-password" required>
      <button type="submit" class="btn btn-primary">Create account</button>
    </form>
    <div class="auth-footer">Made by Agravix</div>
  </div>
</body>
</html>
LANIXWEB_TEMPLATES_SETUP_ACCOUNT_HTML

    mkdir -p "$WEB_APP_DIR/templates"
    cat > "$WEB_APP_DIR/templates/index.html" <<'LANIXWEB_TEMPLATES_INDEX_HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Lanix Panel</title>
<link rel="stylesheet" href="{{ url_for('static', filename='css/style.css') }}">
</head>
<body>
  <div class="app">
    <aside class="sidebar">
      <div class="brand">
        <span class="brand-mark">LANIX</span>
        <span class="brand-sub">Made by Agravix</span>
      </div>
      <nav class="nav">
        <button class="nav-item active" data-view="dashboard">
          <span class="nav-icon">◆</span> Dashboard
        </button>
        <button class="nav-item" data-view="users">
          <span class="nav-icon">◆</span> Users
        </button>
        <button class="nav-item" data-view="service">
          <span class="nav-icon">◆</span> Service
        </button>
        <button class="nav-item" data-view="guide">
          <span class="nav-icon">◆</span> Guide
        </button>
        <button class="nav-item" data-view="settings">
          <span class="nav-icon">◆</span> Settings
        </button>
      </nav>
      <div class="sidebar-footer">
        <div class="user-chip">{{ username }}</div>
        <form action="/logout" method="POST">
          <button type="submit" class="btn btn-ghost btn-sm">Log out</button>
        </form>
      </div>
    </aside>

    <main class="main">

      <section id="view-dashboard" class="view active">
        <h1>Dashboard</h1>
        <div id="dash-not-installed" class="card hidden">
          <h2>Set up your WireGuard server</h2>
          <p class="muted">This will install WireGuard and configure this VPS as the network hub.</p>
          <div class="form-grid">
            <div>
              <label>UDP Port</label>
              <input type="text" id="setup-port" placeholder="51820">
            </div>
            <div>
              <label>Internal Subnet</label>
              <input type="text" id="setup-subnet" placeholder="10.10.10">
            </div>
            <div>
              <label>Public IP (optional)</label>
              <div class="input-row">
                <input type="text" id="setup-ip" placeholder="auto-detect">
                <button class="btn btn-ghost btn-sm" id="btn-detect-ip">Detect</button>
              </div>
            </div>
          </div>
          <button class="btn btn-primary" id="btn-setup">Install &amp; Set Up Server</button>
          <div id="setup-status" class="status-line"></div>
        </div>

        <div id="dash-stats" class="stats-grid hidden">
          <div class="stat-card">
            <div class="stat-label">Server</div>
            <div class="stat-value" id="stat-server">—</div>
          </div>
          <div class="stat-card">
            <div class="stat-label">Public IP</div>
            <div class="stat-value" id="stat-ip">—</div>
          </div>
          <div class="stat-card">
            <div class="stat-label">Users</div>
            <div class="stat-value" id="stat-users">—</div>
          </div>
          <div class="stat-card">
            <div class="stat-label">Online now</div>
            <div class="stat-value accent-green" id="stat-online">—</div>
          </div>
        </div>
      </section>

      <section id="view-users" class="view">
        <div class="view-header">
          <h1>Users</h1>
          <button class="btn btn-primary" id="btn-add-user">+ Add User</button>
        </div>
        <div class="card">
          <table class="table" id="users-table">
            <thead>
              <tr><th>Name</th><th>Internal IP</th><th>Status</th><th></th></tr>
            </thead>
            <tbody id="users-tbody"></tbody>
          </table>
          <div id="users-empty" class="muted hidden">No users yet. Add your first one.</div>
        </div>
      </section>

      <section id="view-service" class="view">
        <div class="view-header">
          <h1>Service Status</h1>
          <button class="btn btn-ghost btn-sm" id="btn-refresh-status">Refresh</button>
        </div>
        <div class="card">
          <pre id="service-output" class="terminal">Loading...</pre>
        </div>
      </section>

      <section id="view-guide" class="view">
        <h1>Client Connection Guide</h1>
        <div class="tabs" id="guide-tabs">
          <button class="tab active" data-os="linux">Linux</button>
          <button class="tab" data-os="windows">Windows</button>
          <button class="tab" data-os="mobile">Android / iOS</button>
        </div>
        <div class="card">
          <ol id="guide-steps" class="steps"></ol>
        </div>
        <div class="card muted-card">
          Each connected user gets a fixed internal IP. Peers reach each other directly
          through that IP — broadcast/discovery traffic usually doesn't cross the tunnel.
        </div>
      </section>

      <section id="view-settings" class="view">
        <h1>Settings</h1>

        <div class="card">
          <h2>Public IP</h2>
          <p class="muted">Re-detect the server's public IP and fix it in every existing user's config.</p>
          <div class="input-row">
            <input type="text" id="fix-ip-manual" placeholder="Leave empty to auto-detect">
            <button class="btn btn-secondary" id="btn-fix-ip">Fix IP</button>
          </div>
          <div id="fix-ip-status" class="status-line"></div>
        </div>

        <div class="card">
          <h2>Change Password</h2>
          <div class="form-grid">
            <div><label>Current password</label><input type="password" id="pwd-old"></div>
            <div><label>New password</label><input type="password" id="pwd-new"></div>
          </div>
          <button class="btn btn-secondary" id="btn-change-pwd">Update Password</button>
          <div id="pwd-status" class="status-line"></div>
        </div>

        <div class="card danger-card">
          <h2>Danger Zone</h2>
          <p class="muted">Fully remove the WireGuard server, all users, and configuration from this VPS.</p>
          <label class="checkbox-row">
            <input type="checkbox" id="remove-packages"> Also remove WireGuard packages
          </label>
          <div class="input-row">
            <input type="text" id="uninstall-confirm" placeholder='Type "YES" to confirm'>
            <button class="btn btn-danger" id="btn-uninstall">Uninstall Everything</button>
          </div>
          <div id="uninstall-status" class="status-line"></div>
        </div>
      </section>

    </main>
  </div>

  <div class="modal-overlay hidden" id="modal-add-user">
    <div class="modal">
      <h2>Add New User</h2>
      <label>Name</label>
      <input type="text" id="add-user-name" placeholder="e.g. friend1">
      <div class="modal-actions">
        <button class="btn btn-ghost" id="btn-cancel-add">Cancel</button>
        <button class="btn btn-primary" id="btn-confirm-add">Create</button>
      </div>
      <div id="add-user-status" class="status-line"></div>
    </div>
  </div>

  <div class="modal-overlay hidden" id="modal-user-detail">
    <div class="modal modal-wide">
      <h2 id="detail-name">User</h2>
      <div class="detail-grid">
        <div>
          <label>Config file</label>
          <textarea id="detail-conf" readonly rows="12"></textarea>
          <div class="modal-actions">
            <button class="btn btn-ghost btn-sm" id="btn-copy-conf">Copy</button>
            <button class="btn btn-ghost btn-sm" id="btn-download-conf">Download .conf</button>
          </div>
        </div>
        <div class="qr-col">
          <label>QR Code</label>
          <img id="detail-qr" alt="QR code">
        </div>
      </div>
      <div class="modal-actions">
        <button class="btn btn-ghost" id="btn-close-detail">Close</button>
      </div>
    </div>
  </div>

  <div class="toast" id="toast"></div>

  <script src="{{ url_for('static', filename='js/app.js') }}"></script>
</body>
</html>
LANIXWEB_TEMPLATES_INDEX_HTML

    mkdir -p "$WEB_APP_DIR/static/css"
    cat > "$WEB_APP_DIR/static/css/style.css" <<'LANIXWEB_STATIC_CSS_STYLE_CSS'
:root {
  --bg: #0b0d12;
  --panel: #12151c;
  --panel-2: #171b25;
  --border: #232733;
  --text: #e5e7eb;
  --muted: #8b93a7;
  --cyan: #22d3ee;
  --magenta: #d946ef;
  --green: #22c55e;
  --red: #ef4444;
  --yellow: #eab308;
  --radius: 12px;
}

* { box-sizing: border-box; }

body {
  margin: 0;
  background: var(--bg);
  color: var(--text);
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
}

a { color: var(--cyan); }

.hidden { display: none !important; }
.muted { color: var(--muted); }

/* ---------- Auth pages ---------- */

.auth-body {
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 100vh;
}

.auth-card {
  background: var(--panel);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 40px;
  width: 360px;
  box-shadow: 0 20px 60px rgba(0,0,0,0.4);
}

.brand {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 4px;
  margin-bottom: 24px;
}

.brand-mark {
  font-size: 28px;
  font-weight: 800;
  letter-spacing: 4px;
  background: linear-gradient(90deg, var(--cyan), var(--magenta));
  -webkit-background-clip: text;
  background-clip: text;
  color: transparent;
}

.brand-sub {
  font-size: 12px;
  color: var(--muted);
}

.auth-intro {
  text-align: center;
  color: var(--muted);
  margin-bottom: 16px;
  font-size: 14px;
}

.auth-form { display: flex; flex-direction: column; gap: 6px; }
.auth-form label { font-size: 12px; color: var(--muted); margin-top: 8px; }
.auth-form button { margin-top: 20px; }

.auth-footer {
  text-align: center;
  margin-top: 24px;
  font-size: 11px;
  color: var(--muted);
}

/* ---------- Layout ---------- */

.app {
  display: flex;
  min-height: 100vh;
}

.sidebar {
  width: 230px;
  flex-shrink: 0;
  background: var(--panel);
  border-right: 1px solid var(--border);
  display: flex;
  flex-direction: column;
  padding: 20px 0;
}

.sidebar .brand {
  align-items: flex-start;
  padding: 0 20px;
  margin-bottom: 30px;
}

.nav { display: flex; flex-direction: column; gap: 2px; flex: 1; }

.nav-item {
  display: flex;
  align-items: center;
  gap: 10px;
  background: none;
  border: none;
  color: var(--muted);
  text-align: left;
  padding: 12px 20px;
  font-size: 14px;
  cursor: pointer;
  border-left: 3px solid transparent;
}

.nav-item:hover { color: var(--text); background: var(--panel-2); }

.nav-item.active {
  color: var(--text);
  background: var(--panel-2);
  border-left-color: var(--cyan);
}

.nav-icon { font-size: 8px; color: var(--cyan); }

.sidebar-footer {
  padding: 0 20px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
}

.user-chip {
  font-size: 13px;
  color: var(--text);
  background: var(--panel-2);
  border: 1px solid var(--border);
  padding: 6px 10px;
  border-radius: 8px;
}

.main {
  flex: 1;
  padding: 32px 40px;
  max-width: 1100px;
}

h1 { font-size: 22px; margin: 0 0 20px; }
h2 { font-size: 16px; margin: 0 0 8px; }

.view { display: none; }
.view.active { display: block; }

.view-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 20px;
}
.view-header h1 { margin: 0; }

/* ---------- Cards ---------- */

.card {
  background: var(--panel);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 24px;
  margin-bottom: 20px;
}

.muted-card { color: var(--muted); font-size: 13px; }

.danger-card { border-color: rgba(239,68,68,0.4); }

.stats-grid {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 16px;
}

.stat-card {
  background: var(--panel);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 20px;
}

.stat-label { font-size: 12px; color: var(--muted); margin-bottom: 8px; }
.stat-value { font-size: 22px; font-weight: 700; }
.accent-green { color: var(--green); }

/* ---------- Forms ---------- */

.form-grid {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 16px;
  margin-bottom: 16px;
}

label { display: block; font-size: 12px; color: var(--muted); margin-bottom: 6px; }

input[type="text"], input[type="password"], textarea {
  width: 100%;
  background: var(--panel-2);
  border: 1px solid var(--border);
  color: var(--text);
  padding: 10px 12px;
  border-radius: 8px;
  font-size: 14px;
  font-family: inherit;
}

textarea { font-family: "SF Mono", Menlo, Consolas, monospace; font-size: 12px; resize: vertical; }

input:focus, textarea:focus {
  outline: none;
  border-color: var(--cyan);
}

.input-row { display: flex; gap: 8px; }
.input-row input { flex: 1; }

.checkbox-row {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 13px;
  color: var(--text);
  margin-bottom: 12px;
}
.checkbox-row input { width: auto; }

/* ---------- Buttons ---------- */

.btn {
  border: none;
  border-radius: 8px;
  padding: 10px 18px;
  font-size: 14px;
  font-weight: 600;
  cursor: pointer;
}

.btn-primary {
  background: linear-gradient(90deg, var(--cyan), var(--magenta));
  color: #06121a;
}
.btn-primary:hover { filter: brightness(1.1); }

.btn-secondary {
  background: var(--panel-2);
  border: 1px solid var(--cyan);
  color: var(--cyan);
}

.btn-ghost {
  background: transparent;
  border: 1px solid var(--border);
  color: var(--text);
}
.btn-ghost:hover { background: var(--panel-2); }

.btn-danger {
  background: var(--red);
  color: white;
}

.btn-sm { padding: 6px 12px; font-size: 12px; }

/* ---------- Table ---------- */

.table { width: 100%; border-collapse: collapse; }
.table th, .table td {
  text-align: left;
  padding: 10px 12px;
  border-bottom: 1px solid var(--border);
  font-size: 14px;
}
.table th { color: var(--muted); font-weight: 500; font-size: 12px; text-transform: uppercase; }

.badge {
  display: inline-block;
  padding: 3px 10px;
  border-radius: 999px;
  font-size: 12px;
  font-weight: 600;
}
.badge-online { background: rgba(34,197,94,0.15); color: var(--green); }
.badge-offline { background: rgba(239,68,68,0.15); color: var(--red); }
.badge-never { background: rgba(234,179,8,0.15); color: var(--yellow); }
.badge-unknown { background: rgba(139,147,167,0.15); color: var(--muted); }

/* ---------- Tabs ---------- */

.tabs { display: flex; gap: 4px; margin-bottom: 16px; }
.tab {
  background: var(--panel-2);
  border: 1px solid var(--border);
  color: var(--muted);
  padding: 8px 16px;
  border-radius: 8px 8px 0 0;
  cursor: pointer;
  font-size: 13px;
}
.tab.active { color: var(--cyan); border-bottom-color: var(--panel); }

.steps { padding-left: 20px; line-height: 1.8; font-size: 14px; }

/* ---------- Terminal ---------- */

.terminal {
  background: #05070a;
  color: #b7f0d0;
  padding: 16px;
  border-radius: 8px;
  font-family: "SF Mono", Menlo, Consolas, monospace;
  font-size: 12px;
  white-space: pre-wrap;
  max-height: 500px;
  overflow: auto;
}

/* ---------- Modal ---------- */

.modal-overlay {
  position: fixed;
  inset: 0;
  background: rgba(0,0,0,0.6);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 100;
}

.modal {
  background: var(--panel);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 28px;
  width: 380px;
}

.modal-wide { width: 640px; }

.modal-actions {
  display: flex;
  justify-content: flex-end;
  gap: 8px;
  margin-top: 16px;
}

.detail-grid {
  display: grid;
  grid-template-columns: 1fr 180px;
  gap: 20px;
}

.qr-col { display: flex; flex-direction: column; align-items: center; }
.qr-col img { width: 160px; height: 160px; background: white; padding: 8px; border-radius: 8px; }

.status-line { margin-top: 10px; font-size: 13px; min-height: 18px; }
.status-line.ok { color: var(--green); }
.status-line.err { color: var(--red); }

/* ---------- Toast ---------- */

.toast {
  position: fixed;
  bottom: 24px;
  right: 24px;
  background: var(--panel-2);
  border: 1px solid var(--border);
  padding: 12px 20px;
  border-radius: 8px;
  font-size: 13px;
  opacity: 0;
  pointer-events: none;
  transition: opacity 0.2s;
  z-index: 200;
}
.toast.show { opacity: 1; }
.toast.ok { border-color: var(--green); color: var(--green); }
.toast.err { border-color: var(--red); color: var(--red); }
LANIXWEB_STATIC_CSS_STYLE_CSS

    mkdir -p "$WEB_APP_DIR/static/js"
    cat > "$WEB_APP_DIR/static/js/app.js" <<'LANIXWEB_STATIC_JS_APP_JS'
const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => Array.from(document.querySelectorAll(sel));

function toast(msg, type = "ok") {
  const el = $("#toast");
  el.textContent = msg;
  el.className = "toast show " + type;
  clearTimeout(el._timer);
  el._timer = setTimeout(() => { el.className = "toast"; }, 3000);
}

async function api(path, options = {}) {
  const res = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  let data = {};
  try { data = await res.json(); } catch (e) { /* no body */ }
  if (!res.ok && !data.error) {
    data.error = `Request failed (${res.status})`;
  }
  return data;
}

/* ---------- Navigation ---------- */

function switchView(view) {
  $$(".nav-item").forEach((b) => b.classList.toggle("active", b.dataset.view === view));
  $$(".view").forEach((v) => v.classList.toggle("active", v.id === "view-" + view));
  if (view === "dashboard") loadDashboard();
  if (view === "users") loadUsers();
  if (view === "service") loadServiceStatus();
  if (view === "guide") loadGuide(currentGuideOs);
}

$$(".nav-item").forEach((btn) => {
  btn.addEventListener("click", () => switchView(btn.dataset.view));
});

/* ---------- Dashboard ---------- */

async function loadDashboard() {
  const state = await api("/api/state");
  if (!state.installed) {
    $("#dash-not-installed").classList.remove("hidden");
    $("#dash-stats").classList.add("hidden");
    return;
  }
  $("#dash-not-installed").classList.add("hidden");
  $("#dash-stats").classList.remove("hidden");
  $("#stat-server").textContent = "Running";
  $("#stat-ip").textContent = state.public_ip || "—";
  $("#stat-users").textContent = state.users_count;
  $("#stat-online").textContent = state.online_count;
}

$("#btn-detect-ip").addEventListener("click", async () => {
  const el = $("#setup-status");
  el.textContent = "Detecting...";
  el.className = "status-line";
  const res = await api("/api/detect-ip");
  if (res.ip) {
    $("#setup-ip").value = res.ip;
    el.textContent = `Detected via ${res.source}: ${res.ip}`;
    el.className = "status-line ok";
  } else {
    el.textContent = "Could not auto-detect. Enter it manually.";
    el.className = "status-line err";
  }
});

$("#btn-setup").addEventListener("click", async () => {
  const btn = $("#btn-setup");
  const el = $("#setup-status");
  btn.disabled = true;
  el.textContent = "Installing WireGuard and configuring the server... this can take a minute.";
  el.className = "status-line";
  const body = {
    port: $("#setup-port").value.trim() || undefined,
    subnet: $("#setup-subnet").value.trim() || undefined,
    public_ip: $("#setup-ip").value.trim() || undefined,
  };
  const res = await api("/api/setup", { method: "POST", body: JSON.stringify(body) });
  btn.disabled = false;
  if (res.ok) {
    el.textContent = `Server is up. Public IP: ${res.public_ip}`;
    el.className = "status-line ok";
    toast("Server set up successfully");
    loadDashboard();
  } else {
    el.textContent = res.error || "Setup failed.";
    el.className = "status-line err";
  }
});

/* ---------- Users ---------- */

function statusBadge(status) {
  const map = {
    online: ["Online", "badge-online"],
    offline: ["Offline", "badge-offline"],
    never: ["Never connected", "badge-never"],
    unknown: ["Unknown", "badge-unknown"],
  };
  const [label, cls] = map[status] || map.unknown;
  return `<span class="badge ${cls}">${label}</span>`;
}

async function loadUsers() {
  const res = await api("/api/users");
  const tbody = $("#users-tbody");
  tbody.innerHTML = "";
  const users = res.users || [];
  $("#users-empty").classList.toggle("hidden", users.length > 0);
  users.forEach((u) => {
    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td>${u.name}</td>
      <td>${u.ip}</td>
      <td>${statusBadge(u.status)}</td>
      <td style="text-align:right">
        <button class="btn btn-ghost btn-sm" data-show="${u.name}">Show</button>
        <button class="btn btn-ghost btn-sm" data-remove="${u.name}">Remove</button>
      </td>`;
    tbody.appendChild(tr);
  });
  $$("[data-show]").forEach((b) => b.addEventListener("click", () => openUserDetail(b.dataset.show)));
  $$("[data-remove]").forEach((b) => b.addEventListener("click", () => removeUser(b.dataset.remove)));
}

async function removeUser(name) {
  if (!confirm(`Remove user "${name}"? This cannot be undone.`)) return;
  const res = await api(`/api/users/${encodeURIComponent(name)}`, { method: "DELETE" });
  if (res.ok) {
    toast(`User "${name}" removed`);
    loadUsers();
    loadDashboard();
  } else {
    toast(res.error || "Failed to remove user", "err");
  }
}

$("#btn-add-user").addEventListener("click", () => {
  $("#add-user-name").value = "";
  $("#add-user-status").textContent = "";
  $("#modal-add-user").classList.remove("hidden");
});
$("#btn-cancel-add").addEventListener("click", () => $("#modal-add-user").classList.add("hidden"));
$("#btn-confirm-add").addEventListener("click", async () => {
  const name = $("#add-user-name").value.trim();
  const el = $("#add-user-status");
  if (!name) { el.textContent = "Name is required."; el.className = "status-line err"; return; }
  const res = await api("/api/users", { method: "POST", body: JSON.stringify({ name }) });
  if (res.ok) {
    $("#modal-add-user").classList.add("hidden");
    toast(`User "${name}" created (${res.ip})`);
    loadUsers();
    loadDashboard();
  } else {
    el.textContent = res.error || "Failed to create user.";
    el.className = "status-line err";
  }
});

let currentDetailName = null;

async function openUserDetail(name) {
  const res = await api(`/api/users/${encodeURIComponent(name)}`);
  if (!res.ok) { toast(res.error || "Failed to load user", "err"); return; }
  currentDetailName = name;
  $("#detail-name").textContent = name;
  $("#detail-conf").value = res.conf;
  $("#detail-qr").src = `/api/users/${encodeURIComponent(name)}/qr?_=${Date.now()}`;
  $("#modal-user-detail").classList.remove("hidden");
}
$("#btn-close-detail").addEventListener("click", () => $("#modal-user-detail").classList.add("hidden"));
$("#btn-copy-conf").addEventListener("click", () => {
  $("#detail-conf").select();
  document.execCommand("copy");
  toast("Config copied to clipboard");
});
$("#btn-download-conf").addEventListener("click", () => {
  if (currentDetailName) window.location.href = `/api/users/${encodeURIComponent(currentDetailName)}/download`;
});

/* ---------- Service ---------- */

async function loadServiceStatus() {
  $("#service-output").textContent = "Loading...";
  const res = await api("/api/status");
  $("#service-output").textContent = res.text || res.error || "No data.";
}
$("#btn-refresh-status").addEventListener("click", loadServiceStatus);

/* ---------- Guide ---------- */

let currentGuideOs = "linux";
let guideData = null;

async function loadGuide(os) {
  if (!guideData) guideData = await api("/api/guide");
  currentGuideOs = os;
  $$(".tab").forEach((t) => t.classList.toggle("active", t.dataset.os === os));
  const steps = guideData[os] || [];
  $("#guide-steps").innerHTML = steps.map((s) => `<li>${s}</li>`).join("");
}
$$(".tab").forEach((t) => t.addEventListener("click", () => loadGuide(t.dataset.os)));

/* ---------- Settings ---------- */

$("#btn-fix-ip").addEventListener("click", async () => {
  const el = $("#fix-ip-status");
  const ip = $("#fix-ip-manual").value.trim() || undefined;
  el.textContent = "Working...";
  el.className = "status-line";
  const res = await api("/api/fix-ip", { method: "POST", body: JSON.stringify({ ip }) });
  if (res.ok) {
    el.textContent = `Public IP updated to ${res.ip}. ${res.updated_users} user config(s) updated.`;
    el.className = "status-line ok";
    toast("Public IP fixed");
    loadDashboard();
  } else {
    el.textContent = res.error || "Failed to fix IP.";
    el.className = "status-line err";
  }
});

$("#btn-change-pwd").addEventListener("click", async () => {
  const el = $("#pwd-status");
  const old_password = $("#pwd-old").value;
  const new_password = $("#pwd-new").value;
  const res = await api("/api/account/password", {
    method: "POST",
    body: JSON.stringify({ old_password, new_password }),
  });
  if (res.ok) {
    el.textContent = "Password updated.";
    el.className = "status-line ok";
    $("#pwd-old").value = "";
    $("#pwd-new").value = "";
    toast("Password updated");
  } else {
    el.textContent = res.error || "Failed to update password.";
    el.className = "status-line err";
  }
});

$("#btn-uninstall").addEventListener("click", async () => {
  const el = $("#uninstall-status");
  if ($("#uninstall-confirm").value.trim() !== "YES") {
    el.textContent = 'Type "YES" to confirm.';
    el.className = "status-line err";
    return;
  }
  const remove_packages = $("#remove-packages").checked;
  el.textContent = "Removing everything...";
  el.className = "status-line";
  const res = await api("/api/uninstall", { method: "POST", body: JSON.stringify({ remove_packages }) });
  if (res.ok) {
    el.textContent = "Everything has been removed.";
    el.className = "status-line ok";
    toast("Uninstalled");
    loadDashboard();
    $("#uninstall-confirm").value = "";
  } else {
    el.textContent = res.error || "Uninstall failed.";
    el.className = "status-line err";
  }
});

/* ---------- Init ---------- */

loadDashboard();
LANIXWEB_STATIC_JS_APP_JS

}

is_web_installed() {
    [[ -f "$WEB_SERVICE_FILE" ]]
}

get_web_port() {
    if [[ -f "$WEB_SERVICE_FILE" ]]; then
        grep -oP '^Environment=LANIX_WEB_PORT=\K.*' "$WEB_SERVICE_FILE"
    fi
}

install_web_panel() {
    if is_web_installed; then
        echo -e "${YELLOW}The web panel is already installed.${NC}"
        return
    fi

    echo -e "${YELLOW}Installing system packages (python3, venv, pip)...${NC}"
    local pm
    pm="$(detect_pkg_manager)"
    case "$pm" in
        apt)
            apt-get update -y
            apt-get install -y python3 python3-venv python3-pip
            ;;
        dnf) dnf install -y python3 python3-pip ;;
        yum) yum install -y python3 python3-pip ;;
        *)
            echo -e "${RED}Unsupported distro.${NC}"
            return 1
            ;;
    esac

    echo -e "${YELLOW}Writing application files to ${WEB_APP_DIR}...${NC}"
    write_web_files

    echo -e "${YELLOW}Creating Python virtual environment...${NC}"
    python3 -m venv "${WEB_APP_DIR}/venv"
    "${WEB_APP_DIR}/venv/bin/pip" install --upgrade pip >/dev/null
    "${WEB_APP_DIR}/venv/bin/pip" install -r "${WEB_APP_DIR}/requirements.txt"

    read -rp "Port for the web panel [default: ${WEB_DEFAULT_PORT}]: " web_port_in
    local web_port="${web_port_in:-$WEB_DEFAULT_PORT}"

    cat > "$WEB_SERVICE_FILE" <<SERVICE_EOF
[Unit]
Description=Lanix Web Panel
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${WEB_APP_DIR}
Environment=LANIX_WEB_PORT=${web_port}
ExecStart=${WEB_APP_DIR}/venv/bin/python ${WEB_APP_DIR}/app.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICE_EOF

    systemctl daemon-reload
    systemctl enable lanix-web >/dev/null 2>&1
    systemctl restart lanix-web
    sleep 1

    if systemctl is-active --quiet lanix-web; then
        local ip
        ip="$(get_public_ip)"
        echo -e "${GREEN}Lanix Web Panel is running.${NC}"
        echo -e "Open: ${CYAN}http://${ip}:${web_port}${NC}"
        echo -e "${YELLOW}The first visit will ask you to create the admin account.${NC}"
        echo -e "${YELLOW}Note: this serves plain HTTP. Consider a reverse proxy with HTTPS, or restrict the port in your firewall.${NC}"
    else
        echo -e "${RED}Service failed to start. Check logs with: journalctl -u lanix-web -e${NC}"
    fi
}

web_change_port() {
    local current
    current="$(get_web_port)"
    echo -e "${DIM}Current port: ${current:-unknown}${NC}"
    read -rp "New port for the web panel: " new_port
    if [[ ! "$new_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid port.${NC}"
        return
    fi
    sed -i "s/^Environment=LANIX_WEB_PORT=.*/Environment=LANIX_WEB_PORT=${new_port}/" "$WEB_SERVICE_FILE"
    systemctl daemon-reload
    systemctl restart lanix-web
    echo -e "${GREEN}Web panel port changed to ${new_port} and service restarted.${NC}"
}

web_reset_credentials() {
    read -rp "New admin username: " new_user
    if [[ -z "$new_user" ]]; then
        echo -e "${RED}Username cannot be empty.${NC}"
        return
    fi
    read -rsp "New admin password: " new_pass
    echo
    if [[ ${#new_pass} -lt 6 ]]; then
        echo -e "${RED}Password must be at least 6 characters.${NC}"
        return
    fi
    read -rsp "Confirm password: " confirm_pass
    echo
    if [[ "$new_pass" != "$confirm_pass" ]]; then
        echo -e "${RED}Passwords do not match.${NC}"
        return
    fi

    WEB_ADMIN_USER="$new_user" WEB_ADMIN_PASS="$new_pass" "${WEB_APP_DIR}/venv/bin/python3" - <<'PYSCRIPT'
import json, os
from werkzeug.security import generate_password_hash

username = os.environ["WEB_ADMIN_USER"]
password = os.environ["WEB_ADMIN_PASS"]
os.makedirs("/etc/lanix-web", exist_ok=True)
data = {"username": username, "password_hash": generate_password_hash(password)}
with open("/etc/lanix-web/auth.json", "w") as f:
    json.dump(data, f)
os.chmod("/etc/lanix-web/auth.json", 0o600)
print("Admin credentials updated.")
PYSCRIPT

    echo -e "${GREEN}You can now log in to the web panel with the new credentials.${NC}"
}

web_status() {
    if ! is_web_installed; then
        echo -e "${RED}Web panel is not installed.${NC}"
        return
    fi
    systemctl status lanix-web --no-pager -l | head -n 10
}

web_restart() {
    systemctl restart lanix-web
    echo -e "${GREEN}Web panel restarted.${NC}"
}

uninstall_web_panel() {
    echo -e "${RED}${BOLD}This removes the web panel (app + service).${NC}"
    echo -e "${DIM}Your WireGuard server and users are not affected.${NC}"
    read -rp "Type YES to confirm: " confirm
    if [[ "$confirm" != "YES" ]]; then
        echo -e "${YELLOW}Cancelled.${NC}"
        return
    fi
    systemctl stop lanix-web 2>/dev/null
    systemctl disable lanix-web 2>/dev/null
    rm -f "$WEB_SERVICE_FILE"
    systemctl daemon-reload
    rm -rf "$WEB_APP_DIR"

    read -rp "Also remove the admin account and panel settings? [y/N]: " rmcfg
    if [[ "$rmcfg" == "y" || "$rmcfg" == "Y" ]]; then
        rm -rf "$WEB_ETC_DIR"
    fi
    echo -e "${GREEN}Web panel removed.${NC}"
}

menu_install_web() {
    banner
    install_web_panel
    press_enter
}

menu_web_settings() {
    while true; do
        banner
        local port
        port="$(get_web_port)"
        local ip
        ip="$(cat "${WG_DIR}/.server_public_ip" 2>/dev/null)"
        echo -e "${BOLD}Web Panel Settings${NC}"
        if systemctl is-active --quiet lanix-web; then
            echo -e " Status: ${GREEN}running${NC}   Port: ${port:-unknown}   URL: http://${ip:-<server-ip>}:${port}"
        else
            echo -e " Status: ${RED}stopped${NC}   Port: ${port:-unknown}"
        fi
        echo -e "${BLUE}------------------------------------------------------------${NC}"
        echo -e " ${BOLD}1)${NC} Change web panel port"
        echo -e " ${BOLD}2)${NC} Reset admin username/password"
        echo -e " ${BOLD}3)${NC} Restart web panel service"
        echo -e " ${BOLD}4)${NC} View service status"
        echo -e " ${BOLD}5)${NC} ${RED}Uninstall web panel${NC}"
        echo -e " ${BOLD}0)${NC} Back to main menu"
        echo -e "${BLUE}------------------------------------------------------------${NC}"
        read -rp "Choose an option: " wchoice
        case "$wchoice" in
            1) web_change_port; press_enter ;;
            2) web_reset_credentials; press_enter ;;
            3) web_restart; press_enter ;;
            4) web_status; press_enter ;;
            5) uninstall_web_panel; press_enter; return ;;
            0) return ;;
            *) echo -e "${RED}Invalid option.${NC}"; sleep 1 ;;
        esac
    done
}


print_usage() {
    echo -e "${BOLD}Lanix${NC} - WireGuard VPN Network Manager"
    echo -e "${DIM}Made by Agravix${NC}"
    echo
    echo "Usage:"
    echo "  lanix                 open the interactive menu"
    echo "  lanix install         install dependencies and set up the server"
    echo "  lanix install-cmd     install just the 'lanix' command (no server setup)"
    echo "  lanix update          update the installed 'lanix' command to this script's version"
    echo "  lanix add <name>      add a new user"
    echo "  lanix remove <name>   remove a user"
    echo "  lanix list            list all users and their internal IPs"
    echo "  lanix show <name>     show a user's config file and QR code"
    echo "  lanix status          show service and peer status"
    echo "  lanix fix-ip          re-detect the server's public IP and update all user configs"
    echo "  lanix guide           show the client connection guide"
    echo "  lanix install-web     install the browser-based web panel"
    echo "  lanix web-menu        open the web panel settings menu (port, credentials, uninstall)"
    echo "  lanix web-status      show the web panel service status"
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

menu_fix_ip() {
    banner
    fix_public_ip
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

    MENU_LABELS+=("Fix / re-detect server public IP")
    MENU_ACTIONS+=("menu_fix_ip")

    MENU_LABELS+=("Client connection guide (Linux / Windows / Android / iOS)")
    MENU_ACTIONS+=("menu_guide")

    if ! is_web_installed; then
        MENU_LABELS+=("Install Web Panel (browser-based dashboard)")
        MENU_ACTIONS+=("menu_install_web")
    else
        MENU_LABELS+=("Web Panel Settings")
        MENU_ACTIONS+=("menu_web_settings")
    fi

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
    update)
        self_update
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
    fix-ip)
        fix_public_ip
        ;;
    guide)
        client_guide
        ;;
    install-web)
        install_web_panel
        ;;
    web-menu)
        menu_web_settings
        ;;
    web-status)
        web_status
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
