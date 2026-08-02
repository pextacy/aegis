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

## Tests

```bash
forge build                          # the ABI tests read out/
npm run typecheck && npm test
```

`test/abi.test.ts` compares the ABI declarations against the compiled contracts
rather than against a second copy written by hand. A field reordered in Solidity
fails there immediately, instead of surfacing later as a proof that will not
verify on-chain.
