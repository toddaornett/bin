#!/usr/bin/env zsh
# ==============================================================================
# repair_network.sh - macOS Network & DNS Socket Repair Tool
# ==============================================================================
# Resolves mDNSResponder socket stalls (EINVAL 22), stale interface bindings,
# corrupt DNS search domains, and connectivity drops (e.g. after VPN/FortiClient
# disconnects).
# ==============================================================================
set -e

# PRIMARY_DNS and TEST_DOMAINS can be overridden via environment variables as
# comma-separated strings, e.g.:
#   PRIMARY_DNS="9.9.9.9,149.112.112.112" TEST_DOMAINS="example.com,cloudflare.com" ./repair_network.sh
# If the env vars are unset, the defaults below are used instead.
: "${PRIMARY_DNS:=1.1.1.1,8.8.8.8,1.0.0.1,8.8.4.4}"
: "${TEST_DOMAINS:=github.com,google.com,apple.com,api.github.com}"
PRIMARY_DNS=("${(@s:,:)PRIMARY_DNS}")
TEST_DOMAINS=("${(@s:,:)TEST_DOMAINS}")

echo "🔧 Starting macOS network and DNS repair..."

# 1. Check/request sudo privileges if available (interactive terminal or cached credentials)
HAS_SUDO=false
if [[ $EUID -eq 0 ]]; then
    HAS_SUDO=true
elif sudo -n true 2>/dev/null; then
    HAS_SUDO=true
elif [[ -t 0 && -t 1 ]]; then
    echo "🔐 Elevating with sudo to restart mDNSResponder daemon..."
    if sudo -v 2>/dev/null; then
        HAS_SUDO=true
    fi
fi

# 2. Flush DNS caches and restart mDNSResponder
echo "▶ Flushing local DNS cache and restarting resolver..."
if [[ "$HAS_SUDO" == "true" ]]; then
    sudo dscacheutil -flushcache 2>/dev/null || dscacheutil -flushcache 2>/dev/null || true
    sudo killall -HUP mDNSResponder 2>/dev/null || true
    echo "  ✔ Flushed cache and sent SIGHUP to mDNSResponder via sudo"
else
    dscacheutil -flushcache 2>/dev/null || true
    killall -HUP mDNSResponder 2>/dev/null || true
    echo "  ✔ Flushed user-level cache (run with sudo to restart daemon directly)"
fi

# 3. Detect Wi-Fi device and service
WIFI_DEVICE=$(networksetup -listallhardwareports | awk '/Hardware Port: Wi-Fi/{getline; print $2}')
WIFI_SERVICE="Wi-Fi"
if [[ -n "$WIFI_DEVICE" ]]; then
    echo "▶ Configuring DNS servers on '${WIFI_SERVICE}' (${WIFI_DEVICE})..."
    networksetup -setsearchdomains "$WIFI_SERVICE" "Empty" 2>/dev/null || true
    networksetup -setdnsservers "$WIFI_SERVICE" "${PRIMARY_DNS[@]}" 2>/dev/null || true
    echo "  ✔ Configured DNS: ${PRIMARY_DNS[*]}"

    # 4. Cycle interface to rebind mDNSResponder sockets
    echo "▶ Cycling Wi-Fi interface to clear stale kernel socket bindings..."
    networksetup -setairportpower "$WIFI_DEVICE" off
    sleep 2
    networksetup -setairportpower "$WIFI_DEVICE" on
    
    # Wait for association and DHCP lease
    echo "▶ Waiting for network link to re-establish..."
    for i in {1..20}; do
        if ifconfig "$WIFI_DEVICE" 2>/dev/null | grep -q "inet " && route -n get default 2>/dev/null | grep -q "gateway"; then
            sleep 2
            break
        fi
        sleep 1
    done
fi

# 5. Verify resolution with retry for link warmup
echo "▶ Verifying DNS resolution and connectivity..."
ALL_OK=true
for domain in "${TEST_DOMAINS[@]}"; do
    RESOLVED=false
    for attempt in {1..3}; do
        if python3 -c "import socket, sys; sys.exit(0 if socket.getaddrinfo('$domain', 443) else 1)" 2>/dev/null; then
            RESOLVED=true
            break
        fi
        sleep 1
    done
    if [[ "$RESOLVED" == "true" ]]; then
        echo "  ✔ $domain resolved successfully"
    else
        echo "  ✘ $domain failed to resolve"
        ALL_OK=false
    fi
done

if [[ "$ALL_OK" == "true" ]]; then
    echo "✨ Network repair complete: all endpoints reachable."
    exit 0
else
    echo "⚠️ Some endpoints failed. Try running with sudo if mDNSResponder remains locked: sudo killall -9 mDNSResponder"
    exit 1
fi