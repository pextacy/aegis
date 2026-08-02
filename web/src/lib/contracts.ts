import type { Address, Hex } from "viem";

import { paymentControllerAbi, policyEngineAbi, treasuryRegistryAbi } from "./abi";
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
  nextSequence: number;
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

/** Every Aegis ABI, for error decoding and coverage checks. */
export const ALL_ABIS = [policyEngineAbi, treasuryRegistryAbi, paymentControllerAbi] as const;
