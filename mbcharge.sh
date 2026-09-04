#!/usr/bin/env bash
#
# mbcharge — Control MacBook battery charging via SMC

set -euo pipefail

# --- Usage -------------------------------------------------------------------

usage_short() {
    echo "Usage: mbcharge [--json] <enable|disable|hold|unhold|status>  (-h for help)"
}

usage_long() {
    cat <<EOF
mbcharge — control MacBook battery charging via SMC

Usage:
  mbcharge [--json] <command>

Commands:
  enable     Enable battery charging
  disable    Disable battery charging
  hold       Hold battery at ~80%
  unhold     Disable hold
  status     Show current state

Options:
  --json     Output machine-readable JSON
  -h, --help Show this help

Examples:
  mbcharge disable
  mbcharge hold
  mbcharge status
  mbcharge --json status | jq
EOF
}

# --- Constants ---------------------------------------------------------------

readonly SMC_CHARGE_KEY="CH0C"
readonly CHARGE_ON="00"
readonly CHARGE_OFF="01"

readonly SMC_HOLD_KEY="CHWA"
readonly HOLD_ON="01"
readonly HOLD_OFF="00"

# --- Globals -----------------------------------------------------------------

JSON=0
CMD=""

# --- Helpers -----------------------------------------------------------------

die() {
    echo "Error: $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' not found in PATH"
}

log() {
    [[ "$JSON" -eq 1 ]] && return 0
    echo "$*"
}

get_smc_value() {
    local key="$1"
    local raw

    raw=$(smc -k "$key" -r 2>/dev/null) || die "Failed to read SMC key: $key"

    echo "$raw" |
        sed -nE 's/^.+\(bytes ([0-9a-fA-F]+)\)/\1/p' |
        tr 'A-F' 'a-f'
}

set_smc_value() {
    local key="$1"
    local value="$2"

    sudo smc -k "$key" -w "$value" >/dev/null ||
        die "Failed to write $key=$value"
}

ensure_state() {
    local key="$1"
    local desired="$2"
    local label="$3"

    local current
    current=$(get_smc_value "$key")

    if [[ "$current" == "$desired" ]]; then
        log "$label already set ($current)"
        return 0
    fi

    log "Setting $label → $desired (was $current)"
    set_smc_value "$key" "$desired"
}

# --- Output ------------------------------------------------------------------

emit_status() {
    local charge hold

    charge=$(get_smc_value "$SMC_CHARGE_KEY")
    hold=$(get_smc_value "$SMC_HOLD_KEY")

    local charge_state hold_state
    [[ "$charge" == "$CHARGE_ON" ]] && charge_state="enabled" || charge_state="disabled"
    [[ "$hold" == "$HOLD_ON" ]] && hold_state="enabled" || hold_state="disabled"

    if [[ "$JSON" -eq 1 ]]; then
        printf '{"charging":"%s","hold":"%s"}\n' "$charge_state" "$hold_state"
    else
        echo "Charging: $charge_state"
        echo "Hold (≈80%%): $hold_state"
    fi
}

# --- Commands ----------------------------------------------------------------

cmd_enable() { ensure_state "$SMC_CHARGE_KEY" "$CHARGE_ON" "charging=enabled"; }
cmd_disable() { ensure_state "$SMC_CHARGE_KEY" "$CHARGE_OFF" "charging=disabled"; }
cmd_hold() { ensure_state "$SMC_HOLD_KEY" "$HOLD_ON" "hold=enabled"; }
cmd_unhold() { ensure_state "$SMC_HOLD_KEY" "$HOLD_OFF" "hold=disabled"; }

# --- Arg parsing -------------------------------------------------------------

parse_args() {
    local args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --json) JSON=1 ;;
        -h | --help)
            usage_long
            exit 0
            ;;
        -*) die "Unknown option: $1" ;;
        *) args+=("$1") ;;
        esac
        shift
    done

    if [[ ${#args[@]} -eq 0 ]]; then
        usage_short
        exit 1
    fi

    CMD="${args[0]}"
}

# --- Main --------------------------------------------------------------------

main() {
    require_cmd smc
    parse_args "$@"

    case "$CMD" in
    enable) cmd_enable ;;
    disable) cmd_disable ;;
    hold) cmd_hold ;;
    unhold) cmd_unhold ;;
    status) emit_status ;;
    *) die "Unknown command: $CMD" ;;
    esac
}

main "$@"
