#!/usr/bin/env bash
#
# aegis-e2e.sh — Phase 3 acceptance, end to end on Coston2.
#
# Deploys the Aegis contracts, registers the sender as an FCC extension, creates
# a policy and a treasury, asks the enclave to generate the treasury's XRPL key,
# relays the result on-chain, and confirms the binding.
#
# This replaces the scaffold's SAY_HELLO test as the environment proof: the
# enclave now answers XRPLW, not GREETING, so the greeting test can no longer
# pass and a KEYGEN completing is the stronger statement anyway.
#
# Usage:
#   ./scripts/aegis-e2e.sh deploy    # deploy + register, write config/extension.env
#   ./scripts/aegis-e2e.sh verify    # policy, treasury, KEYGEN, bind
#   ./scripts/aegis-e2e.sh           # both, for a stack that is already up
#
# The two stages exist because the TEE machine has to be registered against this
# extension id before the enclave will answer, and post-build.sh does that in
# between. Registering a second extension while the machine is bound to the
# first is what produces MachineManager.TooMany().
#
# Requires bash 4.4+, a funded deployer, a running tunnel, a running indexer,
# and the services up (./scripts/start-services.sh --chain coston2).
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[aegis-e2e]${NC} $*"; }
step() { echo -e "\n${CYAN}=== $* ===${NC}"; }
die()  { echo -e "${RED}[aegis-e2e] ERROR:${NC} $*" >&2; exit 1; }

STAGE="${1:-all}"
case "$STAGE" in deploy|verify|all) ;; *) die "unknown stage: $STAGE (deploy|verify|all)" ;; esac

[[ -f "$PROJECT_DIR/.env" ]] || die "no .env — run ./scripts/use-chain.sh coston2"
set -a; source "$PROJECT_DIR/.env"; set +a

CHAIN_URL="${CHAIN_URL:-https://coston2-api.flare.network/ext/C/rpc}"
ADDRESSES="${ADDRESSES_FILE:-$PROJECT_DIR/config/coston2/deployed-addresses.json}"
[[ "$ADDRESSES" = /* ]] || ADDRESSES="$PROJECT_DIR/$ADDRESSES"

for tool in cast forge jq curl; do
    command -v "$tool" >/dev/null || die "$tool is not on PATH"
done
[[ -n "${EXT_PROXY_URL:-}" ]] || die "EXT_PROXY_URL unset — run ./scripts/tunnel.sh"
[[ -n "${DEPLOYMENT_PRIVATE_KEY:-}" ]] || die "DEPLOYMENT_PRIVATE_KEY unset"

KEY="0x${DEPLOYMENT_PRIVATE_KEY#0x}"
OWNER="${INITIAL_OWNER:?INITIAL_OWNER unset}"

addr_of() { jq -r --arg n "$1" '.[] | select(.name == $n) | .address' "$ADDRESSES"; }

FTSO_V2_ADDRESS="$(addr_of FtsoV2)"
TEE_EXTENSION_REGISTRY_ADDRESS="$(addr_of TeeExtensionRegistry)"
TEE_MACHINE_REGISTRY_ADDRESS="$(addr_of TeeMachineRegistry)"
FDC_VERIFICATION_ADDRESS="$(addr_of FdcVerification)"

# The registries are named differently across deployments; fall back to the
# manager entry the deploy tool uses rather than guessing silently.
[[ -n "$TEE_EXTENSION_REGISTRY_ADDRESS" && "$TEE_EXTENSION_REGISTRY_ADDRESS" != "null" ]] \
    || TEE_EXTENSION_REGISTRY_ADDRESS="$(addr_of FlareTeeManager)"
[[ -n "$TEE_MACHINE_REGISTRY_ADDRESS" && "$TEE_MACHINE_REGISTRY_ADDRESS" != "null" ]] \
    || TEE_MACHINE_REGISTRY_ADDRESS="$(addr_of FlareTeeManager)"

for v in FTSO_V2_ADDRESS TEE_EXTENSION_REGISTRY_ADDRESS TEE_MACHINE_REGISTRY_ADDRESS FDC_VERIFICATION_ADDRESS; do
    [[ -n "${!v}" && "${!v}" != "null" ]] || die "$v not found in $ADDRESSES"
done

log "FtsoV2                $FTSO_V2_ADDRESS"
log "TeeExtensionRegistry  $TEE_EXTENSION_REGISTRY_ADDRESS"
log "TeeMachineRegistry    $TEE_MACHINE_REGISTRY_ADDRESS"
log "FdcVerification       $FDC_VERIFICATION_ADDRESS"

send() { cast send --rpc-url "$CHAIN_URL" --private-key "$KEY" "$@"; }
call() { cast call --rpc-url "$CHAIN_URL" "$@"; }

STATE_FILE="$PROJECT_DIR/config/aegis-addresses.env"

# --- 1. Deploy -------------------------------------------------------------

if [[ "$STAGE" == "verify" ]]; then
    [[ -f "$STATE_FILE" ]] || die "$STATE_FILE missing — run the deploy stage first"
    set -a; source "$STATE_FILE"; set +a
    log "reusing $STATE_FILE"
else

step "Deploying the Aegis contracts"
export FTSO_V2_ADDRESS TEE_EXTENSION_REGISTRY_ADDRESS TEE_MACHINE_REGISTRY_ADDRESS FDC_VERIFICATION_ADDRESS
export RESULT_SUBMITTER_ADDRESS="$OWNER"

DEPLOY_LOG="$PROJECT_DIR/config/aegis-deploy.log"
forge script "$PROJECT_DIR/script/DeployAegis.s.sol:DeployAegis" \
    --rpc-url "$CHAIN_URL" --private-key "$KEY" --broadcast \
    > "$DEPLOY_LOG" 2>&1 || { cat "$DEPLOY_LOG" >&2; die "deploy failed"; }

grab() { grep -oE "$1 +0x[0-9a-fA-F]{40}" "$DEPLOY_LOG" | tail -1 | grep -oE '0x[0-9a-fA-F]{40}'; }
POLICY_ENGINE="$(grab POLICY_ENGINE)"
TREASURY_REGISTRY="$(grab TREASURY_REGISTRY)"
PAYMENT_CONTROLLER="$(grab PAYMENT_CONTROLLER)"
AEGIS_SENDER="$(grab AEGIS_INSTRUCTION_SENDER)"
EXECUTION_VERIFIER="$(grab EXECUTION_VERIFIER)"

for v in POLICY_ENGINE TREASURY_REGISTRY PAYMENT_CONTROLLER AEGIS_SENDER EXECUTION_VERIFIER; do
    [[ -n "${!v}" ]] || { cat "$DEPLOY_LOG" >&2; die "could not read $v from the deploy log"; }
    log "$v ${!v}"
done

# --- 2. Register as an FCC extension ---------------------------------------

step "Registering the extension"
(
    cd "$PROJECT_DIR/tools" || exit 1
    go run ./cmd/register-extension -a "$ADDRESSES" -c "$CHAIN_URL" --instructionSender "$AEGIS_SENDER"
) || die "register-extension failed"

send "$AEGIS_SENDER" "setExtensionId()" >/dev/null || die "setExtensionId failed"
EXT_ID="$(call "$AEGIS_SENDER" "extensionId()(uint256)")"
log "extension id $EXT_ID"

# post-build.sh reads these, so the Aegis sender takes the place the scaffold's
# pre-build.sh would otherwise have filled with the Hello World contract.
cat > "$PROJECT_DIR/config/extension.env" <<EOF
# Written by aegis-e2e.sh — do not edit manually
EXTENSION_ID=$(cast to-uint256 "$EXT_ID")
INSTRUCTION_SENDER=$AEGIS_SENDER
EOF

cat > "$STATE_FILE" <<EOF
# Written by aegis-e2e.sh — do not edit manually
POLICY_ENGINE=$POLICY_ENGINE
TREASURY_REGISTRY=$TREASURY_REGISTRY
PAYMENT_CONTROLLER=$PAYMENT_CONTROLLER
AEGIS_SENDER=$AEGIS_SENDER
EXECUTION_VERIFIER=$EXECUTION_VERIFIER
EXT_ID=$EXT_ID
EOF
log "wrote config/extension.env and config/aegis-addresses.env"

fi

if [[ "$STAGE" == "deploy" ]]; then
    echo
    log "Deploy stage complete. Next: start-services.sh, post-build.sh, then"
    log "  ./scripts/aegis-e2e.sh verify"
    exit 0
fi

# --- 3. Policy and treasury ------------------------------------------------

step "Creating a policy and a treasury"
# One tier: up to $100,000, one approval, no timelock. A rolling ceiling of
# $50,000 over 30 days, no allowlist, amendments needing one approval.
send "$POLICY_ENGINE" \
    "createPolicy((uint128,uint8,uint32)[],uint128,uint32,bool,uint8,uint32)(uint256)" \
    "[(100000000000000000000000,1,0)]" 50000000000000000000000 2592000 false 1 0 >/dev/null \
    || die "createPolicy failed"

POLICY_ID=1
send "$POLICY_ENGINE" "setRoles(uint256,address,uint8)" "$POLICY_ID" "$OWNER" 15 >/dev/null \
    || die "setRoles failed"
send "$TREASURY_REGISTRY" "createTreasury(uint256)(uint256)" "$POLICY_ID" >/dev/null \
    || die "createTreasury failed"

TREASURY_ID=1
log "policy $POLICY_ID, treasury $TREASURY_ID"

# --- 4. Ask the enclave for a key ------------------------------------------

step "Requesting KEYGEN"
RECEIPT="$(send "$AEGIS_SENDER" "requestKeygen(uint256)(bytes32)" "$TREASURY_ID" --json)" \
    || die "requestKeygen failed"

# KeygenRequested(bytes32 indexed instructionId, uint256 indexed treasuryId)
TOPIC0="$(cast keccak 'KeygenRequested(bytes32,uint256)')"
INSTRUCTION_ID="$(jq -r --arg t "$TOPIC0" \
    '.logs[] | select(.topics[0] == $t) | .topics[1]' <<<"$RECEIPT" | head -1)"
[[ -n "$INSTRUCTION_ID" && "$INSTRUCTION_ID" != "null" ]] || die "no KeygenRequested event in the receipt"
log "instruction $INSTRUCTION_ID"

# --- 5. Wait for the TEE result --------------------------------------------

step "Polling the proxy for the result"
RESULT=""
for _ in $(seq 1 60); do
    RESPONSE="$(curl -s --max-time 15 "$EXT_PROXY_URL/action/result/$INSTRUCTION_ID" || true)"
    STATUS="$(jq -r '.result.status // empty' <<<"$RESPONSE" 2>/dev/null)"
    if [[ "$STATUS" == "1" ]]; then
        RESULT="$RESPONSE"
        break
    fi
    if [[ "$STATUS" == "0" ]]; then
        die "the enclave refused: $(jq -r '.result.log' <<<"$RESPONSE")"
    fi
    sleep 5
done
[[ -n "$RESULT" ]] || die "no result after five minutes — docker compose logs extension-tee"

DATA="$(jq -r '.result.data' <<<"$RESULT")"
log "result data $DATA"

# ABI (bytes compressedPubKey, string classicAddress)
DECODED="$(cast abi-decode "f()(bytes,string)" "$DATA")" || die "decoding the keygen result failed"
PUBKEY="$(sed -n '1p' <<<"$DECODED" | tr -d ' "')"
CLASSIC="$(sed -n '2p' <<<"$DECODED" | tr -d ' "')"
log "public key $PUBKEY"
log "address    $CLASSIC"

# --- 6. Bind on-chain ------------------------------------------------------

step "Binding the account on-chain"
send "$AEGIS_SENDER" "submitKeygenResult(bytes32,bytes,string)" \
    "$INSTRUCTION_ID" "$PUBKEY" "$CLASSIC" >/dev/null || die "submitKeygenResult failed"

BOUND="$(call "$TREASURY_REGISTRY" "getTreasury(uint256)((uint256,bytes32,string,uint256,bool,uint32))" "$TREASURY_ID")"
grep -q "$CLASSIC" <<<"$BOUND" || die "the treasury does not carry the address the enclave produced"
log "bound: $CLASSIC"

# --- 7. A second binding must be refused -----------------------------------

step "Confirming a treasury accepts exactly one binding"
if send "$AEGIS_SENDER" "requestKeygen(uint256)" "$TREASURY_ID" >/dev/null 2>&1; then
    die "a second keygen was accepted for an already-bound treasury"
fi
log "refused, as it must be"

echo
log "Phase 3 acceptance passed."
log "  AEGIS_INSTRUCTION_SENDER $AEGIS_SENDER"
log "  EXTENSION_ID             $EXT_ID"
log "  TREASURY                 $TREASURY_ID -> $CLASSIC"
