# Aegis

A rule-governed XRPL treasury.

Spending policy lives in Solidity contracts on Flare Coston2. The XRPL private key exists only inside a Flare Confidential Compute TEE, and will not produce a signature unless the on-chain policy authorised that exact payment — same destination, same tag, same amount, same sequence, same expiry, same fee. The enclave recomputes the policy digest from the fields it decoded and refuses to sign on any mismatch.

Nothing about that is a promise made by a service. It is a refusal built into the only component that holds the key.

---

## What it refuses, and why that is the product

| Situation | What happens |
|---|---|
| Destination is not on the policy's allowlist | Reverts at proposal, naming the account and tag |
| Amount is above the highest tier's ceiling | Reverts at proposal — no number of approvals authorises it |
| The proposer approves their own request | Reverted. Segregation of duties is enforced, not requested |
| The same address approves twice | Reverted |
| Dispatch before the tier's timelock | Reverted |
| The XRP/USD feed is more than 180 seconds old | Reverted. There is no cached price to fall back to |
| The rolling window is already committed | Reverted, with the figures that make up the refusal |
| A guardian has frozen the treasury | Propose, approve and dispatch all refused |
| One field of the signing instruction was altered in flight | The enclave returns status `0` and logs `policy digest mismatch`. No signature exists |
| The payment expired without ever being included | An FDC non-existence proof fails the request, releases the window spend, and leaves the sequence alone — because XRPL still expects it |

The dashboard names the rule that fired for every one of these.

---

## What you need

| | |
|---|---|
| bash | 4.4 or newer — macOS ships 3.2, and the scaffold's scripts need the newer one (`brew install bash`) |
| Foundry | `forge`, `cast` |
| Go | 1.22 or newer, with cgo available |
| Node | 20 or newer |
| Docker | with `docker compose` |
| jq, curl | |
| A Coston2 wallet | funded from https://faucet.flare.network/coston2 |

No indexer credentials are required. Aegis runs its own C-chain indexer from source; the shared Flare one is an alternative, not a prerequisite.

---

## From zero to a settled payment

Every step below is a script in this repository. Each one states what it did and stops on the first thing that is not true.

### 1. Pick the chain and fill the environment

```bash
git clone <this repository> aegis && cd aegis
cp .env.example .env.coston2      # fill INITIAL_OWNER and DEPLOYMENT_PRIVATE_KEY
./scripts/use-chain.sh coston2
```

`cast wallet new` will generate the deployer if you do not have one. `LOCAL_MODE=false` and `SIMULATED_TEE=true` are the settings for developing against the live chain.

### 2. Fund the deployer

```bash
cast balance "$INITIAL_OWNER" --rpc-url https://coston2-api.flare.network/ext/C/rpc
```

Deployment, extension registration, TEE machine registration and per-instruction fees all come out of this balance. `./scripts/phase0-check.sh` reports anything still unmet.

### 3. Start the indexer

```bash
./scripts/indexer.sh up        # builds from source, waits until in sync
./scripts/indexer.sh status
```

`ext-proxy` calls `database.Connect` unconditionally and panics without a C-chain indexer, so this comes before the services.

### 4. Open the tunnel

```bash
./scripts/tunnel.sh                     # cloudflared, no account needed
./scripts/tunnel.sh --ngrok <domain>    # a URL that survives restarts
```

Leave it running in its own terminal. It writes `EXT_PROXY_URL` into `.env`. A cloudflared quick tunnel mints a new URL every run, which means re-running `post-build.sh` after a restart.

### 5. Build and start the services

```bash
./scripts/start-services.sh --chain coston2
```

### 6. Deploy Aegis and register the extension

```bash
./scripts/aegis-e2e.sh deploy
```

This deploys `PolicyEngine`, `TreasuryRegistry`, `PaymentController`, `AegisInstructionSender` and `ExecutionVerifier`, wires them together, registers the sender as an FCC extension, and writes `config/extension.env` and `config/aegis-addresses.env`.

The extension id discovery starts at `FIRST_PUBLIC_EXTENSION_ID = 0x10000`; ids below that are reserved for system extensions such as PMW.

### 7. Register the TEE machine, then prove the cycle

```bash
./scripts/start-services.sh --chain coston2   # picks up the new extension id
./scripts/post-build.sh                       # registers the machine
./scripts/aegis-e2e.sh verify
```

`verify` creates a policy and a treasury, asks the enclave to generate the treasury's XRPL key, relays the result on-chain, and confirms the registry re-derived the same address from the returned public key. That is the phase 3 acceptance test, and it replaces the scaffold's `SAY_HELLO` — the enclave now answers `XRPLW`, so the greeting test can no longer pass and a completed `KEYGEN` is the stronger statement anyway.

### 8. Point the dashboard at it

```bash
./scripts/sync-web-env.sh          # writes web/.env.local from the deployment record
cd web && npm install && npm run dev
```

Open http://localhost:3000. The dashboard has no default contract addresses: one pointed at the wrong contract would show a treasury that is not yours and give no sign of it, so an unset address is reported as a configuration error rather than guessed.

### 9. Run the submitter

The submitter watches `PaymentSigned`, submits the signed blob to XRPL Testnet, and closes the loop with an FDC proof. It holds no authority — anyone can run one, and a proof that does not verify is rejected by the contract.

```bash
cd submitter && npm install && npm run build
```

It reads its configuration from the environment:

| | |
|---|---|
| `CHAIN_ID`, `CHAIN_URL`, `CHAIN_WS_URL` | Coston2 |
| `SUBMITTER_PRIVATE_KEY` | a funded key; it only ever submits proofs |
| `PAYMENT_CONTROLLER`, `EXECUTION_VERIFIER` | from `config/aegis-addresses.env` |
| `ADDRESSES_FILE` | `./config/coston2/deployed-addresses.json` |
| `XRPL_WS_URL` | `wss://s.altnet.rippletest.net:51233` |
| `FDC_VERIFIER_URL`, `FDC_VERIFIER_API_KEY`, `FDC_DA_LAYER_URL` | Flare's attestation provider and DA layer |
| `SUBMITTER_CURSOR_FILE`, `SUBMITTER_START_BLOCK` | where to resume from after a restart |

```bash
npm start
```

---

## The lifecycle, in the dashboard

1. **Create a policy** — `/policies/new`. Ascending tiers of (USD ceiling, approvals, timelock), a rolling window, whether the allowlist is enforced, and what an amendment takes. The form rejects everything the contract would reject, in the words the rule uses, before it costs gas.
2. **Grant roles** — on the policy page. `PROPOSER`, `APPROVER`, `GUARDIAN`, `POLICY_ADMIN`. The mask is written whole, so what an address may do is one fact on screen rather than a history of grants and revokes.
3. **Allowlist a destination** — classic address plus tag. Tag `0` means any tag on that account. The checksum is verified in the browser, so a typo never reaches the chain.
4. **Create a treasury** — from the home page, under a policy you administer.
5. **Generate its XRPL key** — on the treasury page. The key is born inside the enclave and never imported. The registry derives the AccountID from the returned public key using the SHA-256 and RIPEMD-160 precompiles, and refuses the binding if the reported address does not match.
6. **Fund the XRPL account** — https://xrpl.org/xrp-testnet-faucet.html, or any testnet account. Until it holds the base reserve the ledger does not consider it to exist, and the dashboard says so.
7. **Record the starting sequence** — on the treasury page, once the account is funded. An XRPL account does not start at sequence 1; it starts at the ledger index it was created in, which is why this cannot be a default and cannot be done before funding. The dashboard reads the live value off the ledger and asks you to confirm it. Payments are refused until it is recorded, and the panel says so rather than letting you build a request that could never be signed.
8. **Propose a payment** — every rule is evaluated live as you type, and the whole call is simulated before the button becomes usable.
9. **Approve it from a second account** — the approval screen shows the destination, the tag, the amount in drops *and* XRP *and* USD, the resolved tier, approvals collected and required, the unlock time and the policy digest. An approver who cannot see those is approving a description rather than a fact.
10. **Dispatch it** — after the timelock. The current XRPL ledger and fee are read live; the contract re-runs the entire policy check against the price and the window as they are at that moment.
11. **Watch it settle** — the submitter puts the blob on XRPL and brings back an FDC proof. `ExecutionVerifier` checks the source, the destination, the spent amount and the payment reference before anything moves to `Settled`.

Everything on those screens is read from Flare and XRPL directly. There is no Aegis backend, which is what makes the audit log reproducible by anyone with an RPC endpoint.

---

## Watching it refuse

Worth doing at least once each — the refusal is the product:

- Propose to an address that is not allowlisted.
- Propose more than the highest tier's ceiling.
- Approve your own proposal.
- Approve twice from the same address.
- Dispatch before the timelock elapses.
- Freeze the treasury as a guardian, then try anything at all.
- Propose while the FTSO feed is stale. If this happens during a demo, that is the fail-closed design working, and saying so is a stronger answer than a fallback price would be.

---

## Layout

```
contracts/          PolicyEngine, TreasuryRegistry, PaymentController,
                    AegisInstructionSender, ExecutionVerifier
go/                 the TEE extension — routing, key generation, the digest
                    check, and the XRPL serialiser and signer
submitter/          watches PaymentSigned, submits to XRPL, retrieves FDC proofs
web/                the dashboard
script/             forge deployment scripts
scripts/            environment, services, and end-to-end scripts
test/               Solidity tests
config/             chain addresses, proxy and extension configuration
docs/               PRD.md, DOCS.md, PLAN.md, phases.md
```

---

## Commands

```bash
# Everything, under one exit code. No chain, tunnel, credentials or faucet.
./scripts/check.sh
./scripts/check.sh --strict     # what CI runs: a skipped section is a failure

# The policy cycle against a local chain and the real enclave, no faucet
./scripts/local-integration.sh

# The same, but settled for real on XRPL Testnet. Needs no funded Coston2
# wallet — the XRPL faucet is an HTTP endpoint — and is the only thing that
# proves the signature is one the network accepts rather than one that merely
# looks well formed.
./scripts/xrpl-settlement.sh

# The Flare integration against real Coston2 contracts, no funded wallet.
# Forks the chain, runs the production deploy script against the live FtsoV2,
# FlareTeeManager and FdcVerification, prices a payment with the real oracle,
# and confirms it refuses once that feed goes stale.
./scripts/coston2-fork-check.sh

# A payment through Flare's real instruction relay on Coston2, after
# aegis-e2e.sh verify. Funds the treasury, records its starting sequence,
# allowlists a destination, then propose -> approve -> dispatch -> signed.
# Settlement is the submitter's job and needs FDC_VERIFIER_API_KEY.
./scripts/coston2-payment.sh

# Contracts
forge build && forge test -vvv && forge fmt

# TEE extension
cd go && go build ./... && go test ./... && go vet ./...

# Submitter
cd submitter && npm run build && npm test

# Dashboard
cd web && npm run typecheck && npm test && npm run build

# After changing a contract ABI
./scripts/generate-bindings.sh      # Go tooling
./scripts/generate-web-abis.sh      # dashboard
```

---

## Known limitations

- **One TEE machine holds the key.** Losing the machine loses the treasury. k-of-n signing across machines is phase 6, and the architecture is built for it: `requestSignature` is the only function in the system that touches signing.
- **The dashboard's audit log is bounded by the RPC.** The public Coston2 endpoint refuses an `eth_getLogs` range wider than 30 blocks, so the log is fetched in chunks over a configured lookback and the page states the block it reached. Point it at an archive node and raise `NEXT_PUBLIC_LOG_CHUNK_BLOCKS` for the whole history in one call. All *state* is read directly from the contracts and is never bounded this way.
- **`setExtensionId()` gets more expensive as other people register extensions.** It scans Flare's shared TEE registry from `FIRST_PUBLIC_EXTENSION_ID = 0x10000` upward looking for its own address, so its cost is set by how many public extensions exist chain-wide, not by anything Aegis does. On Coston2 that counter is past 65,880 — roughly 350 entries to walk, around 1.7M gas worst case — and it only ever grows. Somewhere past a few thousand extensions the call stops fitting in a block and this deployment step becomes impossible. It is a one-shot call per deployment, so the exposure is a deployment that cannot complete rather than a treasury that cannot pay, and the function is one `CLAUDE.md` marks do-not-modify because it comes from the FCC scaffold. Worth knowing before it is urgent: the fix is Flare's to make, by having `register()` return the id to the caller rather than making every extension search for itself.

- **System contract addresses come from `config/coston2/deployed-addresses.json`** while FCC is in development. When they move to `FlareContractRegistry` that is a one-line change, in one place.

---

## Documentation

- `docs/PRD.md` — what this is for and what is deliberately out of scope
- `docs/DOCS.md` — architecture, and §7 catalogues every known environment failure with its fix
- `docs/PLAN.md` — the six phases and their acceptance criteria
- `docs/phases.md` — the working tracker: what is done, what is not
- `CLAUDE.md` — the rules this codebase is written under
