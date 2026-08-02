import { BaseError, ContractFunctionRevertedError, UserRejectedRequestError, type Hex } from "viem";

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
