#!/usr/bin/env bash
# ==============================================================================
# repair_network.sh - macOS Network & DNS Socket Repair Tool
# by Todd Ornett <toddgh@acquirus.com>
# Created: September 1, 2026
# Modified: October 27, 2026
# Version: 0.1.0
# Homepage: https://github.com/toddaornett/bin
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
# OS:        macOS only, since macOS-specific tools (networksetup,
#            dscacheutil, mDNSResponder, configd, scutil, route, ipconfig) are
#            required.
# Shell:     Bash 3.2 or later (the version macOS ships by default).
# Commands (expected to already be present on a stock macOS install):
#   - networksetup   : list/query services, configure DNS, search domains,
#                       toggle Wi-Fi power, enable/disable network services
#   - dscacheutil     : flush the local DNS cache (needs root to do anything)
#   - killall         : send SIGHUP to mDNSResponder / configd (needs root)
#   - ifconfig        : check link status/assigned IPv4 address per interface
#   - ipconfig        : renew a DHCP lease when an interface comes back empty
#   - route           : inspect the default route (gateway and interface)
#   - scutil          : read the resolver list actually in effect
#   - dig             : optional; asks a specific DNS server directly to tell a
#                        broken name apart from an intercepted/missing resolver
#   - python3         : DNS + TCP/TLS probing (stdlib only; no pip packages)
#   - sudo            : optional; needed to reload the resolver, renew DHCP
#                        leases, and (in hardened setups) change DNS. The script
#                        degrades gracefully and says exactly what it skipped.
#   - osascript       : optional; --elevate uses it for a GUI admin prompt when
#                        there is no terminal (hotkey/Hammerspoon launchers).
#   - open / pgrep    : optional; --restart-app uses them.
#
# ENVIRONMENT VARIABLES (optional overrides)
# -------------------------------------------
#   PRIMARY_DNS   - list of DNS server IPs, separated by commas and/or
#                   whitespace
#                   default: 1.1.1.1,8.8.8.8,1.0.0.1,8.8.4.4
#   TEST_DOMAINS  - list of domains to verify resolution against, separated
#                   by commas and/or whitespace
#                   default: github.com,google.com,apple.com,api.github.com,
#                            cursor.com,api2.cursor.sh,grok.com
#
# ==============================================================================
set -e

PROG=${0##*/}
VERSION=0.1.0

# ------------------------------------------------------------------------
# Configuration and validation
# ------------------------------------------------------------------------
PRIMARY_DNS_RAW=${PRIMARY_DNS:-1.1.1.1,8.8.8.8,1.0.0.1,8.8.4.4}
TEST_DOMAINS_RAW=${TEST_DOMAINS:-github.com,google.com,apple.com,api.github.com,cursor.com,api2.cursor.sh,grok.com}

# One entry per line; comma and/or whitespace separated input, blanks dropped.
_list_lines() {
  printf '%s' "$1" | tr -s ' \t,' '\n\n\n' | sed '/^[[:space:]]*$/d'
}

PRIMARY_DNS=()
while IFS= read -r _line; do
  if [[ -n "$_line" ]]; then PRIMARY_DNS+=("$_line"); fi
done <<<"$(_list_lines "$PRIMARY_DNS_RAW")"

TEST_DOMAINS=()
while IFS= read -r _line; do
  if [[ -n "$_line" ]]; then TEST_DOMAINS+=("$_line"); fi
done <<<"$(_list_lines "$TEST_DOMAINS_RAW")"

_is_ipv4() {
  local ip="$1" octet
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  local IFS=.
  for octet in $ip; do
    if ((10#$octet > 255)); then return 1; fi
  done
  return 0
}

_is_domain_name() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]
}

_validate_config() {
  local entry
  if [[ ${#PRIMARY_DNS[@]} -eq 0 ]]; then
    echo "Error: PRIMARY_DNS is empty; it must list at least one IPv4 address." >&2
    exit 1
  fi
  for entry in "${PRIMARY_DNS[@]}"; do
    if ! _is_ipv4 "$entry"; then
      echo "Error: PRIMARY_DNS entry '${entry}' is not a valid IPv4 address." >&2
      exit 1
    fi
  done
  if [[ ${#TEST_DOMAINS[@]} -eq 0 ]]; then
    echo "Error: TEST_DOMAINS is empty; it must list at least one domain." >&2
    exit 1
  fi
  for entry in "${TEST_DOMAINS[@]}"; do
    if ! _is_domain_name "$entry"; then
      echo "Error: TEST_DOMAINS entry '${entry}' is not a valid domain name." >&2
      exit 1
    fi
  done
}

_validate_config

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required for DNS/connectivity probing but was not found in PATH." >&2
  exit 1
fi

# ------------------------------------------------------------------------
# Help / usage
# ------------------------------------------------------------------------
usage() {
  printf '%s %s - macOS Network & DNS Socket Repair Tool\n\n' "$PROG" "$VERSION"
  cat <<'EOF'
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

    --force-dns
            When a service's current DNS servers don't match PRIMARY_DNS,
            overwrite them without prompting. Without this flag, in an
            interactive terminal the script asks for confirmation before
            changing DNS; in a non-interactive context (e.g. cron) it
            leaves DNS untouched on mismatch unless this flag is given.

    --elevate
            When there is no terminal (hotkey, Hammerspoon, launcher), ask
            for administrator privileges through the standard macOS
            authorization dialog instead of silently skipping privileged
            steps. May prompt once per privileged step; each step is a
            reload/notify action, not a setting change.

    -f, --flush, --dns-only
            Only flush the DNS cache and reload the resolver
            (mDNSResponder and configd), then verify TEST_DOMAINS. Does not
            change DNS servers or cycle interfaces, so open connections
            (e.g. an active Grok Bot chat) stay up. Equivalent to
            "sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder;
            sudo killall -HUP configd" plus verification. Try this first
            when an app fails to refresh.

    --restart-app NAME
            After the requested repair/flush finishes, quit and reopen the
            named app (e.g. --restart-app "Grok Bot"). Use as a last resort
            when an app's own connection pool stays dead; this drops any
            in-flight requests in that app. Not available with --check-only.

    --check-only
            Only report state: each targeted service's DNS servers, the
            resolver actually in effect, the default route, and reachability
            of every TEST_DOMAIN over TCP/TLS 443. Changes nothing. Exits 1
            when a service's DNS doesn't match PRIMARY_DNS, when there is no
            default route, or when an endpoint is unreachable.

SERVICE
    One or more trailing network service names to repair, equivalent to
    --service.

DEFAULT BEHAVIOR
    With no options, the script auto-detects which service to repair:
      - If an enabled Ethernet-type service (Ethernet, Thunderbolt Ethernet,
        a USB/LAN adapter, etc.) has an active link, that service is used.
      - Otherwise, the "Wi-Fi" service is used.
    Run with --list to see what would be picked, marked in the output.

    DNS is only changed (permanently, via networksetup) when the service's
    current DNS servers don't already match PRIMARY_DNS. If they match,
    the script leaves DNS alone and just reports that. If they don't match
    and the script is running in an interactive terminal, you'll be asked
    to confirm; in a non-interactive context DNS is left alone unless
    --force-dns is given.

    Interfaces are cycled by powering the radio off/on (Wi-Fi) or by
    disabling and re-enabling the service (Ethernet). Cycling is what makes
    already-running apps notice the network changed. Power/enable state is
    restored even if the script is interrupted.

ENVIRONMENT VARIABLES
    PRIMARY_DNS    List of DNS server IPs to configure, separated by commas
                   and/or whitespace.
                   Default: 1.1.1.1, 8.8.8.8, 1.0.0.1, 8.8.4.4
    TEST_DOMAINS   List of domains used to verify DNS/TLS reachability after
                   the repair, separated by commas and/or whitespace.
                   Default: github.com, google.com, apple.com, api.github.com,
                   cursor.com, api2.cursor.sh, grok.com

EXAMPLES
    repair_network.sh                                 # auto-detect Ethernet or Wi-Fi
    repair_network.sh --list                          # show all services and exit
    repair_network.sh --flush                         # flush + reload resolver only
    repair_network.sh --flush --restart-app "Grok Bot"
    repair_network.sh -s Ethernet                     # repair only Ethernet
    repair_network.sh --service "Wi-Fi,Ethernet"
    repair_network.sh --all                           # repair every active service
    repair_network.sh --all --check-only              # audit every service
    repair_network.sh -s Wi-Fi --force-dns            # overwrite DNS without asking
    repair_network.sh --flush --elevate               # GUI admin prompt, no terminal
    PRIMARY_DNS="9.9.9.9,149.112.112.112" repair_network.sh -s Wi-Fi

EXIT STATUS
    0   All targeted services were reconfigured (as allowed) and all
        TEST_DOMAINS were reachable.
    1   A configuration/argument error occurred, an interface could not be
        restored, --check-only found a mismatch or unreachable endpoint, or
        one or more TEST_DOMAINS failed after the repair.
EOF
}

# ------------------------------------------------------------------------
# Service discovery
# ------------------------------------------------------------------------
# Populates parallel arrays (no associative arrays, for Bash 3.2 compat):
#   SVC_NAMES[i]   - network service name (as used by `networksetup`)
#   SVC_DEVICES[i] - BSD device name (e.g. en0), empty for VPN-style services
#   SVC_PORTS[i]   - hardware port type (e.g. "Wi-Fi", "Ethernet")
#   SVC_ENABLED[i] - 0 if enabled, 1 if disabled
_collect_services() {
  SVC_NAMES=()
  SVC_DEVICES=()
  SVC_PORTS=()
  SVC_ENABLED=()
  local order line name disabled port dev
  if ! order=$(networksetup -listnetworkserviceorder 2>/dev/null); then
    echo "Error: 'networksetup -listnetworkserviceorder' failed." >&2
    return 1
  fi
  name=""
  disabled=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^\([0-9]+\)[[:space:]]+(.+)$ ]]; then
      name="${BASH_REMATCH[1]}"
      if [[ "$name" == \** ]]; then
        disabled=1
        name="${name#\*}"
      else
        disabled=0
      fi
      name="${name%"${name##*[![:space:]]}"}"
    elif [[ "$line" =~ Hardware\ Port:\ ([^,]+),\ Device:\ ([^\)]*) ]]; then
      if [[ -z "$name" ]]; then continue; fi
      port="${BASH_REMATCH[1]}"
      dev="${BASH_REMATCH[2]}"
      dev="${dev%"${dev##*[![:space:]]}"}"
      SVC_NAMES+=("$name")
      SVC_PORTS+=("$port")
      SVC_DEVICES+=("$dev")
      SVC_ENABLED+=("$disabled")
      name=""
    fi
  done <<<"$order"
  if [[ ${#SVC_NAMES[@]} -eq 0 ]]; then
    echo "Error: networksetup reported no network services." >&2
    return 1
  fi
  return 0
}

_is_wifi_port() {
  local lower
  lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  [[ "$lower" == *wi-fi* || "$lower" == *wifi* || "$lower" == *airport* ]]
}

_is_ethernet_port() {
  local lower
  lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  [[ "$lower" == *ethernet* ]] || [[ "$lower" =~ (^|[^[:alpha:]])lan([^[:alpha:]]|$) ]]
}

# Prints the service name that should be used when none was specified.
# Prefers an enabled, linked Ethernet-type service; falls back to enabled Wi-Fi.
_pick_default_service() {
  local i
  for ((i = 0; i < ${#SVC_NAMES[@]}; i++)); do
    if [[ "${SVC_ENABLED[$i]}" == "0" ]] && _is_ethernet_port "${SVC_PORTS[$i]}"; then
      if [[ -n "${SVC_DEVICES[$i]}" ]] && _iface_is_active "${SVC_DEVICES[$i]}"; then
        printf '%s' "${SVC_NAMES[$i]}"
        return 0
      fi
    fi
  done
  for ((i = 0; i < ${#SVC_NAMES[@]}; i++)); do
    if [[ "${SVC_ENABLED[$i]}" == "0" ]] && _is_wifi_port "${SVC_PORTS[$i]}"; then
      printf '%s' "${SVC_NAMES[$i]}"
      return 0
    fi
  done
  return 1
}

cmd_list() {
  if ! _collect_services; then
    exit 1
  fi
  local default_name i
  default_name=$(_pick_default_service || true)
  printf '%-24s %-8s %-36s %-9s %-6s %s\n' "SERVICE" "DEVICE" "HARDWARE PORT" "STATUS" "LINK" "IPV4"
  for ((i = 0; i < ${#SVC_NAMES[@]}; i++)); do
    local svc="${SVC_NAMES[$i]}" dev="${SVC_DEVICES[$i]}" port="${SVC_PORTS[$i]}"
    local status_label="enabled" link="down" ip="-" mark=" "
    if [[ "${SVC_ENABLED[$i]}" == "1" ]]; then status_label="disabled"; fi
    if [[ -n "$dev" ]]; then
      if _iface_is_active "$dev"; then link="up"; fi
      ip=$(_ipv4_of "$dev")
      if [[ -z "$ip" ]]; then ip="-"; fi
    fi
    if [[ -n "$default_name" && "$svc" == "$default_name" ]]; then mark="*"; fi
    printf '%s%-23s %-8s %-36s %-9s %-6s %s\n' "$mark" "$svc" "${dev:--}" "$port" "$status_label" "$link" "$ip"
  done
  if [[ -n "$default_name" ]]; then
    echo
    echo "* = service that would be repaired by default (no --service/--all given)"
  fi
}

# ------------------------------------------------------------------------
# Interface / route helpers
# ------------------------------------------------------------------------
_ipv4_of() {
  local ip
  ip=$(ifconfig "$1" 2>/dev/null | awk '/inet / { print $2; exit }') || ip=""
  printf '%s' "$ip"
}

_iface_is_active() {
  ifconfig "$1" 2>/dev/null | grep -q "status: active"
}

# True when the interface has a non-link-local IPv4. After a Wi-Fi power
# cycle macOS often reports status: active with inet 169.254.x.x (or a
# stale lease) before DHCP finishes; treating that as "up" makes the first
# TEST_DOMAINS lookup fail while later ones succeed.
_has_usable_ipv4() {
  local ip
  ip=$(_ipv4_of "$1")
  [[ -n "$ip" && "$ip" != 169.254.* && "$ip" != 127.* ]]
}

_default_route_gateway() {
  local gw
  gw=$(route -n get default 2>/dev/null | awk '/gateway:/ { print $2; exit }') || gw=""
  printf '%s' "$gw"
}

_default_route_iface() {
  local dev
  dev=$(route -n get default 2>/dev/null | awk '/interface:/ { print $2; exit }') || dev=""
  printf '%s' "$dev"
}

# Prints the nameservers of the first (default) resolver from scutil, i.e. the
# ones actually in effect rather than the ones configured on a service.
_effective_nameservers() {
  scutil --dns 2>/dev/null | awk '
    /^resolver #[0-9]+$/ { block++; next }
    block == 1 && /nameserver\[[0-9]+\]/ { print $3 }
  '
}

# ------------------------------------------------------------------------
# DNS comparison helpers
# ------------------------------------------------------------------------
# Prints the service's currently configured DNS servers, one per line,
# normalized to empty output if none are set (rather than networksetup's
# "There aren't any DNS Servers set on ..." sentence).
_get_current_dns() {
  local svc="$1" out
  out=$(networksetup -getdnsservers "$svc" 2>/dev/null) || out=""
  if [[ "$out" == "There aren't any DNS Servers set on"* ]]; then
    out=""
  fi
  printf '%s' "$out"
}

# Returns 0 if the service's current DNS servers match PRIMARY_DNS
# (compared as sorted sets, so order doesn't matter), 1 otherwise.
_dns_matches() {
  local current_sorted expected_sorted
  current_sorted=$(_get_current_dns "$1" | tr -s ' \t' '\n' | sed '/^$/d' | sort)
  expected_sorted=$(printf '%s\n' "${PRIMARY_DNS[@]}" | sort)
  [[ "$current_sorted" == "$expected_sorted" ]]
}

# ------------------------------------------------------------------------
# Probing (DNS + TCP/TLS 443)
# ------------------------------------------------------------------------
# One python3 process probes every domain concurrently and prints
# "domain<TAB>status<TAB>detail" lines. getaddrinfo() has no timeout of its
# own and can block for ~30s on a stalled resolver, so the whole probe has a
# hard deadline: unfinished domains are reported as dns-timeout and the
# process exits immediately (os._exit skips joining stuck threads).
_probe_domains() {
  local mode="$1"
  shift
  python3 - "$mode" "$@" <<'PYPROBE'
import concurrent.futures
import os
import socket
import ssl
import sys

mode = sys.argv[1]
domains = [d for d in sys.argv[2:] if d]
deadline = 6.0 if mode == "dns" else 8.0


def resolve(domain):
    try:
        infos = socket.getaddrinfo(domain, 443, socket.AF_INET, socket.SOCK_STREAM)
    except OSError as exc:
        return domain, "dns-fail", str(exc)
    addrs = []
    for info in infos:
        ip = info[4][0]
        if ip not in addrs:
            addrs.append(ip)
    if not addrs:
        return domain, "dns-fail", "no A records"
    return domain, "ok", ",".join(addrs)


def probe(domain):
    if mode == "dns":
        return resolve(domain)
    domain, status, detail = resolve(domain)
    if status != "ok":
        return domain, status, detail
    last_error = "no address reachable"
    for ip in detail.split(",")[:3]:
        try:
            raw = socket.create_connection((ip, 443), timeout=4)
        except OSError as exc:
            last_error = "%s: %s" % (ip, exc)
            continue
        try:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
            with context.wrap_socket(raw, server_hostname=domain) as tls:
                return domain, "ok", "%s %s" % (ip, tls.version())
        except OSError as exc:
            last_error = "%s: %s" % (ip, exc)
        finally:
            try:
                raw.close()
            except OSError:
                pass
    return domain, "tcp-fail", last_error


def report(result):
    domain, status, detail = result
    sys.stdout.write("%s\t%s\t%s\n" % (domain, status, " ".join(str(detail).split())))


if not domains:
    sys.exit(0)

pool = concurrent.futures.ThreadPoolExecutor(max_workers=min(8, len(domains)))
futures = {}
for domain in domains:
    futures[pool.submit(probe, domain)] = domain

done = set()
try:
    for future in concurrent.futures.as_completed(futures, timeout=deadline):
        domain = futures[future]
        done.add(domain)
        try:
            report(future.result())
        except Exception as exc:
            report((domain, "probe-error", str(exc)))
except concurrent.futures.TimeoutError:
    pass

for domain in domains:
    if domain not in done:
        report((domain, "dns-timeout", "no answer within %ds" % int(deadline)))

sys.stdout.flush()
os._exit(0)
PYPROBE
}

_probe_any_dns_ok() {
  _probe_domains dns "$@" 2>/dev/null |
    awk -F'\t' '$2 == "ok" { ok = 1 } END { exit(ok ? 0 : 1) }'
}

_wait_for_resolver() {
  local i
  echo "▶ Waiting for the resolver to answer..."
  for ((i = 0; i < 3; i++)); do
    if _probe_any_dns_ok "${TEST_DOMAINS[@]}"; then
      echo "  ✔ Resolver answering"
      return 0
    fi
    sleep 1
  done
  echo "  ⚠ No resolver answer within 3 attempts; continuing with per-endpoint retries."
  return 0
}

# Asks the configured DNS servers directly (plain UDP DNS, bypassing the
# macOS resolver) for names the system resolver could not handle. This tells a
# broken upstream apart from a stale/intercepted system resolver, which is the
# usual VPN-leftover failure mode.
_diagnose_resolver() {
  local domain out answers
  command -v dig >/dev/null 2>&1 || return 0
  [[ $# -gt 0 ]] || return 0
  echo "▶ Asking ${PRIMARY_DNS[0]} directly (bypassing the system resolver)..."
  for domain in "$@"; do
    out=$(dig +short +time=2 +tries=1 A "$domain" @"${PRIMARY_DNS[0]}" 2>/dev/null) || out=""
    answers=$(printf '%s' "$out" | head -3 | tr '\n' ' ')
    answers="${answers% }"
    if [[ -z "$answers" ]]; then
      echo "  ℹ ${domain}: ${PRIMARY_DNS[0]} gave no answer either; the name may be blocked or filtered upstream."
    elif [[ "$DNS_MISMATCH" == "true" ]]; then
      echo "  ℹ ${domain}: ${PRIMARY_DNS[0]} answers (${answers}) but the system resolver did not; service DNS needs rewriting (run without --flush)."
    else
      echo "  ℹ ${domain}: ${PRIMARY_DNS[0]} answers (${answers}) while the system resolver stalled; mDNSResponder itself is wedged, which the privileged flush in a full repair fixes."
    fi
  done
}

# ------------------------------------------------------------------------
# Privileges
# ------------------------------------------------------------------------
# Set when a service's DNS provably differs from PRIMARY_DNS, so failure
# diagnostics can point at the configured servers instead of the resolver.
DNS_MISMATCH=false

PRIV_MODE=none # none | sudo | osascript
SKIPPED_PRIV=false
ELEVATE=false

_priv_run() {
  local cmd="$1" escaped
  case "$PRIV_MODE" in
  sudo)
    sudo sh -c "$cmd"
    ;;
  osascript)
    escaped="${cmd//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    osascript -e "do shell script \"${escaped}\" with administrator privileges"
    ;;
  *)
    return 1
    ;;
  esac
}

_setup_privileges() {
  if [[ $EUID -eq 0 ]]; then
    PRIV_MODE=sudo
    echo "▶ Running as root."
    return 0
  fi
  if sudo -n true 2>/dev/null; then
    PRIV_MODE=sudo
    echo "▶ Using cached sudo credentials."
    return 0
  fi
  if [[ -t 0 && -t 1 ]]; then
    echo "🔐 Administrator privileges are needed to reload mDNSResponder/configd and to renew DHCP leases."
    if sudo -v; then
      PRIV_MODE=sudo
      return 0
    fi
    echo "  ↷ sudo was not granted; privileged steps will be skipped."
    SKIPPED_PRIV=true
    return 0
  fi
  if [[ "$ELEVATE" == "true" ]]; then
    if ! command -v osascript >/dev/null 2>&1; then
      echo "  ↷ --elevate needs osascript, which was not found; privileged steps will be skipped."
      SKIPPED_PRIV=true
      return 0
    fi
    echo "🔐 Requesting administrator privileges through the macOS authorization dialog."
    echo "   (one prompt per privileged step: cache flush, then final flush)"
    PRIV_MODE=osascript
    return 0
  fi
  echo "  ↷ No terminal and --elevate not given: privileged steps are skipped."
  SKIPPED_PRIV=true
  return 0
}

# ------------------------------------------------------------------------
# Interface cycling (with guaranteed restore)
# ------------------------------------------------------------------------
CYCLE_PENDING=""

_cycle_restore() {
  local pending="$CYCLE_PENDING" kind target
  if [[ -z "$pending" ]]; then return 0; fi
  CYCLE_PENDING=""
  kind="${pending%%:*}"
  target="${pending#*:}"
  case "$kind" in
  wifi)
    echo "⚠ Restoring Wi-Fi power on '${target}'..."
    if _wifi_set_power "$target" on; then
      echo "  ✔ '${target}' powered back on."
      return 0
    fi
    echo "  ✘ Automatic restore failed. Run: networksetup -setairportpower ${target} on"
    ;;
  service)
    echo "⚠ Re-enabling network service '${target}'..."
    if _net_svc_set_enabled "$target" on; then
      echo "  ✔ '${target}' re-enabled."
      return 0
    fi
    echo "  ✘ Automatic restore failed. Run: networksetup -setnetworkserviceenabled \"${target}\" on"
    ;;
  esac
  return 1
}

trap '_cycle_restore || true' EXIT
trap '_cycle_restore || true; exit 130' INT
trap '_cycle_restore || true; exit 143' TERM

_wifi_set_power() {
  local device="$1" state="$2"
  if networksetup -setairportpower "$device" "$state" >/dev/null 2>&1; then
    return 0
  fi
  if [[ "$PRIV_MODE" == "none" ]]; then return 1; fi
  _priv_run "networksetup -setairportpower ${device} ${state}" >/dev/null 2>&1
}

_wifi_power_is() {
  networksetup -getairportpower "$1" 2>/dev/null | grep -qi ":[[:space:]]*$2$"
}

_net_svc_set_enabled() {
  local svc="$1" state="$2"
  if networksetup -setnetworkserviceenabled "$svc" "$state" >/dev/null 2>&1; then
    return 0
  fi
  if [[ "$PRIV_MODE" == "none" ]]; then return 1; fi
  _priv_run "networksetup -setnetworkserviceenabled \"${svc}\" ${state}" >/dev/null 2>&1
}

_svc_enabled_is() {
  [[ "$(networksetup -getnetworkserviceenabled "$1" 2>/dev/null)" == "$2" ]]
}

_wait_for_power() {
  local device="$1" want="$2" limit="$3" i
  for ((i = 0; i < limit; i++)); do
    if _wifi_power_is "$device" "$want"; then return 0; fi
    sleep 1
  done
  return 1
}

_wait_for_service_state() {
  local svc="$1" want="$2" limit="$3" i
  for ((i = 0; i < limit; i++)); do
    if _svc_enabled_is "$svc" "$want"; then return 0; fi
    sleep 1
  done
  return 1
}

_cycle_wifi() {
  local device="$1"
  echo "▶ Power-cycling Wi-Fi interface '${device}' so running apps notice the network change..."
  CYCLE_PENDING="wifi:${device}"
  if ! _wifi_set_power "$device" off; then
    echo "  ✘ Could not power off '${device}'."
    CYCLE_PENDING=""
    return 1
  fi
  _wait_for_power "$device" Off 10 || echo "  ⚠ Wi-Fi did not report 'Off' within 10s; continuing."
  sleep 2
  if ! _wifi_set_power "$device" on; then
    echo "  ✘ Could not power '${device}' back on."
    return 1
  fi
  _wait_for_power "$device" On 15 || true
  CYCLE_PENDING=""
  if ! _wifi_power_is "$device" On; then
    echo "  ⚠ Wi-Fi power did not report 'On' within 15s."
    return 1
  fi
  return 0
}

_cycle_service_iface() {
  local svc="$1"
  echo "▶ Disabling and re-enabling '${svc}' so running apps notice the network change..."
  CYCLE_PENDING="service:${svc}"
  if ! _net_svc_set_enabled "$svc" off; then
    echo "  ✘ Could not disable '${svc}'."
    CYCLE_PENDING=""
    return 1
  fi
  _wait_for_service_state "$svc" Disabled 10 || echo "  ⚠ '${svc}' did not report 'Disabled' within 10s; continuing."
  sleep 2
  if ! _net_svc_set_enabled "$svc" on; then
    echo "  ✘ Could not re-enable '${svc}'."
    return 1
  fi
  _wait_for_service_state "$svc" Enabled 15 || true
  CYCLE_PENDING=""
  if ! _svc_enabled_is "$svc" Enabled; then
    echo "  ⚠ '${svc}' did not report 'Enabled' within 15s."
    return 1
  fi
  return 0
}

_wait_for_link() {
  local svc="$1" device="$2" limit="${3:-25}" i ip gw
  echo "▶ Waiting for '${device}' to obtain a usable IPv4 address (up to ${limit}s)..."
  for ((i = 0; i < limit; i++)); do
    if _has_usable_ipv4 "$device"; then
      ip=$(_ipv4_of "$device")
      gw=$(_default_route_gateway)
      if [[ -n "$gw" ]]; then
        echo "  ✔ ${device} up with ${ip} (default gateway ${gw})"
      else
        echo "  ✔ ${device} up with ${ip}, but there is no default route yet."
        echo "    If a VPN was connected, disconnect/reconnect it; check with: route -n get default"
      fi
      return 0
    fi
    sleep 1
  done
  return 1
}

_maybe_renew_dhcp() {
  local svc="$1" device="$2" info
  if [[ -z "$device" ]]; then return 1; fi
  info=$(networksetup -getinfo "$svc" 2>/dev/null) || info=""
  if [[ "$info" == *"Manual Configuration"* ]]; then
    echo "  ↷ '${svc}' is statically configured; not renewing DHCP."
    return 1
  fi
  if [[ "$PRIV_MODE" == "none" ]]; then
    echo "  ↷ Renewing the DHCP lease needs root: sudo ipconfig set ${device} DHCP"
    SKIPPED_PRIV=true
    return 1
  fi
  echo "▶ Renewing the DHCP lease on '${device}'..."
  if ! _priv_run "ipconfig set ${device} DHCP" >/dev/null 2>&1; then
    echo "  ↷ 'ipconfig set ${device} DHCP' failed."
    return 1
  fi
  _wait_for_link "$svc" "$device" 25
}

# ------------------------------------------------------------------------
# DNS flush / rewrite
# ------------------------------------------------------------------------
# The unprivileged DNS cache flush is a no-op on modern macOS (dscacheutil
# exits 0 without doing anything, and killall fails with EPERM), so this either
# reloads the resolver properly or says plainly that it could not.
_flush_dns() {
  local reason="${1:-}" cmd
  printf '▶ Flushing DNS cache and reloading the resolver'
  if [[ -n "$reason" ]]; then printf ' (%s)' "$reason"; fi
  printf '...\n'
  # Strict chain: if mDNSResponder or configd cannot be reloaded, say so rather
  # than reporting a flush that did not happen.
  cmd="dscacheutil -flushcache && killall -HUP mDNSResponder && killall -HUP configd"
  if [[ "$PRIV_MODE" == "none" ]]; then
    echo "  ↷ Needs root; skipped. Run: sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder; sudo killall -HUP configd"
    SKIPPED_PRIV=true
    return 1
  fi
  if _priv_run "$cmd" >/dev/null 2>&1; then
    echo "  ✔ Cache flushed; mDNSResponder reloaded; configd reloaded so apps re-read network state"
    sleep 1
    return 0
  fi
  echo "  ⚠ Privileged flush failed. Run manually:"
  echo "      sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder; sudo killall -HUP configd"
  return 1
}

# Only a DNS mismatch on the interface that actually carries traffic says
# anything about the resolution failures that get reported; an unset DNS on an
# unused bridge does not.
_dns_mismatch_matters() {
  [[ -n "$1" ]] || return 1
  _has_usable_ipv4 "$1"
}

_apply_dns() {
  local svc="$1" cmd
  networksetup -setsearchdomains "$svc" "Empty" >/dev/null 2>&1 || true
  networksetup -setdnsservers "$svc" "${PRIMARY_DNS[@]}" >/dev/null 2>&1 || true
  if _dns_matches "$svc"; then
    echo "  ✔ DNS configured and verified: ${PRIMARY_DNS[*]} (search domains cleared)"
    return 0
  fi
  if [[ "$PRIV_MODE" != "none" ]]; then
    echo "  ↷ Unprivileged DNS change did not take effect; retrying with administrator privileges..."
    cmd="networksetup -setsearchdomains \"${svc}\" Empty; networksetup -setdnsservers \"${svc}\" ${PRIMARY_DNS[*]}"
    _priv_run "$cmd" >/dev/null 2>&1 || true
    if _dns_matches "$svc"; then
      echo "  ✔ DNS configured and verified with administrator privileges: ${PRIMARY_DNS[*]}"
      return 0
    fi
  fi
  echo "  ⚠ Could not verify DNS. Check manually:"
  echo "      networksetup -getdnsservers \"${svc}\""
  return 1
}

_ensure_dns() {
  local svc="$1" device="$2" current ans
  if _dns_matches "$svc"; then
    echo "▶ DNS on '${svc}' already matches PRIMARY_DNS (${PRIMARY_DNS[*]}); leaving it alone."
    return 0
  fi
  current=$(_get_current_dns "$svc" | tr '\n' ' ')
  current="${current% }"
  if [[ -z "$current" ]]; then
    echo "▶ DNS on '${svc}' is unset (using DHCP-provided DNS)."
  else
    echo "▶ DNS on '${svc}' is currently: ${current}"
  fi
  echo "  Does not match PRIMARY_DNS: ${PRIMARY_DNS[*]}"

  ans=""
  if [[ "$FORCE_DNS" == "true" ]]; then
    :
  elif [[ -t 0 && -t 1 ]]; then
    read -r -p "  Overwrite DNS on '${svc}' with ${PRIMARY_DNS[*]}? [y/N] " ans || ans=""
  else
    if _dns_mismatch_matters "$device"; then DNS_MISMATCH=true; fi
    echo "  ↷ Non-interactive session and --force-dns not given; leaving DNS unchanged."
    echo "  ↷ Re-run with --force-dns to overwrite DNS unattended."
    return 0
  fi
  if [[ "$FORCE_DNS" != "true" ]] && [[ ! "$ans" =~ ^[Yy] ]]; then
    if _dns_mismatch_matters "$device"; then DNS_MISMATCH=true; fi
    echo "  ↷ Skipped DNS change on '${svc}' per user choice."
    return 0
  fi
  if ! _apply_dns "$svc"; then
    if _dns_mismatch_matters "$device"; then DNS_MISMATCH=true; fi
    return 1
  fi
  return 0
}

# ------------------------------------------------------------------------
# Repair actions
# ------------------------------------------------------------------------
_repair_service() {
  local svc="$1" device="$2" port="$3"
  local was_active=false link_wait=25
  if [[ -n "$device" ]] && _iface_is_active "$device"; then was_active=true; fi
  if [[ "$was_active" != "true" ]]; then link_wait=10; fi
  _ensure_dns "$svc" "$device"

  if [[ -z "$device" ]]; then
    echo "  ℹ '${svc}' has no hardware device (VPN-style service); nothing to cycle."
    return 0
  fi

  if ! _svc_enabled_is "$svc" Enabled; then
    echo "▶ '${svc}' is disabled; enabling it before the repair..."
    if ! _net_svc_set_enabled "$svc" on; then
      echo "  ✘ Could not enable '${svc}'; skipping this service."
      return 1
    fi
    sleep 1
  fi

  if _is_wifi_port "$port"; then
    _cycle_wifi "$device" || return 1
  else
    _cycle_service_iface "$svc" || return 1
  fi

  if ! _wait_for_link "$svc" "$device" "$link_wait"; then
    echo "  ⚠ No usable IPv4 after ${link_wait}s; trying a DHCP lease renewal."
    _maybe_renew_dhcp "$svc" "$device" || true
  fi
  return 0
}

# ------------------------------------------------------------------------
# Verification
# ------------------------------------------------------------------------
_verify_domains() {
  local -a remaining next stalled
  remaining=("${TEST_DOMAINS[@]}")
  stalled=()
  local attempt out domain status detail
  local failures=0

  echo "▶ Verifying endpoints (DNS + TCP/TLS 443)..."
  for attempt in 1 2 3; do
    if [[ ${#remaining[@]} -eq 0 ]]; then break; fi
    if [[ $attempt -eq 2 ]]; then
      echo "▶ Retrying ${#remaining[@]} unresolved endpoint(s) in 2s..."
      sleep 2
    elif [[ $attempt -eq 3 ]]; then
      echo "▶ Final retry for ${#remaining[@]} unresolved endpoint(s) in 4s..."
      sleep 4
    fi
    out=$(_probe_domains full "${remaining[@]}" 2>/dev/null) || true
    next=()
    while IFS=$'\t' read -r domain status detail; do
      if [[ -z "$domain" ]]; then continue; fi
      if [[ "$status" == "ok" ]]; then
        echo "  ✔ ${domain} reachable (${detail})"
      elif [[ "$status" == "dns-timeout" ]]; then
        # A stalled lookup is a resolver fault, not a transient miss; retrying
        # only multiplies the wait.
        echo "  ✘ ${domain} failed (${status}: ${detail}; resolver stalled)"
        stalled+=("$domain")
      else
        next+=("$domain")
        if [[ $attempt -eq 3 ]]; then
          echo "  ✘ ${domain} failed (${status}: ${detail})"
        fi
      fi
    done <<<"$out"
    if [[ ${#next[@]} -eq 0 ]]; then
      remaining=()
    else
      remaining=("${next[@]}")
    fi
  done
  failures=$(( ${#remaining[@]} + ${#stalled[@]} ))
  if [[ $failures -gt 0 ]]; then
    if [[ ${#stalled[@]} -gt 0 ]]; then
      _diagnose_resolver "${stalled[@]}"
    fi
    if [[ ${#remaining[@]} -gt 0 ]]; then
      _diagnose_resolver "${remaining[@]}"
    fi
    return 1
  fi
  return 0
}

# ------------------------------------------------------------------------
# Optional app restart
# ------------------------------------------------------------------------
_app_running() {
  pgrep -x "$1" >/dev/null 2>&1 || pgrep -f "/${1}.app/Contents/MacOS/" >/dev/null 2>&1
}

_restart_app() {
  local app="$1" i
  if ! command -v open >/dev/null 2>&1; then return 0; fi
  if ! open -Ra "$app" >/dev/null 2>&1; then
    echo "✘ No app named '${app}' was found." >&2
    return 1
  fi
  if _app_running "$app"; then
    echo "▶ Quitting '${app}' so it rebuilds its connections..."
    osascript -e "tell application \"${app}\" to quit" >/dev/null 2>&1 || true
    for ((i = 0; i < 10; i++)); do
      if ! _app_running "$app"; then break; fi
      sleep 1
    done
    if _app_running "$app"; then
      echo "  ↷ '${app}' did not quit within 10s; leaving it running."
      return 1
    fi
    echo "  ✔ '${app}' quit."
  fi
  echo "▶ Reopening '${app}'..."
  if ! open -a "$app" >/dev/null 2>&1; then
    echo "  ⚠ Could not reopen '${app}'." >&2
    return 1
  fi
  for ((i = 0; i < 15; i++)); do
    if _app_running "$app"; then
      echo "  ✔ '${app}' is running again."
      return 0
    fi
    sleep 1
  done
  echo "  ⚠ '${app}' has not appeared yet; it may still be starting."
  return 0
}

# ------------------------------------------------------------------------
# --check-only
# ------------------------------------------------------------------------
cmd_check() {
  local rc=0 i svc dev ip eff route_iface route_gw current out domain status detail
  local -a failed
  echo "🔎 Checking DNS, resolver, route, and reachability (read-only)..."

  for i in "${TARGET_INDEXES[@]}"; do
    svc="${SVC_NAMES[$i]}"
    dev="${SVC_DEVICES[$i]}"
    echo
    echo "── ${svc} ──"
    current=$(_get_current_dns "$svc" | tr '\n' ' ')
    current="${current% }"
    if _dns_matches "$svc"; then
      echo "  service DNS   : ${current:-unset} (matches PRIMARY_DNS)"
    else
      echo "  service DNS   : ${current:-unset (DHCP)} (does not match ${PRIMARY_DNS[*]})"
      if _dns_mismatch_matters "$dev"; then DNS_MISMATCH=true; fi
      rc=1
    fi
    eff=$(_effective_nameservers | tr '\n' ' ')
    eff="${eff% }"
    echo "  resolver #1   : ${eff:-none}"
    if [[ -n "$eff" ]] && [[ "$(printf '%s\n' "$eff" | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ')" != "$(printf '%s\n' "${PRIMARY_DNS[@]}" | sort | tr '\n' ' ')" ]]; then
      echo "  ⚠ resolver #1 differs from PRIMARY_DNS (DHCP or a VPN may be supplying it)"
    fi
    ip=""
    if [[ -n "$dev" ]]; then
      ip=$(_ipv4_of "$dev")
      echo "  device        : ${dev} ${ip:-no IPv4}"
    fi
    route_iface=$(_default_route_iface)
    route_gw=$(_default_route_gateway)
    if [[ -n "$route_iface" ]]; then
      echo "  default route : ${route_iface} via ${route_gw:-?}"
      case "$route_iface" in
      utun*)
        if [[ -n "$ip" ]]; then
          echo "  ⚠ default traffic goes through ${route_iface}; expected while a VPN is connected, stale otherwise"
        fi
        ;;
      esac
    else
      echo "  default route : none"
      rc=1
    fi
  done

  echo
  out=$(_probe_domains full "${TEST_DOMAINS[@]}" 2>/dev/null) || true
  failed=()
  while IFS=$'\t' read -r domain status detail; do
    if [[ -z "$domain" ]]; then continue; fi
    if [[ "$status" == "ok" ]]; then
      echo "  ✔ ${domain} reachable (${detail})"
    else
      echo "  ✘ ${domain} unreachable (${status}: ${detail})"
      failed+=("$domain")
      rc=1
    fi
  done <<<"$out"
  if [[ ${#failed[@]} -gt 0 ]]; then
    _diagnose_resolver "${failed[@]}"
  fi
  return $rc
}

# ------------------------------------------------------------------------
# Hints for --flush runs
# ------------------------------------------------------------------------
# --flush deliberately does not rewrite DNS, so point out when a service's DNS
# still differs from PRIMARY_DNS (the resolver flush alone will not fix that).
_hint_dns_mismatch() {
  local i svc
  if ! _collect_services 2>/dev/null; then return 0; fi
  for ((i = 0; i < ${#SVC_NAMES[@]}; i++)); do
    if [[ "${SVC_ENABLED[$i]}" != "0" ]]; then continue; fi
    svc="${SVC_NAMES[$i]}"
    if _is_wifi_port "${SVC_PORTS[$i]}" || _is_ethernet_port "${SVC_PORTS[$i]}"; then
      if ! _dns_matches "$svc"; then
        echo "  ℹ '${svc}' DNS does not match PRIMARY_DNS; run without --flush (with --force-dns) to rewrite it."
      fi
    fi
  done
  return 0
}

# ------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------
ACTION="repair"
MODE="auto" # auto | all | explicit
RAW_SERVICE_ARGS=()
FORCE_DNS=false
CHECK_ONLY=false
FLUSH_ONLY=false
RESTART_APP=""

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
    if [[ -z "${2:-}" ]]; then
      echo "Error: $1 requires an argument" >&2
      exit 1
    fi
    RAW_SERVICE_ARGS+=("$2")
    shift 2
    ;;
  --service=*)
    RAW_SERVICE_ARGS+=("${1#*=}")
    shift
    ;;
  --force-dns)
    FORCE_DNS=true
    shift
    ;;
  --elevate)
    ELEVATE=true
    shift
    ;;
  --check-only)
    CHECK_ONLY=true
    shift
    ;;
  -f | --flush | --dns-only)
    FLUSH_ONLY=true
    shift
    ;;
  --restart-app)
    if [[ -z "${2:-}" ]]; then
      echo "Error: $1 requires an app name (e.g. --restart-app \"Grok Bot\")" >&2
      exit 1
    fi
    RESTART_APP="$2"
    shift 2
    ;;
  --restart-app=*)
    RESTART_APP="${1#*=}"
    if [[ -z "$RESTART_APP" ]]; then
      echo "Error: --restart-app requires an app name" >&2
      exit 1
    fi
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

if [[ "$CHECK_ONLY" == "true" && "$FLUSH_ONLY" == "true" ]]; then
  echo "Error: --check-only and --flush are mutually exclusive." >&2
  exit 1
fi

if [[ "$CHECK_ONLY" == "true" && -n "$RESTART_APP" ]]; then
  echo "Error: --check-only changes nothing, so --restart-app cannot be combined with it." >&2
  exit 1
fi

# Split each raw argument on commas only (service names may contain spaces),
# trimming surrounding whitespace from each resulting token.
FINAL_SERVICES=()
for entry in "${RAW_SERVICE_ARGS[@]}"; do
  IFS=',' read -r -a _tokens <<<"$entry"
  for tok in "${_tokens[@]}"; do
    tok="${tok#"${tok%%[![:space:]]*}"}"
    tok="${tok%"${tok##*[![:space:]]}"}"
    if [[ -n "$tok" ]]; then FINAL_SERVICES+=("$tok"); fi
  done
done

if [[ "$MODE" == "all" && ${#FINAL_SERVICES[@]} -gt 0 ]]; then
  echo "Error: cannot combine --all with --service or SERVICE arguments." >&2
  exit 1
fi

if [[ "$FLUSH_ONLY" == "true" && ${#FINAL_SERVICES[@]} -gt 0 ]]; then
  echo "Error: --flush takes no service selection (it changes no service settings)." >&2
  exit 1
fi

if [[ "$FLUSH_ONLY" == "true" && "$MODE" == "all" ]]; then
  echo "Error: --flush cannot be combined with --all." >&2
  exit 1
fi

# --flush and --check-only (for DNS-only runs) do not need target resolution
# when no selection was given; --flush never needs it at all.
NEED_TARGETS=true
if [[ "$FLUSH_ONLY" == "true" ]]; then
  NEED_TARGETS=false
fi

TARGET_INDEXES=()
if [[ "$NEED_TARGETS" == "true" ]]; then
  _collect_services || exit 1

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
      # Deduplicate: cycling the same service twice only prolongs the outage.
      already=false
      for existing in "${TARGET_INDEXES[@]}"; do
        if [[ "$existing" == "$found" ]]; then already=true; fi
      done
      if [[ "$already" != "true" ]]; then
        TARGET_INDEXES+=("$found")
      fi
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
fi

if [[ "$CHECK_ONLY" == "true" ]]; then
  cmd_check
  exit $?
fi

# ------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------
if [[ "$FLUSH_ONLY" == "true" ]]; then
  echo "🔧 Flushing macOS DNS cache and reloading the resolver (no interface changes)..."
else
  echo "🔧 Starting macOS network and DNS repair..."
  target_list=""
  for i in "${TARGET_INDEXES[@]}"; do
    target_list="${target_list}${SVC_NAMES[$i]}, "
  done
  echo "▶ Target service(s): ${target_list%, }"
fi

_setup_privileges

# 1. Flush the cache and reload the resolver up front.
_flush_dns "start" || true
if [[ "$FLUSH_ONLY" == "true" ]]; then
  _hint_dns_mismatch
fi

# 2. Reconfigure DNS (only when mismatched) and cycle each targeted service.
#    Skipped entirely with --flush so existing connections stay up.
if [[ "$FLUSH_ONLY" != "true" ]]; then
  for i in "${TARGET_INDEXES[@]}"; do
    _repair_service "${SVC_NAMES[$i]}" "${SVC_DEVICES[$i]}" "${SVC_PORTS[$i]}" || true
  done
  # Answers cached while the interface was coming back up (DHCP DNS, VPN
  # resolvers, half-up IPv6) can be stale, so reload once more on the new link.
  _flush_dns "after interface cycle" || true
fi

# 3. Verify resolution and TLS reachability, then report.
_wait_for_resolver
if _verify_domains; then
  ALL_OK=true
else
  ALL_OK=false
fi

if [[ "$ALL_OK" == "true" ]]; then
  echo "✨ Network repair complete: all endpoints reachable."
else
  if [[ "$PRIV_MODE" == "none" ]]; then
    echo "⚠ Some endpoints failed. Privileged steps were skipped; try again with sudo or --elevate."
  else
    echo "⚠ Some endpoints still failed. Check connectivity, DNS, and whether a VPN is intercepting those names."
  fi
fi

# 4. Optional app restart (opt-in: drops in-flight requests in that app).
APP_RC=0
if [[ -n "$RESTART_APP" ]]; then
  _restart_app "$RESTART_APP" || APP_RC=1
fi

if [[ "$ALL_OK" == "true" && $APP_RC -eq 0 ]]; then
  if [[ "$SKIPPED_PRIV" == "true" ]]; then
    echo "ℹ Privileged steps were skipped; rerun with sudo or --elevate for a complete repair."
  fi
  exit 0
fi
exit 1
