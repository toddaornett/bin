#!/usr/bin/env bash

#!/usr/bin/env bash
#
# taxform.sh — Download IRS tax forms and instructions
#

set -euo pipefail

short_usage() {
    echo "Usage: $(basename "$0") [-y year] -f form [-I | -i] [-q]"
    echo "Try '$(basename "$0") -h' for more information."
}

usage() {
    cat <<EOF
Usage:
  $(basename "$0") [OPTIONS]

Description:
  Download IRS tax forms and/or instructions as PDF files.

Options:
  -y YEAR
      Tax year (default: current year)

  -f FORM
      Form number (e.g. 1040) [required]

  -I
      Download both form and instructions

  -i
      Download instructions only

  -q
      Quiet mode (suppress output)

  -h
      Show this help message

Defaults:
  If neither -I nor -i is specified:
    Download form only

Behavior:
  Attempts download from:
    1) irs-prior (historical forms)
    2) irs-pdf   (current forms fallback)

Examples:
  $(basename "$0") -f 1040
  $(basename "$0") -f 1040 -I
  $(basename "$0") -f 1040 -i
  $(basename "$0") -y 2022 -f 1099
EOF
}

download_file() {
    local filename="$1"
    local url_prior="https://www.irs.gov/pub/irs-prior/${filename}"
    local url_current="https://www.irs.gov/pub/irs-pdf/${filename}"

    if [[ "$quiet" == false ]]; then
        echo "Downloading $filename..."
    fi

    # Try prior first
    if curl -fsS -O "$url_prior"; then
        [[ "$quiet" == false ]] && echo "✓ $filename (irs-prior)"
        return 0
    fi

    # Fallback to current
    if curl -fsS -O "$url_current"; then
        [[ "$quiet" == false ]] && echo "✓ $filename (irs-pdf fallback)"
        return 0
    fi

    [[ "$quiet" == false ]] && echo "✗ Failed: $filename"
    return 1
}

# --- defaults ---
year="$(date +%Y)"
form=""
quiet=false
mode="form"

# --- args ---
if [[ $# -eq 0 ]]; then
    short_usage
    exit 1
fi

while getopts ":y:f:Iiqh" opt; do
    case "$opt" in
    y) year="$OPTARG" ;;
    f) form="$OPTARG" ;;
    I) mode="both" ;;
    i) mode="instructions" ;;
    q) quiet=true ;;
    h)
        usage
        exit 0
        ;;
    \?)
        echo "Error: Invalid option -$OPTARG" >&2
        short_usage >&2
        exit 1
        ;;
    esac
done

# --- validation ---
if [[ -z "$form" ]]; then
    echo "Error: -f <form> is required" >&2
    short_usage >&2
    exit 1
fi

form_file="f${form}--${year}.pdf"
instr_file="i${form}--${year}.pdf"

form_ok=false
instr_ok=false

# --- execution ---
case "$mode" in
form)
    download_file "$form_file" && form_ok=true
    ;;
instructions)
    download_file "$instr_file" && instr_ok=true
    ;;
both)
    download_file "$form_file" && form_ok=true
    download_file "$instr_file" && instr_ok=true
    ;;
esac

# --- summary ---
if [[ "$quiet" == false ]]; then
    case "$mode" in
    form)
        [[ "$form_ok" == true ]] && echo "Done." || echo "Form download failed."
        ;;
    instructions)
        [[ "$instr_ok" == true ]] && echo "Done." || echo "Instructions download failed."
        ;;
    both)
        if [[ "$form_ok" == true && "$instr_ok" == true ]]; then
            echo "Downloaded form and instructions."
        elif [[ "$form_ok" == true ]]; then
            echo "Form OK, instructions failed."
        elif [[ "$instr_ok" == true ]]; then
            echo "Instructions OK, form failed."
        else
            echo "Both downloads failed."
        fi
        ;;
    esac
fi
