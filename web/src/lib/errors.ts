import { BaseError, ContractFunctionRevertedError, hexToString, UserRejectedRequestError, type Hex } from "viem";

import { formatDuration, formatTimestamp, formatUsd, shortHex } from "./format";
import { bytes32ToClassicAddress } from "./xrpl-address";

/**
 * Every custom Solidity error in Aegis, in plain language.
 *
 * A refusal to spend is the correct outcome of most failures in this system, but
 * only if the person reading it can tell which rule fired. "execution reverted"
 * tells an approver nothing; "the rolling window has $4,000 of its $10,000 left
 * and this payment needs $6,500" tells them exactly what to do next.
 *
 * Adding a custom error to a contract means adding it here in the same commit.
 * {@link UNEXPLAINED_ERRORS} is what proves nothing was missed.
 */

/** A revert, decoded and phrased for a person. */
export type ExplainedFailure = {
  /** Short headline, e.g. "Rolling window exhausted". */
  title: string;
  /** The rule that refused, named the way the docs name it. */
  rule: string;
  /** What happened, with the contract's own numbers in it. */
  detail: string;
  /** What the reader can do about it, when there is something. */
  remedy?: string;
  /** The Solidity error name, when one was decoded. */
  errorName: string | null;
};

type Explanation = Omit<ExplainedFailure, "errorName">;
type Explainer = (args: readonly unknown[]) => Explanation;

function bigintAt(args: readonly unknown[], index: number): bigint {
  const value = args[index];
  return typeof value === "bigint" ? value : BigInt(Number(value ?? 0));
}

function stringAt(args: readonly unknown[], index: number): string {
  const value = args[index];
  return typeof value === "string" ? value : String(value ?? "");
}

/** A short ASCII `bytes32` — op commands, attestation types, source ids. */
function bytes32Text(value: unknown): string {
  if (typeof value !== "string") return "an unreadable value";
  try {
    const text = hexToString(value as Hex, { size: 32 }).replace(/\0+$/, "");
    return text === "" ? shortHex(value) : text;
  } catch {
    return shortHex(value);
  }
}

/** Mirrors `TreasuryRegistry.SignerSetState`, in the words the UI uses. */
const SIGNER_SET_STATES = [
  "not configured",
  "collecting signer keys",
  "ready to install its signer list",
  "signing by quorum",
  "signing by quorum with its master key retired",
] as const;

function signerSetState(value: unknown): string {
  const index = Number(value ?? -1);
  return SIGNER_SET_STATES[index] ?? `in an unrecognised state (${index})`;
}

/** A signer AccountID, as its XRPL address where that can be derived. */
function signerLabel(word: unknown): string {
  const hex = typeof word === "string" ? (word as Hex) : ("0x" as Hex);
  try {
    return bytes32ToClassicAddress(hex) ?? shortHex(hex);
  } catch {
    return shortHex(hex);
  }
}

function destinationLabel(word: unknown, tag: unknown): string {
  const hex = typeof word === "string" ? (word as Hex) : ("0x" as Hex);
  let address: string;
  try {
    address = bytes32ToClassicAddress(hex) ?? shortHex(hex);
  } catch {
    address = shortHex(hex);
  }
  const tagValue = typeof tag === "bigint" ? tag : BigInt(Number(tag ?? 0));
  return tagValue === 0n ? `${address} with no destination tag` : `${address} with destination tag ${tagValue}`;
}

/** The request lifecycle, indexed by PaymentController.RequestState. */
export const REQUEST_STATE_NAMES = [
  "Proposed",
  "Approved",
  "Dispatched",
  "Signed",
  "Settled",
  "Failed",
  "Cancelled",
] as const;

function stateName(value: unknown): string {
  const index = Number(value ?? -1);
  return REQUEST_STATE_NAMES[index] ?? `state ${index}`;
}

const EXPLANATIONS: Record<string, Explainer> = {
  // --- PolicyEngine ------------------------------------------------------
  PolicyNotFound: (args) => ({
    title: "No such policy",
    rule: "PolicyEngine — policy existence",
    detail: `Policy ${bigintAt(args, 0)} has never been created.`,
    remedy: "Check the policy id, or create the policy first.",
  }),
  NoTiers: () => ({
    title: "A policy needs at least one tier",
    rule: "PolicyEngine — tier validation",
    detail: "A policy with no tiers could not price any payment, so it cannot be created.",
  }),
  TooManyTiers: () => ({
    title: "Too many tiers",
    rule: "PolicyEngine — MAX_TIERS",
    detail: "A policy may hold at most 16 tiers, so tier resolution stays cheap enough to run on every dispatch.",
  }),
  TiersNotAscending: (args) => ({
    title: "Tiers are out of order",
    rule: "PolicyEngine — ascending tier ceilings",
    detail: `Tier ${bigintAt(args, 0) + 1n} does not have a higher ceiling than the tier before it.`,
    remedy: "Each tier's ceiling must be strictly greater than the one below it.",
  }),
  TierNeedsApprovals: (args) => ({
    title: "A tier needs at least one approval",
    rule: "PolicyEngine — tier validation",
    detail: `Tier ${bigintAt(args, 0) + 1n} requires zero approvals, which would let a proposer pay themselves unchecked.`,
  }),
  RollingWindowRequired: () => ({
    title: "A policy needs a rolling window",
    rule: "PolicyEngine — rolling window",
    detail: "A window of zero USD would block every payment. Set the total that may be committed inside one window.",
  }),
  WindowSecondsRequired: () => ({
    title: "A policy needs a window length",
    rule: "PolicyEngine — rolling window",
    detail: "The window has no length, so no spend could ever age out of it.",
  }),
  AmendApprovalsRequired: () => ({
    title: "A policy needs an amendment threshold",
    rule: "PolicyEngine — amendment parameters",
    detail: "With zero amendment approvals, one address could repoint or unfreeze the treasury alone.",
  }),
  AmountExceedsPolicyCap: (args) => ({
    title: "Above the policy's hard cap",
    rule: "PolicyEngine — highest tier ceiling",
    detail: `The payment is worth $${formatUsd(bigintAt(args, 0))} and the highest tier tops out at $${formatUsd(
      bigintAt(args, 1),
    )}. No number of approvals authorises it.`,
    remedy: "Split the payment, or amend the treasury to a policy with a higher cap.",
  }),
  NotPolicyAdmin: (args) => ({
    title: "Not a policy administrator",
    rule: "PolicyEngine — ROLE_POLICY_ADMIN",
    detail: `${shortHex(stringAt(args, 1))} does not hold POLICY_ADMIN on policy ${bigintAt(args, 0)}.`,
  }),
  ZeroAddress: () => ({
    title: "Zero address",
    rule: "Address validation",
    detail: "The zero address cannot hold a role or be wired as a collaborating contract.",
  }),

  // --- TreasuryRegistry --------------------------------------------------
  TreasuryNotFound: (args) => ({
    title: "No such treasury",
    rule: "TreasuryRegistry — treasury existence",
    detail: `Treasury ${bigintAt(args, 0)} has never been created.`,
  }),
  AmendmentNotFound: (args) => ({
    title: "No such amendment",
    rule: "TreasuryRegistry — amendment existence",
    detail: `Amendment ${bigintAt(args, 0)} has never been proposed.`,
  }),
  NotOwner: () => ({
    title: "Not the deployer",
    rule: "Deployment wiring",
    detail: "Only the address that deployed the contract may wire its collaborators, and only once each.",
  }),
  AlreadyWired: () => ({
    title: "Already wired",
    rule: "Deployment wiring",
    detail: "This collaborator address is set for the life of the contract and cannot be repointed.",
  }),
  NotInstructionSender: () => ({
    title: "Not the instruction sender",
    rule: "TEE result authority",
    detail:
      "Only AegisInstructionSender may deliver a TEE result. A signature or an account binding from anywhere else is refused.",
  }),
  NotExecutionVerifier: () => ({
    title: "Not the execution verifier",
    rule: "Settlement authority",
    detail:
      "Only ExecutionVerifier may settle or fail a request, and it does so only after an FDC proof verified. The submitter holds no authority of its own.",
  }),
  NotGuardian: (args) => ({
    title: "Not a guardian",
    rule: "PolicyEngine — ROLE_GUARDIAN",
    detail: `${shortHex(stringAt(args, 1))} does not hold GUARDIAN on the policy governing treasury ${bigintAt(args, 0)}.`,
  }),
  AccountAlreadyBound: (args) => ({
    title: "XRPL account already bound",
    rule: "TreasuryRegistry — one binding per treasury",
    detail: `Treasury ${bigintAt(args, 0)} already has an XRPL account. A treasury accepts exactly one binding for its lifetime.`,
  }),
  AddressMismatch: (args) => ({
    title: "Reported address does not match the key",
    rule: "TreasuryRegistry — on-chain AccountID derivation",
    detail: `The contract derived ${stringAt(args, 0)} from the public key, but the enclave reported ${stringAt(
      args,
      1,
    )}. The binding is refused.`,
  }),
  TreasuryFrozenError: (args) => ({
    title: "Treasury is frozen",
    rule: "TreasuryRegistry — guardian freeze",
    detail: `Treasury ${bigintAt(args, 0)} is frozen. A guardian stopped it, and unfreezing takes the policy's amendment threshold and timelock.`,
  }),
  TreasuryNotFrozen: (args) => ({
    title: "Treasury is not frozen",
    rule: "TreasuryRegistry — unfreeze amendment",
    detail: `Treasury ${bigintAt(args, 0)} is not frozen, so there is nothing to unfreeze.`,
  }),
  SamePolicy: (args) => ({
    title: "Already on that policy",
    rule: "TreasuryRegistry — policy amendment",
    detail: `The treasury is already governed by policy ${bigintAt(args, 0)}.`,
  }),
  AmendmentAlreadyExecuted: (args) => ({
    title: "Amendment already executed",
    rule: "TreasuryRegistry — amendment lifecycle",
    detail: `Amendment ${bigintAt(args, 0)} has already taken effect.`,
  }),
  SequenceMustAdvance: (args) => ({
    title: "Sequence would go backwards",
    rule: "TreasuryRegistry — sequence tracking",
    detail: `The treasury already expects sequence ${bigintAt(args, 0)}; the proof carries ${bigintAt(args, 1)}.`,
  }),
  SignerSetAlreadyConfigured: (args) => ({
    title: "Quorum is already set",
    rule: "TreasuryRegistry — k-of-n signer set",
    detail:
      `Treasury ${bigintAt(args, 0)} has already committed to a quorum, and it is set once. ` +
      `Changing it means replacing a signer list on XRPL while payments are in flight, and a payment ` +
      `dispatched to the old set could no longer be signed by the new one.`,
    remedy: "A different arrangement is a different treasury.",
  }),
  SignerSetNotConfigured: (args) => ({
    title: "No quorum on this treasury",
    rule: "TreasuryRegistry — k-of-n signer set",
    detail: `Treasury ${bigintAt(args, 0)} signs with a single enclave key and has not committed to a quorum.`,
    remedy: "Configure the signer set first, then collect its keys.",
  }),
  WrongSignerSetState: (args) => ({
    title: "Wrong step in the k-of-n setup",
    rule: "TreasuryRegistry — k-of-n signer set",
    detail:
      `The signer set is ${signerSetState(args[0])}, and this step needs it to be ${signerSetState(args[1])}. ` +
      `The order is the only one XRPL permits: collect the keys, install the signer list, then retire the master key.`,
  }),
  SignerSetNotInState: (args) => ({
    title: "Wrong step in the k-of-n setup",
    rule: "AegisInstructionSender — k-of-n setup",
    detail:
      `The signer set is ${signerSetState(args[0])}, and this instruction needs it to be ${signerSetState(args[1])}. ` +
      `Retiring a master key before the signer list is live would leave an account nothing could ever sign for.`,
  }),
  InvalidQuorum: (args) => ({
    title: "Quorum cannot be met",
    rule: "TreasuryRegistry — k-of-n signer set",
    detail:
      `A quorum of ${bigintAt(args, 0)} out of ${bigintAt(args, 1)} signers is not usable: zero would authorise ` +
      `anything, and more than the signer count would authorise nothing.`,
    remedy: "Choose a quorum between 1 and the number of signers.",
  }),
  TooManySigners: (args) => ({
    title: "More signers than XRPL holds",
    rule: "TreasuryRegistry — k-of-n signer set",
    detail: `XRPL holds at most ${bigintAt(args, 1)} signers on one account; ${bigintAt(args, 0)} were asked for.`,
  }),
  DuplicateSignerKey: (args) => ({
    title: "That enclave is already a signer",
    rule: "TreasuryRegistry — k-of-n signer set",
    detail:
      `${signerLabel(args[1])} already holds a slot in treasury ${bigintAt(args, 0)}'s signer list. ` +
      `XRPL counts a signer once, so a duplicate would inflate a quorum the ledger will not honour.`,
  }),
  SignerIsTreasuryAccount: (args) => ({
    title: "A treasury cannot be its own signer",
    rule: "TreasuryRegistry — k-of-n signer set",
    detail:
      `The key offered for treasury ${bigintAt(args, 0)} derives to the treasury's own XRPL account. ` +
      `XRPL refuses a signer list containing the account itself, so that signer could never count.`,
  }),
  SignerSetComplete: (args) => ({
    title: "Every signer slot is filled",
    rule: "TreasuryRegistry — k-of-n signer set",
    detail: `Treasury ${bigintAt(args, 0)} already has all the signer keys it asked for.`,
  }),
  XrplTxHashRequired: () => ({
    title: "Name the XRPL transaction",
    rule: "TreasuryRegistry — k-of-n setup record",
    detail:
      "A step that happened on XRPL is recorded with the transaction that did it, so the claim can be " +
      "checked against the ledger rather than taken on trust.",
    remedy: "Submit the signed setup transaction first, then record its hash.",
  }),
  NotATreasurySigner: (args) => ({
    title: "Not one of this treasury's signers",
    rule: "PaymentController — k-of-n signature collection",
    detail:
      `${signerLabel(args[1])} is not in treasury ${bigintAt(args, 0)}'s signer list, so XRPL would not count ` +
      `its signature either.`,
  }),
  AlreadyPartiallySigned: (args) => ({
    title: "That enclave has already signed",
    rule: "PaymentController — k-of-n signature collection",
    detail:
      `${signerLabel(args[1])} has already contributed to request ${bigintAt(args, 0)}. ` +
      `A second share from the same signer would inflate a quorum XRPL will not honour.`,
  }),
  NotAQuorumPayment: (args) => ({
    title: "This payment was not dispatched to a quorum",
    rule: "PaymentController — k-of-n signature collection",
    detail: `Request ${bigintAt(args, 0)} was dispatched to a single enclave key, so it collects no shares.`,
  }),
  EmptySignature: (args) => ({
    title: "Empty signature",
    rule: "PaymentController — k-of-n signature collection",
    detail: `A share for request ${bigintAt(args, 0)} arrived with no key or no signature, which is not a contribution.`,
  }),
  UnknownSetupKind: (args) => ({
    title: "Unknown setup step",
    rule: "AegisInstructionSender — k-of-n setup",
    detail:
      `Setup kind ${bigintAt(args, 0)} does not exist. There are two: installing the signer list, and ` +
      `retiring the master key.`,
  }),
  AccountNotBound: (args) => ({
    title: "No XRPL account yet",
    rule: "TreasuryRegistry — starting sequence",
    detail:
      `Treasury ${bigintAt(args, 0)} has no XRPL account bound, so it has no starting sequence to record. ` +
      `Generate the key in the TEE and bind it first.`,
  }),
  SequenceAlreadyConfirmed: (args) => ({
    title: "Starting sequence is already settled",
    rule: "TreasuryRegistry — starting sequence",
    detail:
      `XRPL has already consumed a sequence for treasury ${bigintAt(args, 0)}, so its starting point is a matter ` +
      `of record and can no longer be edited.`,
  }),
  InitialSequenceRequired: () => ({
    title: "Starting sequence cannot be zero",
    rule: "TreasuryRegistry — starting sequence",
    detail: `Zero is how this system marks "not yet known", so it is not a value the account can start at.`,
  }),

  // --- PaymentController -------------------------------------------------
  RequestNotFound: (args) => ({
    title: "No such payment request",
    rule: "PaymentController — request existence",
    detail: `Request ${bigintAt(args, 0)} has never been proposed.`,
  }),
  InstructionSenderNotSet: () => ({
    title: "Signing is not wired up",
    rule: "Deployment wiring",
    detail: "The controller has no instruction sender, so it cannot ask the TEE for a signature.",
    remedy: "Wire AegisInstructionSender before dispatching a payment.",
  }),
  NotProposer: (args) => ({
    title: "Not a proposer",
    rule: "PolicyEngine — ROLE_PROPOSER",
    detail: `${shortHex(stringAt(args, 1))} does not hold PROPOSER on policy ${bigintAt(args, 0)}.`,
  }),
  NotApprover: (args) => ({
    title: "Not an approver",
    rule: "PolicyEngine — ROLE_APPROVER",
    detail: `${shortHex(stringAt(args, 1))} does not hold APPROVER on policy ${bigintAt(args, 0)}.`,
  }),
  TreasuryIsFrozen: (args) => ({
    title: "Treasury is frozen",
    rule: "TreasuryRegistry — guardian freeze",
    detail: `Treasury ${bigintAt(args, 0)} is frozen, which blocks proposing, approving and dispatching alike.`,
  }),
  XrplAccountNotBound: (args) => ({
    title: "No XRPL account yet",
    rule: "TreasuryRegistry — account binding",
    detail: `Treasury ${bigintAt(args, 0)} has no XRPL account, so there is no key to sign with and nothing to pay from.`,
    remedy: "Generate the treasury's key in the enclave and bind it first.",
  }),
  ZeroAmount: () => ({
    title: "Amount is zero",
    rule: "PaymentController — propose",
    detail: "A payment of zero drops would consume a sequence number and move nothing.",
  }),
  DestinationNotLeftAligned: (args) => ({
    title: "Destination is not a left-aligned AccountID",
    rule: "PaymentController — destination encoding",
    detail: `${shortHex(stringAt(args, 0))} has bytes set below the first 20, so it is not an AccountID left-aligned in a word. A right-aligned value would serialise to a different XRPL account than the one intended.`,
  }),
  WindowEntryMismatch: (args) => ({
    title: "Rolling-window accounting is inconsistent",
    rule: "PaymentController — window release",
    detail:
      `Request ${bigintAt(args, 1)} recorded its window spend for treasury ${bigintAt(args, 0)} at entry ` +
      `${bigintAt(args, 2)}, and that entry no longer holds it. This is an invariant failure rather than a rule ` +
      `refusing a payment. The contract stops instead of reporting a release that did not happen.`,
  }),
  SequenceNotInitialised: (args) => ({
    title: "Treasury has no starting sequence yet",
    rule: "PaymentController — starting sequence",
    detail:
      `Treasury ${bigintAt(args, 0)} has not recorded the XRPL sequence its account starts at. An XRPL account ` +
      `begins at the ledger index it was funded in, not at 1, so signing before that is known produces a ` +
      `transaction the network rejects and no proof can ever settle. Fund the account, then record its sequence.`,
  }),
  ZeroDestination: () => ({
    title: "Destination is empty",
    rule: "PaymentController — propose",
    detail: "The destination AccountID is all zeroes.",
  }),
  LastLedgerSequenceRequired: () => ({
    title: "LastLedgerSequence is mandatory",
    rule: "PaymentController — dispatch",
    detail:
      "A transaction without an expiry ledger can never be proven non-existent, which would break the failure path and wedge the treasury's sequence forever.",
  }),
  FirstLedgerSequenceRequired: () => ({
    title: "The current XRPL ledger is required",
    rule: "PaymentController — dispatch",
    detail:
      "Dispatch records the ledger the payment could first appear in. Without a lower bound, a one-ledger non-existence proof could 'prove' a payment absent that had already landed.",
  }),
  LedgerRangeInverted: (args) => ({
    title: "Ledger range runs backwards",
    rule: "PaymentController — dispatch",
    detail: `The first ledger (${bigintAt(args, 0)}) is after the expiry ledger (${bigintAt(args, 1)}).`,
  }),
  ZeroFee: () => ({
    title: "Fee is zero",
    rule: "PaymentController — dispatch",
    detail: "XRPL will not validate a transaction with a zero fee.",
  }),
  StalePrice: (args) => ({
    title: "XRP price is stale",
    rule: "FTSO — MAX_PRICE_AGE, 180 seconds",
    detail: `The XRP/USD feed was last updated at ${formatTimestamp(bigintAt(args, 0))}, which is ${formatDuration(
      bigintAt(args, 1) - bigintAt(args, 0),
    )} ago. Aegis prices every payment at the current price and never falls back to a cached one.`,
    remedy: "Wait for the next feed update and try again.",
  }),
  InvalidPrice: () => ({
    title: "XRP price is unavailable",
    rule: "FTSO — feed value",
    detail: "The XRP/USD feed returned zero, so the payment cannot be valued and is refused.",
  }),
  DestinationNotAllowed: (args) => ({
    title: "Destination is not allowlisted",
    rule: "PolicyEngine — destination allowlist",
    detail: `The policy does not permit ${destinationLabel(args[0], args[1])}.`,
    remedy: "A policy administrator can add the account, either for one tag or for any tag.",
  }),
  RollingWindowExceeded: (args) => ({
    title: "Rolling window exhausted",
    rule: "PolicyEngine — rolling spend window",
    detail: `$${formatUsd(bigintAt(args, 0))} of the $${formatUsd(
      bigintAt(args, 2),
    )} window is already committed, and this payment needs $${formatUsd(bigintAt(args, 1))}.`,
    remedy: "Wait for earlier spend to age out of the window, or split the payment.",
  }),
  WrongState: (args) => ({
    title: "Request is in the wrong state",
    rule: "PaymentController — payment state machine",
    detail: `The request is ${stateName(args[0])} and this step needs it to be ${stateName(args[1])}.`,
  }),
  ProposerCannotApprove: (args) => ({
    title: "A proposer cannot approve their own request",
    rule: "PaymentController — segregation of duties",
    detail: `Request ${bigintAt(args, 0)} was proposed by this address, so its approval would not be a second pair of eyes.`,
  }),
  AlreadyApproved: (args) => ({
    title: "Already approved",
    rule: "PaymentController — one approval per address",
    detail: `${shortHex(stringAt(args, 1))} has already approved request ${bigintAt(args, 0)}.`,
  }),
  ApproverEntryMissing: (args) => ({
    title: "Approval records disagree",
    rule: "PaymentController — internal consistency",
    detail: `Request ${bigintAt(args, 0)} records ${shortHex(
      stringAt(args, 1),
    )} as an approver in one place and not in the other.`,
    remedy:
      "Nothing you did causes this. The contract refuses rather than letting the two records drift apart, which would leave a payment counting an approval nobody holds. Report it with the request id.",
  }),
  NotApproved: (args) => ({
    title: "No approval to withdraw",
    rule: "PaymentController — an approver withdraws only their own approval",
    detail: `${shortHex(stringAt(args, 1))} has not approved request ${bigintAt(args, 0)}.`,
    remedy: "Only the address that gave an approval can take it back. Nobody can strike someone else's.",
  }),
  TimelockNotElapsed: (args) => ({
    title: "Timelock has not elapsed",
    rule: "Tier timelock",
    detail: `This becomes eligible at ${formatTimestamp(bigintAt(args, 0))} — ${formatDuration(
      bigintAt(args, 0) - bigintAt(args, 1),
    )} from now.`,
  }),
  InsufficientApprovals: (args) => ({
    title: "Not enough approvals",
    rule: "Tier approval threshold",
    detail: `${bigintAt(args, 0)} of ${bigintAt(args, 1)} required approvals have been collected.`,
  }),

  // --- AegisInstructionSender --------------------------------------------
  NotPaymentController: () => ({
    title: "Not the payment controller",
    rule: "AegisInstructionSender — signing authority",
    detail:
      "Only PaymentController may ask the TEE for a signature, and it only does so after the whole policy check passed a second time.",
  }),
  NotResultSubmitter: () => ({
    title: "Not the result submitter",
    rule: "AegisInstructionSender — result authority",
    detail: "TEE results arrive from the nominated submitter address. Anything else is refused.",
  }),
  PaymentControllerNotSet: () => ({
    title: "The payment controller is not wired",
    rule: "Deployment wiring",
    detail: "The instruction sender has no controller to report a signature to.",
  }),
  UnknownInstruction: (args) => ({
    title: "Unknown instruction",
    rule: "AegisInstructionSender — instruction bookkeeping",
    detail: `No instruction with id ${shortHex(stringAt(args, 0))} is pending. A result for one that was never sent is refused.`,
  }),
  InstructionAlreadyConsumed: (args) => ({
    title: "Instruction already answered",
    rule: "AegisInstructionSender — replay protection",
    detail: `Instruction ${shortHex(stringAt(args, 0))} has already been consumed. A result cannot be replayed.`,
  }),
  WrongCommand: (args) => ({
    title: "Result answers the wrong command",
    rule: "AegisInstructionSender — command matching",
    detail: `A ${bytes32Text(args[0])} result arrived for an instruction that asked for ${bytes32Text(args[1])}.`,
  }),

  // --- ExecutionVerifier -------------------------------------------------
  ProofNotVerified: () => ({
    title: "The FDC proof does not verify",
    rule: "ExecutionVerifier — FDC verification",
    detail:
      "Flare's FDC verification contract rejected this Merkle proof. Nothing about the payment is taken on trust; a proof that does not verify moves no state.",
  }),
  WrongAttestationType: (args) => ({
    title: "Wrong attestation type",
    rule: "ExecutionVerifier — attestation type",
    detail: `The proof attests ${bytes32Text(args[0])}, and this entry point takes ${bytes32Text(args[1])}.`,
  }),
  WrongSource: (args) => ({
    title: "Wrong chain",
    rule: "ExecutionVerifier — source id",
    detail: `The proof is about ${bytes32Text(args[0])}, and this deployment settles on ${bytes32Text(args[1])}.`,
  }),
  NotAwaitingSettlement: (args) => ({
    title: "Not waiting for settlement",
    rule: "ExecutionVerifier — request state",
    detail: `A settlement proof only applies to a request the enclave has signed. This one is ${stateName(args[0])}.`,
  }),
  NotDispatched: (args) => ({
    title: "Never dispatched",
    rule: "ExecutionVerifier — request state",
    detail: `A non-execution proof only applies to a request that was dispatched. This one is ${stateName(args[0])}.`,
  }),
  ReferenceMismatch: (args) => ({
    title: "The proof is for a different request",
    rule: "ExecutionVerifier — payment reference",
    detail: `The attested payment carries reference ${shortHex(stringAt(args, 0))}, and this request's is ${shortHex(
      stringAt(args, 1),
    )}.`,
  }),
  SourceMismatch: (args) => ({
    title: "Paid from a different account",
    rule: "ExecutionVerifier — source address",
    detail: `The attested payment left ${shortHex(stringAt(args, 0))}, which is not this treasury's XRPL account.`,
  }),
  DestinationMismatch: (args) => ({
    title: "Paid to a different account",
    rule: "ExecutionVerifier — destination address",
    detail: `The attested payment arrived at ${shortHex(stringAt(args, 0))}, which is not the destination this request authorised.`,
  }),
  SpentAmountMismatch: (args) => ({
    title: "A different amount moved",
    rule: "ExecutionVerifier — spent amount",
    detail: `The attested payment spent ${args[0]} drops; this request authorised ${args[1]} including its fee.`,
  }),
  PaymentDidNotSucceed: (args) => ({
    title: "The payment failed on the ledger",
    rule: "ExecutionVerifier — payment status",
    detail: `XRPL recorded status ${bigintAt(args, 0)}, not success. The request is failed, its window spend released, and its sequence advanced — the sequence was consumed even though nothing was delivered.`,
  }),
  PaymentSucceeded: () => ({
    title: "That payment succeeded",
    rule: "ExecutionVerifier — payment status",
    detail: "This entry point records a failure, and the proof shows a successful payment. Use confirmSettlement.",
  }),
  SourceConstrained: () => ({
    title: "The non-existence proof was constrained to a source",
    rule: "ExecutionVerifier — non-existence proof shape",
    detail:
      "A source-constrained search proves less than it appears to: it shows no payment from that account, not that this payment never happened.",
  }),
  SearchStartsTooLate: (args) => ({
    title: "The proof does not cover the whole window",
    rule: "ExecutionVerifier — search range",
    detail: `The search began at ledger ${bigintAt(args, 0)}, after the payment could first have appeared at ${bigintAt(
      args,
      1,
    )}. A gap at the start could hide a payment that already landed.`,
  }),
  SearchEndsTooEarly: (args) => ({
    title: "The proof stops before the payment expires",
    rule: "ExecutionVerifier — search range",
    detail: `The search ended at ledger ${bigintAt(args, 0)}, before the payment's last valid ledger ${bigintAt(
      args,
      1,
    )}. The payment could still be included after that point.`,
  }),
  SearchAmountTooHigh: (args) => ({
    title: "The proof searched for a larger payment",
    rule: "ExecutionVerifier — search amount",
    detail: `The search looked for at least ${bigintAt(args, 0)} drops, more than this payment's ${bigintAt(
      args,
      1,
    )}. Not finding a bigger payment says nothing about this one.`,
  }),

  // --- XrplAddress -------------------------------------------------------
  InvalidPublicKeyLength: () => ({
    title: "Public key is the wrong length",
    rule: "XrplAddress — key derivation",
    detail: "A compressed secp256k1 public key is 33 bytes.",
  }),
  InvalidPublicKeyPrefix: () => ({
    title: "Public key has the wrong prefix",
    rule: "XrplAddress — key derivation",
    detail: "A compressed secp256k1 public key begins with 0x02 or 0x03.",
  }),
};

/** Every error name this module can explain. */
export const EXPLAINED_ERROR_NAMES: readonly string[] = Object.keys(EXPLANATIONS);

/**
 * Error names present in an ABI but not explained here.
 *
 * The dashboard's promise is that every rejection names the rule that fired, so
 * the test for that promise is mechanical: feed it the deployed ABIs and expect
 * an empty list.
 */
export function unexplainedErrorNames(abis: readonly { type: string; name?: string }[][]): string[] {
  const missing = new Set<string>();
  for (const abi of abis) {
    for (const item of abi) {
      if (item.type !== "error" || !item.name) continue;
      if (!(item.name in EXPLANATIONS)) missing.add(item.name);
    }
  }
  return [...missing].sort();
}

/**
 * Turns anything thrown by viem or wagmi into something a person can act on.
 *
 * Falls through to the raw message rather than inventing one — a failure this
 * module does not recognise is still shown, because hiding it would be worse
 * than showing it unpolished.
 */
export function explainFailure(error: unknown): ExplainedFailure {
  if (error instanceof BaseError) {
    const rejected = error.walk((e) => e instanceof UserRejectedRequestError);
    if (rejected) {
      return {
        title: "Signature rejected in the wallet",
        rule: "—",
        detail: "Nothing was sent to the chain.",
        errorName: null,
      };
    }

    const reverted = error.walk((e) => e instanceof ContractFunctionRevertedError);
    if (reverted instanceof ContractFunctionRevertedError) {
      const errorName = reverted.data?.errorName ?? null;
      if (errorName) {
        const explain = EXPLANATIONS[errorName];
        if (explain) {
          return { ...explain(reverted.data?.args ?? []), errorName };
        }
        return {
          title: errorName,
          rule: "Contract rule",
          detail: `The contract reverted with ${errorName}(${(reverted.data?.args ?? [])
            .map((a) => String(a))
            .join(", ")}).`,
          errorName,
        };
      }
      if (reverted.reason) {
        return {
          title: "Transaction reverted",
          rule: "Contract rule",
          detail: reverted.reason,
          errorName: null,
        };
      }
    }

    return {
      title: "Transaction failed",
      rule: "—",
      detail: error.shortMessage || error.message,
      errorName: null,
    };
  }

  if (error instanceof Error) {
    return { title: "Failed", rule: "—", detail: error.message, errorName: null };
  }

  return { title: "Failed", rule: "—", detail: String(error), errorName: null };
}
