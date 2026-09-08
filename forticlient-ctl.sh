#!/bin/bash
# forticlient-ctl — stop / start / status FortiClient on this Mac
#
# "Quit FortiClient" only closes the window. Fully means:
#   1. disconnect VPN
#   2. remove KeepAlive sentinel files so launchd does not respawn helpers
#   3. boot out every FortiClient LaunchAgent / LaunchDaemon
#   4. quit tray + helper apps
#   5. kill leftover Fortinet userland processes
#
# A script cannot silently unload Network Extensions on a DEP/Jamf Mac.
# After stop, disable FortiClientProxy / FortiClientPacketFilter / vpnprovider
# in System Settings if they are still listed as activated.
#
# Usage:
#   forticlient-ctl status
#   forticlient-ctl stop      # needs sudo
#   forticlient-ctl start     # needs sudo
#   forticlient-ctl extensions

set -u

COMMAND="${1:-status}"

CONSOLE_USER="$(stat -f '%Su' /dev/console)"
CONSOLE_UID="$(stat -f '%u' /dev/console)"
GUI_DOMAIN="gui/${CONSOLE_UID}"

DATA_DIR="/Library/Application Support/Fortinet/FortiClient/data"
SENTINELS=(
  "${DATA_DIR}/fct_is_running"
  "${DATA_DIR}/fwkeeprunning"
  "${DATA_DIR}/ztna_is_running"
)

AGENT_PLISTS=(
  "/Library/LaunchAgents/com.fortinet.forticlient.appfw2.plist"
  "/Library/LaunchAgents/com.fortinet.forticlient.credential_store.plist"
  "/Library/LaunchAgents/com.fortinet.forticlient.fct_launcher.plist"
  "/Library/LaunchAgents/com.fortinet.forticlient.fortiagent.plist"
  "/Library/LaunchAgents/com.fortinet.forticlient.fssoagent_launchagent.plist"
  "/Library/LaunchAgents/com.fortinet.forticlient.ztagent.plist"
)

DAEMON_PLISTS=(
  "/Library/LaunchDaemons/com.fortinet.forticlient.config.plist"
  "/Library/LaunchDaemons/com.fortinet.forticlient.epctrl.plist"
  "/Library/LaunchDaemons/com.fortinet.forticlient.fctdnsd.plist"
  "/Library/LaunchDaemons/com.fortinet.forticlient.fmon2.plist"
  "/Library/LaunchDaemons/com.fortinet.forticlient.fssoagent_launchdaemon.plist"
  "/Library/LaunchDaemons/com.fortinet.forticlient.macos.PrivilegedHelper.plist"
  "/Library/LaunchDaemons/com.fortinet.forticlient.sandbox.plist"
  "/Library/LaunchDaemons/com.fortinet.forticlient.servctl2.plist"
  "/Library/LaunchDaemons/com.fortinet.forticlient.vpn.plist"
  "/Library/LaunchDaemons/com.fortinet.forticlient.vpnctl2.plist"
  "/Library/LaunchDaemons/com.fortinet.forticlient.wf.plist"
  "/Library/LaunchDaemons/com.fortinet.forticlient.wf2.plist"
  "/Library/LaunchDaemons/com.fortinet.forticlient.ztnafw.plist"
)

USER_LABELS=(
  com.fortinet.fctappfw2
  com.fortinet.credential_store
  com.fortinet.fct_launcher
  com.fortinet.fortiagent
  com.fortinet.fssoagent_launchagent
  com.fortinet.forticlient.ztagent
  com.fortinet.forticlient.fortitray
)

SYSTEM_LABELS=(
  com.fortinet.config
  com.fortinet.epctrl
  com.fortinet.forticlient.fctdnsd
  com.fortinet.fmon2
  com.fortinet.fssoagent_launchdaemon
  com.fortinet.forticlient.macos.PrivilegedHelper
  com.fortinet.sandbox
  com.fortinet.fctservctl2
  com.fortinet.fctctl
  com.fortinet.vpnctl
  com.fortinet.fctwf
  com.fortinet.fctwf2
  com.fortinet.ztnafw
)

GUI_APPS=(
  FortiClient
  FortiTray
  FortiClientAgent
  FortiClientNetwork
  FctMiscAgent
  ztagent
  fmon2
)

say() { printf '%s\n' "$*"; }
hr() { say "----------------------------------------"; }

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    say "Re-running with sudo (needed to stop LaunchDaemons and sentinel files)..."
    exec sudo --preserve-env=PATH "$0" "$COMMAND"
  fi
}

as_user() {
  launchctl asuser "$CONSOLE_UID" sudo -u "$CONSOLE_USER" -- "$@"
}

plist_label() {
  /usr/libexec/PlistBuddy -c 'Print :Label' "$1" 2>/dev/null || true
}

forti_procs() {
  ps -axo pid=,user=,command= \
    | grep -E '/Applications/FortiClient\.app|/Library/Application Support/Fortinet/|/Library/SystemExtensions/.*/com\.fortinet' \
    | grep -v grep || true
}

print_status() {
  hr
  say "FortiClient status"
  hr
  say "Console user: ${CONSOLE_USER} (${CONSOLE_UID})"
  say "MDM: this Mac is Jamf/DEP enrolled; IT policy can relaunch FortiClient."
  say ""
  say "KeepAlive sentinels:"
  local f
  for f in "${SENTINELS[@]}"; do
    if [[ -e "$f" ]]; then
      say "  present  $f"
    else
      say "  missing  $f"
    fi
  done
  say ""
  say "User launchd jobs:"
  local label
  for label in "${USER_LABELS[@]}"; do
    if launchctl print "${GUI_DOMAIN}/${label}" >/dev/null 2>&1; then
      say "  loaded    ${GUI_DOMAIN}/${label}"
    else
      say "  unloaded  ${GUI_DOMAIN}/${label}"
    fi
  done
  say ""
  say "System launchd jobs:"
  for label in "${SYSTEM_LABELS[@]}"; do
    if launchctl print "system/${label}" >/dev/null 2>&1; then
      say "  loaded    system/${label}"
    else
      say "  unloaded  system/${label}"
    fi
  done
  say ""
  say "Processes:"
  local procs
  procs="$(forti_procs)"
  if [[ -z "$procs" ]]; then
    say "  none"
  else
    say "$procs"
  fi
  say ""
  say "Network extensions (script cannot unload these on a managed Mac):"
  systemextensionsctl list 2>/dev/null | grep -E 'fortinet|enabled|bundleID|FortiClient' || true
  say ""
  say "If FortiClientProxy / FortiClientPacketFilter / vpnprovider still say"
  say "[activated enabled], traffic can still be intercepted after a quit."
}

print_extension_help() {
  hr
  say "Finish the last step by hand"
  hr
  say "English:"
  say "  System Settings → General → Login Items & Extensions → Network Extensions"
  say "  Turn OFF: FortiClientProxy, FortiClientPacketFilter, vpnprovider"
  say ""
  say "日本語:"
  say "  システム設定 → 一般 → ログイン項目と拡張機能 → ネットワーク拡張機能"
  say "  オフ: FortiClientProxy, FortiClientPacketFilter, vpnprovider"
  say ""
  say "Opening Login Items now..."
  as_user open "x-apple.systempreferences:com.apple.LoginItems-Settings.extension" 2>/dev/null || true
}

remove_sentinels() {
  say "Removing KeepAlive sentinel files so launchd will not respawn helpers..."
  local f
  for f in "${SENTINELS[@]}"; do
    if [[ -e "$f" ]]; then
      rm -f "$f" && say "  removed $f"
    fi
  done
}

restore_sentinels() {
  say "Restoring KeepAlive sentinel files..."
  mkdir -p "$DATA_DIR"
  local f
  for f in "${SENTINELS[@]}"; do
    : > "$f"
    say "  touched $f"
  done
}

quit_gui() {
  say "Quitting FortiClient GUI apps as ${CONSOLE_USER}..."
  local app
  for app in "${GUI_APPS[@]}"; do
    as_user osascript -e "tell application \"${app}\" to quit" >/dev/null 2>&1 || true
  done
  as_user osascript -e 'tell application "System Events" to set visible of every process whose name contains "Forti" to false' >/dev/null 2>&1 || true
  sleep 1
}

try_disconnect_vpn() {
  say "Asking FortiClient helpers to drop tunnels..."
  local ctl2="/Library/Application Support/Fortinet/FortiClient/bin/fct_tunnel_ctl2"
  local ctl="/Library/Application Support/Fortinet/FortiClient/bin/fct_tunnel_ctl"
  if [[ -x "$ctl2" ]]; then
    "$ctl2" disconnect >/dev/null 2>&1 || true
  fi
  if [[ -x "$ctl" ]]; then
    "$ctl" disconnect >/dev/null 2>&1 || true
  fi
}

stop_user_jobs() {
  say "Disabling and booting out user LaunchAgents..."
  local label plist
  for label in "${USER_LABELS[@]}"; do
    launchctl disable "${GUI_DOMAIN}/${label}" 2>/dev/null || true
    launchctl bootout "${GUI_DOMAIN}/${label}" 2>/dev/null || true
  done
  for plist in "${AGENT_PLISTS[@]}"; do
    [[ -f "$plist" ]] || continue
    launchctl bootout "$GUI_DOMAIN" "$plist" 2>/dev/null || true
  done
}

stop_system_jobs() {
  say "Disabling and booting out system LaunchDaemons..."
  local label plist
  for label in "${SYSTEM_LABELS[@]}"; do
    launchctl disable "system/${label}" 2>/dev/null || true
    launchctl bootout "system/${label}" 2>/dev/null || true
  done
  for plist in "${DAEMON_PLISTS[@]}"; do
    [[ -f "$plist" ]] || continue
    launchctl bootout system "$plist" 2>/dev/null || true
  done
}

start_system_jobs() {
  say "Enabling and bootstrapping system LaunchDaemons..."
  local label plist
  for label in "${SYSTEM_LABELS[@]}"; do
    launchctl enable "system/${label}" 2>/dev/null || true
  done
  for plist in "${DAEMON_PLISTS[@]}"; do
    [[ -f "$plist" ]] || continue
    launchctl bootstrap system "$plist" 2>/dev/null || launchctl kickstart -k "system/$(plist_label "$plist")" 2>/dev/null || true
  done
}

start_user_jobs() {
  say "Enabling and bootstrapping user LaunchAgents..."
  local label plist
  for label in "${USER_LABELS[@]}"; do
    launchctl enable "${GUI_DOMAIN}/${label}" 2>/dev/null || true
  done
  for plist in "${AGENT_PLISTS[@]}"; do
    [[ -f "$plist" ]] || continue
    launchctl bootstrap "$GUI_DOMAIN" "$plist" 2>/dev/null || true
  done
}

kill_leftovers() {
  say "Killing leftover Fortinet userland processes..."
  pkill -TERM -f '/Applications/FortiClient\.app' 2>/dev/null || true
  pkill -TERM -f '/Library/Application Support/Fortinet/' 2>/dev/null || true
  sleep 1
  pkill -KILL -f '/Applications/FortiClient\.app' 2>/dev/null || true
  pkill -KILL -f '/Library/Application Support/Fortinet/' 2>/dev/null || true
}

do_stop() {
  need_root
  hr
  say "Fully stopping FortiClient (reversible; does not uninstall)"
  hr
  try_disconnect_vpn
  remove_sentinels
  quit_gui
  stop_user_jobs
  stop_system_jobs
  kill_leftovers
  # Sentinels can come back if a helper raced us.
  remove_sentinels
  stop_user_jobs
  stop_system_jobs
  say ""
  print_status
  print_extension_help
  say ""
  say "To bring FortiClient back later:  forticlient-ctl start"
}

do_start() {
  need_root
  hr
  say "Starting FortiClient services again"
  hr
  restore_sentinels
  start_system_jobs
  start_user_jobs
  as_user open -a FortiClient 2>/dev/null || true
  sleep 2
  print_status
}

case "$COMMAND" in
  status)
    print_status
    ;;
  stop)
    do_stop
    ;;
  start)
    do_start
    ;;
  extensions)
    print_status
    print_extension_help
    ;;
  -h|--help|help)
    sed -n '2,20p' "$0"
    ;;
  *)
    say "Unknown command: $COMMAND"
    say "Usage: $0 {status|stop|start|extensions}"
    exit 2
    ;;
esac
