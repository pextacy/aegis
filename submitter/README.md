# Aegis submitter

Watches `PaymentSigned` on Coston2, puts the signed blob on XRPL Testnet, and
closes the loop with an FDC proof.

It holds no authority. Its key pays gas for an attestation request and for
handing a proof to `ExecutionVerifier`, and a proof that does not verify is
rejected by the contract. Anyone can run one, and running two is expected —
whichever arrives second finds a terminal state and returns without reverting.

## What it does

1. Replays `PaymentSigned` from a persisted cursor up to the head, then follows
   the head over a websocket. The replay walks 30 blocks at a time, which is
   what the public Coston2 RPC actually serves for `eth_getLogs`.
2. `submit`s the blob to `wss://s.altnet.rippletest.net:51233` and polls `tx`
   until one of the only two terminal outcomes: validated in a ledger, or the
   network past `LastLedgerSequence` with nothing there. The `submit` engine
   result is logged and never acted on — with two submitters running, one of
   them gets a duplicate-transaction error for a payment that settles fine.
3. Requests the matching attestation, pays the fee `FdcRequestFeeConfigurations`
   quotes for that exact request, waits for the round to finalise, and pulls the
   Merkle proof from the DA layer.
4. Calls the entry point the outcome calls for:

   | XRPL outcome | Proof | Call |
   |---|---|---|
   | validated, `tesSUCCESS` | `Payment` | `confirmSettlement` |
   | validated, `tec…` | `Payment` | `confirmFailedExecution` |
   | expired, never included | `ReferencedPaymentNonexistence` | `confirmNonExecution` |

A payment it cannot carry to a proof stays in `Signed` and is retried on the
next replay. Nothing here concludes an outcome it did not observe.

## Running it

```bash
npm install
npm run build

set -a
source ../.env                       # chain, RPC and the submitter block
source ../config/aegis-addresses.env # PAYMENT_CONTROLLER, EXECUTION_VERIFIER
set +a

npm start
```

Every variable is required and none has a default that could stand in for a real
value — see the submitter block in `.env.example`. A missing one stops the
process at startup rather than producing a submitter pointed at the wrong chain.

## Running it as a container

```bash
docker build -f submitter/Dockerfile -t aegis-submitter submitter/

docker run --rm \
  --env-file ../.env \
  --env-file ../config/aegis-addresses.env \
  -v aegis-submitter-cursor:/var/lib/aegis-submitter \
  -v "$PWD/../config/coston2/deployed-addresses.json:/app/addresses.json:ro" \
  -e ADDRESSES_FILE=/app/addresses.json \
  -e SUBMITTER_CURSOR_FILE=/var/lib/aegis-submitter/cursor.json \
  aegis-submitter
```

The image runs as `node`, not root, and sets no configuration defaults — start
it with nothing and it exits 1 with the name of the first variable it wanted.
That is the same fail-closed rule the rest of the system follows: a submitter
that guessed a chain id would be worse than one that refused to start.

The cursor is the only state worth persisting, hence the volume. Losing it
costs a re-scan from `SUBMITTER_START_BLOCK`, not correctness — every entry
point is idempotent against a request that already reached a terminal state.

Unlike the extension image this one is not the unit of attestation: its hash is
never registered on-chain and no signing policy depends on it, so the
reproducibility guarantees in `REPRODUCIBILITY.md` do not apply. The base image
is still pinned by digest, and npm is pinned to the version that wrote
`package-lock.json`, because Node 22 bundles npm 10 and npm 10 rejects a v3
lockfile written by npm 11 outright.

## Tests

```bash
forge build                          # the ABI tests read out/
npm run typecheck && npm test
```

`test/abi.test.ts` compares the ABI declarations against the compiled contracts
rather than against a second copy written by hand. A field reordered in Solidity
fails there immediately, instead of surfacing later as a proof that will not
verify on-chain.
