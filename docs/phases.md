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
| 0 | Unblock the critical path | — | `[~]` one blocker: faucet |
| 1 | Policy layer in Solidity | — | `[x]` 88 tests passing |
| 2 | XRPL serialiser and signer in Go | — | `[x]` verified against a real XRPL blob |
| 3 | TEE extension | 0, 1, 2 | `[~]` full cycle proven on a local chain **and settled on XRPL Testnet**; Coston2 relay needs the faucet |
| 4 | Settlement and proof | 3 | `[~]` 33 settlement tests, 87 submitter tests, **a real validated XRPL payment**; the FDC proof leg needs the faucet |
| 5 | Interface and hardening | 4 | `[~]` dashboard complete, 32 tests; video and rehearsal need the faucet |
| 6 | Multisig and PMW migration | 5 | post-program |

Phases 0, 1 and 2 have no dependency on each other. The original plan expected P0-1 (indexer credentials) to set the schedule; running our own indexer removed that, so the only thing outstanding in phase 0 is funding the deployer from a captcha-gated faucet.

**The Flare half no longer waits on the faucet either.** `./scripts/coston2-fork-check.sh` forks Coston2 with anvil and funds a deployer on the fork, which puts the production deploy script in front of the real system contracts rather than the doubles that had been standing in for them. It proves four things that had never been checked against anything real: `script/DeployAegis.s.sol` deploys and wires against the live `FtsoV2`, `FlareTeeManager` and `FdcVerification`; the *derived* XRP/USD feed id resolves on the real `FtsoV2` (it is built rather than pasted, and a wrong one reverts); the drops → USD conversion agrees with the real value and the real decimals; and the staleness check refuses with `StalePrice` once that real feed is aged past `MAX_PRICE_AGE`. That last one is the fail-closed path, tested by warping the fork rather than by writing a timestamp into a stub.

Forking also closed the part of the FDC gap that was actually about our code. `test/fork/FdcVerificationFork.t.sol` deploys against the **real `FdcVerification`** on a Coston2 fork and lets Flare's own contract compute the Merkle leaf from a `Payment` response our `IPayment` structs encoded. That is the risk every offline settlement test was blind to by construction: the leaf is `keccak256(abi.encode(Response))`, so a single field of difference between our locally-declared structs and Flare's would reject every real proof, and both sides of the offline tests are ours. Three tests — Flare's verifier accepts our encoding, a settlement completes through it to `Settled` with the sequence advanced, and a response altered after the root is published is rejected by Flare rather than merely by us. That last one is what makes the first two mean something.

Exactly one thing is substituted, and only one: the `Relay`, which is where `FdcVerification` reads the round's finalised root. It is replaced with eleven bytes returning storage slot zero, so a chosen root can be put there. That is the root *oracle* — the leaf hashing, the Merkle walk and the attestation-type handling all stay Flare's. Producing a genuinely finalised root means getting an attestation into a voting round, which needs the verifier API key.

The tests skip themselves via `vm.skip` without `COSTON2_RPC_URL`, so they report as skipped rather than as passing, and CI sets it so they actually run.

The relay's contract half is covered the same way. `test/fork/TeeRegistryFork.t.sol` registers the real `AegisInstructionSender` against the real `FlareTeeManager` on a fork — registration is permissionless, so nothing is substituted — and checks that the id handed out is a public one, that the registry then points it at our sender, that a second registration takes a different id (the `MachineManager.TooMany()` `CLAUDE.md` warns about, pinned rather than trusted), and that machine selection fails because no machine is registered rather than because our locally-declared interface is wrong. That last distinction is the whole point: `ITeeExtensionRegistry` and `ITeeMachineRegistry` are declared locally, so every offline test of them could only show Aegis agreeing with itself.

**A limitation that run surfaced, and it is not ours to fix.** `setExtensionId()` scans the shared registry from `0x10000` upward for its own address, so its cost is set by how many public extensions exist chain-wide. Coston2 is past 65,880 — about 350 entries, roughly 1.7M gas — and it only grows. Past a few thousand extensions the call no longer fits in a block and the deployment step becomes impossible. It is one-shot per deployment, so the exposure is a deploy that cannot complete rather than a treasury that cannot pay, and the function is scaffold do-not-modify. Recorded in the README's limitations. The fix belongs to Flare: have `register()` return the id rather than making every extension search for itself.

**A TEE machine does register on a fork, and that narrowed the last gap to one call.** `test/fork/TeeMachineFork.t.sol` registers one against the real `FlareTeeManager`. On-chain registration takes no hardware quote — the scaffold's own tooling says so, logging that the code hash comes from the proxy's `/info` and is "not independently verified against attestation" — and the gates it does have are all per-extension decisions the extension owner makes: the code-version allowlist and the machine-owner allowlist. So registering our own machine for our own extension exercises the real path rather than bypassing one.

Getting there took the exact payload the chain expects, and each wrong guess was refused by name: `FunctionNotFound` (the diamond routes on the signature string, and `PublicKey` is `(bytes32,bytes32)` not `(uint256,uint256)`), `OwnerNotAllowed`, `InvalidTeePublicKeyOrSignature`, `ECDSAInvalidSignature`. The digest is `keccak256(abi.encode(prefix, chainId, keccak256(abi.encode(machineData))))` then EIP-191 prefixed, with `prefix = bytes32("TEE_MACHINE_REGISTER")` — the chain id is in there to stop a registration signed for one network being replayed on another.

`requestSignature` then reaches machine selection inside the real contract, which is as far as it can go: **a registered machine is not a selectable one.** `getRandomTeeIds` reads `extensionActiveTeeIds`, and a machine joins that set only after `toProduction` is called with an `ITeeAvailabilityCheck.Proof` — an FDC2 attestation that the enclave answered a challenge. Both tests that touch selection assert `TooMany()`: one asked for, zero active.

So what is left unverified on the relay is no longer "needs a real attestation" in the abstract. It is one call, `toProduction`, taking one proof type, and it needs a real FDC round — the same credential the settlement leg needs. Everything before it is checked against deployed code.

The XRPL half no longer waits on it either. `./scripts/xrpl-settlement.sh` funds an enclave-born address from the XRPL Testnet faucet — which is an HTTP endpoint, not a captcha — reads the account's real sequence and ledger height, runs the full policy cycle against them, and submits the signed blob to the network. Transaction `E82AA92E…71D059` validated in ledger 19574777, `tesSUCCESS`, 1,000,000 drops delivered. What still needs C2FLR is Flare's side: the instruction relay and the FDC proof.

That run is also what found the sequence bug recorded below, which no unit test could have caught, because the wrong assumption was shared by the contract and every test that exercised it.

**There is a second external dependency the earlier tracker did not record, and it gates Phase 4 alone.** The FDC verifier server needs an API key: `https://fdc-verifiers-testnet.flare.network` answers `401 Unauthorized` without one, and `.env.example` notes it is "issued with the verifier server". The DA layer is open — it answers a domain error rather than a 401 — so the proof *retrieval* half needs nothing. Only `prepareRequest` is gated. Request the key alongside the faucet click; the two are independent and both are one-time.

**Every other remaining Coston2 task reduces to the faucet.** Nothing between the faucet click and a finished project is manual any more: `./scripts/phase0-finish.sh` polls the balance and then runs deploy, registration and the KEYGEN acceptance, and `./scripts/coston2-payment.sh` is the leg after it — fund the treasury, record its starting sequence, allowlist a destination, then propose → approve → dispatch through Flare's real instruction relay to a signed blob. Settlement is the submitter's, which is tested and is README step 9.

`coston2-payment.sh` has **not been run against Coston2** — that needs the faucet, and saying otherwise would be the kind of claim this file exists to prevent. Everything in it that does not depend on Coston2 has been run, though, against real contracts on a local chain: the `getTreasury` field offsets, `setInitialSequence` and its readback, the derived approver, `setAllowlist`, the `PaymentProposed` and `SignatureRequested` topic parses, and the `getRequest` state offset. The single line never exercised is the poll against `$EXT_PROXY_URL/action/result/<id>`, which is the relay itself and has no local equivalent. `./scripts/check.sh` passes in full — contracts, extension, container conformance, submitter, dashboard and every hygiene rule — on a clean checkout with no chain, tunnel or credentials. Nothing else is code-incomplete. What is left is P0-2 and the four items downstream of it (P0-7's on-chain leg, P3-15 on Coston2, P4's live settlement, P5-11 and P5-12), all of which need C2FLR at `0xbC479252c67526f9BAa0e70E7c27Cc53222b49b5` from `https://faucet.flare.network/coston2`. The captcha is the reason this cannot be automated, and it is the only reason.

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
- [~] **P0-7 — Run the scaffold unmodified.** `./scripts/tunnel.sh` → `pre-build.sh` → `start-services.sh --chain coston2` → `post-build.sh` → `test.sh`. `SAY_HELLO` and `SAY_GOODBYE` both complete. The on-chain leg is blocked on P0-2 alone; everything reachable without it passes — version pins consistent, bindings generated, `forge build` clean, the Go extension builds/vets/tests under Go 1.26.4, all three Docker images built, `test-unit.sh` green, `test-conformance.sh` 16/16, pre-flight reaching Coston2 and stopping only on balance, and `ext-proxy` booting against the local indexer, logging `Database in sync`, and serving its internal API while it waits for a registered TEE machine. Requires bash 4.4+ — macOS 3.2 breaks the scaffold's own scripts. `./scripts/phase0-check.sh` reports what is still unmet.
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

- [x] **P1-1 — `PolicyEngine.sol`: policy storage.** `Tier` and `Policy` structs, `createPolicy`, immutable versions. Tiers ascending by `maxAmountUsd`; the last tier is the hard per-payment cap. Reject unsorted or empty tier arrays at creation.
- [x] **P1-2 — `PolicyEngine.sol`: tier resolution.** `resolveTier` returns the lowest tier whose ceiling covers the amount, reverts `AmountExceedsPolicyCap` when none does.
- [x] **P1-3 — `PolicyEngine.sol`: allowlist.** `setAllowlist` / `isDestinationAllowed` over the pair (AccountID, destination tag). Tag `0` means any tag is permitted for that account.
- [x] **P1-4 — `PolicyEngine.sol`: roles.** Bitmask per policy — `PROPOSER = 1`, `APPROVER = 2`, `GUARDIAN = 4`, `POLICY_ADMIN = 8`. One address may hold several.
- [x] **P1-5 — `TreasuryRegistry.sol`: lifecycle.** `createTreasury`, the `Treasury` struct, `TreasuryCreated`. The XRPL account does not exist yet at this point.
- [x] **P1-6 — `TreasuryRegistry.sol`: freeze.** `setFrozen`, guardian-only, single transaction, no threshold. Unfreeze requires the policy's amendment threshold.
- [x] **P1-7 — `TreasuryRegistry.sol`: sequence tracking.** `nextSequence`, `advanceSequence` restricted to `ExecutionVerifier`.
- [x] **P1-8 — `TreasuryRegistry.sol`: `bindXrplAccount` signature.** Written, access-restricted to `AegisInstructionSender`, not yet reachable — wiring is P3-9.
- [x] **P1-9 — FTSO integration.** Derived feed id `bytes21(abi.encodePacked(uint8(1), bytes7("XRP/USD"), bytes13(0)))`, `MAX_PRICE_AGE = 180`, conversion `amountUsd18 = amountDrops * value * 10^(12 - decimals)`. Never cache a price across transactions.
- [x] **P1-10 — `PaymentController.sol`: `propose`.** Convert to USD, check allowlist, resolve tier, check rolling window, store with `eligibleAt = block.timestamp + tier.timelockSeconds`. Revert on the first violation with a specific custom error, so no one ever approves a request that cannot execute.
- [x] **P1-11 — `PaymentController.sol`: `approve`.** Reject the proposer of that request. Reject a duplicate from the same address. Transition to `Approved` when `approvals >= tier.requiredApprovals`.
- [x] **P1-12 — `PaymentController.sol`: rolling window.** Ring buffer of `(timestamp, amountUsd)` per treasury, pruned lazily on `propose` and `dispatch`. Spend is committed at dispatch, not at proposal, and released when a request ends `Failed`.
- [x] **P1-13 — `PaymentController.sol`: `dispatch` guard.** Requires `Approved`, `block.timestamp >= eligibleAt`, treasury not frozen — then **re-runs the entire policy check**. The instruction-send call itself is P3-1.
- [x] **P1-14 — Policy digest.** `keccak256(abi.encode(requestId, treasuryId, destinationAccountId, destinationTag, amountDrops, sequence, lastLedgerSequence, feeDrops))`, computed in `dispatch` and stored on the request.
- [x] **P1-15 — Policy amendment path.** Repointing a treasury to a new `policyId` requires the current policy's `amendApprovals` and `amendTimelock`.
- [x] **P1-16 — Test suite.** One passing and one failing test per rule. A rule with only a happy path is untested.

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

- [x] **P2-1 — `internal/xrpl/serialize.go`: field encoding.** Canonical serialisation sorted by `(typeCode, fieldCode)` — not by name, not by declaration order. Covers `TransactionType` (1,2), `Flags` (2,2), `Sequence` (2,4), `DestinationTag` (2,14), `LastLedgerSequence` (2,27), `Amount` (6,1), `Fee` (6,8), `SigningPubKey` (7,3), `TxnSignature` (7,4), `Account` (8,1), `Destination` (8,3), `Memos` (15,9).
- [x] **P2-2 — Zero-tag omission.** `DestinationTag` is omitted entirely when zero. Serialising a zero tag produces a different hash than omitting it, and the omitting path is the one used.
- [x] **P2-3 — Amount encoding.** Drops in XRP encoding with the high bit set. `uint64` throughout; no float ever touches an amount.
- [x] **P2-4 — Memos.** One memo carrying `MemoData = keccak256(abi.encode(requestId))`. This is the link `ExecutionVerifier` matches against the FDC payment reference — changing the encoding means changing `ExecutionVerifier` in the same commit.
- [x] **P2-5 — `internal/xrpl/address.go`.** AccountID = `ripemd160(sha256(compressedPubKey33))`. Classic address = base58check with prefix `0x00`, 4-byte double-SHA256 checksum, XRPL alphabet `rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz`.
- [x] **P2-6 — `internal/xrpl/sign.go`: hashing.** SHA-512Half — `sha512` then first 32 bytes, not `sha256`. Single-sign prefix `0x53545800`, transaction id prefix `0x54584E00`.
- [x] **P2-7 — `internal/xrpl/sign.go`: signing.** RFC 6979 deterministic ECDSA over secp256k1, DER encoding with a low-S value. `Flags` carries `tfFullyCanonicalSig` (`0x80000000`).
- [x] **P2-8 — Signed blob assembly.** Re-serialise including `TxnSignature`, hex-uppercase — that is what `submit` takes. Transaction id is SHA-512Half of `0x54584E00 || signedBlob`.
- [x] **P2-9 — `LastLedgerSequence` mandatory.** Refuse to build a transaction without one. A transaction without it can never be proven non-existent, which breaks the entire failure path.
- [x] **P2-10 — Reference test vectors.** A validated Payment pulled from XRPL Testnet with `tx` in binary mode, committed as `go/internal/xrpl/testdata/payment_reference.json`. Never generated by this code — a vector produced by the code under test proves nothing. It carries a Memos array with both MemoType and MemoData and omits Flags and DestinationTag, so the omission paths are exercised by real data.

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

- [x] **P3-1 — `AegisInstructionSender.sol`.** `OP_TYPE_XRPL = bytes32("XRPLW")`, `OP_COMMAND_KEYGEN/SIGNTX/STATUS`. Constructor, `setExtensionId()` and `_getExtensionId()` copied verbatim from the scaffold and never modified. The discovery loop starts at `FIRST_PUBLIC_EXTENSION_ID = 0x10000`; ids below are reserved for system extensions such as PMW.
- [x] **P3-2 — Instruction construction.** `TeeInstructionParams` with `cosigners` = guardian addresses and `cosignersThreshold` = the tier's required approval count, so FCC enforces a second authorisation gate on top of Aegis' own accounting. Machine selection via `getRandomTeeIds(_getExtensionId(), 1)`.
- [x] **P3-3 — `internal/config/config.go`.** `OPTypeXRPL`, the three op commands, and `Version`. Bump `Version` on every behaviour or interface change — it is part of the attestation identity.
- [x] **P3-4 — `pkg/types/types.go`.** `SignRequest`, `SignResponse`, `KeygenResponse`, `State`. `StateResponse` comes from the scaffold and is not modified.
- [x] **P3-5 — `pkg/types/register.go`.** ABI decoder registration for every message and result pair. A missing registration surfaces as a decode failure, not as a clear error.
- [x] **P3-6 — `internal/extension/extension.go`: routing.** Route on `opType`, sub-route on `opCommand`, three handlers. `New()` and the HTTP wiring stay as the scaffold ships them.
- [x] **P3-7 — `processKeygen`.** secp256k1 key from `crypto/rand` inside the enclave, stored in a `sync.RWMutex`-guarded map keyed by `treasuryId`. Never written to disk, never logged, never returned. Returns `(bytes33 compressedPubKey, string classicAddress)`.
- [x] **P3-8 — `processSignTx` and the digest check.** Recompute `keccak256` over the decoded fields and compare against `policyDigest` **before touching the key**. Mismatch returns status `0` with the log line `policy digest mismatch` and no signature.
- [x] **P3-9 — `TreasuryRegistry.bindXrplAccount` wired.** Consumes the `KEYGEN` result, derives the AccountID on-chain with precompiles `0x02` (SHA-256) and `0x03` (RIPEMD-160), rejects any mismatch with the reported classic address, rejects any second binding.
- [x] **P3-10 — `processStatus`.** Returns `(bool hasKey, uint32 lastSignedSequence)`. Nothing else.
- [x] **P3-11 — `GET /state`.** Booleans and sequence numbers only. If a struct field holding a key is reachable from a response type, that is the bug.
- [x] **P3-12 — `recordSignature` path.** `PaymentController.recordSignature`, restricted to `AegisInstructionSender`, moves the request to `Signed` and emits `PaymentSigned(requestId, signedBlob, txHash)` — the event the submitter watches in phase 4.
- [x] **P3-15 — Prove the cycle on a live chain.** `./scripts/local-integration.sh` runs the whole thing against a local chain and the real enclave process: deploy, policy, treasury, KEYGEN, bind, propose, approve, dispatch, SIGNTX, record, then tamper. Real transactions, real contracts, a real XRPL signature. The only piece not covered is Flare's instruction relay, which needs Coston2 and a funded deployer — and the relay is exactly what the policy digest defends against, which the tamper step proves. Two real defects came out of running it that no unit test had caught: `go run` leaves the server alive as a grandchild, so a second run met an enclave that already held the treasury's key; and a right-aligned AccountID passed every on-chain check and was only refused at signing, after approvals had been collected. The second is fixed in `propose`.
- [x] **P3-13 — Tamper test.** Take a real payload, alter one field, confirm status `0` and no signature. Constructing a fake payload does not test the same thing.
- [x] **P3-14 — Keep the generated artefacts in step.** The scaffold's Hello World bindings and its `tools/` deploy CLI are untouched, so `generate-bindings.sh` still does what it did; Aegis deploys through `script/DeployAegis.s.sol` instead, which needs no bindings. What did need regenerating is `testdata/conformance` — the scaffold's fixtures describe an extension that no longer exists. `AEGIS_GEN_FIXTURES=1 go test ./internal/extension -run GenerateConformance` rewrites them, and `test-conformance.sh` passes 16/16 against the Aegis wire contract.

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

- [x] **P4-1 — `submitter/src/watcher.ts`.** Websocket subscription to `PaymentSigned` on Coston2, plus a replay from the persisted cursor to the head on start. The cursor is written per chunk and per handled log, atomically. A malformed cursor file is an error rather than a reason to restart from block zero, which would look like a hang. Replay is walked in 30-block windows because that is what the public Coston2 RPC actually serves.
- [x] **P4-2 — `submitter/src/xrpl.ts`: submit.** `submit` the blob to `wss://s.altnet.rippletest.net:51233`. The engine result is logged and never acted on — two submitters racing means one of them gets a duplicate-transaction error for a payment that is about to settle perfectly well.
- [x] **P4-3 — `submitter/src/xrpl.ts`: confirm.** Poll `tx` until `validated: true`, or until the ledger passes `LastLedgerSequence`. Those are the only two terminal outcomes; `classifyOutcome` returns neither while a transaction is sitting unvalidated in an open ledger, and the polling budget runs out into an error rather than a guess.
- [x] **P4-4 — `submitter/src/fdc.ts`: `Payment` attestation.** Prepare at the verifier server, `FdcHub.requestAttestation` paying the fee `FdcRequestFeeConfigurations` quotes for that exact request, derive the voting round from the receipt's block timestamp, then poll the DA layer's raw endpoint and `decodeAbiParameters` the response into the struct the contract takes.
- [x] **P4-5 — `submitter/src/fdc.ts`: `ReferencedPaymentNonexistence`.** The failure branch, taken when the ledger passes `LastLedgerSequence` with nothing validated. The searched range is exactly `[firstLedgerSequence, lastLedgerSequence]` and the source-address constraint is off, because both narrow the claim and `ExecutionVerifier` rejects a proof that narrowed it.
- [x] **P4-6 — `ExecutionVerifier.confirmSettlement`.** `verifyPayment(proof)`, then assert the attestation type, the source id, the memo reference == `keccak256(abi.encode(requestId))`, attested source == the treasury's classic address, receiving address == `destinationAccountId` re-encoded on-chain, and `spentAmount` == `amountDrops + feeDrops`. On success: state → `Settled`, `advanceSequence`.
- [x] **P4-6b — `ExecutionVerifier.confirmFailedExecution`.** Not in the original plan, and required. A `tec`-coded payment is *in* a ledger: it burned the fee, consumed the sequence, and delivered nothing. It takes a `Payment` proof with a non-zero `status`, checks the *intended* destination and amount, and ends `Failed` with the window released and the **sequence advanced**. Without this path such a payment can only be proven through P4-7, which does not advance — and the treasury then reuses a sequence XRPL has already passed, forever.
- [x] **P4-7 — `ExecutionVerifier.confirmNonExecution`.** Consumes the non-existence proof. State → `Failed`, rolling-window spend released, and the sequence deliberately **not** advanced — see the correction in the notes below.
- [x] **P4-8 — Window release accounting.** The committed spend from P1-12 is returned when a request ends `Failed`, and only then. A settled payment keeps its spend; both failure paths return it.
- [x] **P4-9 — Idempotency and concurrency.** Every entry point returns quietly on a request that already reached `Settled` or `Failed`, emitting `ProofAlreadyConsumed`, so a second submitter with a valid proof neither reverts nor overturns the first. In-process, a request already being worked on is skipped. Tested both ways round: a non-existence proof cannot un-settle a settled payment, and a settlement proof cannot un-fail a proven failure.
- [x] **P4-10 — `firstLedgerSequence`.** `dispatch` takes the XRPL ledger current at dispatch and stores it. It is not part of the policy digest and the enclave never sees it — it is not an XRPL transaction field. It exists so `confirmNonExecution` can require a search range that covers every ledger the payment could have reached; without a lower bound, a one-ledger non-existence proof would "prove" a payment absent that had already landed.

### Verification

```bash
forge test -vvv --match-contract ExecutionVerifier
cd submitter && npm install && npm run typecheck && npm run build && npm test
```

The submitter's ABI declarations are checked against `out/` rather than against a second copy written by hand, so `forge build` has to have run first. A field reordered in Solidity fails `test/abi.test.ts` immediately instead of surfacing as a proof that will not verify on-chain.

### Exit criteria

Contract-side, all proven under `forge test` against an FDC double that attests exact responses rather than accepting a flag — so "a fabricated proof is rejected" and "a tampered proof is rejected" are assertions about the Merkle leaf, not about a boolean the test set:

- A `Payment` proof matching every authorised field moves on-chain state to `Settled` and advances the sequence.
- A proof for a different transaction is rejected by `confirmSettlement` — as is one from another account, to another destination, for another amount, of another attestation type, or from another chain.
- A proof altered after attestation fails verification, because the leaf no longer matches.
- Calling `confirmSettlement` with a fabricated proof reverts `ProofNotVerified` — the submitter holds no authority.
- A transaction allowed to expire past `LastLedgerSequence` is proven non-existent, moves to `Failed`, and releases the committed window spend, freeing capacity for the next payment.
- A non-existence proof whose search starts after dispatch, ends before expiry, sets a threshold above the amount, or constrains source addresses is rejected.
- Two submitters with the same valid proof settle once; neither failure path can overturn a settlement, and settlement cannot overturn a proven failure.

Still outstanding, because it needs a funded deployer on Coston2 (P0-2):

- [ ] A payment settling on XRPL Testnet with the FDC proof moving the live contract to `Settled`.

### Notes

**Correction to the original plan.** `PLAN.md` says the non-execution path advances the sequence "so the next payment is not wedged". That is backwards, and this is the one place in phase 4 worth reading twice.

An XRPL transaction consumes its sequence only by being *included in a ledger*. One that expired past `LastLedgerSequence` without ever being included consumed nothing, and the account still expects that number. Advancing there is what wedges the treasury: every later payment would carry a sequence the account will never reach. Leaving `nextSequence` alone is what keeps it usable — the next dispatch simply reuses it, and the expired transaction can never be replayed because it is past its own expiry ledger.

The case the original wording was reaching for is real, though, and it is not this one. A `tec`-coded transaction *is* in a ledger — fee burned, sequence consumed, nothing delivered — and a non-existence attestation will happily prove it absent, because that attestation only counts *successful* payments. Proving that through `confirmNonExecution` is exactly the permanent wedge the plan warned about. So it gets its own path, P4-6b, driven by a `Payment` proof with a non-zero `status`, which is positive evidence that a ledger consumed the sequence. The submitter always takes the `Payment` path when the transaction exists at all, and the non-existence path only when nothing was included.

**A second correction, and this one came from the network rather than from reasoning.** Both the plan and the contract assumed a treasury's XRPL account starts at sequence 1. It does not. Since the DeletableAccounts amendment a newly funded account takes the *ledger index it was created in* as its first sequence — 19,574,774 for the account this was found with. `createTreasury` hardcoded 1, which meant every treasury would sign its first payment against a sequence XRPL passed millions of ledgers ago.

The failure is unrecoverable, which is what makes it worth its own paragraph. A `tefPAST_SEQ` transaction never reaches a ledger, and every path that advances the sequence needs one that did — settlement needs a settled payment, `confirmFailedExecution` needs a `Payment` proof, and `confirmNonExecution` deliberately does not advance. So the first payment fails and nothing can ever move past it.

The fix is `TreasuryRegistry.setInitialSequence`, and it has to be a separate step rather than a better default: at KEYGEN the account has no sequence because it does not exist, since XRPL creates it on first funding. The order is generate, bind, fund, record. `nextSequence` zero now means "not yet known" and both `propose` and `dispatch` refuse while it holds — `propose` too, so a request that can never be signed does not collect approvals first. The value stays correctable until XRPL consumes one, because otherwise a mistyped sequence would wedge the treasury exactly as the original bug did.

`firstLedgerSequence` (P4-10) is the other thing the plan did not anticipate. A non-existence proof is only as strong as the range it searched, and the range is chosen by whoever requests the attestation. Without a lower bound recorded at dispatch, a one-ledger proof would satisfy the deadline check while saying nothing about the ledgers where the payment actually landed — releasing a window spend for money that had already moved.

The submitter is a liveness helper, not a trust assumption. Anyone can run one. Its only on-chain authority is submitting proofs, and a proof that does not verify is rejected by the contract.

---

## Phase 5 — Interface and hardening

**Goal:** someone who has never seen the codebase completes the full lifecycle using only the README.

**Depends on:** 4.

### Tasks

- [x] **P5-1 — Treasury overview.** `web/src/app/treasuries/[treasuryId]/page.tsx`. XRPL address and live balance from XRPL Testnet, the registry's next sequence beside the ledger's own, active policy summary, payments in flight with tier and unlock countdown, and the audit log for that treasury.
- [x] **P5-2 — Policy authoring.** `web/src/app/policies/new/page.tsx`. Tier editor, rolling window, allowlist enforcement, amendment parameters — every rule `createPolicy` would revert on is rejected in the form first, in the words the rule uses. Roles and the allowlist are edited on the policy page, because they are membership rather than rules.
- [x] **P5-3 — Proposal creation with live validation.** `web/src/app/treasuries/[treasuryId]/propose/page.tsx`. Each rule is its own line, evaluated against live chain state — role, freeze, address checksum, allowlist, FTSO freshness, tier, window — and the last line is an `eth_call` simulation of `propose` itself, so the contract has the final word before the wallet is ever asked.
- [x] **P5-4 — Approval screen.** `web/src/app/requests/[requestId]/page.tsx`. Destination, tag (stated as "none", not as a zero), amount in drops **and** XRP **and** USD at proposal **and** USD live, resolved tier, approvals collected and required, unlock time, and the policy digest with the sequence, ledger range and fee it covers.
- [x] **P5-5 — Countdown timers and window gauge.** `Countdown.tsx` and `WindowGauge.tsx`. The gauge shows committed spend and the proposed payment as separate segments, which is the difference between "there is room" and "there is room for this".
- [x] **P5-6 — Guardian freeze.** `FreezeControl.tsx`, one click behind one confirmation, plus the amendment panel for the unfreeze path — the asymmetry between the two is the point, and both are on the same page.
- [x] **P5-7 — Error surfacing.** `web/src/lib/errors.ts` maps every custom error in all five contracts to a plain-language explanation naming the rule. `web/test/errors.test.ts` proves the coverage mechanically against the generated ABIs, so an error added to a contract without an explanation fails the build rather than reaching a user as a bare selector.
- [x] **P5-8 — Audit log links.** `AuditLogView.tsx` over `web/src/lib/logs.ts`. Every entry links to its Coston2 transaction, and a signature links to its XRPL transaction. The signer and verifier addresses are discovered from the contracts rather than configured, so their events join the scan as soon as they are wired.
- [x] **P5-9 — README.** `README.md` — from zero to a settled payment. The indexer credential request is *not* step one: `./scripts/indexer.sh up` runs our own, and P0-1 recorded why.
- [x] **P5-10 — Hygiene sweep.** Clean, with one thing worth knowing: the sweep's `placeholder` term also matches the HTML `placeholder=` attribute and Tailwind's `placeholder:` variant, which are input hints rather than unfilled values. Use `grep -rn "TODO\|FIXME\|XXX\|mock" --include="*.sol" --include="*.go" --include="*.ts" --include="*.tsx" contracts/ go/ submitter/src/ web/src/` and read any `placeholder` hits rather than counting them. The three remaining `TODO`s are in scaffold interface files that `CLAUDE.md` marks do-not-modify, waiting on `flare-smart-contracts-v2` being published as a package.
- [ ] **P5-11 — Demo video.** 90 seconds: a policy-compliant payment settling, and a policy-violating payment being refused with the rule named. Needs a funded deployer first (P0-2).
- [ ] **P5-12 — Demo rehearsal.** Run the full path end-to-end at least twice. Needs a funded deployer first (P0-2). If FTSO is stale during a live demo, that is the fail-closed design working — say so; a fallback price would be a weaker answer.

### Verification

```bash
cd web && npm run typecheck && npm test && npm run build
forge test && (cd go && go test ./...) && (cd submitter && npm test)
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

`./scripts/check.sh` runs every one that can be checked mechanically, under a single exit code, with no chain, tunnel, credentials or faucet required. Run it before pushing. The boxes below are its sections plus the rules that need a human reading a diff.

- [x] `forge test` and `go test ./...` both pass. 152 contract tests, Go suites green, conformance 16/16.
- [x] No mocks, stubs or simulated components outside `test/`. `check.sh` asserts no shipped file imports `test/helpers`.
- [x] No `TODO`, `FIXME`, `XXX`, placeholder address, `example.com` URL, or function returning a constant "for now". The three remaining `TODO`s are in scaffold interface files `CLAUDE.md` marks do-not-modify, and the sweep excludes them by path rather than by suppressing the pattern.
- [x] No silent fallbacks. Stale price reverts, digest mismatch returns status `0`, unknown treasury errors. Every failure path is a refusal to spend money, which is the correct outcome.
- [x] No key material logged, returned or persisted. `check.sh` asserts no private key type is reachable from `pkg/types`, because that is an invariant rather than a test and drift in it would be silent.
- [x] No check weakened to make a test pass. The one place this was tempting was the `0x0000…0000` literal the hygiene sweep flagged in `chain-data.ts`: it was a genuine sentinel rather than an unfilled value, and the fix was to use viem's `zeroAddress` so the literal disappears — not to add an exemption.
- [x] `SignRequest` changes touch Solidity, Go and the decoder registration in one commit.
- [x] `opType` / `opCommand` changes touch all three locations. `check.sh` asserts the three-way alignment directly.
- [x] ABI changes are followed by `./scripts/generate-bindings.sh`. The submitter additionally checks its ABI declarations against `out/` at test time, so a field reordered in Solidity fails `test/abi.test.ts` rather than surfacing later as a proof that will not verify.
- [x] Extension behaviour changes bump `Version` in `internal/config/config.go`.
- [x] **No dependency advisory of any severity, in either Node package.** `npm audit` reports zero in `submitter/` and zero in `web/`, from a clean `npm ci` as well as from the working tree. The last eight were all in the MetaMask SDK connector chain and needed the wagmi 2 → 3 migration, which is now done: it removed 425 packages, and the app's only code change was importing `injected` from `wagmi/connectors/injected` instead of working around the old barrel through `@wagmi/core`. The `axios` override went with them, because the package it pinned is no longer in the tree at all.
- [x] This file and `PLAN.md` reflect reality — checked off what is done, corrected what turned out wrong.

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
