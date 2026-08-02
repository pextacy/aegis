#!/usr/bin/env bash
#
# coston2-fork-check.sh — Verify the Flare integration against real Coston2
# system contracts, without a funded wallet.
#
# The faucet is reCAPTCHA-gated, which has meant the Flare-side integration
# points were only ever exercised against test doubles: FtsoStub for the price,
# stub registries for the TEE, an FDC double for proofs. That leaves the highest
# risk surface in the system — real addresses, real ABIs, a real oracle —
# unverified for the one reason that has nothing to do with the code.
#
# Forking removes that. `anvil --fork-url` gives the real Coston2 state, and
# anvil_setBalance funds a deployer on the fork, so the production deploy script
# runs against the real FtsoV2, the real FlareTeeManager and the real
# FdcVerification. What this proves:
#
#   1. script/DeployAegis.s.sol deploys and wires against the real registries.
#   2. The derived XRP/USD feed id resolves on the real FtsoV2. A wrong feed id
#      is not a subtle failure here — it reverts or returns nothing — and the id
#      is built rather than pasted, so it has never been checked against the
#      contract that has to recognise it.
#   3. The drops -> USD conversion produces the right figure from the real
#      value and the real decimals, rather than from a stub's chosen ones.
#   4. The staleness check refuses a real feed once it ages past MAX_PRICE_AGE.
#      This is the fail-closed path, tested by warping the fork rather than by
#      writing a timestamp into a double.
#
# What it cannot cover, and does not claim to: Flare's instruction relay, which
# needs a registered TEE machine and a running proxy, and a real FDC attestation
# round, which needs the verifier API key. Those stay in aegis-e2e.sh and the
# submitter.
#
# Usage: ./scripts/coston2-fork-check.sh
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[fork-check]${NC} $*"; }
step() { echo -e "\n${CYAN}=== $* ===${NC}"; }
die()  { echo -e "${RED}[fork-check] ERROR:${NC} $*" >&2; exit 1; }

for tool in anvil cast forge jq node; do
    command -v "$tool" >/dev/null || die "$tool is not on PATH"
done

# The project .env carries CHAIN=coston2, which cast does not know as a chain
# name. Exported values win over dotenv.
export CHAIN=114

UPSTREAM="${UPSTREAM_RPC:-https://coston2-api.flare.network/ext/C/rpc}"
PORT="${FORK_PORT:-8620}"
RPC="http://127.0.0.1:$PORT"
ADDRESSES="$PROJECT_DIR/config/coston2/deployed-addresses.json"
[[ -f "$ADDRESSES" ]] || die "no $ADDRESSES"

KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
OWNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

# The XRP/USD feed id, built the way PaymentController builds it:
# bytes21(abi.encodePacked(uint8(1), bytes7("XRP/USD"), bytes13(0)))
FEED_ID=0x015852502f55534400000000000000000000000000
MAX_PRICE_AGE=180

ANVIL_PID=""
cleanup() {
    [[ -n "$ANVIL_PID" ]] && kill "$ANVIL_PID" 2>/dev/null
    local pids; pids="$(lsof -ti "tcp:$PORT" 2>/dev/null)"
    [[ -n "$pids" ]] && kill $pids 2>/dev/null
    return 0
}
trap cleanup EXIT

addr_of() { jq -r --arg n "$1" '.[] | select(.name == $n) | .address' "$ADDRESSES" | head -1; }
send() { cast send --rpc-url "$RPC" --private-key "$KEY" "$@"; }
call() { cast call --rpc-url "$RPC" "$@"; }

# --- 1. Fork -----------------------------------------------------------------

step "Forking Coston2"
cleanup; sleep 1
anvil --port "$PORT" --fork-url "$UPSTREAM" --silent > /tmp/aegis-fork.log 2>&1 &
ANVIL_PID=$!
for _ in $(seq 1 60); do cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done
BLOCK="$(cast block-number --rpc-url "$RPC" 2>/dev/null)" || die "the fork did not start — see /tmp/aegis-fork.log"
CHAIN_ID="$(cast chain-id --rpc-url "$RPC")"
[[ "$CHAIN_ID" == "114" ]] || die "forked chain id is $CHAIN_ID, expected 114"
log "forked at block $BLOCK, chain id $CHAIN_ID"

# --- 2. The real system contracts --------------------------------------------

step "Resolving the system contracts"
FTSO_V2_ADDRESS="$(addr_of FtsoV2)"
FDC_VERIFICATION_ADDRESS="$(addr_of FdcVerification)"
TEE_EXTENSION_REGISTRY_ADDRESS="$(addr_of TeeExtensionRegistry)"
TEE_MACHINE_REGISTRY_ADDRESS="$(addr_of TeeMachineRegistry)"
[[ -n "$TEE_EXTENSION_REGISTRY_ADDRESS" && "$TEE_EXTENSION_REGISTRY_ADDRESS" != "null" ]] \
    || TEE_EXTENSION_REGISTRY_ADDRESS="$(addr_of FlareTeeManager)"
[[ -n "$TEE_MACHINE_REGISTRY_ADDRESS" && "$TEE_MACHINE_REGISTRY_ADDRESS" != "null" ]] \
    || TEE_MACHINE_REGISTRY_ADDRESS="$(addr_of FlareTeeManager)"

for v in FTSO_V2_ADDRESS FDC_VERIFICATION_ADDRESS TEE_EXTENSION_REGISTRY_ADDRESS TEE_MACHINE_REGISTRY_ADDRESS; do
    [[ -n "${!v}" && "${!v}" != "null" ]] || die "$v missing from deployed-addresses.json"
    # An address with no code is a stale entry in the addresses file, which is
    # exactly the failure this file's own comment warns about.
    CODE="$(call "${!v}" 2>/dev/null; cast code "${!v}" --rpc-url "$RPC" 2>/dev/null)"
    [[ "${#CODE}" -gt 4 ]] || die "$v (${!v}) has no code on Coston2"
    log "$v ${!v}"
done

export FTSO_V2_ADDRESS FDC_VERIFICATION_ADDRESS TEE_EXTENSION_REGISTRY_ADDRESS TEE_MACHINE_REGISTRY_ADDRESS
export RESULT_SUBMITTER_ADDRESS="$OWNER"

# --- 3. The real feed --------------------------------------------------------

step "Reading XRP/USD from the real FtsoV2"
OUT="$(call "$FTSO_V2_ADDRESS" "getFeedById(bytes21)(uint256,int8,uint64)" "$FEED_ID" 2>&1)" \
    || die "the derived feed id did not resolve: $OUT"
VALUE="$(sed -n '1p' <<<"$OUT" | awk '{print $1}')"
DECIMALS="$(sed -n '2p' <<<"$OUT" | awk '{print $1}')"
FEED_TS="$(sed -n '3p' <<<"$OUT" | awk '{print $1}')"
[[ "$VALUE" =~ ^[0-9]+$ && "$VALUE" != "0" ]] || die "the feed returned no value: $OUT"
PRICE="$(node -e "console.log((Number(BigInt('$VALUE'))/10**$DECIMALS).toFixed(6))")"
log "value $VALUE, decimals $DECIMALS -> XRP/USD \$$PRICE"

# --- 4. The production deploy script -----------------------------------------

step "Deploying with script/DeployAegis.s.sol"
cast rpc anvil_setBalance "$OWNER" 0x21e19e0c9bab2400000 --rpc-url "$RPC" >/dev/null
forge script "$PROJECT_DIR/script/DeployAegis.s.sol:DeployAegis" \
    --rpc-url "$RPC" --private-key "$KEY" --broadcast > /tmp/aegis-fork-deploy.log 2>&1 \
    || { tail -40 /tmp/aegis-fork-deploy.log >&2; die "the deploy script failed against real system contracts"; }

grab() { grep -oE "$1 +0x[0-9a-fA-F]{40}" /tmp/aegis-fork-deploy.log | tail -1 | grep -oE '0x[0-9a-fA-F]{40}'; }
POLICY="$(grab POLICY_ENGINE)"; REG="$(grab TREASURY_REGISTRY)"
CTRL="$(grab PAYMENT_CONTROLLER)"; SENDER="$(grab AEGIS_INSTRUCTION_SENDER)"
VERIFIER="$(grab EXECUTION_VERIFIER)"
for v in POLICY REG CTRL SENDER VERIFIER; do
    [[ -n "${!v}" ]] || { tail -40 /tmp/aegis-fork-deploy.log >&2; die "could not read $v"; }
done
log "deployed and wired against the real registries"
log "  controller $CTRL"
log "  verifier   $VERIFIER"

# --- 5. A policy and a treasury ----------------------------------------------

step "Standing up a policy and a treasury"
send "$POLICY" "createPolicy((uint128,uint8,uint32)[],uint128,uint32,bool,uint8,uint32)(uint256)" \
    "[(100000000000000000000000,1,0)]" 50000000000000000000000 2592000 true 1 0 >/dev/null \
    || die "createPolicy failed"
send "$POLICY" "setRoles(uint256,address,uint8)" 1 "$OWNER" 15 >/dev/null || die "setRoles failed"
send "$REG" "createTreasury(uint256)(uint256)" 1 >/dev/null || die "createTreasury failed"

# bindXrplAccount is instruction-sender-only. On a fork the sender can be
# impersonated, which is what FCC would do through the relay.
cast rpc anvil_impersonateAccount "$SENDER" --rpc-url "$RPC" >/dev/null
cast rpc anvil_setBalance "$SENDER" 0xde0b6b3a7640000 --rpc-url "$RPC" >/dev/null
cast send --rpc-url "$RPC" --unlocked --from "$SENDER" "$REG" "bindXrplAccount(uint256,bytes,string)" 1 \
    0x0330E7FC9D56BB25D6893BA3F317AE5BCF33B3291BD63DB32654A313222F7FD020 \
    "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh" >/dev/null || die "bindXrplAccount failed"
send "$REG" "setInitialSequence(uint256,uint32)" 1 19574503 >/dev/null || die "setInitialSequence failed"

DEST=0x58d1dfcaceb23e06290fbbf7a38db1b786e380e3000000000000000000000000
send "$POLICY" "setAllowlist(uint256,bytes32,uint32,bool)" 1 "$DEST" 7 true >/dev/null || die "setAllowlist failed"
log "policy 1, treasury 1, destination allowlisted"

# --- 6. Conversion against the real price ------------------------------------

step "Pricing a payment with the real feed"
DROPS=1000000000        # 1,000 XRP
send "$CTRL" "propose(uint256,bytes32,uint32,uint64)(uint256)" 1 "$DEST" 7 "$DROPS" >/dev/null \
    || die "propose failed against the real feed"

REQ_TUPLE="(uint256,bytes32,uint32,uint64,uint256,uint32,uint32,uint32,uint64,uint8,uint8,uint64,uint8,bytes32,address,uint256,uint256)"
R="$(call "$CTRL" "getRequest(uint256)($REQ_TUPLE)" 1)"
USD="$(tr -d '()' <<<"$R" | awk -F', ' '{print $5}' | awk '{print $1}')"
[[ "$USD" =~ ^[0-9]+$ && "$USD" != "0" ]] || die "no USD amount was recorded: $R"

# The contract's own figure must agree with the feed it read, to within the
# rounding the integer maths implies.
node -e "
const usd = Number(BigInt('$USD'))/1e18;
const xrp = Number(BigInt('$DROPS'))/1e6;
const implied = usd/xrp;
const feed = Number(BigInt('$VALUE'))/10**$DECIMALS;
console.log('  ' + xrp + ' XRP -> \$' + usd.toFixed(4));
console.log('  implied XRP/USD \$' + implied.toFixed(6) + ', feed read \$' + feed.toFixed(6));
// The feed moves between the read above and the propose, so allow a little drift
// while still catching a decimals or scaling error, which would be orders out.
if (Math.abs(implied - feed) / feed > 0.05) {
  console.error('  conversion disagrees with the feed by more than 5% — check the decimal scaling');
  process.exit(1);
}
" || die "the drops -> USD conversion does not match the real feed"
log "conversion agrees with the real oracle"

# --- 7. Fail-closed on a stale real feed -------------------------------------

step "Ageing the real feed past MAX_PRICE_AGE"
cast rpc evm_increaseTime $((MAX_PRICE_AGE + 220)) --rpc-url "$RPC" >/dev/null
cast rpc evm_mine --rpc-url "$RPC" >/dev/null
NOW="$(cast block latest --rpc-url "$RPC" --field timestamp)"
log "fork clock $NOW, feed finalised $FEED_TS, age $((NOW - FEED_TS))s"

STALE_SELECTOR="$(cast sig 'StalePrice(uint64,uint64)')"
if OUT="$(call --from "$OWNER" "$CTRL" "propose(uint256,bytes32,uint32,uint64)(uint256)" 1 "$DEST" 7 "$DROPS" 2>&1)"; then
    die "propose succeeded against a stale feed — the staleness check did not fire"
fi
grep -qi "${STALE_SELECTOR#0x}\|StalePrice" <<<"$OUT" \
    || die "propose refused, but not with StalePrice: $OUT"
log "refused with StalePrice, as it must"

echo
log "The Flare integration is verified against real Coston2 contracts."
log "  FtsoV2               $FTSO_V2_ADDRESS"
log "  derived feed id      $FEED_ID -> \$$PRICE"
log "  DeployAegis.s.sol    deployed and wired against the real registries"
log "  conversion           checked against the real value and decimals"
log "  staleness            fail-closed against a real feed aged past ${MAX_PRICE_AGE}s"
echo
log "Not covered here, and needing credentials: Flare's instruction relay"
log "(a registered TEE machine) and a real FDC round (the verifier API key)."
