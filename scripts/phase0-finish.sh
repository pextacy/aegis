#!/usr/bin/env bash
#
# phase0-finish.sh — Wait for the deployer to be funded, then run the rest of
# Phase 0 unattended.
#
# Funding is the one Phase 0 step that needs a human: the Coston2 faucet is
# reCAPTCHA-gated. Everything after it is mechanical, so this waits for the
# balance to land and then runs the whole chain, leaving nothing to do by hand
# between the faucet click and a finished Phase 0.
#
# Usage:
#   ./scripts/phase0-finish.sh              # wait up to 6 hours, then run
#   ./scripts/phase0-finish.sh --now        # skip the wait, run immediately
#   POLL_SECONDS=30 ./scripts/phase0-finish.sh
#
# Requires bash 4.4+ (macOS ships 3.2 — use /opt/homebrew/bin/bash), a running
# tunnel (./scripts/tunnel.sh) and a running indexer (./scripts/indexer.sh up).
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[phase0-finish]${NC} $*"; }
step() { echo -e "\n${CYAN}=== $* ===${NC}"; }
die()  { echo -e "${RED}[phase0-finish] ERROR:${NC} $*" >&2; exit 1; }

[[ -f "$PROJECT_DIR/.env" ]] || die "no .env — run ./scripts/use-chain.sh coston2"
set -a; source "$PROJECT_DIR/.env"; set +a

CHAIN_URL="${CHAIN_URL:-https://coston2-api.flare.network/ext/C/rpc}"
MIN_WEI=10000000000000000            # 0.01 C2FLR, the pre-flight minimum
POLL_SECONDS="${POLL_SECONDS:-20}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-21600}"   # six hours

SKIP_WAIT=false
[[ "${1:-}" == "--now" ]] && SKIP_WAIT=true

[[ -n "${INITIAL_OWNER:-}" ]] || die "INITIAL_OWNER unset"
command -v cast >/dev/null || die "cast not on PATH"

funded() {
    local bal
    bal=$(cast balance "$INITIAL_OWNER" --rpc-url "$CHAIN_URL" 2>/dev/null | tr -d '\n')
    [[ -n "$bal" ]] || return 1
    awk -v b="$bal" -v m="$MIN_WEI" 'BEGIN { exit !(b >= m) }'
}

# --- Wait for the faucet ---------------------------------------------------

if ! $SKIP_WAIT; then
    step "Waiting for $INITIAL_OWNER to be funded"
    log "faucet: https://faucet.flare.network/coston2"
    log "polling every ${POLL_SECONDS}s, giving up after $((MAX_WAIT_SECONDS / 3600))h"
    waited=0
    until funded; do
        if (( waited >= MAX_WAIT_SECONDS )); then
            die "still unfunded after $((MAX_WAIT_SECONDS / 3600))h — re-run when the faucet has been used"
        fi
        sleep "$POLL_SECONDS"
        waited=$((waited + POLL_SECONDS))
    done
fi

funded || die "deployer is not funded — nothing to do"
log "funded: $(cast balance "$INITIAL_OWNER" --rpc-url "$CHAIN_URL") wei"

# --- Preconditions the rest of the run depends on --------------------------

step "Checking preconditions"
"$SCRIPT_DIR/phase0-check.sh" || die "preconditions unmet — see above"

# --- The scaffold chain ----------------------------------------------------

step "pre-build: deploy InstructionSender and register the extension"
"$SCRIPT_DIR/pre-build.sh" || die "pre-build failed"

step "start-services: redis, ext-proxy, extension-tee"
"$SCRIPT_DIR/start-services.sh" --chain coston2 || die "start-services failed"

step "post-build: allow code version, set governance, register the TEE machine"
"$SCRIPT_DIR/post-build.sh" || die "post-build failed"

step "test: SAY_HELLO and SAY_GOODBYE end to end"
"$SCRIPT_DIR/test.sh" || die "end-to-end test failed"

# --- Exit criteria ---------------------------------------------------------

step "Verifying the Phase 0 exit criteria"
set -a; source "$PROJECT_DIR/.env"; set +a
[[ -f "$PROJECT_DIR/config/extension.env" ]] || die "config/extension.env was not written"
set -a; source "$PROJECT_DIR/config/extension.env"; set +a

INFO=$(curl -s --max-time 30 "$EXT_PROXY_URL/info")
[[ -n "$INFO" ]] || die "$EXT_PROXY_URL/info returned nothing"

CODE_HASH=$(jq -r '.machineData.codeHash // empty' <<<"$INFO")
EXT_ID=$(jq -r '.machineData.extensionId // empty' <<<"$INFO")
OWNER=$(jq -r '.machineData.initialOwner // empty' <<<"$INFO")

fail=0
if [[ "$CODE_HASH" == 0x194844cf* ]]; then
    log "codeHash      $CODE_HASH"
else
    echo -e "${RED}codeHash does not start 0x194844cf: $CODE_HASH${NC}" >&2; fail=1
fi
if [[ "${EXT_ID,,}" == "${EXTENSION_ID,,}" ]]; then
    log "extensionId   $EXT_ID"
else
    echo -e "${RED}extensionId $EXT_ID != $EXTENSION_ID${NC}" >&2; fail=1
fi
if [[ "${OWNER,,}" == "${INITIAL_OWNER,,}" ]]; then
    log "initialOwner  $OWNER"
else
    echo -e "${RED}initialOwner $OWNER != $INITIAL_OWNER${NC}" >&2; fail=1
fi

(( fail == 0 )) || die "exit criteria not met"

echo
log "Phase 0 complete."
log "  EXTENSION_ID        $EXTENSION_ID"
log "  INSTRUCTION_SENDER  $INSTRUCTION_SENDER"
log "  EXT_PROXY_URL       $EXT_PROXY_URL"
log "Record these in docs/phase-0-status.md (P0-8)."
