#!/usr/bin/env bash
#
# check.sh — Run every suite in the repository and the hygiene rules.
#
# One command, one exit code. This is what CI runs and what you should run
# before pushing. Nothing here needs a chain, a tunnel, credentials or the
# faucet: everything on-chain lives in scripts/local-integration.sh and
# scripts/aegis-e2e.sh.
#
# Usage:
#   ./scripts/check.sh            # everything
#   ./scripts/check.sh contracts  # one section (contracts|go|conformance|submitter|web|hygiene)
#
# Requires bash 4.4+. macOS ships 3.2, which cannot expand an empty array under
# `set -u` and breaks the scaffold's own scripts — use /opt/homebrew/bin/bash.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR" || exit 1

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[0;33m'; NC='\033[0m'

# --strict turns a missing toolchain into a failure instead of a skip.
#
# Locally a skip is the right behaviour: someone iterating on contracts should
# not be blocked because they have no Go installed. In CI it is the wrong
# behaviour and dangerously so — a green run that silently omitted the whole
# dashboard reports the same exit code as one that tested it. CI passes
# --strict, so a forgotten `npm ci` fails loudly rather than quietly narrowing
# what "all checks passed" means.
STRICT=false
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --strict) STRICT=true ;;
        *) ARGS+=("$arg") ;;
    esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

FAILURES=()
step()  { echo -e "\n${CYAN}=== $* ===${NC}"; }
pass()  { echo -e "${GREEN}  ok${NC}    $*"; }
fail()  { echo -e "${RED}  FAIL${NC}  $*"; FAILURES+=("$1"); }
skip()  {
    if [[ "$STRICT" == "true" ]]; then
        fail "$1 (skipped under --strict)"
    else
        echo -e "${YELLOW}  skip${NC}  $*"
    fi
}

if (( ${BASH_VERSINFO[0]} < 4 || (${BASH_VERSINFO[0]} == 4 && ${BASH_VERSINFO[1]} < 4) )); then
    echo -e "${RED}bash ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]} is too old — use bash 4.4+${NC}" >&2
    exit 1
fi

# run <label> <command...> — report and record rather than aborting, so one
# broken suite does not hide the state of the others.
run() {
    local label="$1"; shift
    local out
    if out="$("$@" 2>&1)"; then
        pass "$label"
    else
        fail "$label"
        echo "$out" | tail -30 | sed 's/^/        /'
    fi
}

SECTION="${1:-all}"
want() { [[ "$SECTION" == "all" || "$SECTION" == "$1" ]]; }

# --- Contracts -------------------------------------------------------------

if want contracts; then
    step "Contracts"
    if command -v forge >/dev/null; then
        run "forge build" forge build
        # test/fork is excluded here and run once, on its own, below. Letting it
        # run in both places is not merely wasteful: it doubles the requests to
        # a public endpoint and earns an HTTP 429, which surfaces as a test
        # failure that has nothing to do with the code.
        run "forge test" forge test --no-match-path 'test/fork/*'

        # The fork tests check our FDC proof encoding against Flare's real
        # verifier rather than against a double we wrote. They skip themselves
        # without an RPC, and are reported separately so a green "forge test"
        # can never quietly mean "three fewer tests ran".
        if [[ -n "${COSTON2_RPC_URL:-}" ]]; then
            run "forge test (Coston2 fork)" forge test --match-path 'test/fork/*'
        else
            skip "fork tests — set COSTON2_RPC_URL to run them against real Coston2 contracts"
        fi
        run "forge fmt --check" forge fmt --check
    else
        skip "forge not installed"
    fi
fi

# --- TEE extension ---------------------------------------------------------

if want go; then
    step "TEE extension"
    if command -v go >/dev/null; then
        run "go build" go -C go build ./...
        run "go vet" go -C go vet ./...
        run "go test" go -C go test ./...
        run "gofmt" bash -c 'test -z "$(gofmt -l go/internal go/pkg go/cmd)"'
    else
        skip "go not installed"
    fi
fi

# --- Container contract ----------------------------------------------------

if want conformance; then
    step "Container contract"
    if command -v jq >/dev/null && command -v go >/dev/null; then
        run "test-conformance.sh" "$SCRIPT_DIR/test-conformance.sh"
    else
        skip "needs go and jq"
    fi
fi

# --- Submitter -------------------------------------------------------------

if want submitter; then
    step "Submitter"
    if [[ -d submitter/node_modules ]]; then
        run "typecheck" npm --prefix submitter run typecheck
        # The suite includes a live check of the voting-round arithmetic against
        # Coston2, which skips itself without COSTON2_RPC_URL. It is reads only,
        # so it needs no funded wallet.
        run "test" npm --prefix submitter test
        if [[ -z "${COSTON2_RPC_URL:-}" ]]; then
            skip "submitter live checks — set COSTON2_RPC_URL to run them against real Coston2"
        fi
        run "build" npm --prefix submitter run build
    else
        skip "submitter/node_modules missing — npm --prefix submitter ci"
    fi
fi

# --- Dashboard -------------------------------------------------------------

if want web; then
    step "Dashboard"
    if [[ -d web/node_modules ]]; then
        run "typecheck" npm --prefix web run typecheck
        run "test" npm --prefix web test
        run "build" npm --prefix web run build
    else
        skip "web/node_modules missing — npm --prefix web ci"
    fi
fi

# --- Hygiene ---------------------------------------------------------------

if want hygiene; then
    step "Hygiene"

    # Files inherited from the scaffold carry their own TODOs and must not be
    # edited; only Aegis-authored source is swept.
    AEGIS_SOURCE=(
        contracts/AegisInstructionSender.sol
        contracts/ExecutionVerifier.sol
        contracts/PaymentController.sol
        contracts/PolicyEngine.sol
        contracts/TreasuryRegistry.sol
        contracts/lib
        contracts/interfaces/IAegisInstructionSender.sol
        contracts/interfaces/IFtsoV2.sol
        go/internal go/pkg
        submitter/src
        web/src
        script
    )
    EXISTING=()
    for p in "${AEGIS_SOURCE[@]}"; do [[ -e "$p" ]] && EXISTING+=("$p"); done

    # "placeholder" is excluded deliberately: it is a legitimate HTML input
    # attribute. What the rule forbids is an unfinished value, which the other
    # patterns catch.
    if hits="$(grep -rniE 'TODO|FIXME|XXX|changeme|example\.com|0x0{20,}' \
        --include='*.sol' --include='*.go' --include='*.ts' --include='*.tsx' \
        "${EXISTING[@]}" 2>/dev/null | grep -viE '_test\.go|\.test\.ts|/test/')"; then
        fail "unfinished markers in Aegis source"
        echo "$hits" | head -20 | sed 's/^/        /'
    else
        pass "no unfinished markers"
    fi

    # Test doubles must never be reachable from shipped code.
    if hits="$(grep -rn "test/helpers" contracts/ script/ 2>/dev/null | grep -v '^test/')"; then
        fail "a test double is imported by shipped code"
        echo "$hits" | sed 's/^/        /'
    else
        pass "no test doubles in shipped code"
    fi

    # The three-way constant alignment, asserted here as well as in both suites
    # so a drift is visible without reading either.
    SOL_OP="$(grep -oE 'bytes32\("XRPLW"\)' contracts/AegisInstructionSender.sol | head -1)"
    GO_OP="$(grep -oE 'OPTypeXRPL = "XRPLW"' go/internal/config/config.go | head -1)"
    GO_USE="$(grep -oE 'teeutils\.ToHash\(config\.OPTypeXRPL\)' go/internal/extension/extension.go | head -1)"
    if [[ -n "$SOL_OP" && -n "$GO_OP" && -n "$GO_USE" ]]; then
        pass "opType aligned across Solidity, Go config and Go routing"
    else
        fail "opType alignment: solidity='$SOL_OP' goconfig='$GO_OP' gouse='$GO_USE'"
    fi

    # A key must never be reachable from a response type.
    if grep -rnE '\bpriv\w*\s+\*?btcec\.PrivateKey' go/pkg 2>/dev/null; then
        fail "a private key type appears in the public types package"
    else
        pass "no key material in pkg/types"
    fi
fi

# --- Summary ---------------------------------------------------------------

echo
if (( ${#FAILURES[@]} == 0 )); then
    echo -e "${GREEN}All checks passed.${NC}"
    exit 0
fi

echo -e "${RED}${#FAILURES[@]} check(s) failed:${NC}"
for f in "${FAILURES[@]}"; do echo "  - $f"; done
exit 1
