#!/usr/bin/env bash
#
# xrpl-settlement.sh — Prove the signature is one XRPL actually accepts.
#
# local-integration.sh proves the policy cycle produces a signature. It cannot
# prove that signature is *valid*, because it signs against invented sequence
# and ledger numbers and never submits anything. That gap matters more than it
# looks: canonical field ordering, the zero-tag omission, SHA-512Half, DER with
# a low S, and RFC 6979 are each individually easy to get subtly wrong, and
# every one of them fails the same way — a blob that looks fine and that XRPL
# rejects.
#
# So this script closes it end to end, against XRPL Testnet:
#
#   deploy -> policy (allowlist ON) -> treasury -> KEYGEN
#          -> fund the enclave-born address from the XRPL faucet
#          -> read the REAL sequence and ledger from XRPL
#          -> propose -> approve -> dispatch -> SIGNTX
#          -> submit the blob to XRPL Testnet
#          -> poll until validated, then check what actually landed
#
# The key is born in the enclave and funded where it stands; nothing imports a
# key and nothing signs outside the TEE process.
#
# What is still not covered here is Flare's instruction relay and the FDC proof,
# both of which need Coston2 and a funded deployer. Everything XRPL-side is
# real: real faucet, real ledger, real validated transaction.
#
# Usage: ./scripts/xrpl-settlement.sh
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[xrpl-e2e]${NC} $*"; }
step() { echo -e "\n${CYAN}=== $* ===${NC}"; }
die()  { echo -e "${RED}[xrpl-e2e] ERROR:${NC} $*" >&2; exit 1; }

for tool in anvil cast forge jq curl go node; do
    command -v "$tool" >/dev/null || die "$tool is not on PATH"
done

if (( ${BASH_VERSINFO[0]} < 4 || (${BASH_VERSINFO[0]} == 4 && ${BASH_VERSINFO[1]} < 4) )); then
    die "bash ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]} is too old — use bash 4.4+"
fi

# Foundry auto-loads the project .env, which carries CHAIN=coston2. Exported
# values win over dotenv, so this pins the local chain for cast.
export CHAIN=31337

RPC_PORT="${RPC_PORT:-8601}"
EXT_PORT="${EXT_PORT:-7801}"
RPC="http://127.0.0.1:$RPC_PORT"
EXT="http://127.0.0.1:$EXT_PORT"

XRPL_RPC="${XRPL_RPC:-https://s.altnet.rippletest.net:51234/}"
XRPL_FAUCET="${XRPL_FAUCET:-https://faucet.altnet.rippletest.net/accounts}"

# Anvil's first two accounts. Throwaway keys on a throwaway chain.
KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
OWNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
APPROVER_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
APPROVER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8

AMOUNT_DROPS=1000000        # 1 XRP, which the stub feed prices at $0.50
FEE_DROPS=12
DEST_TAG=7                  # non-zero on purpose: exercises the tag that IS serialised
LEDGER_HEADROOM=40          # ~4s per ledger, so roughly 160s to get validated

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

# xrpl <method> <params-json> -> the .result object
xrpl() {
    curl -s --max-time 30 -X POST "$XRPL_RPC" -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg m "$1" --argjson p "$2" '{method:$m, params:[$p]}')" \
        | jq '.result'
}

# A classic address decodes to the 20-byte AccountID the contracts store,
# left-aligned in a bytes32. Right-aligning it is a real bug this project has
# already met once: it passes every on-chain check and is refused only at
# signing, after approvals have been collected.
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

# --- 1. Chain and enclave --------------------------------------------------

step "Starting a local chain and the enclave"
kill_port "$EXT_PORT"; kill_port "$RPC_PORT"; sleep 1

anvil --port "$RPC_PORT" --silent > "$WORK/anvil.log" 2>&1 &
ANVIL_PID=$!
for _ in $(seq 1 40); do cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.5; done
cast block-number --rpc-url "$RPC" >/dev/null 2>&1 || die "anvil did not start"
log "chain up on $RPC"

(
    cd "$PROJECT_DIR/go" || exit 1
    EXTENSION_PORT="$EXT_PORT" SIGN_PORT=7800 go run ./cmd
) > "$WORK/extension.log" 2>&1 &
EXT_PID=$!
for _ in $(seq 1 90); do curl -sf --max-time 2 "$EXT/state" >/dev/null 2>&1 && break; sleep 1; done
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
#
# allowlistEnforced is TRUE here, unlike local-integration.sh. The destination
# is a real account this script funds, so the allowlist can be asserted against
# a real AccountID rather than switched off.

step "Creating a policy and a treasury"
send "$POLICY" "createPolicy((uint128,uint8,uint32)[],uint128,uint32,bool,uint8,uint32)(uint256)" \
    "[(100000000000000000000000,1,0)]" 50000000000000000000000 2592000 true 1 0 >/dev/null \
    || die "createPolicy failed"
send "$POLICY" "setRoles(uint256,address,uint8)" 1 "$OWNER" 15 >/dev/null || die "setRoles failed"
send "$POLICY" "setRoles(uint256,address,uint8)" 1 "$APPROVER" 2 >/dev/null || die "granting approver failed"
send "$REGISTRY" "createTreasury(uint256)(uint256)" 1 >/dev/null || die "createTreasury failed"
log "policy 1 (allowlist enforced), treasury 1"

# --- helpers for talking to the enclave ------------------------------------

b32() { cast format-bytes32-string "$1"; }

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

# --- 4. KEYGEN, then fund the address the enclave just invented -------------

step "KEYGEN"
send "$SENDER" "requestKeygen(uint256)(bytes32)" 1 >/dev/null || die "requestKeygen failed"

KEYGEN_MSG="$(call "$EXT_REGISTRY" \
    "lastSent()((bytes32,bytes32,bytes,address[],uint64,address,uint256,address[]))" \
    | tr -d '()' | awk -F', ' '{print $3}')"
[[ "$KEYGEN_MSG" == 0x* ]] || die "could not read the dispatched keygen message"

RESULT="$(post_action KEYGEN "$KEYGEN_MSG")"
[[ "$(jq -r '.status' <<<"$RESULT")" == "1" ]] \
    || die "the enclave refused KEYGEN: $(jq -r '.log' <<<"$RESULT")"

DECODED="$(cast abi-decode "f()(bytes,string)" "$(jq -r '.data' <<<"$RESULT")")" \
    || die "decoding the keygen result failed"
PUBKEY="$(sed -n '1p' <<<"$DECODED" | tr -d ' "')"
TREASURY_ADDR="$(sed -n '2p' <<<"$DECODED" | tr -d ' "')"
[[ "$TREASURY_ADDR" == r* ]] || die "the enclave returned a malformed address: $TREASURY_ADDR"
log "enclave produced $TREASURY_ADDR"

INSTRUCTION_ID="$(cast keccak "$(cast abi-encode 'f(uint256,bytes32)' 1 "$(b32 KEYGEN)")")"
send "$SENDER" "submitKeygenResult(bytes32,bytes,string)" "$INSTRUCTION_ID" "$PUBKEY" "$TREASURY_ADDR" >/dev/null \
    || die "submitKeygenResult failed"
log "bound on-chain"

step "Funding the treasury on XRPL Testnet"
curl -s --max-time 120 -X POST "$XRPL_FAUCET" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg d "$TREASURY_ADDR" '{destination:$d}')" > "$WORK/fund.json" \
    || die "the faucet request failed"
jq -e '.amount' "$WORK/fund.json" >/dev/null \
    || die "the faucet did not fund the treasury: $(cat "$WORK/fund.json")"
log "faucet sent $(jq -r '.amount' "$WORK/fund.json") XRP to the treasury"

# The faucet returns before the payment is validated; the account has no
# sequence until it exists in a validated ledger.
for _ in $(seq 1 30); do
    ACCOUNT="$(xrpl account_info "$(jq -nc --arg a "$TREASURY_ADDR" '{account:$a, ledger_index:"validated"}')")"
    [[ "$(jq -r '.status' <<<"$ACCOUNT")" == "success" ]] && break
    sleep 4
done
[[ "$(jq -r '.status' <<<"$ACCOUNT")" == "success" ]] \
    || die "the treasury account never appeared in a validated ledger"

SEQUENCE="$(jq -r '.account_data.Sequence' <<<"$ACCOUNT")"
BALANCE="$(jq -r '.account_data.Balance' <<<"$ACCOUNT")"
log "treasury funded: $BALANCE drops, sequence $SEQUENCE"

# This is the step the whole script exists to exercise. The account XRPL just
# created starts at the ledger index it was funded in — the number above, in the
# tens of millions — and a treasury that assumed 1 would sign a transaction the
# network rejects and no proof could ever settle. It cannot be done at KEYGEN
# because the account did not exist then.
send "$REGISTRY" "setInitialSequence(uint256,uint32)" 1 "$SEQUENCE" >/dev/null \
    || die "setInitialSequence failed"
RECORDED="$(call "$REGISTRY" "nextSequenceOf(uint256)(uint32)" 1 | awk '{print $1}')"
[[ "$RECORDED" == "$SEQUENCE" ]] || die "the registry recorded $RECORDED, XRPL says $SEQUENCE"
log "starting sequence recorded on-chain"

step "Creating the destination account"
curl -s --max-time 120 -X POST "$XRPL_FAUCET" -H 'Content-Type: application/json' -d '{}' > "$WORK/dest.json" \
    || die "the faucet request for the destination failed"
DEST_ADDR="$(jq -r '.account.classicAddress' "$WORK/dest.json")"
[[ "$DEST_ADDR" == r* ]] || die "the faucet returned no destination address"
DEST_B32="$(account_id_bytes32 "$DEST_ADDR")" || die "could not decode $DEST_ADDR"
log "destination $DEST_ADDR -> $DEST_B32"

send "$POLICY" "setAllowlist(uint256,bytes32,uint32,bool)" 1 "$DEST_B32" "$DEST_TAG" true >/dev/null \
    || die "setAllowlist failed"
call "$POLICY" "isDestinationAllowed(uint256,bytes32,uint32)(bool)" 1 "$DEST_B32" "$DEST_TAG" \
    | grep -q true || die "the allowlist did not take"
log "allowlisted with tag $DEST_TAG"

# --- 5. The payment, against real ledger numbers ---------------------------

step "propose -> approve -> dispatch -> SIGNTX"
CURRENT_LEDGER="$(xrpl ledger_current '{}' | jq -r '.ledger_current_index')"
[[ "$CURRENT_LEDGER" =~ ^[0-9]+$ ]] || die "could not read the current ledger"
LAST_LEDGER=$(( CURRENT_LEDGER + LEDGER_HEADROOM ))
log "ledger $CURRENT_LEDGER, expiring at $LAST_LEDGER"

send "$CONTROLLER" "propose(uint256,bytes32,uint32,uint64)(uint256)" \
    1 "$DEST_B32" "$DEST_TAG" "$AMOUNT_DROPS" >/dev/null || die "propose failed"
cast send --rpc-url "$RPC" --private-key "$APPROVER_KEY" "$CONTROLLER" "approve(uint256)" 1 >/dev/null \
    || die "approve failed"

DISPATCH_SIG="dispatch(uint256,uint32,uint32,uint64)"
if ! call --from "$OWNER" "$CONTROLLER" "$DISPATCH_SIG" 1 "$CURRENT_LEDGER" "$LAST_LEDGER" "$FEE_DROPS" \
        > "$WORK/dispatch.sim" 2>&1; then
    tail -40 "$WORK/dispatch.sim" >&2
    die "dispatch would revert"
fi
send "$CONTROLLER" "$DISPATCH_SIG" 1 "$CURRENT_LEDGER" "$LAST_LEDGER" "$FEE_DROPS" >/dev/null \
    || die "dispatch failed"

SIGN_MSG="$(call "$EXT_REGISTRY" \
    "lastSent()((bytes32,bytes32,bytes,address[],uint64,address,uint256,address[]))" \
    | tr -d '()' | awk -F', ' '{print $3}')"
[[ "$SIGN_MSG" == 0x* ]] || die "could not read the dispatched sign request"

RESULT="$(post_action SIGNTX "$SIGN_MSG")"
[[ "$(jq -r '.status' <<<"$RESULT")" == "1" ]] \
    || die "the enclave refused SIGNTX: $(jq -r '.log' <<<"$RESULT")"

SIGNED="$(cast abi-decode "f()(bytes,bytes32)" "$(jq -r '.data' <<<"$RESULT")")"
BLOB="$(sed -n '1p' <<<"$SIGNED" | tr -d ' "')"
TXHASH="$(sed -n '2p' <<<"$SIGNED" | tr -d ' "')"
[[ ${#BLOB} -gt 100 ]] || die "the signed blob is implausibly short: $BLOB"
log "signed blob ${#BLOB} hex chars"
log "tx hash computed in the enclave: $TXHASH"

SIGN_INSTRUCTION_ID="$(cast keccak "$(cast abi-encode 'f(uint256,bytes32)' 2 "$(b32 SIGNTX)")")"
send "$SENDER" "submitSignatureResult(bytes32,bytes,bytes32)" "$SIGN_INSTRUCTION_ID" "$BLOB" "$TXHASH" >/dev/null \
    || die "submitSignatureResult failed"
log "request 1 recorded as Signed"

# --- 6. Submit it to XRPL --------------------------------------------------

step "Submitting to XRPL Testnet"
BLOB_HEX="$(tr '[:lower:]' '[:upper:]' <<<"${BLOB#0x}")"
SUBMIT="$(xrpl submit "$(jq -nc --arg b "$BLOB_HEX" '{tx_blob:$b}')")"
ENGINE="$(jq -r '.engine_result // "none"' <<<"$SUBMIT")"
log "engine result: $ENGINE — $(jq -r '.engine_result_message // ""' <<<"$SUBMIT")"

# A malformed or badly signed blob never reaches a ledger, and says so here.
case "$ENGINE" in
    tesSUCCESS|terQUEUED) ;;
    tefPAST_SEQ|tefALREADY) log "already seen by the network, polling anyway" ;;
    *) echo "$SUBMIT" | jq . >&2; die "XRPL rejected the blob outright: $ENGINE" ;;
esac

# The enclave computes the transaction id itself, from the signed blob. If XRPL
# validates a transaction under that same hash, the serialisation matched
# byte-for-byte — there is no way to arrive at the same SHA-512Half otherwise.
SUBMITTED_HASH="$(jq -r '.tx_json.hash // empty' <<<"$SUBMIT")"
EXPECTED_HASH="$(tr '[:lower:]' '[:upper:]' <<<"${TXHASH#0x}")"
if [[ -n "$SUBMITTED_HASH" ]]; then
    [[ "$SUBMITTED_HASH" == "$EXPECTED_HASH" ]] \
        || die "XRPL parsed a different transaction id: $SUBMITTED_HASH vs $EXPECTED_HASH"
    log "XRPL agrees on the transaction id"
fi

step "Waiting for validation"
VALIDATED=false
for _ in $(seq 1 45); do
    TX="$(xrpl tx "$(jq -nc --arg t "$EXPECTED_HASH" '{transaction:$t}')")"
    if [[ "$(jq -r '.validated // false' <<<"$TX")" == "true" ]]; then VALIDATED=true; break; fi
    NOW="$(xrpl ledger_current '{}' | jq -r '.ledger_current_index')"
    if [[ "$NOW" =~ ^[0-9]+$ ]] && (( NOW > LAST_LEDGER )); then
        die "the ledger passed $LAST_LEDGER with nothing validated — this is the confirmNonExecution path, not a pass"
    fi
    sleep 4
done
[[ "$VALIDATED" == "true" ]] || die "the transaction never validated"

# --- 7. Check what actually landed -----------------------------------------

step "Checking the validated transaction"
RESULT_CODE="$(jq -r '.meta.TransactionResult // .metaData.TransactionResult' <<<"$TX")"
DELIVERED="$(jq -r '.meta.delivered_amount // .metaData.delivered_amount' <<<"$TX")"
GOT_DEST="$(jq -r '.tx_json.Destination // .Destination' <<<"$TX")"
GOT_TAG="$(jq -r '.tx_json.DestinationTag // .DestinationTag' <<<"$TX")"
GOT_ACCOUNT="$(jq -r '.tx_json.Account // .Account' <<<"$TX")"
GOT_SEQ="$(jq -r '.tx_json.Sequence // .Sequence' <<<"$TX")"
GOT_LLS="$(jq -r '.tx_json.LastLedgerSequence // .LastLedgerSequence' <<<"$TX")"
LEDGER_IDX="$(jq -r '.ledger_index' <<<"$TX")"

[[ "$RESULT_CODE" == "tesSUCCESS" ]] || die "the transaction landed but failed: $RESULT_CODE"
[[ "$GOT_ACCOUNT" == "$TREASURY_ADDR" ]] || die "source mismatch: $GOT_ACCOUNT"
[[ "$GOT_DEST" == "$DEST_ADDR" ]]        || die "destination mismatch: $GOT_DEST"
[[ "$GOT_TAG" == "$DEST_TAG" ]]          || die "destination tag mismatch: $GOT_TAG"
[[ "$DELIVERED" == "$AMOUNT_DROPS" ]]    || die "delivered $DELIVERED, authorised $AMOUNT_DROPS"
[[ "$GOT_LLS" == "$LAST_LEDGER" ]]       || die "LastLedgerSequence mismatch: $GOT_LLS"

# The memo is what ExecutionVerifier matches an FDC proof against. If this does
# not equal keccak256(abi.encode(requestId)), settlement cannot be proven on
# Coston2 no matter how well the payment itself went.
EXPECTED_MEMO="$(tr '[:lower:]' '[:upper:]' <<<"$(cast keccak "$(cast abi-encode 'f(uint256)' 1)")")"
EXPECTED_MEMO="${EXPECTED_MEMO#0X}"
GOT_MEMO="$(jq -r '[.tx_json.Memos[]?, .Memos[]?] | .[0].Memo.MemoData // empty' <<<"$TX")"
[[ "$GOT_MEMO" == "$EXPECTED_MEMO" ]] \
    || die "memo mismatch: $GOT_MEMO vs $EXPECTED_MEMO — ExecutionVerifier could not match this payment"

echo
log "Settled on XRPL Testnet, in ledger $LEDGER_IDX."
log "  treasury    $TREASURY_ADDR (key born in the enclave, never exported)"
log "  destination $DEST_ADDR tag $GOT_TAG"
log "  delivered   $DELIVERED drops, sequence $GOT_SEQ, expiring $GOT_LLS"
log "  tx          $EXPECTED_HASH"
log "  memo        $GOT_MEMO == keccak256(abi.encode(1))"
log "The enclave's transaction id matched the one XRPL validated, so the"
log "serialisation is byte-identical to what the network parsed."
