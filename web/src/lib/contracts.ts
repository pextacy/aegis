import type { Address, Hex } from "viem";

import {
  aegisInstructionSenderAbi,
  executionVerifierAbi,
  paymentControllerAbi,
  policyEngineAbi,
  treasuryRegistryAbi,
} from "./abi";
import { requireConfig } from "./config";

/**
 * The deployed Aegis contracts, and the shapes they return.
 *
 * The ABIs are generated from the Foundry build by scripts/generate-web-abis.sh
 * and never edited here. The types below are written out rather than inferred so
 * that a struct field that changes shape breaks the build at the point of use.
 */

export type Tier = {
  maxAmountUsd: bigint;
  requiredApprovals: number;
  timelockSeconds: number;
};

export type Policy = {
  id: bigint;
  tiers: readonly Tier[];
  rollingWindowUsd: bigint;
  windowSeconds: number;
  allowlistEnforced: boolean;
  amendApprovals: number;
  amendTimelock: number;
};

export type Treasury = {
  id: bigint;
  xrplAccountId: Hex;
  xrplAddress: string;
  policyId: bigint;
  frozen: boolean;
  /** Zero means the XRPL account's starting sequence has not been recorded yet. */
  nextSequence: number;
  /** True once XRPL has consumed a sequence, after which the start is fixed. */
  sequenceConfirmed: boolean;
};

export type PaymentRequest = {
  treasuryId: bigint;
  destinationAccountId: Hex;
  destinationTag: number;
  amountDrops: bigint;
  amountUsdAtProposal: bigint;
  sequence: number;
  firstLedgerSequence: number;
  lastLedgerSequence: number;
  feeDrops: bigint;
  approvals: number;
  requiredApprovals: number;
  eligibleAt: bigint;
  state: number;
  policyDigest: Hex;
  proposer: Address;
  committedUsd: bigint;
  windowIndex: bigint;
  /** Zero on a treasury that signs with one key; set at dispatch otherwise. */
  multiSignDigest: Hex;
  /** How many enclave signatures this payment needs. Zero means one key. */
  quorumRequired: number;
};

/**
 * TreasuryRegistry.SignerSetState.
 *
 * The order is the only one XRPL permits: a signer list cannot be installed
 * before there are keys to put in it, and a master key cannot be retired before
 * something else can authorise.
 */
export const SIGNER_SET_NONE = 0;
export const SIGNER_SET_COLLECTING = 1;
export const SIGNER_SET_READY = 2;
export const SIGNER_SET_INSTALLED = 3;
export const SIGNER_SET_LOCKED = 4;

/** A treasury's k-of-n arrangement. A zeroed one means single-key signing. */
export type SignerSet = {
  quorum: number;
  signerCount: number;
  state: number;
  /** The XRPL sequence the SignerListSet consumed. */
  installSequence: number;
  /** The XRPL sequence the master key's retirement consumed. */
  retireSequence: number;
  /** The XRPL transaction that installed the signer list, once recorded. */
  installTxHash: Hex;
  /** The XRPL transaction that retired the master key, once recorded. */
  retireTxHash: Hex;
};

/** One enclave's share of a k-of-n signature. */
export type PartialSignature = {
  signerAccountId: Hex;
  signerPubKey: Hex;
  signature: Hex;
};

/** TreasuryRegistry.AmendmentKind. */
export const AMENDMENT_UNFREEZE = 0;
export const AMENDMENT_CHANGE_POLICY = 1;

export type Amendment = {
  treasuryId: bigint;
  kind: number;
  newPolicyId: bigint;
  proposer: Address;
  eligibleAt: bigint;
  approvals: number;
  executed: boolean;
};

export type ContractHandles = {
  policyEngine: { address: Address; abi: typeof policyEngineAbi };
  treasuryRegistry: { address: Address; abi: typeof treasuryRegistryAbi };
  paymentController: { address: Address; abi: typeof paymentControllerAbi };
};

/** Address-and-ABI pairs for the configured deployment. */
export function contractHandles(): ContractHandles {
  const config = requireConfig();
  return {
    policyEngine: { address: config.policyEngine, abi: policyEngineAbi },
    treasuryRegistry: { address: config.treasuryRegistry, abi: treasuryRegistryAbi },
    paymentController: { address: config.paymentController, abi: paymentControllerAbi },
  };
}

/**
 * Handles for the two contracts whose addresses are discovered rather than
 * configured.
 *
 * `AegisInstructionSender` and `ExecutionVerifier` are wired into the registry
 * and the controller once each, and both expose the wiring as a public getter.
 * Reading it from the chain means the dashboard cannot be pointed at a signer or
 * a verifier that the contracts do not actually trust — and an unwired address
 * shows up as exactly that, rather than as a missing environment variable.
 */
export function wiredHandles(instructionSender: Address, executionVerifier: Address) {
  return {
    instructionSender: { address: instructionSender, abi: aegisInstructionSenderAbi },
    executionVerifier: { address: executionVerifier, abi: executionVerifierAbi },
  } as const;
}

/** Every Aegis ABI, for error decoding and coverage checks. */
export const ALL_ABIS = [
  policyEngineAbi,
  treasuryRegistryAbi,
  paymentControllerAbi,
  aegisInstructionSenderAbi,
  executionVerifierAbi,
] as const;
