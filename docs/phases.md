# Aegis — Phase Execution Tracker

`PLAN.md` states *what* each phase delivers and why. This file is the working breakdown: numbered tasks, the files each one touches, the command that proves it, and the gate that closes the phase.

Rules for using this file:

- A task is checked only when its verification command passes **against Coston2**, not in a local simulation.
- A phase is closed only when every exit criterion is a passing test, not a judgement call.
- If a task turns out to be wrong, correct it here rather than leaving it aspirational — same rule `CLAUDE.md` §"Before you finish any task" applies to `PLAN.md`.
- Task ids are stable. Reference them in commit bodies (`feat(contracts): tier resolution — P1-1`).

Legend: `[ ]` not started · `[~]` in progress · `[x]` done and verified · `[!]` blocked

---

## Status

| Phase | Title | Depends on | State |
|---|---|---|---|
| 0 | Unblock the critical path | — | `[ ]` |
| 1 | Policy layer in Solidity | — | `[ ]` |
| 2 | XRPL serialiser and signer in Go | — | `[ ]` |
| 3 | TEE extension | 0, 1, 2 | `[ ]` |
| 4 | Settlement and proof | 3 | `[ ]` |
| 5 | Interface and hardening | 4 | `[ ]` |
| 6 | Multisig and PMW migration | 5 | post-program |

Phases 0, 1 and 2 have no dependency on each other. Start all three on day one. The schedule is determined by P0-1 (indexer credentials), which is a request to a third party with unknown latency — everything in phase 3 onward is blocked behind it.

---

## Phase 0 — Unblock the critical path

**Goal:** every external dependency resolved and the untouched scaffold proven working end-to-end, before a line of Aegis code exists.

### Tasks

Live state and the full environment record are in `phase-0-status.md`.

- [x] **P0-1 — A C-chain indexer the proxy can read.** Resolved without the credential request. `tee-proxy` calls `database.Connect` unconditionally and panics without an indexer database, and its `direct` endpoint does not substitute — but `flare-system-c-chain-indexer` is open source and writes exactly the schema `go-flare-common/pkg/database` reads, so `./scripts/indexer.sh up` runs our own in FSP mode against the public Coston2 RPC. Verified: the proxy starts against it and logs `Database in sync`. Two things that cost time and are worth knowing — the public RPC caps `eth_getLogs` at 30 blocks, not the 1000 the sample config suggests, and the build needs cgo because `supranational/blst` has no pure-Go path. The original request text is still in `phase-0-status.md` if you want the shared indexer as a fallback.
- [~] **P0-1b — Request Coston2 indexer credentials (optional).** Via `https://flare.network/resources/technical-support` or `@FlareDevs`, stating what is being built. Coston2 indexer is `34.38.42.208:3306`, database `indexer` — **verified open without a VPN**. Do not target Coston: different credentials, and `35.241.249.150:3306` is filtered from a plain connection. *This is the first action of the project.* Request text drafted in `phase-0-status.md`.
- [!] **P0-2 — Fund the Coston2 wallet.** Deployer `0xbC479252c67526f9BAa0e70E7c27Cc53222b49b5` generated with `cast wallet new` and written to `.env.coston2`. Pre-flight requires ≥ `0.01 C2FLR` and currently reports `balance: 0 wei`. Fund from `https://faucet.flare.network/coston2` with headroom for gas, extension registration, TEE machine registration, and per-instruction fees.
- [x] **P0-3 — Clone and pin the scaffold.** `flare-foundation/fce-extension-scaffold` at `f48cafb889441a62e47c083f4be8dd7d3f456f83` (2026-07-28), vendored verbatim into the repository root; its own docs relocated to `docs/scaffold/`. FCC is not a fully public production system; an unpinned scaffold is an API change waiting to break the build.
- [x] **P0-4 — Public HTTPS tunnel to port 6674.** `./scripts/tunnel.sh` brings one up and writes `EXT_PROXY_URL` into `.env.coston2` and `.env` itself. Backed by cloudflared, which needs no account — the original plan named ngrok, but ngrok requires a signup and the requirement is a tunnel, not a vendor. The tradeoff is real and unchanged: a quick tunnel mints a new URL per run, so a restart after registration means re-running `post-build.sh`. `./scripts/tunnel.sh --ngrok <domain>` uses a reserved ngrok domain instead, which survives restarts; ngrok is installed and that upgrade is a convenience, not a precondition.
- [x] **P0-5 — Fill the environment.** `.env.coston2` written and activated with `./scripts/use-chain.sh coston2` — that is the scaffold's intended path, not editing `.env` by hand. Carries `LANGUAGE=go`, `CHAIN`, `CHAIN_URL`, `ADDRESSES_FILE`, `INITIAL_OWNER`, `DEPLOYMENT_PRIVATE_KEY`, `PROXY_PRIVATE_KEY`, `LOCAL_MODE=false`, `SIMULATED_TEE=true`, `NORMAL_PROXY_URL`. `EXT_PROXY_URL` stays empty until P0-4. `SIMULATED_TEE=true` must pair with container `MODE=1` — `docker-compose.yaml` defaults to it — or registration fails `code hashes do not match`. Governance vars left unset so `post-build` and the TEE node both fall back to the same deployer/threshold-1 default; setting one side only is what produces `InvalidGovernanceHash`.
- [x] **P0-6 — Point the proxy at an indexer.** `config/proxy/extension_proxy.coston2.docker.toml` targets the local `indexer-db` service. Verified end to end: proxy boots, syncs, and serves its internal API. Both proxy configs stay gitignored so credentials for the shared indexer never land in git if you switch to it.
- [~] **P0-7 — Run the scaffold unmodified.** `./scripts/tunnel.sh` → `pre-build.sh` → `start-services.sh --chain coston2` → `post-build.sh` → `test.sh`. `SAY_HELLO` and `SAY_GOODBYE` both complete. The on-chain leg is blocked on P0-1 and P0-2; everything reachable without them passes — version pins consistent, bindings generated, `forge build` clean, the Go extension builds/vets/tests under Go 1.26.4, all three Docker images built, `test-unit.sh` green, `test-conformance.sh` 16/16, pre-flight reaching Coston2 and stopping only on balance, and `ext-proxy` reaching the indexer and being rejected only at authentication. Requires bash 4.4+ — macOS 3.2 breaks the scaffold's own scripts. `./scripts/phase0-check.sh` reports what is still unmet.
- [x] **P0-8 — Record the environment.** `phase-0-status.md` — toolchain versions, scaffold pin, dependency pins, chain facts, deployer, ports, and what each blocker needs. Extension id, instruction sender, code hash and tunnel domain are the four values still to fill after P0-7, because a reset means reproducing them exactly.

### Verification

```bash
./scripts/test.sh
curl -s "$EXT_PROXY_URL/info" | jq '.machineData'
```

### Exit criteria

- `test.sh` passes on the untouched scaffold against Coston2.
- `machineData.codeHash` starts `0x194844cf`.
- `machineData.extensionId` matches `config/extension.env`.
- `machineData.initialOwner` matches `INITIAL_OWNER`.

### Notes

Every failure mode in this phase is environmental — `InvalidGovernanceHash`, `ChallengeExpired`, `code hashes do not match`, `MachineManager.TooMany()`, proxy never becoming ready. `DOCS.md` §7 catalogues each one with its fix. Meeting them for the first time while also debugging your own XRPL serialiser is the single most likely way this project fails.

Do not run `pre-build.sh --force` casually — it deploys a new sender and registers a new extension id while the TEE machine stays bound to the old one.

---

## Phase 1 — Policy layer in Solidity

**Goal:** the complete rule engine, provable under `forge test`. No TEE involvement, so iteration is fast and independent of P0-1.

### Tasks

- [ ] **P1-1 — `PolicyEngine.sol`: policy storage.** `Tier` and `Policy` structs, `createPolicy`, immutable versions. Tiers ascending by `maxAmountUsd`; the last tier is the hard per-payment cap. Reject unsorted or empty tier arrays at creation.
- [ ] **P1-2 — `PolicyEngine.sol`: tier resolution.** `resolveTier` returns the lowest tier whose ceiling covers the amount, reverts `AmountExceedsPolicyCap` when none does.
- [ ] **P1-3 — `PolicyEngine.sol`: allowlist.** `setAllowlist` / `isDestinationAllowed` over the pair (AccountID, destination tag). Tag `0` means any tag is permitted for that account.
- [ ] **P1-4 — `PolicyEngine.sol`: roles.** Bitmask per policy — `PROPOSER = 1`, `APPROVER = 2`, `GUARDIAN = 4`, `POLICY_ADMIN = 8`. One address may hold several.
- [ ] **P1-5 — `TreasuryRegistry.sol`: lifecycle.** `createTreasury`, the `Treasury` struct, `TreasuryCreated`. The XRPL account does not exist yet at this point.
- [ ] **P1-6 — `TreasuryRegistry.sol`: freeze.** `setFrozen`, guardian-only, single transaction, no threshold. Unfreeze requires the policy's amendment threshold.
- [ ] **P1-7 — `TreasuryRegistry.sol`: sequence tracking.** `nextSequence`, `advanceSequence` restricted to `ExecutionVerifier`.
- [ ] **P1-8 — `TreasuryRegistry.sol`: `bindXrplAccount` signature.** Written, access-restricted to `AegisInstructionSender`, not yet reachable — wiring is P3-9.
- [ ] **P1-9 — FTSO integration.** Derived feed id `bytes21(abi.encodePacked(uint8(1), bytes7("XRP/USD"), bytes13(0)))`, `MAX_PRICE_AGE = 180`, conversion `amountUsd18 = amountDrops * value * 10^(12 - decimals)`. Never cache a price across transactions.
- [ ] **P1-10 — `PaymentController.sol`: `propose`.** Convert to USD, check allowlist, resolve tier, check rolling window, store with `eligibleAt = block.timestamp + tier.timelockSeconds`. Revert on the first violation with a specific custom error, so no one ever approves a request that cannot execute.
- [ ] **P1-11 — `PaymentController.sol`: `approve`.** Reject the proposer of that request. Reject a duplicate from the same address. Transition to `Approved` when `approvals >= tier.requiredApprovals`.
- [ ] **P1-12 — `PaymentController.sol`: rolling window.** Ring buffer of `(timestamp, amountUsd)` per treasury, pruned lazily on `propose` and `dispatch`. Spend is committed at dispatch, not at proposal, and released when a request ends `Failed`.
- [ ] **P1-13 — `PaymentController.sol`: `dispatch` guard.** Requires `Approved`, `block.timestamp >= eligibleAt`, treasury not frozen — then **re-runs the entire policy check**. The instruction-send call itself is P3-1.
- [ ] **P1-14 — Policy digest.** `keccak256(abi.encode(requestId, treasuryId, destinationAccountId, destinationTag, amountDrops, sequence, lastLedgerSequence, feeDrops))`, computed in `dispatch` and stored on the request.
- [ ] **P1-15 — Policy amendment path.** Repointing a treasury to a new `policyId` requires the current policy's `amendApprovals` and `amendTimelock`.
- [ ] **P1-16 — Test suite.** One passing and one failing test per rule. A rule with only a happy path is untested.

### Verification

```bash
forge build && forge test -vvv && forge fmt --check
```

### Exit criteria

Each is an individual passing test:

- Tier resolution correct at, just below, and just above every ceiling.
- Above the highest ceiling reverts `AmountExceedsPolicyCap` at proposal.
- Rolling window exhaustion blocks a dispatch that passed at proposal.
- Non-allowlisted destination reverts; tag `0` correctly means "any tag".
- Proposer cannot approve their own request.
- The same address cannot approve twice.
- Dispatch before `eligibleAt` reverts.
- A price older than 180 seconds reverts dispatch.
- A frozen treasury rejects propose, approve and dispatch.
- Policy amendment requires the amendment threshold and timelock.

### Notes

`dispatch` re-runs the full check rather than trusting the proposal-time result. The price moves and the window is shared between requests. A request valid an hour ago is not automatically valid now, and grandfathering is how treasuries get drained.

---

## Phase 2 — XRPL serialiser and signer in Go

**Goal:** a standalone Go package that produces byte-identical output to the XRPL reference implementation. Still no TEE. Independent of phases 0 and 1.

### Tasks

- [ ] **P2-1 — `internal/xrpl/serialize.go`: field encoding.** Canonical serialisation sorted by `(typeCode, fieldCode)` — not by name, not by declaration order. Covers `TransactionType` (1,2), `Flags` (2,2), `Sequence` (2,4), `DestinationTag` (2,14), `LastLedgerSequence` (2,27), `Amount` (6,1), `Fee` (6,8), `SigningPubKey` (7,3), `TxnSignature` (7,4), `Account` (8,1), `Destination` (8,3), `Memos` (15,9).
- [ ] **P2-2 — Zero-tag omission.** `DestinationTag` is omitted entirely when zero. Serialising a zero tag produces a different hash than omitting it, and the omitting path is the one used.
- [ ] **P2-3 — Amount encoding.** Drops in XRP encoding with the high bit set. `uint64` throughout; no float ever touches an amount.
- [ ] **P2-4 — Memos.** One memo carrying `MemoData = keccak256(abi.encode(requestId))`. This is the link `ExecutionVerifier` matches against the FDC payment reference — changing the encoding means changing `ExecutionVerifier` in the same commit.
- [ ] **P2-5 — `internal/xrpl/address.go`.** AccountID = `ripemd160(sha256(compressedPubKey33))`. Classic address = base58check with prefix `0x00`, 4-byte double-SHA256 checksum, XRPL alphabet `rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz`.
- [ ] **P2-6 — `internal/xrpl/sign.go`: hashing.** SHA-512Half — `sha512` then first 32 bytes, not `sha256`. Single-sign prefix `0x53545800`, transaction id prefix `0x54584E00`.
- [ ] **P2-7 — `internal/xrpl/sign.go`: signing.** RFC 6979 deterministic ECDSA over secp256k1, DER encoding with a low-S value. `Flags` carries `tfFullyCanonicalSig` (`0x80000000`).
- [ ] **P2-8 — Signed blob assembly.** Re-serialise including `TxnSignature`, hex-uppercase — that is what `submit` takes. Transaction id is SHA-512Half of `0x54584E00 || signedBlob`.
- [ ] **P2-9 — `LastLedgerSequence` mandatory.** Refuse to build a transaction without one. A transaction without it can never be proven non-existent, which breaks the entire failure path.
- [ ] **P2-10 — Reference test vectors.** Taken from the XRPL reference implementation, committed as fixtures. Never generated by this code — a vector produced by the code under test proves nothing.

### Verification

```bash
cd aegis-fce && go build ./... && go vet ./... && go test ./internal/xrpl/... -v
```

### Exit criteria

- Serialising a known transaction produces byte-identical output to the reference vector.
- A known keypair and transaction produce the reference signature exactly.
- A known public key derives the reference classic address.
- Omitting a zero `DestinationTag` produces a different hash than including it, and the omitting path is the one used.
- Signing the same request twice produces identical bytes, confirming RFC 6979.

### Notes

No XRPL library. The enclave image is the unit of attestation and must stay small and reproducible. This package is a few hundred lines and testable in isolation, which is worth far more than a dependency.

---

## Phase 3 — TEE extension

**Goal:** connect phases 1 and 2 through FCC. A full propose → approve → dispatch → signature cycle on Coston2.

**Depends on:** 0, 1, 2 — all three, completely.

### Tasks

- [ ] **P3-1 — `AegisInstructionSender.sol`.** `OP_TYPE_XRPL = bytes32("XRPLW")`, `OP_COMMAND_KEYGEN/SIGNTX/STATUS`. Constructor, `setExtensionId()` and `_getExtensionId()` copied verbatim from the scaffold and never modified. The discovery loop starts at `FIRST_PUBLIC_EXTENSION_ID = 0x10000`; ids below are reserved for system extensions such as PMW.
- [ ] **P3-2 — Instruction construction.** `TeeInstructionParams` with `cosigners` = guardian addresses and `cosignersThreshold` = the tier's required approval count, so FCC enforces a second authorisation gate on top of Aegis' own accounting. Machine selection via `getRandomTeeIds(_getExtensionId(), 1)`.
- [ ] **P3-3 — `internal/config/config.go`.** `OPTypeXRPL`, the three op commands, and `Version`. Bump `Version` on every behaviour or interface change — it is part of the attestation identity.
- [ ] **P3-4 — `pkg/types/types.go`.** `SignRequest`, `SignResponse`, `KeygenResponse`, `State`. `StateResponse` comes from the scaffold and is not modified.
- [ ] **P3-5 — `pkg/types/register.go`.** ABI decoder registration for every message and result pair. A missing registration surfaces as a decode failure, not as a clear error.
- [ ] **P3-6 — `internal/extension/extension.go`: routing.** Route on `opType`, sub-route on `opCommand`, three handlers. `New()` and the HTTP wiring stay as the scaffold ships them.
- [ ] **P3-7 — `processKeygen`.** secp256k1 key from `crypto/rand` inside the enclave, stored in a `sync.RWMutex`-guarded map keyed by `treasuryId`. Never written to disk, never logged, never returned. Returns `(bytes33 compressedPubKey, string classicAddress)`.
- [ ] **P3-8 — `processSignTx` and the digest check.** Recompute `keccak256` over the decoded fields and compare against `policyDigest` **before touching the key**. Mismatch returns status `0` with the log line `policy digest mismatch` and no signature.
- [ ] **P3-9 — `TreasuryRegistry.bindXrplAccount` wired.** Consumes the `KEYGEN` result, derives the AccountID on-chain with precompiles `0x02` (SHA-256) and `0x03` (RIPEMD-160), rejects any mismatch with the reported classic address, rejects any second binding.
- [ ] **P3-10 — `processStatus`.** Returns `(bool hasKey, uint32 lastSignedSequence)`. Nothing else.
- [ ] **P3-11 — `GET /state`.** Booleans and sequence numbers only. If a struct field holding a key is reachable from a response type, that is the bug.
- [ ] **P3-12 — `recordSignature` path.** `PaymentController.recordSignature`, restricted to `AegisInstructionSender`, moves the request to `Signed` and emits `PaymentSigned(requestId, signedBlob, txHash)` — the event the submitter watches in phase 4.
- [ ] **P3-13 — Tamper test.** Take a real payload, alter one field, confirm status `0` and no signature. Constructing a fake payload does not test the same thing.
- [ ] **P3-14 — Regenerate bindings.** `./scripts/generate-bindings.sh` after any ABI change.

### Verification

```bash
cd aegis-fce && go build ./... && go test ./... && go vet ./...
./scripts/start-services.sh --chain coston2
./scripts/test.sh
```

### Exit criteria

- `KEYGEN` produces an XRPL address, binds it on-chain, and a second binding attempt reverts.
- The on-chain derived AccountID matches the address returned by the enclave.
- `SIGNTX` with a correct digest returns a signed blob whose signature verifies against the treasury public key.
- `SIGNTX` with any single field altered returns status `0` and the log `policy digest mismatch`, with no signature produced, driven by an actually tampered payload.
- `GET /state` contains no key material under any input.
- A full propose → approve → dispatch → signature cycle completes on Coston2.

### Notes

The three-way constant alignment is the most common failure here. On `unsupported op type`, check `bytes32("XRPLW")` against `OPTypeXRPL` against `teeutils.ToHash(config.OPTypeXRPL)` before debugging anything else. `bytes32("...")` truncates at 32 bytes — keep the strings short.

If `SignRequest` changes, both sides change in the same commit and the decoder registration is updated. A one-sided change produces `policy digest mismatch` on every payment, which looks like a bug and is the system working.

Keys are born in the enclave, never imported. The scaffold's ECIES `/decrypt` path on port 7701 exists, but an encrypted key in calldata is permanent public storage and encryption breaks over time. Import is P6-5 and travels off-chain.

---

## Phase 4 — Settlement and proof

**Goal:** close the loop with FDC. This is what separates Aegis from a signing service.

**Depends on:** 3.

### Tasks

- [ ] **P4-1 — `submitter/src/watcher.ts`.** Websocket subscription to `PaymentSigned` on Coston2. Reconnect and replay from the last processed block on restart.
- [ ] **P4-2 — `submitter/src/xrpl.ts`: submit.** `submit` the blob to `wss://s.altnet.rippletest.net:51233`.
- [ ] **P4-3 — `submitter/src/xrpl.ts`: confirm.** Poll `tx` until `validated: true`, or until the ledger passes `LastLedgerSequence`. Those are the only two terminal outcomes.
- [ ] **P4-4 — `submitter/src/fdc.ts`: `Payment` attestation.** Request with `sourceId = testXRP` and the transaction hash, wait for round finality, retrieve the Merkle proof from the DA layer.
- [ ] **P4-5 — `submitter/src/fdc.ts`: `ReferencedPaymentNonexistence`.** The failure branch, taken when the ledger passes `LastLedgerSequence` with nothing validated.
- [ ] **P4-6 — `ExecutionVerifier.confirmSettlement`.** `ContractRegistry.getFdcVerification().verifyPayment(proof)`, then assert attested source == treasury AccountID, receiving address == `destinationAccountId`, `spentAmount` == `amountDrops + feeDrops`, and payment reference == `keccak256(abi.encode(requestId))`. On success: state → `Settled`, `advanceSequence`.
- [ ] **P4-7 — `ExecutionVerifier.confirmNonExecution`.** Consumes the non-existence proof. State → `Failed`, rolling-window spend released, **sequence advanced**.
- [ ] **P4-8 — Window release accounting.** The committed spend from P1-12 is returned when a request ends `Failed`, and only then.
- [ ] **P4-9 — Idempotency and concurrency.** Two submitters running simultaneously cause no double-spend and no state corruption. Re-submitting an already-settled request is a no-op, not a revert loop.

### Verification

```bash
cd submitter && npm run build && npm test
forge test -vvv --match-contract ExecutionVerifier
```

### Exit criteria

- A payment settles on XRPL Testnet and the FDC proof moves on-chain state to `Settled`.
- A proof for a different transaction is rejected by `confirmSettlement`.
- A transaction deliberately allowed to expire past `LastLedgerSequence` is proven non-existent, moves to `Failed`, releases the committed window spend, and advances the sequence so the next payment is not wedged.
- Manually calling `confirmSettlement` with a fabricated proof reverts — the submitter holds no authority.
- Two submitters running at once produce no double-spend and no state corruption.

### Notes

The sequence advance on the failure path is easy to skip and catastrophic to omit. Without it, one expired transaction blocks the treasury permanently, because XRPL keeps expecting that sequence number.

The submitter is a liveness helper, not a trust assumption. Anyone can run one. Its only on-chain authority is submitting proofs, and a proof that does not verify is rejected by the contract.

---

## Phase 5 — Interface and hardening

**Goal:** someone who has never seen the codebase completes the full lifecycle using only the README.

**Depends on:** 4.

### Tasks

- [ ] **P5-1 — Treasury overview.** Balance, active policy summary, pending requests with tier and unlock countdown, complete audit log.
- [ ] **P5-2 — Policy authoring.** Tier editor, rolling window, allowlist, roles, amendment parameters. Reject an invalid tier ordering in the form, not at the revert.
- [ ] **P5-3 — Proposal creation with live validation.** Run the policy check client-side before submission, so a violating proposal is refused before it costs gas or an approver's attention.
- [ ] **P5-4 — Approval screen.** Destination address, destination tag, amount in drops **and** XRP **and** USD, resolved tier, approvals collected and required, unlock time, policy digest. Every fact the contract will check.
- [ ] **P5-5 — Countdown timers and window gauge.** Live timelock countdowns and a rolling-window consumption gauge.
- [ ] **P5-6 — Guardian freeze.** One click, with confirmation. No threshold, no delay — that is the point of a guardian.
- [ ] **P5-7 — Error surfacing.** Every custom Solidity error mapped to a plain-language explanation naming the rule that fired.
- [ ] **P5-8 — Audit log links.** Every request links to its Coston2 transactions and its XRPL transaction.
- [ ] **P5-9 — README.** From-zero setup path, including the indexer credential request as step one, since nothing runs without it.
- [ ] **P5-10 — Hygiene sweep.** `grep -rn "TODO\|FIXME\|XXX\|placeholder\|mock" --include="*.sol" --include="*.go" --include="*.ts" contracts/ aegis-fce/ submitter/ web/src/` returns nothing.
- [ ] **P5-11 — Demo video.** 90 seconds: a policy-compliant payment settling, and a policy-violating payment being refused with the rule named.
- [ ] **P5-12 — Demo rehearsal.** Run the full path end-to-end at least twice. If FTSO is stale during a live demo, that is the fail-closed design working — say so; a fallback price would be a weaker answer.

### Verification

```bash
cd web && npm run build
forge test && (cd aegis-fce && go test ./...) && (cd submitter && npm test)
```

### Exit criteria

- A person who has not seen the codebase can create a treasury, define a policy, propose a payment, approve it with a second account, and watch it settle, using only the README.
- Every rejection in the UI names the rule that fired.
- The audit log for any request can be reconstructed independently from chain data with no Aegis service running.
- The hygiene sweep in P5-10 returns nothing outside `test/`.

### Notes

The approval screen is the product's most important surface. An approver who cannot see destination, tag, both amounts, tier, threshold and unlock time is approving a description rather than a fact — which is the exact failure Aegis exists to prevent.

---

## Phase 6 — Multisig and PMW migration

Post-hackathon. Specified now because the architecture depends on it being possible, and because the submission claims it as the migration path.

### Tasks

- [ ] **P6-1 — k-of-n across TEE machines.** `getRandomTeeIds(extensionId, n)` returning multiple machines.
- [ ] **P6-2 — XRPL `SignerList`.** Configured with the n enclave-held keys.
- [ ] **P6-3 — Multi-sign serialisation.** Hash prefix `0x534D5400` with the signer's AccountID appended, per-signer `Signers` array entries.
- [ ] **P6-4 — PMW swap.** `AegisInstructionSender.requestSignature` calls PMW instead of the custom extension once its interface is public.
- [ ] **P6-5 — Key import path.** Over an off-chain channel to the proxy, for migrating existing treasuries. Never through calldata.
- [ ] **P6-6 — Registry migration.** System contract addresses move from `config/coston2/deployed-addresses.json` to `FlareContractRegistry` when FCC ships. One line, in one place, on the day it becomes possible.

### Why the architecture already supports this

`requestSignature` is the only function in the system that touches signing. `PolicyEngine`, `TreasuryRegistry` and `PaymentController` are signing-agnostic. `SignRequest` deliberately carries structured fields rather than a serialised blob, so a different signer consuming the same fields is a drop-in replacement.

PMW provides natively what P6-1 to P6-3 build by hand: wallets as k-of-n key sets across TEE machines on native XRPL and BTC multisig accounts, per-instruction nonces with transaction chaining, reissuance at a different fee, nullification, and FDC execution proofs. Building the custom extension first is not wasted work — it is what makes the migration a module swap rather than a rewrite, and it is the only route available while system extension ids below `0x10000` remain reserved.

---

## Cross-phase gates

These apply to every commit in every phase, from `CLAUDE.md`. A phase cannot close with any of them failing.

- [ ] `forge test` and `go test ./...` both pass.
- [ ] No mocks, stubs or simulated components outside `test/`. Nothing in `src/`, `contracts/`, `aegis-fce/`, `submitter/` or `web/` imports a test double.
- [ ] No `TODO`, `FIXME`, `XXX`, placeholder address, `example.com` URL, or function returning a constant "for now".
- [ ] No silent fallbacks. Stale price reverts, digest mismatch returns status `0`, unknown treasury errors. Every failure path is a refusal to spend money, which is the correct outcome.
- [ ] No key material logged, returned or persisted — not at debug level, not in an error message, not in `/state`.
- [ ] No check weakened to make a test pass. If `MAX_PRICE_AGE` blocks a test, the test setup is wrong.
- [ ] `SignRequest` changes touch Solidity, Go and the decoder registration in one commit.
- [ ] `opType` / `opCommand` changes touch all three locations.
- [ ] ABI changes are followed by `./scripts/generate-bindings.sh`.
- [ ] Extension behaviour changes bump `Version` in `internal/config/config.go`.
- [ ] This file and `PLAN.md` reflect reality — checked off what is done, corrected what turned out wrong.

---

## Definition of done

The project is done when a person outside the team can, using only the README:

1. Create a treasury whose XRPL key was born inside a TEE.
2. Define a policy with tiers, a rolling window and an allowlist.
3. Propose a payment, have a second account approve it, wait out the timelock, and watch it settle on XRPL Testnet.
4. See the settlement confirmed on Coston2 by an FDC proof.
5. Attempt a payment that violates each rule and be refused each time, with the specific rule named.
6. Reconstruct the entire history from chain data alone, with no Aegis service running.

---

## Numbering note

`PLAN.md` is authoritative on phase numbers: **5 = interface and hardening, 6 = multisig and PMW**. `DOCS.md` §8 and `CLAUDE.md` refer to multisig and key import as "phase 5" in passing — those references predate the split and mean phase 6. Corrected here; worth fixing at the source when either file is next touched.
