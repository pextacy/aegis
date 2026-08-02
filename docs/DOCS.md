# Aegis — Technical Documentation

**Aegis** is a rule-governed XRPL treasury. Spending policy is defined in Solidity contracts on Flare. The XRPL private key exists only inside a Flare Confidential Compute (FCC) Trusted Execution Environment. No human, including the treasury owner, can produce a valid XRPL payment unless the on-chain policy contract authorised it first.

This document is the engineering reference: architecture, contract surface, the TEE instruction protocol, XRPL serialisation rules, and the deployment runbook.

---

## 1. Problem statement in one paragraph

XRPL has native multisig (`SignerList`) but no way to express *conditional* authority. You cannot say "payments under $5,000 to whitelisted vendors need one approver, anything above needs three approvers and a 24-hour delay, and nothing goes out at all if the monthly budget is exhausted." Today that logic lives in a custodian's backend or in a spreadsheet next to a hardware wallet. Aegis moves that logic into Flare smart contracts and makes the signing key physically incapable of ignoring it.

---

## 2. System architecture

```
                        ┌─────────────────────────────────────────┐
                        │            Flare (Coston2)              │
                        │                                         │
  Proposer ────────────►│  TreasuryRegistry ── PolicyEngine       │
  Approvers ───────────►│         │              │                │
                        │         │              ├── FtsoV2       │
                        │         ▼              │   (XRP/USD)    │
                        │  PaymentController ────┘                │
                        │         │                               │
                        │         │ sendInstructions()            │
                        │         ▼                               │
                        │  AegisInstructionSender                 │
                        │         │                               │
                        │  TeeExtensionRegistry (system contract) │
                        │  TeeMachineRegistry   (system contract) │
                        └─────────┬───────────────────────────────┘
                                  │ instruction event
                                  ▼
                     Data providers relay + sign (≥50% weight)
                                  │
                        ┌─────────▼──────────┐
                        │     ext-proxy      │  public HTTPS, port 6674
                        │  (queue + results) │
                        └─────────┬──────────┘
                                  │ POST /action
                        ┌─────────▼──────────┐
                        │   aegis-fce (TEE)  │  Confidential VM
                        │  • key generation  │
                        │  • field re-check  │
                        │  • XRPL signing    │
                        └─────────┬──────────┘
                                  │ signed tx blob (via proxy results)
                                  ▼
                        ┌────────────────────┐
                        │  submitter service │ ──► XRPL Testnet
                        └─────────┬──────────┘
                                  │ FDC Payment attestation request
                                  ▼
                        ExecutionVerifier.confirmSettlement(proof)
```

Five components. Each is a real deliverable:

| Component | Language | Runs where | Purpose |
|---|---|---|---|
| `contracts/` | Solidity 0.8.27 | Coston2 | Policy definition, approval accounting, instruction dispatch, settlement verification |
| `aegis-fce/` | Go | Confidential VM (simulated locally) | Key custody, independent policy digest re-check, XRPL serialisation and signing |
| `submitter/` | TypeScript | Operator host | Polls proxy for signed blobs, submits to XRPL, requests FDC attestation, closes the loop on-chain |
| `web/` | Next.js + wagmi | Browser | Treasury creation, policy authoring, proposal and approval UI, audit log |
| `tools/` | Go | Operator host | Deploy, register extension, register TEE machine, end-to-end test (inherited from scaffold, extended) |

### 2.1 Why the TEE re-validates

The relay path (data providers → proxy → TEE) is not trusted to preserve payload integrity beyond signature threshold. Aegis therefore never sends a pre-serialised XRPL blob to the TEE. It sends **structured fields** plus a `policyDigest` that `PaymentController` computed on-chain. The TEE recomputes `keccak256` over the fields it received and refuses to sign unless it matches `policyDigest`. A relayer that swaps the destination address produces a digest mismatch and the instruction fails with status `0`.

This is the single most important security property in the system and the thing that distinguishes Aegis from "an oracle that signs whatever it is told."

---

## 3. On-chain contracts

All contracts target Solidity `^0.8.27` and compile with Foundry.

### 3.1 `TreasuryRegistry.sol`

Owns the treasury lifecycle and the mapping between a Flare-side treasury and an XRPL account.

```solidity
struct Treasury {
    uint256 id;
    bytes32 xrplAccountId;      // 20-byte XRPL AccountID, left-aligned in bytes32
    string  xrplAddress;        // base58check classic address, r...
    uint256 policyId;
    address policyAdmin;
    bool    frozen;
    uint32  nextSequence;       // mirror of XRPL account sequence
}
```

Functions:

- `createTreasury(uint256 policyId) returns (uint256 treasuryId)` — reserves an id, emits `TreasuryCreated`. The XRPL account does not exist yet.
- `bindXrplAccount(uint256 treasuryId, bytes calldata compressedPubKey, string calldata classicAddress)` — callable only by `AegisInstructionSender` after a successful `KEYGEN` result. Derives the AccountID from the public key on-chain (RIPEMD-160 of SHA-256 of the 33-byte compressed key) and requires it to match the supplied classic address decoding. Rejects any second binding.
- `setFrozen(uint256 treasuryId, bool value)` — guardian-only emergency stop. A frozen treasury rejects all `propose` and `dispatch` calls.
- `advanceSequence(uint256 treasuryId, uint32 confirmedSequence)` — called by `ExecutionVerifier` on confirmed settlement or confirmed non-execution.

RIPEMD-160 is available as precompile `0x03` and SHA-256 as `0x02`, so AccountID derivation is done on-chain without a library.

### 3.2 `PolicyEngine.sol`

Stores immutable policy versions. A policy is never mutated in place; amending creates a new `policyId` and the treasury must be repointed, which itself is a governed action.

```solidity
struct Tier {
    uint128 maxAmountUsd;       // 18-decimal USD ceiling for this tier
    uint8   requiredApprovals;
    uint32  timelockSeconds;
}

struct Policy {
    uint256 id;
    Tier[]  tiers;              // ascending by maxAmountUsd; last tier is the hard cap
    uint128 rollingWindowUsd;   // spend ceiling within windowSeconds
    uint32  windowSeconds;
    bool    allowlistEnforced;
    uint8   amendApprovals;     // approvals required to move a treasury to a new policy
    uint32  amendTimelock;
}
```

- `createPolicy(Tier[] calldata tiers, uint128 rollingWindowUsd, uint32 windowSeconds, bool allowlistEnforced, uint8 amendApprovals, uint32 amendTimelock) returns (uint256)`
- `setAllowlist(uint256 policyId, bytes32 xrplAccountId, uint32 destinationTag, bool allowed)` — a destination is the pair (AccountID, destination tag). Tag `0` means "any tag permitted for this account".
- `resolveTier(uint256 policyId, uint256 amountUsd) view returns (Tier memory)` — returns the lowest tier whose ceiling covers `amountUsd`, reverts `AmountExceedsPolicyCap` if none does.
- `isDestinationAllowed(uint256 policyId, bytes32 accountId, uint32 tag) view returns (bool)`

Roles are held in `PolicyEngine` as bitmask assignments per policy: `ROLE_PROPOSER = 1`, `ROLE_APPROVER = 2`, `ROLE_GUARDIAN = 4`, `ROLE_POLICY_ADMIN = 8`. An address may hold several. Approval counting rejects duplicate approvals from one address and rejects an approval from the proposer of that same request.

### 3.3 `PaymentController.sol`

The state machine. One `PaymentRequest` per proposed XRPL payment.

```solidity
enum RequestState {
    Proposed,      // 0
    Approved,      // 1  threshold met, timelock running
    Dispatched,    // 2  instruction sent to TEE
    Signed,        // 3  TEE returned a signature, blob is public
    Settled,       // 4  FDC proved the payment landed on XRPL
    Failed,        // 5  FDC proved non-execution, or TEE rejected
    Cancelled      // 6  withdrawn before dispatch
}

struct PaymentRequest {
    uint256 treasuryId;
    bytes32 destinationAccountId;
    uint32  destinationTag;
    uint64  amountDrops;
    uint256 amountUsdAtProposal;
    uint32  sequence;
    uint32  lastLedgerSequence;
    uint64  feeDrops;
    uint8   approvals;
    uint64  eligibleAt;
    RequestState state;
    bytes32 policyDigest;
}
```

Key functions:

- `propose(uint256 treasuryId, bytes32 destAccountId, uint32 destTag, uint64 amountDrops)` — reads XRP/USD from FTSO, converts drops to an 18-decimal USD figure, checks allowlist, resolves the tier, checks the rolling window, stores the request with `eligibleAt = block.timestamp + tier.timelockSeconds`. Reverts early on any policy violation so users never approve a request that cannot execute.
- `approve(uint256 requestId)` — increments approvals; transitions to `Approved` when `approvals >= tier.requiredApprovals`.
- `dispatch(uint256 requestId, uint32 lastLedgerSequence, uint64 feeDrops) payable` — requires `Approved`, `block.timestamp >= eligibleAt`, treasury not frozen. Re-runs the full policy check (the FTSO price has moved since proposal; the rolling window may have been consumed by another request). Computes `policyDigest`, calls `AegisInstructionSender.requestSignature(...)`, forwards `msg.value` as the TEE instruction fee, moves to `Dispatched`.
- `recordSignature(uint256 requestId, bytes calldata signedBlob, bytes32 txHash)` — restricted to `AegisInstructionSender`. Moves to `Signed` and emits `PaymentSigned` which the submitter service watches.
- `markFailed(uint256 requestId, bytes32 reason)` — restricted to `ExecutionVerifier`.

The rolling window is accounted with a ring buffer of `(timestamp, amountUsd)` entries per treasury, pruned lazily on each `propose` and `dispatch`. Spend is committed at `dispatch`, not at `propose`, and released if the request ends `Failed`.

### 3.4 `AegisInstructionSender.sol`

The FCC entry point. Structurally identical to the scaffold's `InstructionSender.sol`, with Aegis operation codes.

```solidity
bytes32 public constant OP_TYPE_XRPL     = bytes32("XRPLW");
bytes32 public constant OP_COMMAND_KEYGEN = bytes32("KEYGEN");
bytes32 public constant OP_COMMAND_SIGNTX = bytes32("SIGNTX");
bytes32 public constant OP_COMMAND_STATUS = bytes32("STATUS");
```

`setExtensionId()` and the constructor are copied verbatim from the scaffold and must not be modified — the registry discovery loop starts at `FIRST_PUBLIC_EXTENSION_ID = 0x10000` because ids below that are reserved for system extensions such as PMW and the TEE-based FDC.

Instructions are built with the system struct:

```solidity
ITeeExtensionRegistry.TeeInstructionParams({
    opType: OP_TYPE_XRPL,
    opCommand: OP_COMMAND_SIGNTX,
    message: abi.encode(signRequest),
    cosigners: cosigners,
    cosignersThreshold: threshold,
    claimBackAddress: msg.sender
});
```

TEE machine selection uses `TEE_MACHINE_REGISTRY.getRandomTeeIds(_getExtensionId(), 1)` for v1. The `cosigners` array carries the guardian addresses and `cosignersThreshold` carries the tier's required approval count, so the FCC layer independently enforces a second authorisation gate on payment operations on top of Aegis' own accounting.

### 3.5 `ExecutionVerifier.sol`

Consumes FDC attestations to close the loop.

- `confirmSettlement(uint256 requestId, IPayment.Proof calldata proof)` — calls `ContractRegistry.getFdcVerification().verifyPayment(proof)`, then asserts that the attested source address equals the treasury AccountID, the receiving address equals `destinationAccountId`, `spentAmount` equals `amountDrops + feeDrops`, and the standard payment reference matches `keccak256(abi.encode(requestId))` as carried in the XRPL memo. On success: state → `Settled`, `TreasuryRegistry.advanceSequence`.
- `confirmNonExecution(uint256 requestId, IReferencedPaymentNonexistence.Proof calldata proof)` — proves the payment did not appear before `lastLedgerSequence`. State → `Failed`, rolling-window spend released, sequence advanced so the treasury is not wedged.

These two paths are why the TEE never needs to know whether a transaction landed. On-chain state is reconciled from proofs, not from the submitter's word.

### 3.6 FTSO integration

`PaymentController` reads XRP/USD through FtsoV2. The feed id is derived, not hardcoded:

```solidity
bytes21 constant XRP_USD_FEED = bytes21(abi.encodePacked(uint8(1), bytes7("XRP/USD"), bytes13(0)));
```

Category byte `1` is the crypto category. Read with:

```solidity
(uint256 value, int8 decimals, uint64 ts) = ContractRegistry.getFtsoV2().getFeedById(XRP_USD_FEED);
require(block.timestamp - ts <= MAX_PRICE_AGE, "stale price");
```

`MAX_PRICE_AGE` is 180 seconds. A stale feed blocks `dispatch` rather than falling back to a cached price — refusing to spend is the correct failure mode for a treasury.

USD conversion:

```
amountUsd18 = amountDrops * value * 10^(12 - decimals)
```

`10^12` converts drops (1e-6 XRP) to an 18-decimal fixed point, then the feed's own decimals are normalised out.

---

## 4. TEE extension protocol

The extension is Go, built from `flare-foundation/fce-extension-scaffold`. It exposes exactly the two HTTP endpoints the framework requires: `GET /state` and `POST /action`.

### 4.1 Operation table

| opType | opCommand | Message encoding | Returns |
|---|---|---|---|
| `XRPLW` | `KEYGEN` | ABI `(uint256 treasuryId)` | ABI `(bytes33 compressedPubKey, string classicAddress)` |
| `XRPLW` | `SIGNTX` | ABI `SignRequest` (below) | ABI `(bytes signedBlob, bytes32 txHash)` |
| `XRPLW` | `STATUS` | ABI `(uint256 treasuryId)` | ABI `(bool hasKey, uint32 lastSignedSequence)` |

Constants must be byte-identical in three places or the extension answers `unsupported op type`:

```solidity
bytes32 public constant OP_TYPE_XRPL = bytes32("XRPLW");
```
```go
const OPTypeXRPL = "XRPLW"   // internal/config/config.go
```
```go
case dataFixed.OPType == teeutils.ToHash(config.OPTypeXRPL):   // internal/extension/extension.go
```

### 4.2 `SignRequest` payload

```solidity
struct SignRequest {
    uint256 requestId;
    uint256 treasuryId;
    bytes32 destinationAccountId;
    uint32  destinationTag;
    uint64  amountDrops;
    uint32  sequence;
    uint32  lastLedgerSequence;
    uint64  feeDrops;
    bytes32 policyDigest;
}
```

`policyDigest` is computed by `PaymentController` as:

```solidity
keccak256(abi.encode(
    requestId, treasuryId, destinationAccountId, destinationTag,
    amountDrops, sequence, lastLedgerSequence, feeDrops
));
```

The extension recomputes the same digest over the fields it decoded and compares. Mismatch returns status `0` with the log line `policy digest mismatch`. Nothing is signed.

### 4.3 Key generation and custody

`KEYGEN` generates a secp256k1 key with `crypto/rand` inside the enclave. The private key is held in process memory in a `sync.RWMutex`-guarded map keyed by `treasuryId`, and is never written to disk, never logged, and never returned from any endpoint. `GET /state` reports only `hasKey` booleans and the last sequence signed per treasury.

The classic address is derived as:

1. `sha256(compressedPubKey33)` → 32 bytes
2. `ripemd160(...)` → 20-byte AccountID
3. prefix `0x00`, append first 4 bytes of `sha256(sha256(0x00 || accountId))`
4. base58 encode with the XRPL alphabet `rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz`

The scaffold's `sign-extension` example ships a `/decrypt` endpoint on `SIGN_PORT` (default 7701) for importing an externally generated key via ECIES. Aegis does not use import in v1 — keys are born in the enclave, which is strictly stronger. The import path is documented in `PLAN.md` as a phase 5 item for migrating existing treasuries, and when it is built the encrypted key travels over an off-chain channel to the proxy, not through calldata.

### 4.4 XRPL serialisation and signing

Signing is implemented directly rather than by embedding an XRPL library, because the enclave image must stay small and reproducible.

Transaction fields for a `Payment`, in canonical field order:

| Field | Type code | Field code | Value |
|---|---|---|---|
| `TransactionType` | UInt16 (1) | 2 | `0` (Payment) |
| `Flags` | UInt32 (2) | 2 | `0x80000000` (tfFullyCanonicalSig) |
| `Sequence` | UInt32 (2) | 4 | from request |
| `DestinationTag` | UInt32 (2) | 14 | omitted when `0` |
| `LastLedgerSequence` | UInt32 (2) | 27 | from request |
| `Amount` | Amount (6) | 1 | drops, XRP encoding, high bit set |
| `Fee` | Amount (6) | 8 | drops |
| `SigningPubKey` | Blob (7) | 3 | 33-byte compressed key |
| `TxnSignature` | Blob (7) | 4 | filled after signing |
| `Account` | AccountID (8) | 1 | treasury AccountID |
| `Destination` | AccountID (8) | 3 | request destination |
| `Memos` | STArray (15) | 9 | one memo carrying `requestId` |

Signing procedure:

1. Serialise all fields except `TxnSignature`, sorted by `(typeCode, fieldCode)`.
2. Prepend the single-sign hash prefix `0x53545800` (`STX\0`).
3. `sha512(...)`, take the first 32 bytes (SHA-512Half).
4. ECDSA-sign with the treasury key, produce a DER-encoded signature with a low-S value.
5. Re-serialise including `TxnSignature`, hex-uppercase the result — that is the blob for `submit`.
6. The transaction hash is SHA-512Half of prefix `0x54584E00` (`TXN\0`) over the complete signed blob.

The `Memos` array carries `MemoData` = the 32-byte `keccak256(abi.encode(requestId))`, which is what `ExecutionVerifier` matches against the FDC payment reference. This is what makes an on-chain request and an XRPL transaction provably the same event.

Deterministic nonce generation follows RFC 6979 so that two TEE machines signing the same request produce the same signature, which matters for the k-of-n roadmap.

### 4.5 Result status codes

The framework defines three:

- `0` — error, message in `Log`. Aegis uses this for digest mismatch, unknown treasury, missing key, malformed payload.
- `1` — success, ABI-encoded data returned.
- `>= 2` — pending. Aegis does not use pending in v1; every operation completes within the handler.

---

## 5. Submitter service

A small TypeScript daemon. Real network calls, no simulation.

1. Subscribes to `PaymentSigned(uint256 requestId, bytes signedBlob, bytes32 txHash)` on Coston2 via a websocket provider.
2. Submits the blob to XRPL Testnet (`wss://s.altnet.rippletest.net:51233`) with `submit` and waits for validation by polling `tx` until `validated: true` or `LastLedgerSequence` is passed.
3. On validation, requests a `Payment` attestation from the Coston2 FDC verifier server with `sourceId = testXRP` and the transaction hash, waits for the round to finalise, retrieves the Merkle proof from the DA layer, and calls `ExecutionVerifier.confirmSettlement(requestId, proof)`.
4. If the ledger passes `LastLedgerSequence` with no validated transaction, it requests a `ReferencedPaymentNonexistence` attestation instead and calls `confirmNonExecution`.

The submitter holds no keys that can move funds. Its only on-chain authority is submitting proofs, and a proof that does not verify is rejected by the contract. Anyone can run one; it is a liveness helper, not a trust assumption.

---

## 6. Deployment runbook — Coston2

### 6.1 Prerequisites

- Docker Desktop
- Foundry
- Go 1.22+
- Node 20+
- ngrok or cloudflared
- A Coston2 wallet funded from `https://faucet.flare.network/coston2`
- Coston2 indexer database credentials — request via `https://flare.network/resources/technical-support` or `@FlareDevs`, stating what you are building. The proxy cannot start without them. Request these on day one; everything else is blocked behind them.

### 6.2 Environment

`.env` values that matter:

```bash
DEPLOYMENT_PRIVATE_KEY="<funded coston2 key, hex, no 0x>"
INITIAL_OWNER="0x<your address>"
PROXY_PRIVATE_KEY="<funded key>"
CHAIN_URL=https://coston2-api.flare.network/ext/C/rpc
ADDRESSES_FILE=./config/coston2/deployed-addresses.json
LOCAL_MODE=false
SIMULATED_TEE=true
NORMAL_PROXY_URL=https://tee-proxy-coston2-1.flare.rocks
EXT_PROXY_URL=https://<your tunnel domain>
```

`LOCAL_MODE=false` keeps the attestation path enabled against the live chain. `SIMULATED_TEE=true` lets you develop without Confidential VM hardware; it pairs with `MODE=1` injected by Docker Compose, and the two must agree or registration fails with `code hashes do not match`.

Coston2 network facts: chain id `114`, RPC `https://coston2-api.flare.network/ext/C/rpc`, explorer `https://coston2-explorer.flare.network`.

Indexer block, filled with the credentials you were issued:

```toml
[db]
host = "34.38.42.208"
port = 3306
database = "indexer"
username = "<issued>"
password = "<issued>"
log_queries = false
```

### 6.3 Sequence

```bash
ngrok http 6674                              # separate terminal, before anything else
./scripts/pre-build.sh                       # compile, deploy, register extension
./scripts/start-services.sh --chain coston2  # redis + ext-proxy + extension-tee
./scripts/post-build.sh                      # allow code version, set governance, register TEE machine
./scripts/test.sh                            # end-to-end
```

`pre-build.sh` writes `EXTENSION_ID` and `INSTRUCTION_SENDER` into `config/extension.env` and then refuses to run again. Do not use `--force` casually: it deploys a new sender and registers a new extension id while your TEE machine stays bound to the old one, and the end-to-end test then fails with `MachineManager.TooMany()`.

`post-build.sh` runs `register-tee -command rRap`. The capital `R` issues a fresh attestation challenge, which is what prevents `Verification.ChallengeExpired` on re-runs.

### 6.4 Port reference

| Service | Container | Host |
|---|---|---|
| ext-proxy internal | 6663 | 6673 |
| ext-proxy external | 6664 | 6674 |
| redis | 6379 | 6382 |
| extension HTTP | 8080 | — |
| sign port | 7701 | — |

Only the external proxy port 6674 is tunnelled. Exposing it makes the proxy HTTP API reachable by anyone holding the URL, so the tunnel runs against Coston2 only and is stopped when you finish.

### 6.5 Verification checks

```bash
curl -s "$EXT_PROXY_URL/info" | jq '.machineData'
```

For a simulated TEE expect `codeHash` starting `0x194844cf`, `extensionId` matching `config/extension.env`, and `initialOwner` matching your address.

---

## 7. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `unsupported op type` / `unsupported op command` | `bytes32("...")` in Solidity does not match the Go constant | Align the three locations in §4.1 exactly |
| Proxy never becomes ready | Tunnel not on 6674, or indexer `[db]` credentials wrong | `docker compose logs ext-proxy` |
| `MachineManager.TooMany()` | Extension id in `config/extension.env` differs from the registered TEE | Full reset, or re-run only `post-build.sh` and `test.sh` |
| `InvalidGovernanceHash` | `GOVERNANCE_SIGNERS` / `GOVERNANCE_THRESHOLD` differ between `.env` and the container | Rebuild and restart after changing them |
| `Verification.ChallengeExpired` | Stale attestation challenge | Re-run `post-build.sh` |
| `code hashes do not match` | `SIMULATED_TEE` and container `MODE` disagree | `SIMULATED_TEE=true` with `MODE=1` |
| TEE registration times out | Proxy missed a signing policy round | `docker compose restart ext-proxy` |
| `policy digest mismatch` from the extension | Field tampering in relay, or an encoder change on one side only | Compare the ABI struct definition in Solidity and Go; this error is working as designed |
| `stale price` on dispatch | FTSO feed older than 180s | Wait for the next voting round; do not lower the threshold |

---

## 8. Security model

**Trusted:** the TEE hardware attestation, the Flare signing policy (≥50% data provider weight to relay an instruction), the Solidity policy contracts.

**Untrusted:** the proxy operator, the submitter service, the host running the confidential VM, any individual approver, the frontend.

Properties that hold:

- No party can extract the XRPL private key. It is generated in the enclave and never leaves.
- No party can cause a payment that the policy contract did not authorise, because the TEE independently verifies the policy digest.
- No party can replay a signed transaction, because XRPL sequence numbers are consumed and the contract tracks them.
- No party can hide a payment, because every signature is emitted on-chain and every settlement is proven by FDC.
- A compromised submitter can delay settlement but cannot redirect funds or forge a proof.

Known limitations in v1, stated plainly rather than hidden:

- A single TEE machine holds the key, so machine loss means treasury loss. The k-of-n `SignerList` design that removes this is specified in `PLAN.md` phase 5 and is exactly what the PMW system application provides natively once it is public.
- `SIMULATED_TEE=true` during development means attestation is simulated. Production requires a GCP Confidential Space VM; the deployment path for that is in the scaffold's `DEPLOYMENT_STEPS.md`.
- Policy amendment moves a treasury to a new `policyId`; it does not migrate historical spend accounting, which resets the rolling window. This is documented behaviour, and the amendment path carries its own timelock for that reason.

---

## 9. Relationship to Protocol Managed Wallets

FCC ships PMW as a system application: it assembles and signs transactions on XRPL and BTC through smart contract calls, manages nonces, supports reissuance and nullification, and represents wallets as k-of-n multisig across TEE machines. PMW answers *how do I sign on another chain*.

Aegis answers a different question: *under what conditions should that signature ever be produced*. It is a policy layer, and it is built as a Flare Compute Extension because the FCE framework is the public developer surface today while PMW's reserved system extension ids sit below `0x10000`.

The migration is a swap of one module, not a rewrite. `AegisInstructionSender.requestSignature` is the only place that touches signing. When the PMW interface is public, that function calls PMW instead of the custom extension, and Aegis inherits native multisig, nonce chaining, and reissuance while every contract in §3.1 to §3.3 stays unchanged. That boundary is deliberate and is the reason `SignRequest` carries structured fields rather than a serialised blob.
