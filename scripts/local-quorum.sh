#!/usr/bin/env bash
#
# local-quorum.sh — Run the k-of-n cycle for real, without a faucet.
#
# Drives the whole Phase 6 path against a local chain and three real enclave
# processes, each holding its own key and none holding another's:
#
#   deploy -> treasury -> KEYGEN -> bind
#          -> configure 2-of-3 -> SKEYGN on three machines -> bind three signers
#          -> SETUP: sign the signer list, then retire the master key
#          -> propose -> approve -> dispatch -> MSIGN on three machines
#          -> collect a quorum -> assemble the transaction
#          -> tamper the payload, and tamper only the source account
#
# Real transactions, real contracts, three real Go extensions answering on their
# real HTTP surfaces, and the submitter's own assembler putting the shares
# together. The one thing not exercised is Flare's instruction relay, which
# needs Coston2 and a funded deployer — and the relay is exactly what the two
# digest checks defend against, which the tamper steps at the end prove.
#
# Usage: ./scripts/local-quorum.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[quorum]${NC} $*"; }
step() { echo -e "\n${CYAN}==> $*${NC}"; }
die()  { echo -e "${RED}[quorum] $*${NC}" >&2; exit 1; }

for tool in anvil cast forge jq curl go node xxd; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done

# Foundry auto-loads the project's .env, which carries CHAIN=coston2 for the real
# deployment. Exported values win over dotenv, so this pins the local chain.
export CHAIN=31337
export ETH_RPC_URL=""

RPC_PORT="${RPC_PORT:-8598}"
RPC="http://127.0.0.1:$RPC_PORT"

# Three machines. Each is a separate process with its own keystore, which is what
# makes "no single machine can sign alone" a fact about this run rather than a
# claim about the design.
EXT_PORTS=(7789 7787 7785)
SIGN_PORTS=(7788 7786 7784)

# Anvil's first account. A throwaway key on a throwaway chain.
KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
OWNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
APPROVER_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
APPROVER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8

WORK="$(mktemp -d)"
ANVIL_PID=""

# `go run` spawns the compiled binary as a grandchild, so killing the shell's
# child leaves the server listening and the next run meets an enclave that
# already holds the treasury's key.
kill_port() {
    local port="$1" pids
    pids="$(lsof -ti tcp:"$port" 2>/dev/null || true)"
    [[ -n "$pids" ]] && kill $pids 2>/dev/null || true
}

cleanup() {
    for port in "${EXT_PORTS[@]}"; do kill_port "$port"; done
    [[ -n "$ANVIL_PID" ]] && kill "$ANVIL_PID" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

send() { cast send --rpc-url "$RPC" --private-key "$KEY" "$@"; }
call() { cast call --rpc-url "$RPC" "$@"; }
b32()  { cast format-bytes32-string "$1"; }

# --- 1. Chain and three enclaves -------------------------------------------

step "Starting a local chain and three enclaves"
for port in "${EXT_PORTS[@]}"; do kill_port "$port"; done

anvil --port "$RPC_PORT" --silent > "$WORK/anvil.log" 2>&1 &
ANVIL_PID=$!
for _ in $(seq 1 40); do
    cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break
    sleep 0.25
done
cast block-number --rpc-url "$RPC" >/dev/null 2>&1 || die "anvil did not start"
log "chain up on $RPC"

for i in 0 1 2; do
    (
        cd "$PROJECT_DIR/go"
        EXTENSION_PORT="${EXT_PORTS[$i]}" SIGN_PORT="${SIGN_PORTS[$i]}" go run ./cmd
    ) > "$WORK/extension-$i.log" 2>&1 &
done

for i in 0 1 2; do
    for _ in $(seq 1 90); do
        curl -sf --max-time 2 "http://127.0.0.1:${EXT_PORTS[$i]}/state" >/dev/null 2>&1 && break
        sleep 1
    done
    curl -sf --max-time 5 "http://127.0.0.1:${EXT_PORTS[$i]}/state" >/dev/null 2>&1 \
        || { cat "$WORK/extension-$i.log" >&2; die "enclave $i did not start"; }
done
log "three enclaves up on ${EXT_PORTS[*]}"

# post_action <machine-index> <opCommand> <message-hex> -> the ActionResult JSON
post_action() {
    local machine="$1" command="$2" message="$3"
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

    curl -s --max-time 30 -X POST "http://127.0.0.1:${EXT_PORTS[$machine]}/action" \
        -H 'Content-Type: application/json' -d "$body"
}

# The last message the sender dispatched, and the id the stub gave it.
last_message() {
    call "$EXT_REGISTRY" \
        "lastSent()((bytes32,bytes32,bytes,address[],uint64,address,uint256,address[]))" \
        | tr -d '()' | awk -F', ' '{print $3}'
}
last_instruction_id() {
    local command="$1" nonce
    nonce="$(call "$EXT_REGISTRY" "sentCount()(uint256)" | awk '{print $1}')"
    cast keccak "$(cast abi-encode 'f(uint256,bytes32)' "$nonce" "$(b32 "$command")")"
}

# --- 2. Deploy, policy, treasury -------------------------------------------

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

send "$POLICY" "createPolicy((uint128,uint8,uint32)[],uint128,uint32,bool,uint8,uint32)(uint256)" \
    "[(100000000000000000000000,1,0)]" 50000000000000000000000 2592000 false 1 0 >/dev/null \
    || die "createPolicy failed"
send "$POLICY" "setRoles(uint256,address,uint8)" 1 "$OWNER" 15 >/dev/null || die "setRoles failed"
send "$POLICY" "setRoles(uint256,address,uint8)" 1 "$APPROVER" 2 >/dev/null || die "granting approver failed"
send "$REGISTRY" "createTreasury(uint256)(uint256)" 1 >/dev/null || die "createTreasury failed"
log "policy 1, treasury 1"

# --- 3. The treasury's own account, from machine 0 --------------------------

step "KEYGEN — the account the quorum will take over"
send "$SENDER" "requestKeygen(uint256)(bytes32)" 1 >/dev/null || die "requestKeygen failed"
KEYGEN_ID="$(last_instruction_id KEYGEN)"

RESULT="$(post_action 0 KEYGEN "$(last_message)")"
[[ "$(jq -r '.status' <<<"$RESULT")" == "1" ]] \
    || die "the enclave refused KEYGEN: $(jq -r '.log' <<<"$RESULT")"

DECODED="$(cast abi-decode "f()(bytes,string)" "$(jq -r '.data' <<<"$RESULT")")"
PUBKEY="$(sed -n '1p' <<<"$DECODED" | tr -d ' "')"
CLASSIC="$(sed -n '2p' <<<"$DECODED" | tr -d ' "')"
[[ "$CLASSIC" == r* ]] || die "the enclave returned a malformed address: $CLASSIC"

send "$SENDER" "submitKeygenResult(bytes32,bytes,string)" "$KEYGEN_ID" "$PUBKEY" "$CLASSIC" >/dev/null \
    || die "submitKeygenResult failed"

START_SEQUENCE=19574503
send "$REGISTRY" "setInitialSequence(uint256,uint32)" 1 "$START_SEQUENCE" >/dev/null \
    || die "setInitialSequence failed"
log "treasury account $CLASSIC, starting at sequence $START_SEQUENCE"

# --- 4. Three signer keys, one per machine ---------------------------------

step "Configuring 2-of-3 and collecting three signer keys"
send "$REGISTRY" "configureSignerSet(uint256,uint8,uint8)" 1 2 3 >/dev/null \
    || die "configureSignerSet failed"

send "$SENDER" "requestSignerKeygen(uint256)(bytes32)" 1 >/dev/null || die "requestSignerKeygen failed"
SKEYGN_ID="$(last_instruction_id SKEYGN)"
SKEYGN_MSG="$(last_message)"

SIGNER_ADDRS=()
for i in 0 1 2; do
    RESULT="$(post_action "$i" SKEYGN "$SKEYGN_MSG")"
    [[ "$(jq -r '.status' <<<"$RESULT")" == "1" ]] \
        || die "enclave $i refused SKEYGN: $(jq -r '.log' <<<"$RESULT")"

    DECODED="$(cast abi-decode "f()(bytes,string)" "$(jq -r '.data' <<<"$RESULT")")"
    SIGNER_KEY="$(sed -n '1p' <<<"$DECODED" | tr -d ' "')"
    SIGNER_ADDR="$(sed -n '2p' <<<"$DECODED" | tr -d ' "')"
    [[ "$SIGNER_ADDR" == r* ]] || die "enclave $i returned a malformed signer address"
    [[ "$SIGNER_ADDR" != "$CLASSIC" ]] || die "enclave $i reused the treasury's own key as a signer"

    send "$SENDER" "submitSignerKeygenResult(bytes32,bytes,string)" \
        "$SKEYGN_ID" "$SIGNER_KEY" "$SIGNER_ADDR" >/dev/null \
        || die "submitSignerKeygenResult failed for enclave $i"

    SIGNER_ADDRS+=("$SIGNER_ADDR")
    log "enclave $i signs as $SIGNER_ADDR"
done

# Three distinct machines must produce three distinct keys, or the list is k
# copies of one key rather than k of n.
UNIQUE="$(printf '%s\n' "${SIGNER_ADDRS[@]}" | sort -u | wc -l | tr -d ' ')"
[[ "$UNIQUE" == "3" ]] || die "the three machines did not produce three different signers"

SIGNER_SET_TUPLE="(uint8,uint8,uint8,bytes32,bytes32)"
SET_STATE="$(call "$REGISTRY" "getSignerSet(uint256)($SIGNER_SET_TUPLE)" 1 | tr -d '()' | awk -F', ' '{print $3}')"
[[ "$SET_STATE" == "2" ]] || die "the signer set did not reach Ready (2); state was $SET_STATE"
log "signer set is Ready: 2 of 3"

# --- 5. Handing the account over -------------------------------------------

step "SETUP — the signer list, then the master key's retirement"

# Only the machine that ran KEYGEN holds the master key. The other two hold
# signer keys for the same treasury and must refuse for want of the right one:
# that separation is the reason the keystore keeps two maps.
send "$SENDER" "requestSetup(uint256,uint8,uint32,uint32,uint64)(bytes32)" \
    1 0 "$START_SEQUENCE" 900000 12 >/dev/null || die "requestSetup(signer list) failed"
SETUP_ID="$(last_instruction_id SETUP)"
SETUP_MSG="$(last_message)"

for i in 1 2; do
    RESULT="$(post_action "$i" SETUP "$SETUP_MSG")"
    [[ "$(jq -r '.status' <<<"$RESULT")" == "0" ]] \
        || die "enclave $i signed a signer list without holding the master key"
    grep -q "no master key" <<<"$(jq -r '.log' <<<"$RESULT")" \
        || die "enclave $i refused, but not for want of the master key"
done
log "the two signer-only machines refused, as they must"

RESULT="$(post_action 0 SETUP "$SETUP_MSG")"
[[ "$(jq -r '.status' <<<"$RESULT")" == "1" ]] \
    || die "the master-key machine refused SETUP: $(jq -r '.log' <<<"$RESULT")"

DECODED="$(cast abi-decode "f()(bytes,bytes32)" "$(jq -r '.data' <<<"$RESULT")")"
LIST_BLOB="$(sed -n '1p' <<<"$DECODED" | tr -d ' "')"
LIST_TX="$(sed -n '2p' <<<"$DECODED" | tr -d ' "')"
[[ "${LIST_BLOB:0:6}" == "12000c" || "${LIST_BLOB:2:6}" == "12000C" ]] \
    || [[ "$(tr 'A-F' 'a-f' <<<"${LIST_BLOB:0:8}")" == "0x12000c" ]] \
    || die "the signed blob is not a SignerListSet: ${LIST_BLOB:0:12}"
log "signer list signed, XRPL transaction $LIST_TX"

send "$SENDER" "submitSetupResult(bytes32,uint8,bytes,bytes32)" "$SETUP_ID" 0 "$LIST_BLOB" "$LIST_TX" >/dev/null \
    || die "submitSetupResult failed"

# Recorded rather than proven: no FDC attestation type covers a SignerListSet,
# so what goes on-chain is the hash anyone can check against the ledger. A false
# claim routes dispatch to a quorum XRPL then refuses, which is fail-closed.
send "$REGISTRY" "confirmSignerListInstalled(uint256,bytes32)" 1 "$LIST_TX" >/dev/null \
    || die "confirmSignerListInstalled failed"

QUORUM_NOW="$(call "$REGISTRY" "signingIsQuorum(uint256)(bool)" 1)"
[[ "$QUORUM_NOW" == "true" ]] || die "the treasury is not signing by quorum"

send "$SENDER" "requestSetup(uint256,uint8,uint32,uint32,uint64)(bytes32)" \
    1 1 "$((START_SEQUENCE + 1))" 900000 12 >/dev/null || die "requestSetup(retire) failed"
RETIRE_ID="$(last_instruction_id SETUP)"

RESULT="$(post_action 0 SETUP "$(last_message)")"
[[ "$(jq -r '.status' <<<"$RESULT")" == "1" ]] \
    || die "the master key refused to retire itself: $(jq -r '.log' <<<"$RESULT")"

DECODED="$(cast abi-decode "f()(bytes,bytes32)" "$(jq -r '.data' <<<"$RESULT")")"
RETIRE_BLOB="$(sed -n '1p' <<<"$DECODED" | tr -d ' "')"
RETIRE_TX="$(sed -n '2p' <<<"$DECODED" | tr -d ' "')"
# asfDisableMaster, as the serialiser encodes SetFlag. Without it the
# transaction is a no-op that burns a fee and leaves the key live.
grep -qi "2021" <<<"$RETIRE_BLOB" || die "the retirement does not set asfDisableMaster"

send "$SENDER" "submitSetupResult(bytes32,uint8,bytes,bytes32)" "$RETIRE_ID" 1 "$RETIRE_BLOB" "$RETIRE_TX" >/dev/null \
    || die "submitSetupResult(retire) failed"
send "$REGISTRY" "confirmMasterKeyRetired(uint256,bytes32)" 1 "$RETIRE_TX" >/dev/null \
    || die "confirmMasterKeyRetired failed"
log "master key retired in $RETIRE_TX — the quorum is now the only authority"

# --- 6. A payment, signed by two of three ----------------------------------

step "propose -> approve -> dispatch -> MSIGN on three machines"
send "$CONTROLLER" "propose(uint256,bytes32,uint32,uint64)(uint256)" \
    1 "0xaed2aca19c6f54926f8482648a694e7cb62baa22000000000000000000000000" 7 1000000 >/dev/null \
    || die "propose failed"
cast send --rpc-url "$RPC" --private-key "$APPROVER_KEY" "$CONTROLLER" "approve(uint256)" 1 >/dev/null \
    || die "approve failed"
send "$CONTROLLER" "dispatch(uint256,uint32,uint32,uint64)" 1 899000 900000 12 >/dev/null \
    || die "dispatch failed"

MSIGN_ID="$(last_instruction_id MSIGN)"
MSIGN_MSG="$(last_message)"
[[ "$MSIGN_MSG" == 0x* ]] || die "could not read the dispatched multi-sign request"

for i in 0 1; do
    RESULT="$(post_action "$i" MSIGN "$MSIGN_MSG")"
    [[ "$(jq -r '.status' <<<"$RESULT")" == "1" ]] \
        || die "enclave $i refused MSIGN: $(jq -r '.log' <<<"$RESULT")"

    DECODED="$(cast abi-decode "f()(bytes,bytes)" "$(jq -r '.data' <<<"$RESULT")")"
    SHARE_KEY="$(sed -n '1p' <<<"$DECODED" | tr -d ' "')"
    SHARE_SIG="$(sed -n '2p' <<<"$DECODED" | tr -d ' "')"
    [[ ${#SHARE_SIG} -gt 100 ]] || die "enclave $i returned an implausibly short signature"

    send "$SENDER" "submitPartialSignatureResult(bytes32,bytes,bytes)" \
        "$MSIGN_ID" "$SHARE_KEY" "$SHARE_SIG" >/dev/null \
        || die "submitPartialSignatureResult failed for enclave $i"
    log "enclave $i contributed its share"
done

REQUEST_TUPLE="(uint256,bytes32,uint32,uint64,uint256,uint32,uint32,uint32,uint64,uint8,uint8,uint64,uint8,bytes32,address,uint256,uint256,bytes32,uint8)"
STATE_FIELD="$(call "$CONTROLLER" "getRequest(uint256)($REQUEST_TUPLE)" 1 | tr -d '()' | awk -F', ' '{print $13}')"
[[ "$STATE_FIELD" == "3" ]] || die "the request did not reach Signed (3); state was $STATE_FIELD"
log "request 1 is Signed on two of three shares"

# The third machine answers late. It is a straggler, not a fault, so the
# contract records it as ignored rather than reverting the relayer's call.
RESULT="$(post_action 2 MSIGN "$MSIGN_MSG")"
[[ "$(jq -r '.status' <<<"$RESULT")" == "1" ]] || die "enclave 2 refused MSIGN"
DECODED="$(cast abi-decode "f()(bytes,bytes)" "$(jq -r '.data' <<<"$RESULT")")"
send "$SENDER" "submitPartialSignatureResult(bytes32,bytes,bytes)" "$MSIGN_ID" \
    "$(sed -n '1p' <<<"$DECODED" | tr -d ' "')" "$(sed -n '2p' <<<"$DECODED" | tr -d ' "')" >/dev/null \
    || die "a late share reverted instead of being ignored"

COLLECTED="$(call "$CONTROLLER" "partialSignatureCount(uint256)(uint256)" 1 | awk '{print $1}')"
[[ "$COLLECTED" == "2" ]] || die "a late share was stored; count is $COLLECTED"
log "the late share was ignored, not stored"

# --- 7. Assembly, by the submitter's own code ------------------------------

step "Assembling the transaction from the published shares"
SHARES_JSON="$WORK/shares.json"
call "$CONTROLLER" "partialSignaturesOf(uint256)((bytes32,bytes,bytes)[])" 1 > "$WORK/shares.raw"

SOURCE_WORD="$(call "$REGISTRY" "getTreasury(uint256)((uint256,bytes32,string,uint256,bool,uint32,bool))" 1 \
    | tr -d '()' | awk -F', ' '{print $2}')"

node --input-type=module -e "
import { readFileSync } from 'node:fs';
import { assembleMultisigned } from '$PROJECT_DIR/submitter/dist/serialize.js';

const raw = readFileSync('$WORK/shares.raw', 'utf8');
const words = [...raw.matchAll(/0x[0-9a-fA-F]+/g)].map((m) => m[0]);
// (accountId, pubKey, signature) per share, in the order the contract stored them.
if (words.length !== 6) throw new Error('expected three fields for each of two shares, got ' + words.length);

const buf = (hex) => Buffer.from(hex.slice(2), 'hex');
const signers = [0, 3].map((i) => ({
  account: buf(words[i]).subarray(0, 20),
  signingPubKey: buf(words[i + 1]),
  txnSignature: buf(words[i + 2]),
}));

const { signedBlob, txHash } = assembleMultisigned({
  account: buf('$SOURCE_WORD').subarray(0, 20),
  destination: buf('0xaed2aca19c6f54926f8482648a694e7cb62baa22'),
  amountDrops: 1000000n,
  feeDrops: 12n,
  sequence: $START_SEQUENCE,
  lastLedgerSequence: 900000,
  destinationTag: 7,
  flags: 0x80000000,
}, signers);

const hex = signedBlob.toString('hex').toUpperCase();
if (!hex.startsWith('120000')) throw new Error('not a Payment: ' + hex.slice(0, 12));
if (!hex.includes('7300')) throw new Error('SigningPubKey is not the empty blob that selects the signer list');
for (const s of signers) {
  if (!hex.includes(s.account.toString('hex').toUpperCase())) throw new Error('a signer is missing from the blob');
}
console.log(JSON.stringify({ length: hex.length, txHash: txHash.toString('hex').toUpperCase() }));
" > "$SHARES_JSON" || die "assembly failed — run 'cd submitter && npm run build' first"

log "assembled $(jq -r '.length' "$SHARES_JSON") hex chars, tx $(jq -r '.txHash' "$SHARES_JSON")"

# --- 8. The two properties this all exists for -----------------------------

step "Tampering with the relayed payload"
# MultiSignRequest is a static ABI tuple of eleven 32-byte words:
#   0 requestId 1 treasuryId 2 sourceAccountId 3 destinationAccountId
#   4 destinationTag 5 amountDrops 6 sequence 7 lastLedgerSequence
#   8 feeDrops 9 policyDigest 10 multiSignDigest
# Flip the least significant byte of amountDrops (word 5). The payload still
# decodes cleanly; the only thing wrong with it is that the digest no longer
# describes it, which is exactly what a dishonest relayer produces.
AMOUNT_LSB=$(( 2 + (5 * 32 + 31) * 2 ))
TAMPERED="${MSIGN_MSG:0:$AMOUNT_LSB}$(printf '%02x' $(( (16#${MSIGN_MSG:$AMOUNT_LSB:2}) ^ 0xFF )))${MSIGN_MSG:$((AMOUNT_LSB + 2))}"
[[ ${#TAMPERED} -eq ${#MSIGN_MSG} ]] || die "the tamper changed the payload length"

for i in 0 1 2; do
    RESULT="$(post_action "$i" MSIGN "$TAMPERED")"
    [[ "$(jq -r '.status' <<<"$RESULT")" == "0" ]] || die "enclave $i signed a tampered payment"
    grep -q "policy digest mismatch" <<<"$(jq -r '.log' <<<"$RESULT")" \
        || die "enclave $i refused, but not for the digest"
done
log "every machine refused: policy digest mismatch"

step "Redirecting the payment to another account"
# Now change only sourceAccountId (word 2). The policy digest still matches —
# it never covered the source — so without the second digest this would be a
# legitimately approved payment pointed at a different signer list.
SOURCE_LSB=$(( 2 + (2 * 32 + 19) * 2 ))
REDIRECTED="${MSIGN_MSG:0:$SOURCE_LSB}$(printf '%02x' $(( (16#${MSIGN_MSG:$SOURCE_LSB:2}) ^ 0xFF )))${MSIGN_MSG:$((SOURCE_LSB + 2))}"
[[ "$REDIRECTED" != "$MSIGN_MSG" ]] || die "the redirect did not change the payload"

for i in 0 1 2; do
    RESULT="$(post_action "$i" MSIGN "$REDIRECTED")"
    [[ "$(jq -r '.status' <<<"$RESULT")" == "0" ]] || die "enclave $i signed a redirected payment"
    grep -q "source account digest mismatch" <<<"$(jq -r '.log' <<<"$RESULT")" \
        || die "enclave $i refused, but not for the source account: $(jq -r '.log' <<<"$RESULT")"
    [[ "$(jq -r '.data' <<<"$RESULT")" == "0x" ]] || die "a refused request still returned a signature"
done
log "every machine refused: source account digest mismatch"

# --- 9. No key material, on any machine ------------------------------------

step "Checking GET /state on all three"
for i in 0 1 2; do
    STATE_JSON="$(curl -s --max-time 10 "http://127.0.0.1:${EXT_PORTS[$i]}/state")"
    jq -e '.state.treasuries[0].hasSignerKey == true' <<<"$STATE_JSON" >/dev/null \
        || die "enclave $i does not report a signer key"
    grep -qiE '"priv|secret|seed' <<<"$STATE_JSON" && die "something key-shaped appeared in enclave $i's state"
done
jq -e '.state.treasuries[0].hasKey == true' <<<"$(curl -s "http://127.0.0.1:${EXT_PORTS[0]}/state")" >/dev/null \
    || die "the master-key machine does not report its key"
for i in 1 2; do
    jq -e '.state.treasuries[0].hasKey == false' <<<"$(curl -s "http://127.0.0.1:${EXT_PORTS[$i]}/state")" >/dev/null \
        || die "enclave $i reports a master key it should not hold"
done
log "each machine reports only what it holds, and no key material"

echo
log "The k-of-n cycle passed end to end on a live chain, across three real enclaves."
log "  treasury 1  -> $CLASSIC, 2 of 3"
log "  signers     -> ${SIGNER_ADDRS[*]}"
log "  request 1   -> Signed on two shares, assembled into tx $(jq -r '.txHash' "$SHARES_JSON")"
log "  a tampered payment and a redirected one were both refused by all three"
