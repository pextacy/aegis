#!/usr/bin/env bash
#
# coston2-payment.sh — Drive a payment through the real FCC relay on Coston2.
#
# aegis-e2e.sh stops at KEYGEN and binding. This is the leg after it: fund the
# treasury on XRPL, record the sequence its account actually starts at,
# allowlist a destination, then propose -> approve -> dispatch and let Flare's
# instruction relay carry the request to the enclave. The blob comes back
# through the proxy and is recorded on-chain, which emits PaymentSigned.
#
# Settlement is deliberately NOT done here. That is the submitter's job, it is
# tested, and running it is step 9 of the README:
#
#   cd submitter && npm start
#
# The submitter needs FDC_VERIFIER_API_KEY. The verifier server answers 401
# without one and it is issued by Flare separately from the faucet.
#
# What this exercises that xrpl-settlement.sh cannot: Flare's instruction relay.
# That is the untrusted hop the policy digest exists to defend, and the only
# part of the system a local chain cannot stand in for.
#
# Usage:
#   ./scripts/coston2-payment.sh                 # treasury 1, 1 XRP
#   TREASURY_ID=2 AMOUNT_DROPS=500000 ./scripts/coston2-payment.sh
#
# Requires: a funded deployer, a registered TEE machine, the services up, and
# ./scripts/aegis-e2e.sh verify already passed.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[coston2-pay]${NC} $*"; }
step() { echo -e "\n${CYAN}=== $* ===${NC}"; }
die()  { echo -e "${RED}[coston2-pay] ERROR:${NC} $*" >&2; exit 1; }

for tool in cast jq curl node; do
    command -v "$tool" >/dev/null || die "$tool is not on PATH"
done

[[ -f "$PROJECT_DIR/.env" ]] || die "no .env — run ./scripts/use-chain.sh coston2"
set -a; source "$PROJECT_DIR/.env"; set +a

STATE_FILE="$PROJECT_DIR/config/aegis-addresses.env"
[[ -f "$STATE_FILE" ]] || die "no config/aegis-addresses.env — run ./scripts/aegis-e2e.sh deploy"
set -a; source "$STATE_FILE"; set +a

[[ -f "$PROJECT_DIR/config/extension.env" ]] && { set -a; source "$PROJECT_DIR/config/extension.env"; set +a; }

CHAIN_URL="${CHAIN_URL:-https://coston2-api.flare.network/ext/C/rpc}"
XRPL_RPC="${XRPL_RPC:-https://s.altnet.rippletest.net:51234/}"
XRPL_FAUCET="${XRPL_FAUCET:-https://faucet.altnet.rippletest.net/accounts}"

TREASURY_ID="${TREASURY_ID:-1}"
AMOUNT_DROPS="${AMOUNT_DROPS:-1000000}"
FEE_DROPS="${FEE_DROPS:-12}"
DEST_TAG="${DEST_TAG:-7}"
LEDGER_HEADROOM="${LEDGER_HEADROOM:-60}"

for v in POLICY_ENGINE TREASURY_REGISTRY PAYMENT_CONTROLLER AEGIS_INSTRUCTION_SENDER; do
    [[ -n "${!v:-}" ]] || die "$v is not set — is config/aegis-addresses.env complete?"
done
[[ -n "${EXT_PROXY_URL:-}" ]] || die "EXT_PROXY_URL unset — is the tunnel running?"
[[ -n "${DEPLOYMENT_PRIVATE_KEY:-}" ]] || die "DEPLOYMENT_PRIVATE_KEY unset"

send() { cast send --rpc-url "$CHAIN_URL" --private-key "$DEPLOYMENT_PRIVATE_KEY" "$@"; }
call() { cast call --rpc-url "$CHAIN_URL" "$@"; }

xrpl() {
    curl -s --max-time 30 -X POST "$XRPL_RPC" -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg m "$1" --argjson p "$2" '{method:$m, params:[$p]}')" | jq '.result'
}

account_id_bytes32() {
    node -e '
const A="rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz";
const crypto=require("crypto");
const s=process.argv[1];
let n=0n;
for(const c of s){const i=A.indexOf(c); if(i<0){console.error("bad base58 char: "+c);process.exit(1);} n=n*58n+BigInt(i);}
let hex=n.toString(16); if(hex.length%2) hex="0"+hex;
let body=Buffer.from(hex,"hex");
let zeros=0; for(const c of s){ if(c===A[0]) zeros++; else break; }
const full=Buffer.concat([Buffer.alloc(zeros),body]);
const payload=full.subarray(0,full.length-4), check=full.subarray(full.length-4);
const d=crypto.createHash("sha256").update(crypto.createHash("sha256").update(payload).digest()).digest().subarray(0,4);
if(!d.equals(check)){console.error("checksum mismatch");process.exit(1);}
if(payload[0]!==0x00||payload.length!==21){console.error("not a classic AccountID");process.exit(1);}
process.stdout.write("0x"+payload.subarray(1).toString("hex")+"0".repeat(24));
' "$1"
}

TREASURY_TUPLE="(uint256,bytes32,string,uint256,bool,uint32,bool)"

# --- 1. The treasury and its XRPL account ----------------------------------

step "Reading treasury $TREASURY_ID"
BOUND="$(call "$TREASURY_REGISTRY" "getTreasury(uint256)($TREASURY_TUPLE)" "$TREASURY_ID")" \
    || die "could not read treasury $TREASURY_ID"
TREASURY_ADDR="$(tr -d '()' <<<"$BOUND" | awk -F', ' '{print $3}' | tr -d ' "')"
POLICY_ID="$(tr -d '()' <<<"$BOUND" | awk -F', ' '{print $4}' | tr -d ' ')"
[[ "$TREASURY_ADDR" == r* ]] || die "treasury $TREASURY_ID has no bound XRPL account — run ./scripts/aegis-e2e.sh verify"
log "treasury $TREASURY_ID -> $TREASURY_ADDR (policy $POLICY_ID)"

step "Funding it on XRPL Testnet"
curl -s --max-time 120 -X POST "$XRPL_FAUCET" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg d "$TREASURY_ADDR" '{destination:$d}')" > /tmp/aegis-fund.json || die "the faucet request failed"
jq -e '.amount' /tmp/aegis-fund.json >/dev/null || die "the faucet did not fund it: $(cat /tmp/aegis-fund.json)"
log "faucet sent $(jq -r '.amount' /tmp/aegis-fund.json) XRP"

for _ in $(seq 1 30); do
    ACCOUNT="$(xrpl account_info "$(jq -nc --arg a "$TREASURY_ADDR" '{account:$a, ledger_index:"validated"}')")"
    [[ "$(jq -r '.status' <<<"$ACCOUNT")" == "success" ]] && break
    sleep 4
done
[[ "$(jq -r '.status' <<<"$ACCOUNT")" == "success" ]] || die "the account never appeared in a validated ledger"
SEQUENCE="$(jq -r '.account_data.Sequence' <<<"$ACCOUNT")"
log "funded, sequence $SEQUENCE"

# --- 2. Record the sequence the account actually starts at ------------------

RECORDED="$(call "$TREASURY_REGISTRY" "nextSequenceOf(uint256)(uint32)" "$TREASURY_ID" | awk '{print $1}')"
if [[ "$RECORDED" == "0" ]]; then
    step "Recording the starting sequence"
    send "$TREASURY_REGISTRY" "setInitialSequence(uint256,uint32)" "$TREASURY_ID" "$SEQUENCE" >/dev/null \
        || die "setInitialSequence failed"
    log "recorded $SEQUENCE"
else
    log "starting sequence already recorded as $RECORDED"
fi

# --- 3. A destination, allowlisted -----------------------------------------

step "Creating and allowlisting a destination"
curl -s --max-time 120 -X POST "$XRPL_FAUCET" -H 'Content-Type: application/json' -d '{}' > /tmp/aegis-dest.json \
    || die "the faucet request for a destination failed"
DEST_ADDR="$(jq -r '.account.classicAddress' /tmp/aegis-dest.json)"
[[ "$DEST_ADDR" == r* ]] || die "the faucet returned no destination"
DEST_B32="$(account_id_bytes32 "$DEST_ADDR")" || die "could not decode $DEST_ADDR"

send "$POLICY_ENGINE" "setAllowlist(uint256,bytes32,uint32,bool)" "$POLICY_ID" "$DEST_B32" "$DEST_TAG" true >/dev/null \
    || die "setAllowlist failed"
log "$DEST_ADDR tag $DEST_TAG"

# --- 4. The approver -------------------------------------------------------
#
# The proposer cannot approve their own request, so a payment needs a second
# address regardless of how the policy is written. This derives one
# deterministically from the deployer key and tops it up for gas.

step "Preparing an approver"
APPROVER_KEY="$(cast keccak "aegis-approver:$DEPLOYMENT_PRIVATE_KEY")"
APPROVER="$(cast wallet address --private-key "$APPROVER_KEY")"
send "$POLICY_ENGINE" "setRoles(uint256,address,uint8)" "$POLICY_ID" "$APPROVER" 2 >/dev/null \
    || die "granting APPROVER failed"

APPROVER_BAL="$(cast balance "$APPROVER" --rpc-url "$CHAIN_URL" 2>/dev/null || echo 0)"
if awk -v b="$APPROVER_BAL" 'BEGIN { exit !(b < 5000000000000000) }'; then
    send --value 0.01ether "$APPROVER" >/dev/null || die "could not fund the approver"
    log "funded $APPROVER for gas"
fi
log "approver $APPROVER"

# --- 5. propose -> approve -> dispatch -------------------------------------

step "propose"
RECEIPT="$(send "$PAYMENT_CONTROLLER" "propose(uint256,bytes32,uint32,uint64)(uint256)" \
    "$TREASURY_ID" "$DEST_B32" "$DEST_TAG" "$AMOUNT_DROPS" --json)" || die "propose failed"

# Read the id out of the event rather than from nextRequestId(): another
# proposal landing between the two calls would hand us someone else's request.
PROPOSED_TOPIC="$(cast keccak 'PaymentProposed(uint256,uint256,address,bytes32,uint32,uint64,uint256,uint8,uint64)')"
REQUEST_ID_HEX="$(jq -r --arg t "$PROPOSED_TOPIC" \
    '.logs[] | select(.topics[0] == $t) | .topics[1]' <<<"$RECEIPT" 2>/dev/null | head -1)"
[[ -n "$REQUEST_ID_HEX" && "$REQUEST_ID_HEX" != "null" ]] || die "no PaymentProposed event in the receipt"
REQUEST_ID="$(cast to-dec "$REQUEST_ID_HEX")"
log "request $REQUEST_ID"

step "approve"
cast send --rpc-url "$CHAIN_URL" --private-key "$APPROVER_KEY" \
    "$PAYMENT_CONTROLLER" "approve(uint256)" "$REQUEST_ID" >/dev/null || die "approve failed"

step "dispatch"
CURRENT_LEDGER="$(xrpl ledger_current '{}' | jq -r '.ledger_current_index')"
[[ "$CURRENT_LEDGER" =~ ^[0-9]+$ ]] || die "could not read the current XRPL ledger"
LAST_LEDGER=$(( CURRENT_LEDGER + LEDGER_HEADROOM ))
log "ledger $CURRENT_LEDGER, expiring at $LAST_LEDGER"

DISPATCH_SIG="dispatch(uint256,uint32,uint32,uint64)"
call --from "$INITIAL_OWNER" "$PAYMENT_CONTROLLER" "$DISPATCH_SIG" \
    "$REQUEST_ID" "$CURRENT_LEDGER" "$LAST_LEDGER" "$FEE_DROPS" >/dev/null \
    || die "dispatch would revert — the simulation names the rule"

RECEIPT="$(send "$PAYMENT_CONTROLLER" "$DISPATCH_SIG" \
    "$REQUEST_ID" "$CURRENT_LEDGER" "$LAST_LEDGER" "$FEE_DROPS" --json)" || die "dispatch failed"

# SignatureRequested(bytes32 indexed instructionId, uint256 indexed requestId,
# uint256 indexed treasuryId) — the instruction id is the first indexed field,
# so topics[1].
SIG_TOPIC="$(cast keccak 'SignatureRequested(bytes32,uint256,uint256)')"
INSTRUCTION_ID="$(jq -r --arg t "$SIG_TOPIC" \
    '.logs[] | select(.topics[0] == $t) | .topics[1]' <<<"$RECEIPT" 2>/dev/null | head -1)"
[[ -n "$INSTRUCTION_ID" && "$INSTRUCTION_ID" != "null" ]] \
    || die "no SignatureRequested event in the dispatch receipt"
log "instruction $INSTRUCTION_ID"

# --- 6. The relay ----------------------------------------------------------

step "Waiting for the enclave, through Flare's relay"
RESULT=""
for _ in $(seq 1 60); do
    RESPONSE="$(curl -s --max-time 15 "$EXT_PROXY_URL/action/result/$INSTRUCTION_ID" || true)"
    STATUS="$(jq -r '.result.status // empty' <<<"$RESPONSE" 2>/dev/null)"
    if [[ "$STATUS" == "1" ]]; then RESULT="$RESPONSE"; break; fi
    if [[ "$STATUS" == "0" ]]; then
        die "the enclave refused: $(jq -r '.result.log' <<<"$RESPONSE")"
    fi
    sleep 5
done
[[ -n "$RESULT" ]] || die "no result after five minutes — docker compose logs extension-tee"

DECODED="$(cast abi-decode "f()(bytes,bytes32)" "$(jq -r '.result.data' <<<"$RESULT")")" \
    || die "decoding the signature result failed"
BLOB="$(sed -n '1p' <<<"$DECODED" | tr -d ' "')"
TXHASH="$(sed -n '2p' <<<"$DECODED" | tr -d ' "')"
[[ ${#BLOB} -gt 100 ]] || die "the signed blob is implausibly short"
log "signed, tx $TXHASH"

step "Recording the signature on-chain"
send "$AEGIS_INSTRUCTION_SENDER" "submitSignatureResult(bytes32,bytes,bytes32)" \
    "$INSTRUCTION_ID" "$BLOB" "$TXHASH" >/dev/null || die "submitSignatureResult failed"

REQUEST_TUPLE="(uint256,bytes32,uint32,uint64,uint256,uint32,uint32,uint32,uint64,uint8,uint8,uint64,uint8,bytes32,address,uint256,uint256)"
STATE="$(call "$PAYMENT_CONTROLLER" "getRequest(uint256)($REQUEST_TUPLE)" "$REQUEST_ID")"
STATE_FIELD="$(tr -d '()' <<<"$STATE" | awk -F', ' '{print $13}')"
[[ "$STATE_FIELD" == "3" ]] || die "the request did not reach Signed (3); state was $STATE_FIELD"

echo
log "Signed on Coston2, through the real relay."
log "  request     $REQUEST_ID -> Signed"
log "  treasury    $TREASURY_ID  $TREASURY_ADDR"
log "  destination $DEST_ADDR tag $DEST_TAG"
log "  amount      $AMOUNT_DROPS drops, sequence $SEQUENCE, expiring $LAST_LEDGER"
log "  tx          $TXHASH"
echo
log "PaymentSigned is emitted. Start the submitter to settle it and bring back"
log "the FDC proof:  cd submitter && npm start"
log "It needs FDC_VERIFIER_API_KEY — the verifier server answers 401 without one."
