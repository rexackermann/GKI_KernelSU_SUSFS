#!/system/bin/sh
# Hotspot DNS Redirect - KernelSU/Magisk Service Script
# Forces all hotspot/tethering DNS traffic through the phone's local resolver,
# which respects /etc/hosts (AdAway, systemless hosts, etc.)
#
# Features:
#   - Redirects all DNS (port 53) from hotspot clients to local resolver
#   - Blocks DNS-over-TLS (port 853)
#   - Blocks direct access to known public DNS servers (Google, Cloudflare, etc.)
#   - Blocks known DNS-over-HTTPS (DoH) server IPs
#   - Auto-recovers when Android's netd flushes iptables rules
#   - OverlayFS compatible (no system modifications)

MODDIR="${0%/*}"
LOG="/data/local/tmp/hotspot-dns-redirect.log"
CHAIN="HOTSPOT_DNS"

# Known hotspot interface names across different devices/OEMs
HOTSPOT_IFACES="wlan1 ap0 swlan0 wlan2 softap0 rndis0 usb0 bt-pan"

# Known public DNS server IPs to block (prevents clients from hardcoding DNS)
PUBLIC_DNS_IPS="
8.8.8.8 8.8.4.4
1.1.1.1 1.0.0.1
9.9.9.9 149.112.112.112
208.67.222.222 208.67.220.220
64.6.64.6 64.6.65.6
185.228.168.168 185.228.169.168
76.76.19.19 76.223.122.150
94.140.14.14 94.140.15.15
"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$$] $1" >> "$LOG"
}

# Truncate log if it gets too big (>512KB)
truncate_log() {
    if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null)" -gt 524288 ]; then
        tail -100 "$LOG" > "${LOG}.tmp"
        mv "${LOG}.tmp" "$LOG"
    fi
}

# Clear old log on boot
echo "" > "$LOG"
log "=== Hotspot DNS Redirect v1.1.0 started ==="
log "Module dir: $MODDIR"

setup_chain() {
    local iface="$1"

    # Create custom chain if it doesn't exist
    iptables -t nat -N "$CHAIN" 2>/dev/null
    iptables -N "${CHAIN}_FWD" 2>/dev/null

    # Flush existing rules in our chains
    iptables -t nat -F "$CHAIN" 2>/dev/null
    iptables -F "${CHAIN}_FWD" 2>/dev/null

    # ──────────────────────────────────────────────────────
    # 1. REDIRECT: Force all DNS (port 53) to local resolver
    # ──────────────────────────────────────────────────────
    iptables -t nat -A "$CHAIN" -i "$iface" -p udp --dport 53 -j REDIRECT --to-port 53
    iptables -t nat -A "$CHAIN" -i "$iface" -p tcp --dport 53 -j REDIRECT --to-port 53

    # ──────────────────────────────────────────────────────
    # 2. BLOCK: DNS-over-TLS (port 853)
    # ──────────────────────────────────────────────────────
    iptables -A "${CHAIN}_FWD" -i "$iface" -p tcp --dport 853 -j REJECT --reject-with tcp-reset
    iptables -A "${CHAIN}_FWD" -i "$iface" -p udp --dport 853 -j REJECT

    # ──────────────────────────────────────────────────────
    # 3. BLOCK: Known public DNS servers (by IP)
    #    Prevents clients from hardcoding DNS like 8.8.8.8
    # ──────────────────────────────────────────────────────
    for dns_ip in $PUBLIC_DNS_IPS; do
        # Block port 53 to these IPs (redundant with redirect, but defense-in-depth)
        iptables -A "${CHAIN}_FWD" -i "$iface" -d "$dns_ip" -p udp --dport 53 -j REJECT
        iptables -A "${CHAIN}_FWD" -i "$iface" -d "$dns_ip" -p tcp --dport 53 -j REJECT

        # Block HTTPS (port 443) to these IPs — kills DNS-over-HTTPS (DoH)
        iptables -A "${CHAIN}_FWD" -i "$iface" -d "$dns_ip" -p tcp --dport 443 -j REJECT --reject-with tcp-reset
    done

    # ──────────────────────────────────────────────────────
    # 4. BLOCK: QUIC/HTTP3 to public DNS (DoH over UDP/443)
    # ──────────────────────────────────────────────────────
    for dns_ip in $PUBLIC_DNS_IPS; do
        iptables -A "${CHAIN}_FWD" -i "$iface" -d "$dns_ip" -p udp --dport 443 -j REJECT
    done

    # ──────────────────────────────────────────────────────
    # 5. BLOCK: ALL traffic to public DNS IPs (including ICMP/ping)
    #    Makes these IPs completely unreachable from hotspot clients
    # ──────────────────────────────────────────────────────
    for dns_ip in $PUBLIC_DNS_IPS; do
        iptables -A "${CHAIN}_FWD" -i "$iface" -d "$dns_ip" -j DROP
    done

    # Hook our chains into PREROUTING and FORWARD
    if ! iptables -t nat -C PREROUTING -j "$CHAIN" 2>/dev/null; then
        iptables -t nat -I PREROUTING -j "$CHAIN"
    fi
    if ! iptables -C FORWARD -j "${CHAIN}_FWD" 2>/dev/null; then
        iptables -I FORWARD -j "${CHAIN}_FWD"
    fi

    log "Applied full DNS lockdown on interface: $iface"
    log "  - Port 53 redirected to local resolver"
    log "  - Port 853 (DoT) blocked"
    log "  - Port 443 (DoH) blocked for known DNS IPs"
    log "  - $(echo $PUBLIC_DNS_IPS | wc -w) public DNS IPs blocked"
}

teardown_chain() {
    # Unhook from main chains
    iptables -t nat -D PREROUTING -j "$CHAIN" 2>/dev/null
    iptables -D FORWARD -j "${CHAIN}_FWD" 2>/dev/null

    # Flush and delete our chains
    iptables -t nat -F "$CHAIN" 2>/dev/null
    iptables -t nat -X "$CHAIN" 2>/dev/null
    iptables -F "${CHAIN}_FWD" 2>/dev/null
    iptables -X "${CHAIN}_FWD" 2>/dev/null

    log "Removed all DNS redirect rules"
}

is_rules_active() {
    iptables -t nat -C PREROUTING -j "$CHAIN" 2>/dev/null
}

get_active_hotspot_iface() {
    # Method 1: Check for known interface names that are UP
    for iface in $HOTSPOT_IFACES; do
        if ip link show "$iface" 2>/dev/null | grep -q "state UP"; then
            echo "$iface"
            return
        fi
    done

    # Method 2: Look for any interface with a typical hotspot IP range
    for iface in $(ip -o addr show 2>/dev/null | grep -E "192\.168\.(43|49|2|44|45)\." | awk '{print $2}'); do
        echo "$iface"
        return
    done

    # Method 3: Check tethering via USB (rndis)
    for iface in rndis0 usb0; do
        if ip link show "$iface" 2>/dev/null | grep -q "state UP\|state UNKNOWN"; then
            echo "$iface"
            return
        fi
    done
}

# ──────────────────────────────────────────────────────
# Main loop
# ──────────────────────────────────────────────────────

# Wait for boot to complete
sleep 20
log "Boot wait complete, starting monitor loop"

LAST_IFACE=""

while true; do
    CURRENT_IFACE=$(get_active_hotspot_iface)

    if [ -n "$CURRENT_IFACE" ]; then
        if [ "$CURRENT_IFACE" != "$LAST_IFACE" ]; then
            # New hotspot session or interface changed
            teardown_chain
            setup_chain "$CURRENT_IFACE"
            LAST_IFACE="$CURRENT_IFACE"
        elif ! is_rules_active; then
            # Same interface but rules got flushed by netd
            log "Rules flushed by netd, re-applying on $CURRENT_IFACE"
            setup_chain "$CURRENT_IFACE"
        fi
    else
        if [ -n "$LAST_IFACE" ]; then
            teardown_chain
            LAST_IFACE=""
            log "Hotspot deactivated, rules cleaned up"
        fi
    fi

    truncate_log
    sleep 5
done
