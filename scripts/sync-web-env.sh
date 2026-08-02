#!/usr/bin/env bash
#
# Writes web/.env.local from the record forge kept of the Aegis deployment.
#
# The dashboard has no default contract addresses, on purpose: one pointed at the
# wrong contract would show a treasury that is not yours and give no sign of it.
# This script is the supported way to fill them in — it reads the broadcast file
# forge wrote when DeployAegis ran, so the addresses come from the deployment
# itself rather than from anyone's notes.
#
# Usage: ./scripts/sync-web-env.sh [--chain-id 114]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHAIN_ID="${CHAIN_ID:-114}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --chain-id)
            CHAIN_ID="$2"
            shift 2
            ;;
        *)
            echo "sync-web-env: unknown argument $1" >&2
            exit 1
            ;;
    esac
done

if ! command -v jq >/dev/null 2>&1; then
    echo "sync-web-env: jq is required" >&2
    exit 1
fi

BROADCAST="$ROOT/broadcast/DeployAegis.s.sol/$CHAIN_ID/run-latest.json"
if [[ ! -f "$BROADCAST" ]]; then
    echo "sync-web-env: no deployment record at ${BROADCAST#"$ROOT"/}" >&2
    echo "  Deploy first:  ./scripts/aegis-e2e.sh deploy" >&2
    exit 1
fi

address_of() {
    jq -r --arg name "$1" '
        [.transactions[] | select(.contractName == $name and .contractAddress != null) | .contractAddress] | last // ""
    ' "$BROADCAST"
}

# aegis-e2e.sh records what it deployed, and the rest of the tooling reads that
# file. Preferring it keeps the dashboard pointed at the same contracts as the
# submitter and the extension, rather than at whatever forge broadcast last.
STATE_FILE="$ROOT/config/aegis-addresses.env"
if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    echo "sync-web-env: addresses from ${STATE_FILE#"$ROOT"/}"
else
    POLICY_ENGINE="$(address_of PolicyEngine)"
    TREASURY_REGISTRY="$(address_of TreasuryRegistry)"
    PAYMENT_CONTROLLER="$(address_of PaymentController)"
    echo "sync-web-env: addresses from ${BROADCAST#"$ROOT"/}"
fi

for pair in "PolicyEngine:$POLICY_ENGINE" "TreasuryRegistry:$TREASURY_REGISTRY" "PaymentController:$PAYMENT_CONTROLLER"; do
    if [[ -z "${pair##*:}" ]]; then
        echo "sync-web-env: ${pair%%:*} is not in ${BROADCAST#"$ROOT"/}" >&2
        exit 1
    fi
done

# The first receipt is the block the deployment landed in. The audit log never
# scans below it, because there is nothing there. forge has written this field
# both as a hex string and as a number over the years, so accept either.
RAW_BLOCK="$(jq -r '.receipts[0].blockNumber // empty' "$BROADCAST")"
if [[ -z "$RAW_BLOCK" ]]; then
    echo "sync-web-env: ${BROADCAST#"$ROOT"/} has no receipts, so the deployment block is unknown" >&2
    exit 1
fi
if [[ "$RAW_BLOCK" == 0x* ]]; then
    DEPLOYMENT_BLOCK=$((RAW_BLOCK))
else
    DEPLOYMENT_BLOCK="$RAW_BLOCK"
fi

case "$CHAIN_ID" in
    114)
        RPC_URL="${CHAIN_URL:-https://coston2-api.flare.network/ext/C/rpc}"
        EXPLORER_URL="https://coston2-explorer.flare.network"
        ;;
    16)
        RPC_URL="${CHAIN_URL:-https://coston-api.flare.network/ext/C/rpc}"
        EXPLORER_URL="https://coston-explorer.flare.network"
        ;;
    14)
        RPC_URL="${CHAIN_URL:-https://flare-api.flare.network/ext/C/rpc}"
        EXPLORER_URL="https://flare-explorer.flare.network"
        ;;
    *)
        echo "sync-web-env: chain id $CHAIN_ID is not a Flare network Aegis supports" >&2
        exit 1
        ;;
esac

TARGET="$ROOT/web/.env.local"
cat >"$TARGET" <<EOF
# Written by scripts/sync-web-env.sh from
# ${BROADCAST#"$ROOT"/}
# Re-run it after every deployment; editing this by hand invites a dashboard
# pointed at a contract that is not the one you deployed.

NEXT_PUBLIC_CHAIN_ID=$CHAIN_ID
NEXT_PUBLIC_RPC_URL=$RPC_URL
NEXT_PUBLIC_EXPLORER_URL=$EXPLORER_URL

NEXT_PUBLIC_POLICY_ENGINE_ADDRESS=$POLICY_ENGINE
NEXT_PUBLIC_TREASURY_REGISTRY_ADDRESS=$TREASURY_REGISTRY
NEXT_PUBLIC_PAYMENT_CONTROLLER_ADDRESS=$PAYMENT_CONTROLLER

NEXT_PUBLIC_DEPLOYMENT_BLOCK=$DEPLOYMENT_BLOCK

NEXT_PUBLIC_XRPL_RPC_URL=${XRPL_RPC_URL:-https://s.altnet.rippletest.net:51234}
NEXT_PUBLIC_XRPL_EXPLORER_URL=${XRPL_EXPLORER_URL:-https://testnet.xrpl.org}

NEXT_PUBLIC_LOG_CHUNK_BLOCKS=${LOG_CHUNK_BLOCKS:-30}
NEXT_PUBLIC_LOG_LOOKBACK_BLOCKS=${LOG_LOOKBACK_BLOCKS:-4000}
EOF

echo "sync-web-env: wrote ${TARGET#"$ROOT"/}"
echo "  PolicyEngine       $POLICY_ENGINE"
echo "  TreasuryRegistry   $TREASURY_REGISTRY"
echo "  PaymentController  $PAYMENT_CONTROLLER"
echo "  deployment block   $DEPLOYMENT_BLOCK"
