#!/usr/bin/env bash
#
# zjoin.sh — Reassemble files created by zdiv.sh
#

set -euo pipefail
shopt -s nullglob

short_usage() {
    echo "Usage: $(basename "$0") [--verify] <basename> > combined.zip"
    echo "Try '$(basename "$0") -h' for more information."
}

usage() {
    cat <<EOF
Usage:
  $(basename "$0") [OPTIONS] <basename> > combined.zip

Description:
  Reassemble files created by zdiv.sh.

  Automatically detects format:

  1) Zip split:
       archive-part.z01, archive-part.z02, archive-part.zip
       → uses zip recovery

  2) Exact split:
       archivei.zip, archiveii.zip, ...
       → uses binary concatenation

Options:
  --verify
      Verify reconstructed archive using 'unzip -t'.
      This requires temporarily writing the output to disk.

  -h, --help
      Show full help.

Examples:
  $(basename "$0") archive > archive-full.zip
  $(basename "$0") --verify archive > archive-full.zip
EOF
}

roman_to_int() {
    local s="$1" n=0
    local v=(1000 900 500 400 100 90 50 40 10 9 5 4 1)
    local r=(m cm d cd c xc l xl x ix v iv i)
    local i pos=0

    while [[ $pos -lt ${#s} ]]; do
        local matched=0
        for ((i = 0; i < ${#r[@]}; i++)); do
            if [[ "${s:$pos:${#r[i]}}" == "${r[i]}" ]]; then
                n=$((n + v[i]))
                pos=$((pos + ${#r[i]}))
                matched=1
                break
            fi
        done
        [[ $matched -eq 1 ]] || return 1
    done
    echo "$n"
}

# --- args ---
verify=0

if [[ $# -eq 0 ]]; then
    short_usage
    exit 1
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
    --verify)
        verify=1
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        break
        ;;
    esac
done

[[ $# -eq 1 ]] || {
    short_usage >&2
    exit 1
}

base="$1"

# temp output if verifying
tmpfile=""
if [[ $verify -eq 1 ]]; then
    tmpfile="$(mktemp)"
    trap 'rm -f "$tmpfile"' EXIT
fi

output() {
    if [[ $verify -eq 1 ]]; then
        cat >"$tmpfile"
        echo "Verifying archive..." >&2
        unzip -t "$tmpfile" >&2
        cat "$tmpfile"
    else
        cat
    fi
}

# --- zip split ---
if compgen -G "${base}-part.z*" >/dev/null; then
    last="${base}-part.zip"
    [[ -f "$last" ]] || {
        echo "Error: missing $last" >&2
        exit 1
    }

    echo "Detected zip split format" >&2

    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT

    zip -FF "$last" --out "$tmpdir/out.zip" >/dev/null

    if [[ $verify -eq 1 ]]; then
        cat "$tmpdir/out.zip" | output
    else
        cat "$tmpdir/out.zip"
    fi

    exit 0
fi

# --- roman split ---
declare -A order=()

for f in "${base}"*.zip; do
    [[ -f "$f" ]] || continue
    s="${f#${base}}"
    s="${s%.zip}"
    [[ "$s" =~ ^[ivxlcdm]+$ ]] || continue
    if n=$(roman_to_int "$s"); then
        order[$n]="$f"
    fi
done

[[ ${#order[@]} -gt 0 ]] || {
    echo "Error: no recognizable parts for '$base'" >&2
    exit 1
}

echo "Detected Roman split format" >&2

nums=($(printf "%s\n" "${!order[@]}" | sort -n))

if [[ $verify -eq 1 ]]; then
    for n in "${nums[@]}"; do
        cat "${order[$n]}"
    done | output
else
    for n in "${nums[@]}"; do
        cat "${order[$n]}"
    done
fi
