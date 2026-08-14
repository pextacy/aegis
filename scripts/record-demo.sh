#!/usr/bin/env bash
#
# record-demo.sh — Screen-record the demo to ~/Desktop/aegis.mov.
#
# Uses macOS' own screencapture: `-v` records video, `-k` draws the click
# indicator the recording needs to be followable.
#
# Screen Recording is a TCC permission and can only be granted by a person, in
# System Settings → Privacy & Security → Screen Recording, to whichever app owns
# this terminal. Two things make it stick:
#
#   1. The app must live in /Applications. An app still sitting in ~/Downloads
#      is run "translocated" from a randomised read-only path, and a permission
#      granted to that path is gone the next time it launches.
#   2. The app has to be quit and reopened after the toggle.
#
# This script checks the permission first and says which of those is missing,
# rather than producing a zero-byte file and calling it a recording.
#
# Usage:
#   ./scripts/record-demo.sh            # record ./scripts/demo.sh
#   ./scripts/record-demo.sh quorum     # record ./scripts/local-quorum.sh
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[record]${NC} $*"; }
step() { echo -e "\n${CYAN}==> $*${NC}"; }
die()  { echo -e "${RED}[record] $*${NC}" >&2; exit 1; }

WHAT="${1:-demo}"
case "$WHAT" in
    demo)   TARGET="$SCRIPT_DIR/demo.sh"; OUT="$HOME/Desktop/aegis.mov" ;;
    quorum) TARGET="$SCRIPT_DIR/local-quorum.sh"; OUT="$HOME/Desktop/aegis-quorum.mov" ;;
    *) die "unknown target: $WHAT (demo|quorum)" ;;
esac
[[ -x "$TARGET" ]] || die "$TARGET is not executable"

# --- Is the permission actually granted? -----------------------------------

step "Checking the Screen Recording permission"
PROBE="$(mktemp -t aegis-probe).mov"
rm -f "$PROBE"
screencapture -V 1 -v "$PROBE" >/dev/null 2>&1 || true
sleep 2

if [[ ! -s "$PROBE" ]]; then
    rm -f "$PROBE"
    # The permission belongs to the .app that owns this terminal, not to the
    # shell, so walk the parent chain until one turns up.
    OWNER_APP="your terminal"
    pid=$PPID
    for _ in 1 2 3 4 5 6; do
        name="$(ps -o comm= -p "$pid" 2>/dev/null)" || break
        case "$name" in *.app/*) OWNER_APP="${name%%.app/*}.app"; break ;; esac
        pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
        [[ -z "$pid" || "$pid" == "1" ]] && break
    done
    echo
    die "Screen Recording is not granted.

  Grant it to the app that owns this terminal:
    $OWNER_APP

  System Settings → Privacy & Security → Screen Recording → enable it,
  then quit and reopen that app and run this again.

  If the path above contains 'AppTranslocation', the app is running from a
  quarantined copy: move it into /Applications first, or the permission will
  not survive a relaunch."
fi
rm -f "$PROBE"
log "granted"

# --- Record ----------------------------------------------------------------

step "Recording $WHAT to $OUT"
log "click indicator on; stop early with Ctrl-C"
rm -f "$OUT"

screencapture -v -k "$OUT" &
CAPTURE_PID=$!
sleep 2   # let the recorder settle before the first frame that matters

set +e
"$TARGET"
STATUS=$?
set -e

sleep 2
# screencapture finalises the file on SIGINT; killing it outright truncates.
kill -INT "$CAPTURE_PID" 2>/dev/null || true
wait "$CAPTURE_PID" 2>/dev/null || true

[[ -s "$OUT" ]] || die "the recording came out empty"
log "saved $OUT ($(du -h "$OUT" | cut -f1))"
[[ "$STATUS" == "0" ]] || log "note: $WHAT exited $STATUS — the recording kept what happened"
