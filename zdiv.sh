#!/usr/bin/env bash
#
# zdiv.sh — Split a ZIP archive into parts with Roman numeral suffixes
#

set -euo pipefail
shopt -s nullglob

short_usage() {
    echo "Usage: $(basename "$0") [-s size | -n parts | --exact-n parts] <zip_file> [output_dir]"
    echo "Try '$(basename "$0") -h' for more information."
}

usage() {
    cat <<EOF
Usage:
  $(basename "$0") [OPTIONS] <zip_file> [output_dir]

Description:
  Split a ZIP archive into parts and rename them using lowercase
  Roman numerals (archivei.zip, archiveii.zip, ...).

Options:
  -s SIZE
      Split into parts of approximately SIZE (e.g. 100m, 1g, 500k).

  -n PARTS
      Approximate number of parts (zip may produce fewer).

  --exact-n PARTS
      Exact number of parts using binary split (not valid ZIP parts).
      Reassemble with:
        cat archive*.zip > combined.zip

  -h, --help
      Show full help.

Defaults:
  -s 100m

Examples:
  $(basename "$0") archive.zip
  $(basename "$0") -s 50m archive.zip ./parts
  $(basename "$0") -n 4 archive.zip
  $(basename "$0") --exact-n 3 archive.zip
EOF
}

int_to_roman() {
    local num=$1 result=""
    local values=(1000 900 500 400 100 90 50 40 10 9 5 4 1)
    local numerals=(m cm d cd c xc l xl x ix v iv i)
    for ((i = 0; i < ${#values[@]}; i++)); do
        while ((num >= values[i])); do
            result+="${numerals[i]}"
            ((num -= values[i]))
        done
    done
    echo "$result"
}

# --- defaults ---
split_size="100m"
num_parts=""
exact_parts=""

# --- parse args ---
if [[ $# -eq 0 ]]; then
    short_usage
    exit 1
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
    -s)
        split_size="$2"
        shift 2
        ;;
    -n)
        num_parts="$2"
        shift 2
        ;;
    --exact-n)
        exact_parts="$2"
        shift 2
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *) break ;;
    esac
done

if [[ $# -lt 1 || $# -gt 2 ]]; then
    short_usage >&2
    exit 1
fi

zip_file="$1"
output_dir="${2:-.}"

[[ -f "$zip_file" ]] || {
    echo "Error: File not found: $zip_file" >&2
    exit 1
}
[[ "$zip_file" == *.zip ]] || {
    echo "Error: Not a .zip file" >&2
    exit 1
}

mkdir -p "$output_dir"

base="${zip_file%.zip}"
name="$(basename "$base")"

# --- exact mode ---
if [[ -n "$exact_parts" ]]; then
    [[ "$exact_parts" =~ ^[0-9]+$ ]] || {
        echo "Error: invalid --exact-n" >&2
        exit 1
    }

    size=$(stat -c%s "$zip_file" 2>/dev/null || stat -f%z "$zip_file")
    chunk=$(((size + exact_parts - 1) / exact_parts))

    prefix="${output_dir}/${name}-chunk-"
    split -b "$chunk" -d "$zip_file" "$prefix"

    chunks=("${prefix}"*)
    [[ ${#chunks[@]} -eq "$exact_parts" ]] || {
        echo "Error: expected $exact_parts parts, got ${#chunks[@]}" >&2
        exit 1
    }

    echo "Renaming ${exact_parts} parts using Roman numerals" >&2

    i=1
    for f in "${chunks[@]}"; do
        r=$(int_to_roman "$i")
        out="${output_dir}/${name}${r}.zip"
        [[ ! -e "$out" ]] || {
            echo "Error: $out exists" >&2
            exit 1
        }
        mv "$f" "$out"
        printf "Part %d/%d → %s\n" "$i" "$exact_parts" "$(basename "$out")"
        ((i++))
    done

    exit 0
fi

# --- validate size ---
[[ "$split_size" =~ ^[0-9]+[bkmg]?$ ]] || {
    echo "Error: invalid size '$split_size'" >&2
    exit 1
}

# --- -n mode ---
if [[ -n "$num_parts" ]]; then
    [[ "$num_parts" =~ ^[0-9]+$ ]] || {
        echo "Error: invalid -n" >&2
        exit 1
    }
    echo "Note: -n is approximate" >&2

    size=$(stat -c%s "$zip_file" 2>/dev/null || stat -f%z "$zip_file")
    chunk=$(((size + num_parts - 1) / num_parts))
    split_size="${chunk}b"
fi

echo "Splitting '$zip_file' into parts of size: $split_size" >&2

zip -s "$split_size" "$zip_file" \
    --out "${output_dir}/${name}-part.zip" >/dev/null

parts=("${output_dir}/${name}-part.z"*)

[[ ${#parts[@]} -gt 1 ]] || {
    echo "Error: split did not produce multiple parts" >&2
    exit 1
}

total=${#parts[@]}
echo "Renaming ${total} parts using Roman numerals" >&2

i=1
for f in "${parts[@]}"; do
    r=$(int_to_roman "$i")
    out="${output_dir}/${name}${r}.zip"
    [[ ! -e "$out" ]] || {
        echo "Error: $out exists" >&2
        exit 1
    }
    mv "$f" "$out"
    printf "Part %d/%d → %s\n" "$i" "$total" "$(basename "$out")"
    ((i++))
done
