#!/usr/bin/env bash
# ==============================================================================
# Title:        wgmipfixer.sh (WireGuard & UDP Tunnel Symmetric Routing Fixer)
# Description:  Fixes asymmetric UDP source IP routing (io: read/write on closed
#               pipe) on single-IP and multi-IP Linux servers running WireGuard,
#               Backpack, Sing-box, or raw-socket UDP tunnels.
# Author:       Shayan Aghaee
# License:      MIT
# ==============================================================================

set -u

# --- Colors & Styling ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Global Configuration & Paths ---
STATE_DIR="/etc/wgmipfixer"
BACKUP_FILE="${STATE_DIR}/original_state.env"
ACTIVE_CONF="${STATE_DIR}/active_config.env"
WORKER_SCRIPT="/usr/local/bin/wg-sym-worker.sh"
SERVICE_FILE="/etc/systemd/system/wgmipfixer.service"

CHAIN_PRE="WG_SYM_PRE"
CHAIN_POST="WG_SYM_POST"
DEFAULT_WG_PORT=51820
BASE_RELAY_PORT=52820

# --- 1. Root / Sudo Privilege Check ---
if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${YELLOW}[!] Root privileges are required. Elevating via sudo...${NC}"
    exec sudo -E bash "$0" "$@"
fi

# --- Helper Logging Functions ---
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC}   $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERR]${NC}  $1"; }

# --- 2. Auto-Detect Network Environment ---
detect_environment() {
    mkdir -p "${STATE_DIR}"

    # Detect default network interface
    DEF_IFACE=$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1)
    if [[ -z "${DEF_IFACE}" ]]; then
        DEF_IFACE=$(ip -o -4 addr show scope global | awk '{print $2}' | head -n1)
    fi

    # Detect default gateway
    DEF_GW=$(ip -4 route show default dev "${DEF_IFACE}" | awk '/default/ {print $3}' | head -n1)

    # Detect current preferred source IP in default route (if any)
    CURR_ROUTE_SRC=$(ip -4 route show default dev "${DEF_IFACE}" | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)

    # Detect all public/global IPv4 addresses on the primary interface
    mapfile -t PUBLIC_IPS < <(ip -4 -o addr show dev "${DEF_IFACE}" scope global | awk '{print $4}' | cut -d/ -f1)
    IP_COUNT=${#PUBLIC_IPS[@]}

    # Detect active UDP port (Check if 51820 is open, otherwise check active config or default to 51820)
    if [[ -f "${ACTIVE_CONF}" ]]; then
        # shellcheck disable=SC1090
        source "${ACTIVE_CONF}"
    fi
    WG_PORT="${WG_PORT:-${DEFAULT_WG_PORT}}"

    # Detect if service is currently active
    if systemctl is-active --quiet wgmipfixer.service 2>/dev/null; then
        SERVICE_STATUS="${GREEN}ACTIVE (${MODE_APPLIED:-Configured})${NC}"
    else
        SERVICE_STATUS="${YELLOW}INACTIVE${NC}"
    fi
}

# --- 3. Save Original Kernel State (Once Before Any Modification) ---
save_original_state() {
    if [[ ! -f "${BACKUP_FILE}" ]]; then
        log_info "Saving original kernel routing and sysctl state to ${BACKUP_FILE}..."
        local rp_all rp_def rp_iface
        rp_all=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo "1")
        rp_def=$(sysctl -n net.ipv4.conf.default.rp_filter 2>/dev/null || echo "1")
        rp_iface=$(sysctl -n "net.ipv4.conf.${DEF_IFACE}.rp_filter" 2>/dev/null || echo "1")

        cat << EOF > "${BACKUP_FILE}"
ORIG_IFACE="${DEF_IFACE}"
ORIG_GW="${DEF_GW}"
ORIG_ROUTE_SRC="${CURR_ROUTE_SRC}"
ORIG_RP_ALL="${rp_all}"
ORIG_RP_DEF="${rp_def}"
ORIG_RP_IFACE="${rp_iface}"
EOF
        chmod 600 "${BACKUP_FILE}"
        log_success "Original network state backed up safely."
    fi
}

# --- 4. Dependency Check & Auto-Installation ---
install_dependencies() {
    local missing_pkgs=()

    command -v iptables >/dev/null 2>&1 || missing_pkgs+=("iptables")
    command -v socat >/dev/null 2>&1    || missing_pkgs+=("socat")
    command -v conntrack >/dev/null 2>&1 || missing_pkgs+=("conntrack")
    command -v ip >/dev/null 2>&1       || missing_pkgs+=("iproute2")

    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        log_info "Installing required packages: ${missing_pkgs[*]}..."
        if command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing_pkgs[@]}" >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y -q "${missing_pkgs[@]}" >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y -q "${missing_pkgs[@]}" >/dev/null 2>&1
        elif command -v pacman >/dev/null 2>&1; then
            pacman -Sy --noconfirm "${missing_pkgs[@]}" >/dev/null 2>&1
        else
            log_error "Unsupported package manager. Please install manually: ${missing_pkgs[*]}"
            exit 1
        fi
        log_success "All required dependencies installed."
    else
        log_success "All dependencies (iptables, socat, conntrack, iproute2) are already installed."
    fi
}

# --- 5. Isolated Iptables & Socat Cleanup (Only touches script's own artifacts) ---
clean_script_rules_only() {
    # Stop active socat relays spawned by our worker
    if [[ -f "${STATE_DIR}/socat.pids" ]]; then
        while read -r pid; do
            if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
                kill "${pid}" 2>/dev/null || true
            fi
        done < "${STATE_DIR}/socat.pids"
        rm -f "${STATE_DIR}/socat.pids"
    fi
    pkill -f "socat.*UDP4-LISTEN:528" 2>/dev/null || true

    # Remove jump rules from PREROUTING and POSTROUTING (loop in case of duplicates)
    while iptables -t nat -D PREROUTING -j "${CHAIN_PRE}" 2>/dev/null; do :; done
    while iptables -t nat -D POSTROUTING -j "${CHAIN_POST}" 2>/dev/null; do :; done

    # Flush and delete our custom chains ONLY
    if iptables -t nat -L "${CHAIN_PRE}" -n >/dev/null 2>&1; then
        iptables -t nat -F "${CHAIN_PRE}" 2>/dev/null || true
        iptables -t nat -X "${CHAIN_PRE}" 2>/dev/null || true
    fi

    if iptables -t nat -L "${CHAIN_POST}" -n >/dev/null 2>&1; then
        iptables -t nat -F "${CHAIN_POST}" 2>/dev/null || true
        iptables -t nat -X "${CHAIN_POST}" 2>/dev/null || true
    fi
}

# --- 6. Generate Worker Script & Systemd Service for Reboot Persistence ---
create_systemd_persistence() {
    cat << 'EOF' > "${WORKER_SCRIPT}"
#!/usr/bin/env bash
set -u

STATE_DIR="/etc/wgmipfixer"
ACTIVE_CONF="${STATE_DIR}/active_config.env"
CHAIN_PRE="WG_SYM_PRE"
CHAIN_POST="WG_SYM_POST"

if [[ ! -f "${ACTIVE_CONF}" ]]; then
    echo "No active configuration found at ${ACTIVE_CONF}"
    exit 1
fi

source "${ACTIVE_CONF}"

# Wait briefly for interface to settle
sleep 2

clean_chains() {
    if [[ -f "${STATE_DIR}/socat.pids" ]]; then
        while read -r pid; do
            [[ -n "${pid}" ]] && kill "${pid}" 2>/dev/null || true
        done < "${STATE_DIR}/socat.pids"
        rm -f "${STATE_DIR}/socat.pids"
    fi
    pkill -f "socat.*UDP4-LISTEN:528" 2>/dev/null || true

    while iptables -t nat -D PREROUTING -j "${CHAIN_PRE}" 2>/dev/null; do :; done
    while iptables -t nat -D POSTROUTING -j "${CHAIN_POST}" 2>/dev/null; do :; done

    iptables -t nat -F "${CHAIN_PRE}" 2>/dev/null || true
    iptables -t nat -X "${CHAIN_PRE}" 2>/dev/null || true
    iptables -t nat -F "${CHAIN_POST}" 2>/dev/null || true
    iptables -t nat -X "${CHAIN_POST}" 2>/dev/null || true
}

case "${1:-start}" in
    start)
        clean_chains

        # 1. Disable strict rp_filter for asymmetric/multi-homed UDP handling
        sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1
        sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1
        sysctl -w "net.ipv4.conf.${DEF_IFACE}.rp_filter=0" >/dev/null 2>&1

        # 2. Create isolated custom chains
        iptables -t nat -N "${CHAIN_PRE}" 2>/dev/null || iptables -t nat -F "${CHAIN_PRE}"
        iptables -t nat -N "${CHAIN_POST}" 2>/dev/null || iptables -t nat -F "${CHAIN_POST}"
        iptables -t nat -I PREROUTING 1 -j "${CHAIN_PRE}"
        iptables -t nat -I POSTROUTING 1 -j "${CHAIN_POST}"

        # 3. Set Primary IP as default route source
        if [[ -n "${DEF_GW}" && -n "${PRIMARY_IP}" ]]; then
            ip route replace default via "${DEF_GW}" dev "${DEF_IFACE}" src "${PRIMARY_IP}" 2>/dev/null || true
        fi

        if [[ "${MODE_APPLIED}" == "SINGLE_IP" ]]; then
            # Force all outbound packets from WG_PORT to use PRIMARY_IP
            iptables -t nat -A "${CHAIN_POST}" -o "${DEF_IFACE}" -p udp --sport "${WG_PORT}" -j SNAT --to-source "${PRIMARY_IP}"
        elif [[ "${MODE_APPLIED}" == "MULTI_IP" ]]; then
            # Primary IP is handled natively by default route src + fallback SNAT
            # Secondary IPs are handled via dedicated Socat UDP relays bound to each IP
            RELAY_PORT="${BASE_RELAY_PORT}"
            for sec_ip in ${SECONDARY_IPS}; do
                RELAY_PORT=$((RELAY_PORT + 1))
                iptables -t nat -A "${CHAIN_PRE}" -d "${sec_ip}" -p udp --dport "${WG_PORT}" -j DNAT --to-destination "${sec_ip}:${RELAY_PORT}"
                nohup socat -T 180 "UDP4-LISTEN:${RELAY_PORT},bind=${sec_ip},reuseaddr,fork" "UDP4:127.0.0.1:${WG_PORT}" >/dev/null 2>&1 &
                echo $! >> "${STATE_DIR}/socat.pids"
            done
        fi

        ip route flush cache 2>/dev/null || true
        conntrack -F 2>/dev/null || true
        ;;
    stop)
        clean_chains
        ip route flush cache 2>/dev/null || true
        conntrack -F 2>/dev/null || true
        ;;
esac
EOF

    chmod +x "${WORKER_SCRIPT}"

    cat << EOF > "${SERVICE_FILE}"
[Unit]
Description=WireGuard & UDP Tunnel Symmetric Routing Fixer (${MODE_APPLIED})
After=network-online.target backpack.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${WORKER_SCRIPT} start
ExecStop=${WORKER_SCRIPT} stop
RemainAfterExit=yes
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable wgmipfixer.service >/dev/null 2>&1
    systemctl restart wgmipfixer.service
}

# --- 7. Prompt for Target UDP Port ---
ask_udp_port() {
    echo ""
    read -rp "$(echo -e "${CYAN}[?] Enter WireGuard / Tunnel UDP Port [default: ${WG_PORT}]: ${NC}")" input_port
    if [[ -n "${input_port}" ]]; then
        if [[ "${input_port}" =~ ^[0-9]+$ ]] && (( input_port >= 1 && input_port <= 65535 )); then
            WG_PORT="${input_port}"
        else
            log_warn "Invalid port '${input_port}'. Using default port: ${WG_PORT}"
        fi
    fi
}

# --- 8. Option 1: Single-IP Server Mode ---
apply_single_ip_mode() {
    echo -e "\n${BOLD}=== [Option 1] Configuring Single-IP Mode ===${NC}"
    if [[ "${IP_COUNT}" -eq 0 ]]; then
        log_error "No public IPv4 addresses detected on interface ${DEF_IFACE}!"
        exit 1
    fi

    ask_udp_port
    install_dependencies
    save_original_state

    local target_ip="${PUBLIC_IPS[0]}"

    # If the server actually has multiple IPs, let the user choose which single IP to lock onto
    if [[ "${IP_COUNT}" -gt 1 ]]; then
        echo -e "\n${YELLOW}[i] Multiple public IPs detected on ${DEF_IFACE}:${NC}"
        for i in "${!PUBLIC_IPS[@]}"; do
            echo -e "    $((i+1))) ${PUBLIC_IPS[$i]}"
        done
        read -rp "$(echo -e "${CYAN}[?] Select which IP to use as the primary outbound IP [1-${IP_COUNT}, default: 1]: ${NC}")" ip_choice
        if [[ -n "${ip_choice}" && "${ip_choice}" =~ ^[0-9]+$ ]] && (( ip_choice >= 1 && ip_choice <= IP_COUNT )); then
            target_ip="${PUBLIC_IPS[$((ip_choice-1))]}"
        fi
    fi

    MODE_APPLIED="SINGLE_IP"
    PRIMARY_IP="${target_ip}"
    SECONDARY_IPS=""

    cat << EOF > "${ACTIVE_CONF}"
MODE_APPLIED="${MODE_APPLIED}"
DEF_IFACE="${DEF_IFACE}"
DEF_GW="${DEF_GW}"
WG_PORT="${WG_PORT}"
BASE_RELAY_PORT="${BASE_RELAY_PORT}"
PRIMARY_IP="${PRIMARY_IP}"
SECONDARY_IPS=""
EOF

    log_info "Applying kernel routing and isolated SNAT chain (${CHAIN_POST})..."
    create_systemd_persistence
    log_success "Single-IP Symmetric Routing configured and enabled at boot."
    print_final_report
}

# --- 9. Option 2: Multi-IP Server Mode ---
apply_multi_ip_mode() {
    echo -e "\n${BOLD}=== [Option 2] Configuring Multi-IP Server Mode ===${NC}"
    if [[ "${IP_COUNT}" -lt 2 ]]; then
        log_warn "Only ${IP_COUNT} public IP detected (${PUBLIC_IPS[0]:-none}). Switching to Single-IP optimization..."
        apply_single_ip_mode
        return
    fi

    ask_udp_port
    install_dependencies
    save_original_state

    echo -e "\n${BLUE}[i] Detected ${IP_COUNT} Public IPv4 addresses on ${DEF_IFACE}:${NC}"
    for i in "${!PUBLIC_IPS[@]}"; do
        echo -e "    $((i+1))) ${PUBLIC_IPS[$i]}"
    done

    read -rp "$(echo -e "${CYAN}[?] Select which IP should act as the Primary Native IP [1-${IP_COUNT}, default: 1 (${PUBLIC_IPS[0]})]: ${NC}")" pri_choice
    local pri_idx=0
    if [[ -n "${pri_choice}" && "${pri_choice}" =~ ^[0-9]+$ ]] && (( pri_choice >= 1 && pri_choice <= IP_COUNT )); then
        pri_idx=$((pri_choice - 1))
    fi

    PRIMARY_IP="${PUBLIC_IPS[$pri_idx]}"
    local sec_list=()
    for i in "${!PUBLIC_IPS[@]}"; do
        if [[ "${i}" -ne "${pri_idx}" ]]; then
            sec_list+=("${PUBLIC_IPS[$i]}")
        fi
    done
    SECONDARY_IPS="${sec_list[*]}"
    MODE_APPLIED="MULTI_IP"

    cat << EOF > "${ACTIVE_CONF}"
MODE_APPLIED="${MODE_APPLIED}"
DEF_IFACE="${DEF_IFACE}"
DEF_GW="${DEF_GW}"
WG_PORT="${WG_PORT}"
BASE_RELAY_PORT="${BASE_RELAY_PORT}"
PRIMARY_IP="${PRIMARY_IP}"
SECONDARY_IPS="${SECONDARY_IPS}"
EOF

    log_info "Applying Primary Route (${PRIMARY_IP}) + Isolated Socat Relays for Secondary IPs (${SECONDARY_IPS})..."
    create_systemd_persistence
    log_success "Multi-IP Active-Active Symmetric Routing configured and enabled at boot."
    print_final_report
}

# --- 10. Option 3: Rollback & Clean Restore ---
rollback_changes() {
    echo -e "\n${BOLD}=== [Option 3] Rolling Back Script Changes ===${NC}"

    log_info "Removing ONLY custom chains (${CHAIN_PRE}, ${CHAIN_POST}) and stopping script relays..."
    if systemctl is-active --quiet wgmipfixer.service 2>/dev/null; then
        systemctl stop wgmipfixer.service 2>/dev/null || true
    fi
    if systemctl is-enabled --quiet wgmipfixer.service 2>/dev/null; then
        systemctl disable wgmipfixer.service 2>/dev/null || true
    fi

    clean_script_rules_only
    rm -f "${SERVICE_FILE}" "${WORKER_SCRIPT}" "${ACTIVE_CONF}"
    systemctl daemon-reload 2>/dev/null || true
    log_success "Custom iptables chains and systemd service removed. Other firewall rules were NOT touched."

    if [[ -f "${BACKUP_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${BACKUP_FILE}"
        log_info "Restoring original kernel routing and rp_filter settings from backup..."

        sysctl -w "net.ipv4.conf.all.rp_filter=${ORIG_RP_ALL:-1}" >/dev/null 2>&1 || true
        sysctl -w "net.ipv4.conf.default.rp_filter=${ORIG_RP_DEF:-1}" >/dev/null 2>&1 || true
        if [[ -n "${ORIG_IFACE:-}" ]]; then
            sysctl -w "net.ipv4.conf.${ORIG_IFACE}.rp_filter=${ORIG_RP_IFACE:-1}" >/dev/null 2>&1 || true
        fi

        if [[ -n "${ORIG_GW:-}" && -n "${ORIG_IFACE:-}" ]]; then
            if [[ -n "${ORIG_ROUTE_SRC:-}" ]]; then
                ip route replace default via "${ORIG_GW}" dev "${ORIG_IFACE}" src "${ORIG_ROUTE_SRC}" 2>/dev/null || true
            else
                ip route replace default via "${ORIG_GW}" dev "${ORIG_IFACE}" 2>/dev/null || true
            fi
        fi

        rm -f "${BACKUP_FILE}"
        log_success "Original kernel route and sysctl parameters restored."
    else
        log_warn "No backup state file found (${BACKUP_FILE}). Kernel default route left as-is."
    fi

    ip route flush cache 2>/dev/null || true
    conntrack -F 2>/dev/null || true

    echo -e "\n${GREEN}======================================================================${NC}"
    echo -e "${BOLD}                 ROLLBACK COMPLETED SUCCESSFULLY                      ${NC}"
    echo -e "${GREEN}======================================================================${NC}"
    echo -e "  * Custom NAT Chains (${CHAIN_PRE} / ${CHAIN_POST}): ${RED}DELETED${NC}"
    echo -e "  * Socat UDP Relay Processes:                  ${RED}TERMINATED${NC}"
    echo -e "  * Systemd Persistence Service:                ${RED}REMOVED${NC}"
    echo -e "  * Existing Third-Party Firewall Rules:        ${GREEN}UNTOUCHED (SAFE)${NC}"
    echo -e "  * Current Default Route:"
    echo -e "    ${CYAN}$(ip -4 route show default | head -n1)${NC}"
    echo -e "${GREEN}======================================================================${NC}\n"
}

# --- 11. Execution Summary Report ---
print_final_report() {
    detect_environment
    echo -e "\n${GREEN}======================================================================${NC}"
    echo -e "${BOLD}                 EXECUTION & DIAGNOSTIC REPORT                        ${NC}"
    echo -e "${GREEN}======================================================================${NC}"
    echo -e "  ${BOLD}Applied Mode:${NC}          ${CYAN}${MODE_APPLIED}${NC}"
    echo -e "  ${BOLD}Network Interface:${NC}     ${DEF_IFACE}"
    echo -e "  ${BOLD}Default Gateway:${NC}       ${DEF_GW}"
    echo -e "  ${BOLD}Target UDP Port:${NC}       ${WG_PORT}"
    echo -e "  ${BOLD}Kernel Default Route:${NC}  $(ip -4 route show default | head -n1)"
    echo -e "  ${BOLD}Systemd Boot Service:${NC}  $(systemctl is-active wgmipfixer.service 2>/dev/null) (enabled)"
    echo -e "----------------------------------------------------------------------"
    echo -e "  ${BOLD}IP Routing Breakdown:${NC}"
    echo -e "    [Primary]   ${GREEN}${PRIMARY_IP}:${WG_PORT}${NC} -> Handled natively via Kernel Default Route"

    if [[ "${MODE_APPLIED}" == "MULTI_IP" && -n "${SECONDARY_IPS:-}" ]]; then
        local r_port="${BASE_RELAY_PORT}"
        for s_ip in ${SECONDARY_IPS}; do
            r_port=$((r_port + 1))
            local s_pid
            s_pid=$(pgrep -f "socat.*UDP4-LISTEN:${r_port},bind=${s_ip}" | head -n1 || echo "N/A")
            echo -e "    [Secondary] ${GREEN}${s_ip}:${WG_PORT}${NC} -> DNAT to ${s_ip}:${r_port} (Socat PID: ${s_pid})"
        done
    fi

    echo -e "----------------------------------------------------------------------"
    echo -e "  ${BOLD}Isolated Iptables Rules (${CHAIN_PRE} & ${CHAIN_POST}):${NC}"
    iptables -t nat -S "${CHAIN_PRE}" 2>/dev/null | sed 's/^/    /'
    iptables -t nat -S "${CHAIN_POST}" 2>/dev/null | sed 's/^/    /'
    echo -e "----------------------------------------------------------------------"
    echo -e "  ${BOLD}Live Verification Command:${NC}"
    echo -e "    ${YELLOW}sudo tcpdump -ni ${DEF_IFACE} udp port ${WG_PORT}${NC}"
    echo -e "${GREEN}======================================================================${NC}\n"
}

# --- 12. Interactive CLI Menu ---
show_menu() {
    detect_environment
    clear
    echo -e "${CYAN}======================================================================${NC}"
    echo -e "${BOLD}       WireGuard & UDP Tunnel Symmetric Routing Fixer (v1.0)          ${NC}"
    echo -e "${CYAN}======================================================================${NC}"
    echo -e "  ${BOLD}Detected Interface:${NC}  ${GREEN}${DEF_IFACE:-Unknown}${NC}"
    echo -e "  ${BOLD}Default Gateway:${NC}     ${GREEN}${DEF_GW:-Unknown}${NC}"
    echo -e "  ${BOLD}Public IPv4 Count:${NC}   ${GREEN}${IP_COUNT}${NC} (${PUBLIC_IPS[*]:-None})"
    echo -e "  ${BOLD}Default Route Src:${NC}   ${YELLOW}${CURR_ROUTE_SRC:-Not Set (System Default)}${NC}"
    echo -e "  ${BOLD}Target UDP Port:${NC}     ${CYAN}${WG_PORT}${NC}"
    echo -e "  ${BOLD}Fixer Status:${NC}        ${SERVICE_STATUS}"
    echo -e "${CYAN}----------------------------------------------------------------------${NC}"
    echo -e "  ${BOLD}1)${NC} Server with 1 IP      (Optimize & Lock Outbound Source IP)"
    echo -e "  ${BOLD}2)${NC} Server with Multi-IP  (Active-Active Symmetric Routing for All IPs)"
    echo -e "  ${BOLD}3)${NC} Rollback & Restore    (Revert to previous state & remove ONLY script rules)"
    echo -e "  ${BOLD}0)${NC} Exit"
    echo -e "${CYAN}======================================================================${NC}"
    read -rp "$(echo -e "${BOLD}Select an option [0-3]: ${NC}")" choice

    case "${choice}" in
        1) apply_single_ip_mode ;;
        2) apply_multi_ip_mode ;;
        3) rollback_changes ;;
        0) echo -e "${GREEN}Exiting. Goodbye!${NC}"; exit 0 ;;
        *) log_error "Invalid option '${choice}'. Please select 0, 1, 2, or 3."; exit 1 ;;
    esac
}

# --- Entrypoint ---
show_menu
