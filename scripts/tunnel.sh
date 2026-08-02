#!/usr/bin/env bash
#
# tunnel.sh — Expose host port 6674 (ext-proxy external) over public HTTPS and
# write the resulting URL into .env.coston2 and .env.
#
# Port 6674 is the only port that gets tunnelled. Exposing it makes the proxy
# HTTP API reachable by anyone holding the URL, so run this against Coston2 only
# and stop it when you finish.
#
# Two backends:
#   cloudflared  (default) — no account, but a new URL on every restart, which
#                            means re-running post-build.sh to re-register.
#   ngrok        --ngrok   — needs an authtoken and a reserved domain, and the
#                            URL then survives restarts. Preferred once set up.
#
# Usage:
#   ./scripts/tunnel.sh                     # cloudflared quick tunnel
#   ./scripts/tunnel.sh --ngrok <domain>    # ngrok on a reserved domain
#
# Runs in the foreground. Leave it in its own terminal.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PORT=6674
ENV_FILE="$PROJECT_DIR/.env.coston2"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
log() { echo -e "${GREEN}[tunnel]${NC} $*"; }
die() { echo -e "${RED}[tunnel] ERROR:${NC} $*" >&2; exit 1; }

# Rewrite EXT_PROXY_URL in .env.coston2, then mirror it to the active .env so
# the scripts and a running shell agree without a use-chain.sh round trip.
write_url() {
    local url="$1"
    [[ -f "$ENV_FILE" ]] || die "$ENV_FILE not found"
    local tmp; tmp="$(mktemp)"
    if grep -q '^EXT_PROXY_URL=' "$ENV_FILE"; then
        sed "s|^EXT_PROXY_URL=.*|EXT_PROXY_URL=$url|" "$ENV_FILE" > "$tmp"
    else
        cat "$ENV_FILE" > "$tmp"
        echo "EXT_PROXY_URL=$url" >> "$tmp"
    fi
    mv "$tmp" "$ENV_FILE"
    cp "$ENV_FILE" "$PROJECT_DIR/.env"
    log "EXT_PROXY_URL=$url written to .env.coston2 and .env"
}

BACKEND=cloudflared
NGROK_DOMAIN=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ngrok) BACKEND=ngrok; NGROK_DOMAIN="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

if [[ "$BACKEND" == "ngrok" ]]; then
    command -v ngrok >/dev/null || die "ngrok not installed (brew install ngrok)"
    [[ -n "$NGROK_DOMAIN" ]] || die "--ngrok needs a reserved domain, e.g. --ngrok my-name.ngrok-free.app"
    ngrok config check >/dev/null 2>&1 || die "ngrok has no authtoken — ngrok config add-authtoken <token>"
    write_url "https://${NGROK_DOMAIN#https://}"
    log "starting ngrok on $NGROK_DOMAIN -> localhost:$PORT"
    exec ngrok http "--domain=${NGROK_DOMAIN#https://}" "$PORT"
fi

command -v cloudflared >/dev/null || die "cloudflared not installed (brew install cloudflared)"

LOG_FILE="$(mktemp)"
log "starting cloudflared quick tunnel -> localhost:$PORT"
cloudflared tunnel --url "http://localhost:$PORT" --no-autoupdate > "$LOG_FILE" 2>&1 &
TUNNEL_PID=$!
trap 'kill $TUNNEL_PID 2>/dev/null; rm -f "$LOG_FILE"' EXIT

URL=""
for _ in $(seq 1 30); do
    URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG_FILE" 2>/dev/null | head -1)"
    [[ -n "$URL" ]] && break
    sleep 1
done
[[ -n "$URL" ]] || { cat "$LOG_FILE" >&2; die "cloudflared did not report a URL"; }

write_url "$URL"
echo
log "tunnel is live. Leave this running."
log "This URL is new. If the extension was already registered against an older"
log "one, re-run ./scripts/post-build.sh so the machine re-registers under it."
echo
wait $TUNNEL_PID
