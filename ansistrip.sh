#!/usr/bin/env bash
# =============================================================================
# ansistrip.sh — Strip ANSI escape sequences from a text stream
# =============================================================================
#
# SYNOPSIS
#   ansistrip.sh < input.txt
#   some-command | ansistrip.sh
#   ansistrip.sh [FILE ...]
#
# DESCRIPTION
#   Reads from standard input (or one or more files) and writes to standard
#   output with all ANSI/VT100 escape sequences removed.  Useful for cleaning
#   up colourised terminal output before piping it to tools that don't
#   understand escape codes (grep, awk, mail, log files, etc.).
#
#   Sequences stripped include:
#     - SGR (Select Graphic Rendition) — colours, bold, underline, etc.
#         ESC [ <params> m        e.g. \e[0m  \e[1;32m  \e[38;5;200m
#     - Cursor movement           — ESC [ <n> A/B/C/D/E/F/G/H/f
#     - Erase sequences           — ESC [ <n> J / ESC [ <n> K
#     - Scroll sequences          — ESC [ <n> S / ESC [ <n> T
#     - Save / restore cursor     — ESC [ s  /  ESC [ u
#     - OSC sequences (titles)    — ESC ] <text> BEL/ST
#     - Private-mode DEC seqs     — ESC [ ? <n> h/l
#
# USAGE AS A FILTER
#   The script is designed to sit in a pipeline:
#
#     ./build.sh 2>&1 | ansistrip.sh | tee build.log
#     cat coloured.log | ansistrip.sh > clean.log
#     journalctl -u myservice | ansistrip.sh | grep ERROR
#
# USAGE WITH FILE ARGUMENTS
#   When one or more filenames are given the files are processed in order,
#   just like cat(1):
#
#     ansistrip.sh coloured1.log coloured2.log > clean.log
#
# DEPENDENCIES
#   perl (5.x)  — present on virtually every Unix/Linux/macOS system.
#
# EXIT STATUS
#   Propagates the exit status of perl.  0 on success, non-zero on error.
#
# PORTABILITY
#   Requires bash ≥ 3.2 (shebang) and perl ≥ 5.8.
#   Tested on: Linux (GNU), macOS (BSD), WSL2.
#
# AUTHOR / LICENCE
#   Public domain — do whatever you like with this script.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
if ! command -v perl > /dev/null 2>&1; then
    printf '%s: error: perl is required but was not found in PATH\n' \
        "$(basename "$0")" >&2
    exit 127
fi

# ---------------------------------------------------------------------------
# Core filter
#
# The perl one-liner runs in-place edit mode (-p loops over every line and
# prints it; -e supplies the script inline).
#
# Regex breakdown:
#   \e          — ESC character (0x1B)
#   (           — start alternation group
#     \[        — CSI introducer  "ESC ["
#     [0-9;?]*  — optional numeric/semicolon/private params (e.g. "1;32" "?25")
#     [A-Za-z]  — final byte that identifies the sequence type
#   |           — OR
#     \]        — OSC introducer  "ESC ]"
#     [^\a]*    — OSC payload (anything up to …)
#     (\a|\\)   — … BEL (0x07) or ST (ESC \)
#   )           — end alternation group
# ---------------------------------------------------------------------------
perl -pe '
    s/\e(
        \[ [0-9;?]* [A-Za-z]    # CSI sequences  (SGR, cursor, erase, …)
      |
        \] [^\a]* (\a|\\)       # OSC sequences  (window title, etc.)
    )//gx
' -- "$@"
