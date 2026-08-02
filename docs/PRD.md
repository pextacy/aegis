# Aegis — Product Requirements

**Product:** Aegis — rule-governed XRPL treasury built on Flare Confidential Compute
**Bounties:** Interoperable Asset Products and Confidential Compute Apps (both)
**Target networks:** Coston2 (development and demo), XRPL Testnet (settlement)

---

## 1. The problem

An organisation holding XRP has two options today.

**Custodian.** Someone else holds the key. Spending rules are enforced by that company's internal software. You get an audit trail they produce, and you trust it. Counterparty risk is total.

**Self-custody with XRPL multisig.** You hold the keys. XRPL's `SignerList` gives you k-of-n, and that is the entire vocabulary available. There is no concept of an amount threshold, a spending window, a destination allowlist, a waiting period, or a role. A treasurer authorised to pay a $200 hosting bill holds exactly the same authority as one moving $2 million.

Every organisation bridges that gap with process: a spreadsheet of approved vendors, a Slack thread for approvals, a rule that large payments need a second person. None of it is enforced by anything. It is enforced by people remembering.

Aegis makes those rules executable. Policy is a Solidity contract on Flare. The XRPL signing key lives inside a TEE that will not produce a signature unless that contract authorised the exact payment. The rule is not a norm anymore — it is a physical constraint on the key.

---

## 2. Target users

### Primary — DAO treasury operators
5 to 15 signers, monthly outflows in the tens to hundreds of thousands of dollars. They already run Safe on EVM chains and are frustrated that XRP holdings sit outside that discipline. They need the same guarantees for XRP without giving it to a custodian.

**Buying trigger:** they hold XRP and their existing governance stops at the XRPL boundary.

### Primary — Crypto-native funds and corporate XRP holders
Hold XRP as treasury. Need segregation of duties for an auditor, spending caps for a risk committee, and an audit trail neither the finance team nor the engineering team can quietly edit.

**Buying trigger:** an audit or a board asking "what stops one person from moving all of it."

### Secondary — Protocols with XRPL-side operations
Any Flare protocol that needs to pay out on XRPL — FAssets agents handling redemptions, liquidity managers, payout systems. They need programmatic XRPL payments bounded by rules, with no human key holder anywhere in the loop.

**Buying trigger:** they are currently running a hot wallet in a container and know it.

### Non-users
Individual XRP holders. Aegis is overhead without a second person to constrain. The product does not target them and the UI does not pretend to.

---

## 3. User stories

**As a policy admin**, I define a policy with amount tiers, so that a $500 payment does not require the same ceremony as a $500,000 payment.

**As a policy admin**, I set a rolling 30-day spending ceiling, so that a compromised approver set cannot drain the treasury in a single session even if every individual payment looks legitimate.

**As a proposer**, I propose a payment and am told immediately if it violates policy, so that I do not waste approvers' time on a request that can never execute.

**As an approver**, I see the exact XRPL destination, amount in XRP and USD, tier, required approvals, and unlock time before I approve, so that I am approving a fact rather than a description.

**As an approver**, I cannot approve my own proposal, so that segregation of duties is enforced rather than requested.

**As a guardian**, I can freeze the treasury immediately without any other signature, so that a suspected compromise stops before the next block.

**As an auditor**, I can reconstruct every payment from chain data alone — who proposed, who approved, what policy applied, which XRPL transaction settled — without asking the organisation for records.

**As a treasury operator**, I know that even if my own frontend is compromised, no payment can be produced that the on-chain policy did not authorise.

**As a treasury operator**, I know that even the Aegis operator cannot sign a payment, because there is no key outside the enclave.

---

## 4. Functional requirements

### Treasury lifecycle

**FR-1** The system creates a treasury bound to a policy id, then generates an XRPL account whose key material exists only inside a TEE. The account is bound on-chain by deriving the AccountID from the returned public key and rejecting any mismatch with the reported classic address.

**FR-2** A treasury accepts exactly one XRPL account binding for its lifetime. A second binding attempt reverts.

**FR-3** A guardian can freeze a treasury in one transaction. A frozen treasury rejects new proposals and dispatches. Unfreezing requires the policy's amendment threshold.

### Policy

**FR-4** A policy defines an ordered set of tiers. Each tier carries a USD ceiling, a required approval count, and a timelock in seconds. The highest tier's ceiling is the treasury's hard per-payment cap; a payment above it cannot be proposed at all.

**FR-5** A policy defines a rolling window ceiling in USD and a window length in seconds. Committed spend inside the window is tracked on-chain and released if a payment is proven not to have executed.

**FR-6** A policy optionally enforces a destination allowlist. A destination is the pair (XRPL AccountID, destination tag), where tag `0` means any tag is acceptable for that account.

**FR-7** Policies are immutable once created. Changing rules means creating a new policy and repointing the treasury, which itself requires the current policy's amendment approval count and amendment timelock.

**FR-8** Roles are PROPOSER, APPROVER, GUARDIAN, POLICY_ADMIN. One address may hold several. Role assignment is per-policy.

### Payment flow

**FR-9** Proposing a payment converts the drops amount to USD using the FTSO XRP/USD feed, resolves the applicable tier, checks the allowlist, checks the rolling window, and reverts with a specific error on the first violation.

**FR-10** An approval from the request's proposer is rejected. A duplicate approval from the same address is rejected.

**FR-11** A request becomes dispatchable only when the approval threshold is met and the tier's timelock has elapsed.

**FR-12** Dispatch re-evaluates the full policy against current state, because the price and the window may have moved since proposal. A request that passed at proposal and fails at dispatch is rejected, not grandfathered.

**FR-13** Dispatch refuses to proceed if the FTSO price is older than 180 seconds.

**FR-14** The TEE independently verifies that the fields it received hash to the policy digest computed on-chain, and refuses to sign on mismatch.

**FR-15** The signed transaction blob and its hash are recorded on-chain and emitted, so signing is a public event.

### Settlement

**FR-16** Settlement is confirmed by an FDC `Payment` attestation proving the XRPL transaction occurred, with the source, destination, amount, and a reference matching the on-chain request id.

**FR-17** Non-execution is confirmed by an FDC `ReferencedPaymentNonexistence` attestation, which releases the committed window spend and advances the sequence so the treasury is not wedged behind a dead transaction.

**FR-18** No state transition to Settled or Failed is possible without a verifying proof. The submitter service's assertions carry no authority.

### Interface

**FR-19** The dashboard shows treasury balance, active policy summary, pending requests with their tier and unlock countdown, and a complete audit log.

**FR-20** The approval screen shows destination address, destination tag, amount in drops and XRP and USD, resolved tier, approvals collected and required, unlock time, and the policy digest. An approver sees the same facts the contract will check.

**FR-21** Every request in the audit log links to its Coston2 transactions and its XRPL transaction.

---

## 5. Non-functional requirements

**NFR-1 — No key material leaves the enclave.** Not in logs, not in `/state`, not in any response, not on disk. `GET /state` returns booleans and sequence numbers only.

**NFR-2 — Fail closed.** Every ambiguous condition rejects. Stale price rejects. Digest mismatch rejects. Unknown treasury rejects. There is no permissive fallback path anywhere in the system.

**NFR-3 — Auditability from chain data alone.** A third party with an RPC endpoint can reconstruct the full history without access to any Aegis service.

**NFR-4 — Latency.** Proposal and approval are single transactions. Dispatch to signature completes within the instruction relay round. Settlement confirmation is bounded by FDC round finality.

**NFR-5 — Reproducible enclave image.** The extension's Docker image is the unit of attestation. Builds must be reproducible so the on-chain code hash is meaningful.

**NFR-6 — Deterministic signatures.** RFC 6979 nonce derivation, so the same request signed by two machines yields the same signature.

**NFR-7 — No secret in calldata.** Nothing confidential is written on-chain. On-chain data is public and encryption breaks over time.

---

## 6. Out of scope for v1

Stated so scope is honest rather than implied:

- Non-XRP assets on XRPL (issued currencies, trustlines)
- Bitcoin, even though FCC supports it
- k-of-n signing across multiple TEE machines and native XRPL `SignerList` — designed, not built, and specified as the PMW migration path
- Importing an existing XRPL key into a treasury
- Fiat off-ramp, invoicing, accounting exports
- Mainnet deployment; FCC itself is not yet a fully public production system
- Mobile apps

---

## 7. Success metrics

**Correctness (binary, must all pass):**
- A payment within policy signs and settles, and the settlement is confirmed by an FDC proof.
- A payment that exceeds the tier cap is rejected at proposal.
- A payment that exhausts the rolling window is rejected at dispatch even after passing at proposal.
- A payment to a non-allowlisted destination is rejected.
- An approval by the proposer is rejected.
- Dispatch before the timelock expires is rejected.
- A tampered field in the relay path produces a digest mismatch and no signature.
- A frozen treasury rejects everything.
- A transaction that misses `LastLedgerSequence` is proven non-existent and the window spend is released.

**Adoption during the program:**
- At least three treasuries created by people who are not the build team.
- At least one XRPL testnet payment executed end-to-end by an external user.
- Written feedback from at least two DAO or fund operators on whether the policy vocabulary matches how they actually work.

**Ecosystem signal:**
- The policy digest verification pattern documented well enough to be reused by other FCE developers.
- A stated migration path to PMW that a Flare engineer would agree is correct.

---

## 8. Judging criteria mapping

| Criterion | How Aegis answers it |
|---|---|
| Product usefulness | Solves a problem XRPL cannot express natively and that every multi-person XRP holder currently solves with process instead of code |
| Flare integration quality | Cannot exist without Flare. FCC holds the key and enforces the digest check. FTSO prices the tiers. FDC proves settlement. Remove any one and the product is gone |
| Technical execution | Live on Coston2 and XRPL Testnet, real signing, real proofs, no simulated components in the demo path |
| Evidence of new work | Entire codebase written during the program; §9 documents the boundary precisely |
| Clarity and future potential | PMW migration is a single-module swap; the contract layer is already the durable part |

---

## 9. New work declaration

Everything in this repository is written during the program. Nothing is ported from a prior project.

Reused as a starting point, and declared as such:
- `flare-foundation/fce-extension-scaffold` — the Hello World FCE structure, deploy scripts, and Docker composition. Aegis replaces the extension logic, the Solidity entry point, and the test harness. The `base/` framework packages and `go/tools/` deploy CLIs are used unmodified, as the guides instruct.

Written from scratch:
- All six Solidity contracts in `contracts/`
- The complete XRPL serialiser, address deriver, and signer in Go, with no XRPL library dependency
- The policy digest verification mechanism
- The submitter service and its FDC attestation flow
- The dashboard
- The full test suite

---

## 10. Roadmap beyond the hackathon

**Immediate.** k-of-n across TEE machines using XRPL `SignerList`, removing the single-machine key loss risk. Multi-sign hash prefix and per-signer serialisation are already specified.

**Next.** Migrate signing to PMW when its interface is public, inheriting native nonce chaining, reissuance with a different fee, and nullification.

**Then.** Extend policy to XRPL issued currencies and to FXRP on the Flare side, so a single policy governs an organisation's assets on both chains. Add Bitcoin, which FCC already supports.

**Later.** Policy templates for common structures — a DAO grants committee, a fund's operating account, a protocol payout wallet — so onboarding does not start from an empty rule set.
