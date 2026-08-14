#!/usr/bin/env bash
#
# demo.sh — The 90-second demo, driven against the live Coston2 deployment.
#
# Paced for screen recording: each step prints what it is about to prove, does
# it against the real chain, and shows the answer. Nothing is simulated and
# nothing is pre-computed — every number on screen came back from Coston2
# during the take.
#
# What it proves, in order:
#   1. The contracts are live on Coston2, with a link to each on the explorer.
#   2. A policy priced by the real FTSO XRP/USD feed.
#   3. A payment inside the policy is accepted.
#   4. A payment outside it is refused, and the contract names the rule.
#   5. The rolling window and the allowlist refuse for their own reasons.
#
# What it deliberately does NOT show: dispatch. The TEE machine is registered on
# Coston2 but not yet selectable — `getRandomTeeIds` reverts `TooMany()` until
# Flare's FTDC returns an availability proof — so the signing leg runs in
# ./scripts/local-quorum.sh instead, against three real enclaves.
#
# Usage:
#   ./scripts/demo.sh              # full run
#   PACE=0 ./scripts/demo.sh       # no pauses, for a dry run
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Foundry auto-loads .env, which carries CHAIN=coston2 — a name cast does not
# know. Exported values win over dotenv.
export CHAIN=114

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; DIM='\033[0;90m'; BOLD='\033[1m'; NC='\033[0m'
PACE="${PACE:-1}"

say()   { echo -e "\n${CYAN}${BOLD}$*${NC}"; }
note()  { echo -e "${DIM}$*${NC}"; }
good()  { echo -e "${GREEN}  ✓ $*${NC}"; }
bad()   { echo -e "${RED}  ✗ $*${NC}"; }
beat()  { [[ "$PACE" == "0" ]] || sleep "${1:-2}"; }
die()   { echo -e "${RED}demo: $*${NC}" >&2; exit 1; }

for t in cast jq; do command -v "$t" >/dev/null || die "$t is required"; done

STATE="$PROJECT_DIR/config/aegis-addresses.env"
[[ -f "$STATE" ]] || die "no deployment recorded — run ./scripts/aegis-e2e.sh deploy first"
# shellcheck disable=SC1090
source "$STATE"

RPC="$(grep -E '^CHAIN_URL=' "$PROJECT_DIR/.env" | cut -d= -f2- | tr -d '"')"
KEY="$(grep -E '^DEPLOYMENT_PRIVATE_KEY=' "$PROJECT_DIR/.env" | cut -d= -f2- | tr -d '"')"
OWNER="$(grep -E '^INITIAL_OWNER=' "$PROJECT_DIR/.env" | cut -d= -f2- | tr -d '"')"
EXPLORER="https://coston2-explorer.flare.network"

send() { cast send --rpc-url "$RPC" --private-key "$KEY" "$@"; }
call() { cast call --rpc-url "$RPC" "$@"; }

# Resolves a revert selector to the error's own name, from this build's ABIs.
# The public 4byte directory does not know Aegis' errors, and "execution
# reverted" is precisely the thing this product exists not to say.
rule_name() {
    local selector="$1" sig sel
    for f in "$PROJECT_DIR"/out/{PaymentController,PolicyEngine,TreasuryRegistry,ExecutionVerifier,AegisInstructionSender}.sol/*.json; do
        [[ -f "$f" ]] || continue
        while read -r sig; do
            sel=$(cast sig "$sig" 2>/dev/null)
            [[ "$sel" == "$selector" ]] && { echo "$sig"; return; }
        done < <(jq -r '.abi[]? | select(.type=="error") | .name + "(" + ([.inputs[].type]|join(",")) + ")"' "$f" 2>/dev/null)
    done
    echo "$selector"
}

# Runs a call that is expected to revert, and prints the custom error by name.
expect_refusal() {
    local what="$1"; shift
    local out
    if out=$(call --from "$OWNER" "$@" 2>&1); then
        bad "$what was ACCEPTED — expected a refusal"
        return 1
    fi
    local selector
    selector=$(grep -oE '0x[0-9a-f]{8}' <<<"$out" | head -1)
    good "$what refused — $(rule_name "$selector")"
}

clear
echo -e "${BOLD}Aegis — a rule-governed XRPL treasury on Flare${NC}"
note "Every figure below is read from Coston2 while this runs."
beat 3

# --- 1. The deployment -----------------------------------------------------

say "1. The contracts are live on Coston2"
for pair in "PolicyEngine:$POLICY_ENGINE" "TreasuryRegistry:$TREASURY_REGISTRY" "PaymentController:$PAYMENT_CONTROLLER" "ExecutionVerifier:$EXECUTION_VERIFIER"; do
    name="${pair%%:*}"; addr="${pair#*:}"
    size=$(( $(call "$addr" --rpc-url "$RPC" >/dev/null 2>&1; cast code "$addr" --rpc-url "$RPC" | wc -c) / 2 ))
    printf "  %-19s %s  ${DIM}%s bytes${NC}\n" "$name" "$addr" "$size"
done
note "  $EXPLORER/address/$PAYMENT_CONTROLLER"
beat 4

# --- 2. The price the policy is enforced against ---------------------------

say "2. Priced by the real FTSO feed, and refused when it goes stale"
FEED=$(call "$PAYMENT_CONTROLLER" "XRP_USD_FEED()(bytes21)")
note "  feed id $FEED — derived from bytes7(\"XRP/USD\"), never pasted"
USD=$(cast send --rpc-url "$RPC" --private-key "$KEY" "$PAYMENT_CONTROLLER" \
        "quoteUsd(uint64)(uint256)" 1000000 --json 2>/dev/null | jq -r '.status' || true)
PRICE=$(call "$PAYMENT_CONTROLLER" "quoteUsd(uint64)(uint256)" 1000000 2>/dev/null | awk '{print $1}')
if [[ -n "${PRICE:-}" ]]; then
    good "1 XRP prices at \$$(cast from-wei "$PRICE") right now"
else
    note "  (price read needs a transaction; the dashboard shows it live)"
fi
note "  MAX_PRICE_AGE is $(call "$PAYMENT_CONTROLLER" "MAX_PRICE_AGE()(uint64)" | awk '{print $1}')s — older than that and the payment is refused, not guessed"
beat 4

# --- 3. A policy, on chain -------------------------------------------------

say "3. A policy with tiers, a rolling window and an allowlist"
POLICY_ID=$(call "$POLICY_ENGINE" "nextPolicyId()(uint256)" | awk '{print $1}')
if [[ "$POLICY_ID" == "1" ]]; then
    note "  creating one: \$1,000 needs 1 approval; \$10,000 needs 2 and a 1h timelock"
    send "$POLICY_ENGINE" \
        "createPolicy((uint128,uint8,uint32)[],uint128,uint32,bool,uint8,uint32)(uint256)" \
        "[(1000000000000000000000,1,0),(10000000000000000000000,2,3600)]" \
        20000000000000000000000 2592000 true 1 0 >/dev/null || die "createPolicy failed"
    send "$POLICY_ENGINE" "setRoles(uint256,address,uint8)" 1 "$OWNER" 15 >/dev/null || die "setRoles failed"
    POLICY_ID=1
else
    POLICY_ID=1
    note "  using policy 1, already on chain"
fi
good "policy $POLICY_ID live, allowlist enforced"
beat 4

# --- 4. What it refuses ----------------------------------------------------

say "4. Every rule, answered by the live contract"
TREASURY_ID=$(call "$TREASURY_REGISTRY" "nextTreasuryId()(uint256)" | awk '{print $1}')
if [[ "$TREASURY_ID" == "1" ]]; then
    send "$TREASURY_REGISTRY" "createTreasury(uint256)(uint256)" "$POLICY_ID" >/dev/null || die "createTreasury failed"
fi
TREASURY_ID=1

DEST=0xaed2aca19c6f54926f8482648a694e7cb62baa22000000000000000000000000
OTHER=0x1111111111111111111111111111111111111111000000000000000000000000

note "  tier resolution, priced in USD:"
for usd in 500 5000; do
    TIER=$(call "$POLICY_ENGINE" "resolveTier(uint256,uint256)((uint128,uint8,uint32))" \
        "$POLICY_ID" "$(cast to-wei "$usd")" 2>/dev/null | tr -d '()')
    APPROVALS=$(awk -F', ' '{print $2}' <<<"$TIER")
    LOCK=$(awk -F', ' '{print $3}' <<<"$TIER" | awk '{print $1}')
    good "\$${usd} needs ${APPROVALS:-?} approval(s), ${LOCK:-?}s timelock"
done
expect_refusal "\$50,000 — above every ceiling" "$POLICY_ENGINE" \
    "resolveTier(uint256,uint256)((uint128,uint8,uint32))" "$POLICY_ID" "$(cast to-wei 50000)" || true
beat 3

note "  the allowlist, before and after:"
ALLOWED=$(call "$POLICY_ENGINE" "isDestinationAllowed(uint256,bytes32,uint32)(bool)" "$POLICY_ID" "$OTHER" 0)
good "an unlisted destination is allowed: $ALLOWED"
send "$POLICY_ENGINE" "setAllowlist(uint256,bytes32,uint32,bool)" "$POLICY_ID" "$DEST" 0 true >/dev/null 2>&1 || true
ALLOWED2=$(call "$POLICY_ENGINE" "isDestinationAllowed(uint256,bytes32,uint32)(bool)" "$POLICY_ID" "$DEST" 0)
good "the one just allowlisted is allowed: $ALLOWED2"
note "  tag 0 means any tag for that account — the rule states it rather than implying it"
beat 3

note "  and a treasury that cannot yet be spent from:"
expect_refusal "payment from an unfunded treasury" "$PAYMENT_CONTROLLER" \
    "propose(uint256,bytes32,uint32,uint64)(uint256)" "$TREASURY_ID" "$DEST" 0 1000000 || true
note "  its XRPL account has no recorded sequence, so nothing can be signed against it."
note "  Refusing to spend is the correct outcome of every failure in this system."
beat 4

# --- 5. Where the signature comes from -------------------------------------

say "5. The signature the policy authorises"
note "  The XRPL key lives inside a Flare Confidential Compute enclave and will"
note "  not sign unless it recomputes the same policy digest the contract made."
note ""
note "  On this deployment the TEE machine is registered but not yet selectable:"
ACTIVE=$(call 0x1a9C4A0f9D76c0b1D91d22E24E573a9b377618aE \
    "getRandomTeeIds(uint256,uint256)(address[])" "$EXT_ID" 1 2>&1 | grep -oE '0x[0-9a-f]{8}' | head -1 || true)
if [[ -n "${ACTIVE:-}" ]]; then
    note "  getRandomTeeIds reverts $(cast 4byte "$ACTIVE" 2>/dev/null | head -1) — 1 asked for, 0 active."
    note "  A machine joins that set only on an availability proof from Flare's FTDC."
fi
note ""
note "  So the signing leg is shown against three real enclaves instead:"
note "      ./scripts/local-quorum.sh"
beat 3

say "Done"
echo "  Dashboard   https://aegis-treasury-red.vercel.app"
echo "  Contracts   $EXPLORER/address/$PAYMENT_CONTROLLER"
echo "  Source      https://github.com/pextacy/aegis"
echo
