#!/usr/bin/env bash
# ==============================================================================
# repair_network.sh - macOS Network & DNS Socket Repair Tool
# ==============================================================================
# Resolves mDNSResponder socket stalls (EINVAL 22), stale interface bindings,
# corrupt DNS search domains, and connectivity drops (e.g. after VPN/FortiClient
# disconnects) on Wi-Fi, Ethernet, and other macOS network services.
#
# Run with -h/--help for full usage, or --list to see available services.
# ==============================================================================
#
# DEPENDENCIES
# ------------
# OS:        macOS only since macOS-specific tools (networksetup,
#            dscacheutil, mDNSResponder) are required.
# Shell:     Bash 3.2 or later (the version macOS ships by default). No
#            Bash 4+ features (e.g. associative arrays, mapfile) are used.
# Commands (expected to already be present on a stock macOS install):
#   - networksetup   : list/query services, configure DNS, search domains,
#                       toggle Wi-Fi power, enable/disable network services
#   - dscacheutil     : flush the local DNS cache
#   - killall         : send SIGHUP to mDNSResponder (or force-kill on failure)
#   - ifconfig        : check link status/assigned IPv4 address per interface
#   - grep            : match command output (link status, gateway, etc.)
#   - awk             : parse `ifconfig`/`networksetup` output
#   - python3         : used for DNS resolution checks via the `socket` module
#                        (no third-party packages required)
#   - sudo            : optional; used if available/interactive to flush the
#                        system-level DNS cache and restart mDNSResponder.
#                        Script degrades gracefully to user-level operations
#                        without it.
#
# ENVIRONMENT VARIABLES (optional overrides)
# -------------------------------------------
#   PRIMARY_DNS   - list of DNS server IPs, separated by commas and/or
#                   whitespace
#                   default: 1.1.1.1,8.8.8.8,1.0.0.1,8.8.4.4
#   TEST_DOMAINS  - list of domains to verify resolution against, separated
#                   by commas and/or whitespace
#                   default: github.com,google.com,apple.com,api.github.com
#
# ==============================================================================
set -e

: "${PRIMARY_DNS:=1.1.1.1,8.8.8.8,1.0.0.1,8.8.4.4}"
: "${TEST_DOMAINS:=github.com,google.com,apple.com,api.github.com}"

_normalize_list() {
	# Collapses any run of commas and/or whitespace into a single comma, and
	# trims a leading/trailing comma. Used for PRIMARY_DNS / TEST_DOMAINS,
	# whose individual entries never contain whitespace themselves.
	local norm
	norm=$(printf '%s' "$1" | tr -s ' \t,' ',')
	norm="${norm#,}"
	norm="${norm%,}"
	printf '%s' "$norm"
}
IFS=',' read -r -a PRIMARY_DNS <<<"$(_normalize_list "$PRIMARY_DNS")"
IFS=',' read -r -a TEST_DOMAINS <<<"$(_normalize_list "$TEST_DOMAINS")"

# ------------------------------------------------------------------------
# Help / usage
# ------------------------------------------------------------------------
usage() {
	cat <<'EOF'
repair_network.sh - macOS Network & DNS Socket Repair Tool

Resolves mDNSResponder socket stalls (EINVAL 22), stale interface bindings,
corrupt DNS search domains, and connectivity drops (e.g. after VPN/FortiClient
disconnects) on Wi-Fi, Ethernet, and other macOS network services.

USAGE
    repair_network.sh [OPTIONS] [SERVICE...]

OPTIONS
    -h, --help
            Show this help message and exit.

    -l, --list
            List all macOS network services (Wi-Fi, Ethernet, and others)
            along with their device name, hardware port type, enabled/
            disabled state, link status, and current IPv4 address, then
            exit without repairing anything. Use this to find the exact
            name to pass to --service.

    -a, --all
            Repair every enabled Wi-Fi and Ethernet-type network service
            instead of just one. Cannot be combined with --service or
            trailing SERVICE arguments.

    -s, --service NAME
            Repair a specific network service by name, exactly as shown by
            --list (e.g. "Wi-Fi", "Ethernet", "Thunderbolt Ethernet"). May
            be given more than once, or as a single comma-separated value
            (e.g. --service "Wi-Fi,Ethernet"). Names may contain spaces, so
            multiple names in one value must be comma-separated, not
            space-separated.

SERVICE
    One or more trailing network service names to repair, equivalent to
    --service.

DEFAULT BEHAVIOR
    With no options, the script auto-detects which service to repair:
      - If an enabled Ethernet-type service (Ethernet, Thunderbolt Ethernet,
        a USB/LAN adapter, etc.) has an active link, that service is used.
      - Otherwise, the "Wi-Fi" service is used.
    Run with --list to see what would be picked, marked in the output.

ENVIRONMENT VARIABLES
    PRIMARY_DNS    List of DNS server IPs to configure, separated by commas
                   and/or whitespace.
                   Default: 1.1.1.1, 8.8.8.8, 1.0.0.1, 8.8.4.4
    TEST_DOMAINS   List of domains used to verify DNS resolution after the
                   repair, separated by commas and/or whitespace.
                   Default: github.com, google.com, apple.com, api.github.com

EXAMPLES
    repair_network.sh                         # auto-detect Ethernet or Wi-Fi
    repair_network.sh --list                  # show all services and exit
    repair_network.sh -s Ethernet             # repair only Ethernet
    repair_network.sh --service "Wi-Fi,Ethernet"
    repair_network.sh --all                   # repair every active service
    PRIMARY_DNS="9.9.9.9,149.112.112.112" repair_network.sh -s Wi-Fi

EXIT STATUS
    0   All targeted services were reconfigured and all TEST_DOMAINS resolved.
    1   A configuration/argument error occurred, or one or more TEST_DOMAINS
        failed to resolve after the repair.
EOF
}

# ------------------------------------------------------------------------
# Service discovery
# ------------------------------------------------------------------------
# Populates parallel arrays (no associative arrays, for Bash 3.2 compat):
#   SVC_NAMES[i]   - network service name (as used by `networksetup`)
#   SVC_DEVICES[i] - BSD device name (e.g. en0), empty if none
#   SVC_PORTS[i]   - hardware port type (e.g. "Wi-Fi", "Ethernet")
#   SVC_ENABLED[i] - 0 if enabled, 1 if disabled
_collect_services() {
	SVC_NAMES=()
	SVC_DEVICES=()
	SVC_PORTS=()
	SVC_ENABLED=()
	local line name disabled
	name=""
	disabled=0
	while IFS= read -r line; do
		if [[ "$line" =~ ^\([0-9]+\)\ (.+)$ ]]; then
			name="${BASH_REMATCH[1]}"
			if [[ "$name" == \** ]]; then
				disabled=1
				name="${name#\*}"
			else
				disabled=0
			fi
		elif [[ "$line" =~ Hardware\ Port:\ ([^,]+),\ Device:\ ([^,\)]+) ]]; then
			[[ -n "$name" ]] || continue
			SVC_NAMES+=("$name")
			SVC_PORTS+=("${BASH_REMATCH[1]}")
			SVC_DEVICES+=("${BASH_REMATCH[2]}")
			SVC_ENABLED+=("$disabled")
			name=""
		fi
	done < <(networksetup -listnetworkserviceorder 2>/dev/null)
}

_is_wifi_port() {
	local port=" $1 "
	shopt -s nocasematch
	local rc=1
	if [[ "$port" =~ wi-?fi ]] || [[ "$port" =~ airport ]]; then
		rc=0
	fi
	shopt -u nocasematch
	return $rc
}

_is_ethernet_port() {
	local port=" $1 "
	shopt -s nocasematch
	local rc=1
	if [[ "$port" =~ ethernet ]] || [[ "$port" =~ [[:space:]]lan[[:space:]] ]]; then
		rc=0
	fi
	shopt -u nocasematch
	return $rc
}

# Prints the service name that should be used when none was specified.
# Prefers an active (linked) Ethernet-type service; falls back to Wi-Fi.
_pick_default_service() {
	local i
	for ((i = 0; i < ${#SVC_NAMES[@]}; i++)); do
		if [[ "${SVC_ENABLED[$i]}" == "0" ]] && _is_ethernet_port "${SVC_PORTS[$i]}"; then
			if [[ -n "${SVC_DEVICES[$i]}" ]] && ifconfig "${SVC_DEVICES[$i]}" 2>/dev/null | grep -q "status: active"; then
				printf '%s' "${SVC_NAMES[$i]}"
				return 0
			fi
		fi
	done
	for ((i = 0; i < ${#SVC_NAMES[@]}; i++)); do
		if _is_wifi_port "${SVC_PORTS[$i]}"; then
			printf '%s' "${SVC_NAMES[$i]}"
			return 0
		fi
	done
	return 1
}

cmd_list() {
	_collect_services
	local default_name
	default_name=$(_pick_default_service || true)
	printf '%-24s %-8s %-22s %-9s %-6s %s\n' "SERVICE" "DEVICE" "HARDWARE PORT" "STATUS" "LINK" "IPV4"
	local i
	for ((i = 0; i < ${#SVC_NAMES[@]}; i++)); do
		local svc="${SVC_NAMES[$i]}" dev="${SVC_DEVICES[$i]}" port="${SVC_PORTS[$i]}"
		local status_label="enabled" link="down" ip="-" mark=" "
		[[ "${SVC_ENABLED[$i]}" == "1" ]] && status_label="disabled"
		if [[ -n "$dev" ]]; then
			ifconfig "$dev" 2>/dev/null | grep -q "status: active" && link="up"
			ip=$(ifconfig "$dev" 2>/dev/null | awk '/inet /{print $2; exit}')
			[[ -z "$ip" ]] && ip="-"
		fi
		[[ "$svc" == "$default_name" ]] && mark="*"
		printf '%s%-23s %-8s %-22s %-9s %-6s %s\n' "$mark" "$svc" "${dev:--}" "$port" "$status_label" "$link" "$ip"
	done
	if [[ -n "$default_name" ]]; then
		echo
		echo "* = service that would be repaired by default (no --service/--all given)"
	fi
}

# ------------------------------------------------------------------------
# Repair actions
# ------------------------------------------------------------------------
_repair_service() {
	local svc="$1" device="$2" port="$3"

	echo "▶ Configuring DNS servers on '${svc}'${device:+ (${device})}..."
	networksetup -setsearchdomains "$svc" "Empty" 2>/dev/null || true
	networksetup -setdnsservers "$svc" "${PRIMARY_DNS[@]}" 2>/dev/null || true
	echo "  ✔ Configured DNS: ${PRIMARY_DNS[*]}"

	if [[ -z "$device" ]]; then
		echo "  ℹ No hardware device associated with '${svc}'; skipping interface cycle."
		return 0
	fi

	if _is_wifi_port "$port"; then
		echo "▶ Cycling Wi-Fi interface '${device}' to clear stale kernel socket bindings..."
		networksetup -setairportpower "$device" off
		sleep 2
		networksetup -setairportpower "$device" on
	else
		echo "▶ Cycling network service '${svc}' (${device}) to clear stale kernel socket bindings..."
		networksetup -setnetworkserviceenabled "$svc" off
		sleep 2
		networksetup -setnetworkserviceenabled "$svc" on
	fi

	echo "▶ Waiting for '${svc}' link to re-establish..."
	local i
	for i in {1..20}; do
		if ifconfig "$device" 2>/dev/null | grep -q "status: active" && ifconfig "$device" 2>/dev/null | grep -q "inet "; then
			sleep 2
			break
		fi
		sleep 1
	done
}

# ------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------
ACTION="repair"
MODE="auto" # auto | all | explicit
RAW_SERVICE_ARGS=()

while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --help)
		usage
		exit 0
		;;
	-l | --list)
		ACTION="list"
		shift
		;;
	-a | --all)
		MODE="all"
		shift
		;;
	-s | --service)
		[[ -n "${2:-}" ]] || {
			echo "Error: $1 requires an argument" >&2
			exit 1
		}
		RAW_SERVICE_ARGS+=("$2")
		shift 2
		;;
	--service=*)
		RAW_SERVICE_ARGS+=("${1#*=}")
		shift
		;;
	--)
		shift
		while [[ $# -gt 0 ]]; do
			RAW_SERVICE_ARGS+=("$1")
			shift
		done
		;;
	-*)
		echo "Unknown option: $1" >&2
		echo >&2
		usage >&2
		exit 1
		;;
	*)
		RAW_SERVICE_ARGS+=("$1")
		shift
		;;
	esac
done

if [[ "$ACTION" == "list" ]]; then
	cmd_list
	exit 0
fi

# Split each raw argument on commas only (service names may contain spaces),
# trimming surrounding whitespace from each resulting token.
FINAL_SERVICES=()
for entry in "${RAW_SERVICE_ARGS[@]}"; do
	IFS=',' read -r -a _tokens <<<"$entry"
	for tok in "${_tokens[@]}"; do
		tok="${tok#"${tok%%[![:space:]]*}"}"
		tok="${tok%"${tok##*[![:space:]]}"}"
		[[ -n "$tok" ]] && FINAL_SERVICES+=("$tok")
	done
done

if [[ "$MODE" == "all" && ${#FINAL_SERVICES[@]} -gt 0 ]]; then
	echo "Error: cannot combine --all with --service or SERVICE arguments." >&2
	exit 1
fi

_collect_services

TARGET_INDEXES=()
if [[ "$MODE" == "all" ]]; then
	for ((i = 0; i < ${#SVC_NAMES[@]}; i++)); do
		if [[ "${SVC_ENABLED[$i]}" == "0" ]] && { _is_wifi_port "${SVC_PORTS[$i]}" || _is_ethernet_port "${SVC_PORTS[$i]}"; }; then
			TARGET_INDEXES+=("$i")
		fi
	done
	if [[ ${#TARGET_INDEXES[@]} -eq 0 ]]; then
		echo "Error: no enabled Wi-Fi or Ethernet services found to repair." >&2
		exit 1
	fi
elif [[ ${#FINAL_SERVICES[@]} -gt 0 ]]; then
	for want in "${FINAL_SERVICES[@]}"; do
		found=-1
		for ((i = 0; i < ${#SVC_NAMES[@]}; i++)); do
			if [[ "${SVC_NAMES[$i]}" == "$want" ]]; then
				found=$i
				break
			fi
		done
		if [[ $found -eq -1 ]]; then
			shopt -s nocasematch
			for ((i = 0; i < ${#SVC_NAMES[@]}; i++)); do
				if [[ "${SVC_NAMES[$i]}" == "$want" ]]; then
					found=$i
					break
				fi
			done
			shopt -u nocasematch
		fi
		if [[ $found -eq -1 ]]; then
			echo "Error: no network service named '${want}' found. Run with --list to see available services." >&2
			exit 1
		fi
		TARGET_INDEXES+=("$found")
	done
else
	default_name=$(_pick_default_service) || {
		echo "Error: could not auto-detect a Wi-Fi or Ethernet service. Run with --list to see available services, or specify one with --service." >&2
		exit 1
	}
	for ((i = 0; i < ${#SVC_NAMES[@]}; i++)); do
		if [[ "${SVC_NAMES[$i]}" == "$default_name" ]]; then
			TARGET_INDEXES+=("$i")
			break
		fi
	done
fi

echo "🔧 Starting macOS network and DNS repair..."
target_list=""
for i in "${TARGET_INDEXES[@]}"; do
	target_list="${target_list}${SVC_NAMES[$i]}, "
done
echo "▶ Target service(s): ${target_list%, }"

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

# 3 & 4. Reconfigure DNS and cycle each targeted service
for i in "${TARGET_INDEXES[@]}"; do
	_repair_service "${SVC_NAMES[$i]}" "${SVC_DEVICES[$i]}" "${SVC_PORTS[$i]}"
done

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
