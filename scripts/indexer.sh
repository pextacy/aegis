#!/usr/bin/env bash
#
# indexer.sh — Run a local Coston2 C-chain indexer for ext-proxy to read.
#
# tee-proxy calls database.Connect unconditionally and panics without a C-chain
# indexer database. Flare runs a shared one, but its credentials are issued on
# request. This builds the same indexer from source and points it at the public
# Coston2 RPC, so nothing is gated on a support ticket.
#
# Usage:
#   ./scripts/indexer.sh up        # build, start, and wait until in sync
#   ./scripts/indexer.sh status    # rows indexed and distance from chain head
#   ./scripts/indexer.sh logs      # follow the indexer log
#   ./scripts/indexer.sh down      # stop and remove
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE=(docker compose -f "$PROJECT_DIR/docker-compose.indexer.yaml")

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
log() { echo -e "${GREEN}[indexer]${NC} $*"; }
die() { echo -e "${RED}[indexer] ERROR:${NC} $*" >&2; exit 1; }

if [[ -f "$PROJECT_DIR/.env" ]]; then
    set -a; source "$PROJECT_DIR/.env"; set +a
fi

query() {
    docker exec "$(${COMPOSE[@]} ps -q indexer-db 2>/dev/null)" \
        mysql -uroot -proot flare_ftso_indexer -N -e "$1" 2>/dev/null
}

cmd_status() {
    local behind rows
    behind=$(query "SELECT (SELECT \`index\` FROM states WHERE name='last_chain_block') - (SELECT \`index\` FROM states WHERE name='last_database_block');")
    rows=$(query "SELECT CONCAT((SELECT COUNT(*) FROM blocks),' blocks, ',(SELECT COUNT(*) FROM logs),' logs, ',(SELECT COUNT(*) FROM transactions),' txs');")
    [[ -n "$rows" ]] || die "database not reachable — is the indexer up?"
    log "$rows"
    log "blocks behind chain head: ${behind:-unknown}"
    [[ -n "$behind" && "$behind" -le 20 ]]
}

case "${1:-up}" in
    up)
        log "building and starting the indexer (first build clones and compiles it)"
        "${COMPOSE[@]}" up -d --build || die "compose up failed"

        log "waiting for the indexer to reach the chain head"
        for _ in $(seq 1 120); do
            if cmd_status >/dev/null 2>&1; then
                cmd_status
                log "in sync — point ext-proxy at indexer-db:3306 and start it"
                exit 0
            fi
            sleep 5
        done
        cmd_status || true
        die "indexer did not reach the chain head in ten minutes — ./scripts/indexer.sh logs"
        ;;
    status) cmd_status || exit 1 ;;
    logs)   "${COMPOSE[@]}" logs -f indexer ;;
    down)   "${COMPOSE[@]}" down ;;
    *)      die "unknown command: $1 (up|status|logs|down)" ;;
esac
