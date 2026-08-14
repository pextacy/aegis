#!/usr/bin/env bash
#
# phase0-check.sh — Report which Phase 0 preconditions are still unmet.
#
# Every check reads real state: chain balance, config files, installed tools.
# Nothing is assumed. Exits 0 when Phase 0 is ready to run end-to-end.
#
# Usage: ./scripts/phase0-check.sh
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
BLOCKED=0

ok()    { echo -e "  ${GREEN}ok${NC}       $*"; }
blocked() { echo -e "  ${RED}blocked${NC}  $*"; BLOCKED=$((BLOCKED + 1)); }
warn()  { echo -e "  ${YELLOW}warn${NC}     $*"; }

if [[ -f "$PROJECT_DIR/.env" ]]; then
    set -a; source "$PROJECT_DIR/.env"; set +a
else
    echo -e "${RED}No .env — run ./scripts/use-chain.sh coston2 first.${NC}" >&2
    exit 1
fi

CHAIN_URL="${CHAIN_URL:-https://coston2-api.flare.network/ext/C/rpc}"
MIN_WEI=10000000000000000   # 0.01 C2FLR, the pre-flight minimum

echo
echo "Phase 0 preconditions"
echo

# --- P0-2: funded deployer ---
if [[ -z "${INITIAL_OWNER:-}" ]]; then
    blocked "P0-2  INITIAL_OWNER unset in .env"
elif ! command -v cast >/dev/null 2>&1; then
    warn "P0-2  cast not on PATH — cannot read balance"
else
    BAL=$(cast balance "$INITIAL_OWNER" --rpc-url "$CHAIN_URL" 2>/dev/null)
    if [[ -z "$BAL" ]]; then
        blocked "P0-2  could not read balance for $INITIAL_OWNER"
    elif [[ "$(echo "$BAL" | tr -d '\n')" == "0" ]]; then
        blocked "P0-2  $INITIAL_OWNER holds 0 — fund at https://faucet.flare.network/coston2"
    elif awk -v b="$BAL" -v m="$MIN_WEI" 'BEGIN { exit !(b < m) }'; then
        blocked "P0-2  balance $BAL wei is below the $MIN_WEI wei pre-flight minimum"
    else
        ok "P0-2  deployer funded ($(cast to-unit "$BAL" ether 2>/dev/null || echo "$BAL wei") C2FLR)"
    fi
fi

# --- P0-6: a C-chain indexer the proxy can read ---
# ext-proxy panics without one. Either our own local indexer is running, or the
# config points at Flare's shared one with issued credentials.
TOML="$PROJECT_DIR/config/proxy/extension_proxy.coston2.docker.toml"
if [[ ! -f "$TOML" ]]; then
    blocked "P0-6  $TOML missing — copy it from the .example"
elif grep -q "issued-by-flare-support\|<indexer-db" "$TOML"; then
    blocked "P0-6  indexer credentials not filled in $(basename "$TOML")"
elif grep -q 'host = "indexer-db"' "$TOML"; then
    DB_CID=$(docker compose -f "$PROJECT_DIR/docker-compose.indexer.yaml" ps -q indexer-db 2>/dev/null)
    if [[ -z "$DB_CID" ]]; then
        blocked "P0-6  local indexer not running — ./scripts/indexer.sh up"
    else
        BEHIND=$(docker exec "$DB_CID" mysql -uroot -proot flare_ftso_indexer -N -e \
            "SELECT (SELECT \`index\` FROM states WHERE name='last_chain_block') - (SELECT \`index\` FROM states WHERE name='last_database_block');" 2>/dev/null)
        # A freshly started indexer answers NULL until it has written both state
        # rows, and an unquoted NULL inside (( )) is read as a variable name —
        # which under `set -u` aborts the whole check rather than reporting it.
        if [[ -z "$BEHIND" ]]; then
            blocked "P0-6  local indexer database not answering — ./scripts/indexer.sh logs"
        elif [[ ! "$BEHIND" =~ ^-?[0-9]+$ ]]; then
            blocked "P0-6  local indexer is still starting up — ./scripts/indexer.sh logs"
        elif (( BEHIND > 60 )); then
            blocked "P0-6  local indexer is $BEHIND blocks behind — still catching up"
        else
            ok "P0-6  local indexer in sync ($BEHIND blocks behind head)"
        fi
    fi
else
    ok "P0-6  configured against an external indexer"
fi

# --- P0-4: tunnel ---
# Any public HTTPS tunnel to host port 6674 satisfies this. cloudflared needs no
# account; ngrok needs one but its reserved domain survives restarts. What is
# checked here is that the URL is set and actually reaches this machine — the
# backend does not matter.
if [[ -z "${EXT_PROXY_URL:-}" ]]; then
    blocked "P0-4  EXT_PROXY_URL unset — run ./scripts/tunnel.sh"
elif [[ "$EXT_PROXY_URL" != https://* ]]; then
    blocked "P0-4  EXT_PROXY_URL must be https (got: $EXT_PROXY_URL)"
else
    # 502 means the tunnel is up but nothing is listening on 6674 yet, which is
    # the expected state before start-services.sh runs. Anything that answers
    # proves the tunnel resolves to this machine; a connection failure does not.
    TCODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$EXT_PROXY_URL/info" 2>/dev/null)
    if [[ -z "$TCODE" || "$TCODE" == "000" ]]; then
        blocked "P0-4  $EXT_PROXY_URL is not reachable — is the tunnel running? ./scripts/tunnel.sh"
    elif [[ "$TCODE" == "200" ]]; then
        ok "P0-4  tunnel live and proxy answering ($EXT_PROXY_URL)"
    else
        ok "P0-4  tunnel live, proxy not up yet — HTTP $TCODE ($EXT_PROXY_URL)"
    fi
fi

# --- P0-3 / toolchain ---
for tool in docker forge go node jq; do
    command -v "$tool" >/dev/null 2>&1 && ok "tool     $tool" || blocked "tool     $tool not on PATH"
done

if docker info >/dev/null 2>&1; then
    ok "tool     docker daemon running"
else
    blocked "tool     docker daemon not running"
fi

# The scaffold's scripts expand possibly-empty arrays under `set -u`, which is
# an error in bash < 4.4. macOS ships 3.2.57, where test-conformance.sh reports
# three false failures with "body_args[@]: unbound variable".
BASH_MAJOR="${BASH_VERSINFO[0]:-0}"
BASH_MINOR="${BASH_VERSINFO[1]:-0}"
if (( BASH_MAJOR > 4 || (BASH_MAJOR == 4 && BASH_MINOR >= 4) )); then
    ok "tool     bash $BASH_MAJOR.$BASH_MINOR"
else
    blocked "tool     bash $BASH_MAJOR.$BASH_MINOR is too old for the scaffold scripts — brew install bash, then run them with /opt/homebrew/bin/bash"
fi

# --- chain reachability ---
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$CHAIN_URL" \
    -H 'content-type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' --max-time 15)
[[ "$CODE" == "200" ]] && ok "chain    Coston2 RPC responding" || blocked "chain    Coston2 RPC returned $CODE"

echo
if [[ $BLOCKED -eq 0 ]]; then
    echo -e "${GREEN}Phase 0 is ready. Run, in order:${NC}"
    echo "  ngrok http --domain=\${EXT_PROXY_URL#https://} 6674   # separate terminal"
    echo "  ./scripts/pre-build.sh"
    echo "  ./scripts/start-services.sh --chain coston2"
    echo "  ./scripts/post-build.sh"
    echo "  ./scripts/test.sh"
    exit 0
else
    echo -e "${RED}$BLOCKED precondition(s) unmet.${NC} See docs/phase-0-status.md."
    exit 1
fi
