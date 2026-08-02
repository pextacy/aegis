#!/usr/bin/env bash
#
# local-integration.sh — Run the Phase 3 cycle for real, without a faucet.
#
# Drives the whole path against a local chain and the real enclave process:
#
#   deploy -> policy -> treasury -> KEYGEN -> bind
#          -> propose -> approve -> dispatch -> SIGNTX -> record
#          -> tamper the payload and confirm the enclave refuses
#
# Real transactions, real contracts, the real Go extension answering on its real
# HTTP surface. The one thing not exercised is Flare's instruction relay, which
# needs Coston2 and a funded deployer — the relay is what carries the message
# between dispatch and the enclave, so here the script hands it over directly.
# That is exactly the boundary the policy digest exists to protect, and the
# tamper step at the end proves the protection works.
#
# Usage: ./scripts/local-integration.sh
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[local-e2e]${NC} $*"; }
step() { echo -e "\n${CYAN}=== $* ===${NC}"; }
die()  { echo -e "${RED}[local-e2e] ERROR:${NC} $*" >&2; exit 1; }

for tool in anvil cast forge jq curl go; do
    command -v "$tool" >/dev/null || die "$tool is not on PATH"
done

# Foundry auto-loads the project's .env, which carries CHAIN=coston2 for the
# real deployment. cast would then try to resolve a chain that is not this one.
# Exported values win over dotenv, so this pins the local chain.
export CHAIN=31337

RPC_PORT="${RPC_PORT:-8599}"
EXT_PORT="${EXT_PORT:-7799}"
RPC="http://127.0.0.1:$RPC_PORT"
EXT="http://127.0.0.1:$EXT_PORT"

# Anvil's first account. A throwaway key on a throwaway chain.
KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
OWNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

WORK="$(mktemp -d)"
ANVIL_PID=""
EXT_PID=""
# `go run` spawns the compiled binary as a grandchild, so killing the shell's
# child leaves the server listening and the next run meets an enclave that
# already holds the treasury's key.
kill_port() {
    local pids
    pids="$(lsof -ti "tcp:$1" 2>/dev/null)"
    [[ -n "$pids" ]] && kill $pids 2>/dev/null
    return 0
}

cleanup() {
    [[ -n "$EXT_PID" ]] && kill "$EXT_PID" 2>/dev/null
    [[ -n "$ANVIL_PID" ]] && kill "$ANVIL_PID" 2>/dev/null
    kill_port "$EXT_PORT"
    kill_port "$RPC_PORT"
    rm -rf "$WORK"
}
trap cleanup EXIT

send() { cast send --rpc-url "$RPC" --private-key "$KEY" "$@"; }
call() { cast call --rpc-url "$RPC" "$@"; }

# --- 1. Chain and enclave --------------------------------------------------

step "Starting a local chain and the enclave"

# A leftover from an interrupted run would answer with state we did not create.
kill_port "$EXT_PORT"
kill_port "$RPC_PORT"
sleep 1

anvil --port "$RPC_PORT" --silent > "$WORK/anvil.log" 2>&1 &
ANVIL_PID=$!
for _ in $(seq 1 40); do
    cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break
    sleep 0.5
done
cast block-number --rpc-url "$RPC" >/dev/null 2>&1 || die "anvil did not start"
log "chain up on $RPC"

(
    cd "$PROJECT_DIR/go" || exit 1
    EXTENSION_PORT="$EXT_PORT" SIGN_PORT=7798 go run ./cmd
) > "$WORK/extension.log" 2>&1 &
EXT_PID=$!
for _ in $(seq 1 90); do
    curl -sf --max-time 2 "$EXT/state" >/dev/null 2>&1 && break
    sleep 1
done
curl -sf --max-time 5 "$EXT/state" >/dev/null 2>&1 \
    || { cat "$WORK/extension.log" >&2; die "the extension did not start"; }
log "enclave up on $EXT"

# --- 2. Deploy -------------------------------------------------------------

step "Deploying"
forge script "$PROJECT_DIR/test/integration/DeployLocal.s.sol:DeployLocal" \
    --rpc-url "$RPC" --private-key "$KEY" --broadcast \
    > "$WORK/deploy.log" 2>&1 || { tail -40 "$WORK/deploy.log" >&2; die "deploy failed"; }

grab() { grep -oE "$1 +0x[0-9a-fA-F]{40}" "$WORK/deploy.log" | tail -1 | grep -oE '0x[0-9a-fA-F]{40}'; }
POLICY="$(grab POLICY_ENGINE)"
REGISTRY="$(grab TREASURY_REGISTRY)"
CONTROLLER="$(grab PAYMENT_CONTROLLER)"
SENDER="$(grab AEGIS_INSTRUCTION_SENDER)"
EXT_REGISTRY="$(grab EXT_REGISTRY_STUB)"
for v in POLICY REGISTRY CONTROLLER SENDER EXT_REGISTRY; do
    [[ -n "${!v}" ]] || { tail -40 "$WORK/deploy.log" >&2; die "could not read $v"; }
done
log "sender $SENDER"

# --- 3. Policy and treasury ------------------------------------------------

step "Creating a policy and a treasury"
send "$POLICY" "createPolicy((uint128,uint8,uint32)[],uint128,uint32,bool,uint8,uint32)(uint256)" \
    "[(100000000000000000000000,1,0)]" 50000000000000000000000 2592000 false 1 0 >/dev/null \
    || die "createPolicy failed"
send "$POLICY" "setRoles(uint256,address,uint8)" 1 "$OWNER" 15 >/dev/null || die "setRoles failed"
send "$REGISTRY" "createTreasury(uint256)(uint256)" 1 >/dev/null || die "createTreasury failed"
log "policy 1, treasury 1"

# --- helpers for talking to the enclave ------------------------------------

b32() { cast format-bytes32-string "$1"; }

# post_action <opCommand> <message-hex> -> the ActionResult JSON
post_action() {
    local command="$1" message="$2"
    local data_fixed body
    data_fixed="$(jq -nc \
        --arg op "$(b32 XRPLW)" \
        --arg cmd "$(b32 "$command")" \
        --arg msg "$message" \
        '{instructionId:"0x1111111111111111111111111111111111111111111111111111111111111111",
          teeId:"0x0000000000000000000000000000000000000000",
          timestamp:1700000000, rewardEpochId:42,
          opType:$op, opCommand:$cmd,
          cosigners:[], cosignersThreshold:0,
          originalMessage:$msg, additionalFixedMessage:"0x"}')"

    body="$(jq -nc --arg m "0x$(printf '%s' "$data_fixed" | xxd -p | tr -d '\n')" \
        '{data:{id:"0x1111111111111111111111111111111111111111111111111111111111111111",
                type:"instruction", submissionTag:"submit", message:$m},
          additionalVariableMessages:[], timestamps:[],
          additionalActionData:"0x", signatures:[]}')"

    curl -s --max-time 30 -X POST "$EXT/action" -H 'Content-Type: application/json' -d "$body"
}

# --- 4. KEYGEN -------------------------------------------------------------

step "KEYGEN"
send "$SENDER" "requestKeygen(uint256)(bytes32)" 1 >/dev/null || die "requestKeygen failed"

KEYGEN_MSG="$(call "$EXT_REGISTRY" \
    "lastSent()((bytes32,bytes32,bytes,address[],uint64,address,uint256,address[]))" \
    | tr -d '()' | awk -F', ' '{print $3}')"
[[ "$KEYGEN_MSG" == 0x* ]] || die "could not read the dispatched keygen message"
log "dispatched message $KEYGEN_MSG"

RESULT="$(post_action KEYGEN "$KEYGEN_MSG")"
STATUS="$(jq -r '.status' <<<"$RESULT")"
[[ "$STATUS" == "1" ]] || die "the enclave refused KEYGEN: $(jq -r '.log' <<<"$RESULT")"

DECODED="$(cast abi-decode "f()(bytes,string)" "$(jq -r '.data' <<<"$RESULT")")" \
    || die "decoding the keygen result failed"
PUBKEY="$(sed -n '1p' <<<"$DECODED" | tr -d ' "')"
CLASSIC="$(sed -n '2p' <<<"$DECODED" | tr -d ' "')"
[[ "$CLASSIC" == r* ]] || die "the enclave returned a malformed address: $CLASSIC"
log "enclave produced $CLASSIC"

INSTRUCTION_ID="$(cast keccak "$(cast abi-encode 'f(uint256,bytes32)' 1 "$(b32 KEYGEN)")")"
send "$SENDER" "submitKeygenResult(bytes32,bytes,string)" "$INSTRUCTION_ID" "$PUBKEY" "$CLASSIC" >/dev/null \
    || die "submitKeygenResult failed"

BOUND="$(call "$REGISTRY" "getTreasury(uint256)((uint256,bytes32,string,uint256,bool,uint32,bool))" 1)"
grep -q "$CLASSIC" <<<"$BOUND" || die "the treasury does not carry the enclave's address"
log "bound on-chain: $CLASSIC"

# A treasury refuses to pay until it knows the sequence its XRPL account starts
# at, because an account created since the DeletableAccounts amendment starts at
# the ledger index it was funded in, not at 1. No account is funded on this
# local run, so a plausible height stands in — scripts/xrpl-settlement.sh is the
# one that reads the real number off the ledger.
START_SEQUENCE=19574503
send "$REGISTRY" "setInitialSequence(uint256,uint32)" 1 "$START_SEQUENCE" >/dev/null \
    || die "setInitialSequence failed"
log "starting sequence $START_SEQUENCE recorded"

# --- 5. A payment, end to end ----------------------------------------------

step "propose -> approve -> dispatch -> SIGNTX"
send "$CONTROLLER" "propose(uint256,bytes32,uint32,uint64)(uint256)" \
    1 "0xaed2aca19c6f54926f8482648a694e7cb62baa22000000000000000000000000" 7 1000000 >/dev/null \
    || die "propose failed"

# The proposer cannot approve, so a second account does.
APPROVER_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
APPROVER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
send "$POLICY" "setRoles(uint256,address,uint8)" 1 "$APPROVER" 2 >/dev/null || die "granting approver failed"
cast send --rpc-url "$RPC" --private-key "$APPROVER_KEY" "$CONTROLLER" "approve(uint256)" 1 >/dev/null \
    || die "approve failed"

# Simulate first: cast decodes custom errors on a call but not on a failed
# estimate, so this is what turns "execution reverted" into the rule that fired.
# dispatch takes the ledger range: nothing signed here may land before
# firstLedgerSequence or after lastLedgerSequence.
DISPATCH_SIG="dispatch(uint256,uint32,uint32,uint64)"
if ! call --from "$OWNER" "$CONTROLLER" "$DISPATCH_SIG" 1 899000 900000 12 > "$WORK/dispatch.sim" 2>&1; then
    cast call --rpc-url "$RPC" --from "$OWNER" --trace \
        "$CONTROLLER" "$DISPATCH_SIG" 1 899000 900000 12 >> "$WORK/dispatch.sim" 2>&1 || true
    tail -40 "$WORK/dispatch.sim" >&2
    die "dispatch would revert"
fi
send "$CONTROLLER" "$DISPATCH_SIG" 1 899000 900000 12 >/dev/null || die "dispatch failed"

SIGN_MSG="$(call "$EXT_REGISTRY" \
    "lastSent()((bytes32,bytes32,bytes,address[],uint64,address,uint256,address[]))" \
    | tr -d '()' | awk -F', ' '{print $3}')"
[[ "$SIGN_MSG" == 0x* ]] || die "could not read the dispatched sign request"

RESULT="$(post_action SIGNTX "$SIGN_MSG")"
STATUS="$(jq -r '.status' <<<"$RESULT")"
[[ "$STATUS" == "1" ]] || die "the enclave refused SIGNTX: $(jq -r '.log' <<<"$RESULT")"

SIGNED="$(cast abi-decode "f()(bytes,bytes32)" "$(jq -r '.data' <<<"$RESULT")")"
BLOB="$(sed -n '1p' <<<"$SIGNED" | tr -d ' "')"
TXHASH="$(sed -n '2p' <<<"$SIGNED" | tr -d ' "')"
[[ ${#BLOB} -gt 100 ]] || die "the signed blob is implausibly short: $BLOB"
log "signed blob ${#BLOB} hex chars, tx $TXHASH"

SIGN_INSTRUCTION_ID="$(cast keccak "$(cast abi-encode 'f(uint256,bytes32)' 2 "$(b32 SIGNTX)")")"
send "$SENDER" "submitSignatureResult(bytes32,bytes,bytes32)" "$SIGN_INSTRUCTION_ID" "$BLOB" "$TXHASH" >/dev/null \
    || die "submitSignatureResult failed"

REQUEST_TUPLE="(uint256,bytes32,uint32,uint64,uint256,uint32,uint32,uint32,uint64,uint8,uint8,uint64,uint8,bytes32,address,uint256,uint256)"
STATE="$(call "$CONTROLLER" "getRequest(uint256)($REQUEST_TUPLE)" 1)"
STATE_FIELD="$(tr -d '()' <<<"$STATE" | awk -F', ' '{print $13}')"
[[ "$STATE_FIELD" == "3" ]] \
    || die "the request did not reach Signed (3); state was $STATE_FIELD"
log "request 1 is Signed"

# --- 6. The property this all exists for -----------------------------------

step "Tampering with the relayed payload"
# SignRequest is a static ABI tuple of nine 32-byte words:
#   0 requestId  1 treasuryId  2 destinationAccountId  3 destinationTag
#   4 amountDrops  5 sequence  6 lastLedgerSequence  7 feeDrops  8 policyDigest
# Flip the least significant byte of amountDrops (word 4, byte 31). That keeps
# the encoding valid, so the payload decodes cleanly and the only thing wrong
# with it is that the digest no longer describes it — which is exactly what a
# dishonest relayer produces. Corrupting a narrow field's padding instead would
# be caught at decode, before the check under test.
AMOUNT_LSB=$(( 2 + (4 * 32 + 31) * 2 ))
TAMPERED="${SIGN_MSG:0:$AMOUNT_LSB}$(printf '%02x' $(( (16#${SIGN_MSG:$AMOUNT_LSB:2}) ^ 0xFF )))${SIGN_MSG:$((AMOUNT_LSB + 2))}"
[[ "$TAMPERED" != "$SIGN_MSG" ]] || die "the tamper did not change the payload"
[[ ${#TAMPERED} -eq ${#SIGN_MSG} ]] || die "the tamper changed the payload length"

RESULT="$(post_action SIGNTX "$TAMPERED")"
STATUS="$(jq -r '.status' <<<"$RESULT")"
LOG="$(jq -r '.log' <<<"$RESULT")"

[[ "$STATUS" == "0" ]] || die "the enclave signed a tampered payload"
grep -q "policy digest mismatch" <<<"$LOG" || die "refused, but not for the digest: $LOG"
log "refused: $LOG"

DATA="$(jq -r '.data' <<<"$RESULT")"
[[ "$DATA" == "0x" || "$DATA" == "null" ]] || die "a refused request still returned data"
log "no signature was produced"

# --- 7. /state must still hold no key --------------------------------------

step "Checking GET /state"
STATE_JSON="$(curl -s --max-time 10 "$EXT/state")"
jq -e '.state.treasuries | length == 1' <<<"$STATE_JSON" >/dev/null || die "unexpected treasury count"
jq -e '.state.signedCount == 1 and .state.rejectedCount == 1' <<<"$STATE_JSON" >/dev/null \
    || die "counters disagree with what happened: $STATE_JSON"
grep -qiE '"priv|secret|[0-9a-f]{64}"' <<<"$(jq -r '.state.treasuries[].classicAddress' <<<"$STATE_JSON")" \
    && die "something key-shaped appeared in /state"
log "state reports booleans, counters and addresses only"

echo
log "Phase 3 cycle passed end to end on a live chain."
log "  treasury 1 -> $CLASSIC"
log "  request 1  -> Signed, tx $TXHASH"
log "  a tampered payload was refused with 'policy digest mismatch'"
