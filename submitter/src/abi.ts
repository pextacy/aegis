/**
 * The on-chain surface the submitter touches.
 *
 * Only what is actually called is declared. The attestation response tuples are
 * spelled out in full because the DA layer returns `abi.encode(Response)` as
 * opaque bytes and this is what turns it back into the struct
 * `ExecutionVerifier` expects — a field out of order here would decode into a
 * proof that fails verification on-chain.
 */

import type { AbiParameter } from "viem";

export const paymentControllerAbi = [
  {
    type: "event",
    name: "PaymentSigned",
    inputs: [
      { name: "requestId", type: "uint256", indexed: true },
      { name: "signedBlob", type: "bytes", indexed: false },
      { name: "txHash", type: "bytes32", indexed: false },
    ],
  },
  {
    type: "function",
    name: "getRequest",
    stateMutability: "view",
    inputs: [{ name: "requestId", type: "uint256" }],
    outputs: [
      {
        type: "tuple",
        components: [
          { name: "treasuryId", type: "uint256" },
          { name: "destinationAccountId", type: "bytes32" },
          { name: "destinationTag", type: "uint32" },
          { name: "amountDrops", type: "uint64" },
          { name: "amountUsdAtProposal", type: "uint256" },
          { name: "sequence", type: "uint32" },
          { name: "firstLedgerSequence", type: "uint32" },
          { name: "lastLedgerSequence", type: "uint32" },
          { name: "feeDrops", type: "uint64" },
          { name: "approvals", type: "uint8" },
          { name: "requiredApprovals", type: "uint8" },
          { name: "eligibleAt", type: "uint64" },
          { name: "state", type: "uint8" },
          { name: "policyDigest", type: "bytes32" },
          { name: "proposer", type: "address" },
          { name: "committedUsd", type: "uint256" },
          { name: "windowIndex", type: "uint256" },
          { name: "multiSignDigest", type: "bytes32" },
          { name: "quorumRequired", type: "uint8" },
        ],
      },
    ],
  },
  {
    // Emitted once a k-of-n payment has collected its quorum. There is no blob
    // in it: the shares are published individually and assembling them is the
    // submitter's job, which is what makes the assembler powerless rather than
    // trusted.
    type: "event",
    name: "PaymentMultiSigned",
    inputs: [
      { name: "requestId", type: "uint256", indexed: true },
      { name: "treasuryId", type: "uint256", indexed: true },
      { name: "collected", type: "uint8", indexed: false },
      { name: "quorum", type: "uint8", indexed: false },
    ],
  },
  {
    type: "function",
    name: "partialSignaturesOf",
    stateMutability: "view",
    inputs: [{ name: "requestId", type: "uint256" }],
    outputs: [
      {
        type: "tuple[]",
        components: [
          { name: "signerAccountId", type: "bytes32" },
          { name: "signerPubKey", type: "bytes" },
          { name: "signature", type: "bytes" },
        ],
      },
    ],
  },
  {
    type: "function",
    name: "TREASURY_REGISTRY",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
] as const;

/**
 * The registry read the assembler needs: which XRPL account a payment leaves.
 *
 * Discovered from the payment controller rather than configured, so a submitter
 * pointed at one deployment cannot be reading another deployment's treasuries.
 */
export const treasuryRegistryAbi = [
  {
    type: "function",
    name: "getTreasury",
    stateMutability: "view",
    inputs: [{ name: "treasuryId", type: "uint256" }],
    outputs: [
      {
        type: "tuple",
        components: [
          { name: "id", type: "uint256" },
          { name: "xrplAccountId", type: "bytes32" },
          { name: "xrplAddress", type: "string" },
          { name: "policyId", type: "uint256" },
          { name: "frozen", type: "bool" },
          { name: "nextSequence", type: "uint32" },
          { name: "sequenceConfirmed", type: "bool" },
        ],
      },
    ],
  },
] as const;

/** Mirrors `PaymentController.RequestState`. */
export enum RequestState {
  Proposed = 0,
  Approved = 1,
  Dispatched = 2,
  Signed = 3,
  Settled = 4,
  Failed = 5,
  Cancelled = 6,
}

/** States from which no proof can move a request any further. */
export function isTerminal(state: RequestState): boolean {
  return state === RequestState.Settled || state === RequestState.Failed || state === RequestState.Cancelled;
}

const paymentResponseComponents = [
  { name: "attestationType", type: "bytes32" },
  { name: "sourceId", type: "bytes32" },
  { name: "votingRound", type: "uint64" },
  { name: "lowestUsedTimestamp", type: "uint64" },
  {
    name: "requestBody",
    type: "tuple",
    components: [
      { name: "transactionId", type: "bytes32" },
      { name: "inUtxo", type: "uint256" },
      { name: "utxo", type: "uint256" },
    ],
  },
  {
    name: "responseBody",
    type: "tuple",
    components: [
      { name: "blockNumber", type: "uint64" },
      { name: "blockTimestamp", type: "uint64" },
      { name: "sourceAddressHash", type: "bytes32" },
      { name: "sourceAddressesRoot", type: "bytes32" },
      { name: "receivingAddressHash", type: "bytes32" },
      { name: "intendedReceivingAddressHash", type: "bytes32" },
      { name: "spentAmount", type: "int256" },
      { name: "intendedSpentAmount", type: "int256" },
      { name: "receivedAmount", type: "int256" },
      { name: "intendedReceivedAmount", type: "int256" },
      { name: "standardPaymentReference", type: "bytes32" },
      { name: "oneToOne", type: "bool" },
      { name: "status", type: "uint8" },
    ],
  },
] as const satisfies readonly AbiParameter[];

const nonexistenceResponseComponents = [
  { name: "attestationType", type: "bytes32" },
  { name: "sourceId", type: "bytes32" },
  { name: "votingRound", type: "uint64" },
  { name: "lowestUsedTimestamp", type: "uint64" },
  {
    name: "requestBody",
    type: "tuple",
    components: [
      { name: "minimalBlockNumber", type: "uint64" },
      { name: "deadlineBlockNumber", type: "uint64" },
      { name: "deadlineTimestamp", type: "uint64" },
      { name: "destinationAddressHash", type: "bytes32" },
      { name: "amount", type: "uint256" },
      { name: "standardPaymentReference", type: "bytes32" },
      { name: "checkSourceAddresses", type: "bool" },
      { name: "sourceAddressesRoot", type: "bytes32" },
    ],
  },
  {
    name: "responseBody",
    type: "tuple",
    components: [
      { name: "minimalBlockTimestamp", type: "uint64" },
      { name: "firstOverflowBlockNumber", type: "uint64" },
      { name: "firstOverflowBlockTimestamp", type: "uint64" },
    ],
  },
] as const satisfies readonly AbiParameter[];

/** `abi.encode(IPayment.Response)`, as the DA layer returns it. */
export const paymentResponseParameters = [
  { name: "response", type: "tuple", components: paymentResponseComponents },
] as const satisfies readonly AbiParameter[];

/** `abi.encode(IReferencedPaymentNonexistence.Response)`. */
export const nonexistenceResponseParameters = [
  { name: "response", type: "tuple", components: nonexistenceResponseComponents },
] as const satisfies readonly AbiParameter[];

export const executionVerifierAbi = [
  {
    type: "function",
    name: "confirmSettlement",
    stateMutability: "nonpayable",
    inputs: [
      { name: "requestId", type: "uint256" },
      {
        name: "proof",
        type: "tuple",
        components: [
          { name: "merkleProof", type: "bytes32[]" },
          { name: "data", type: "tuple", components: paymentResponseComponents },
        ],
      },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "confirmFailedExecution",
    stateMutability: "nonpayable",
    inputs: [
      { name: "requestId", type: "uint256" },
      {
        name: "proof",
        type: "tuple",
        components: [
          { name: "merkleProof", type: "bytes32[]" },
          { name: "data", type: "tuple", components: paymentResponseComponents },
        ],
      },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "confirmNonExecution",
    stateMutability: "nonpayable",
    inputs: [
      { name: "requestId", type: "uint256" },
      {
        name: "proof",
        type: "tuple",
        components: [
          { name: "merkleProof", type: "bytes32[]" },
          { name: "data", type: "tuple", components: nonexistenceResponseComponents },
        ],
      },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "requestReference",
    stateMutability: "pure",
    inputs: [{ name: "requestId", type: "uint256" }],
    outputs: [{ type: "bytes32" }],
  },
  {
    type: "function",
    name: "addressHashOf",
    stateMutability: "pure",
    inputs: [{ name: "xrplAccountId", type: "bytes32" }],
    outputs: [{ type: "bytes32" }],
  },
] as const;

export const fdcHubAbi = [
  {
    type: "function",
    name: "requestAttestation",
    stateMutability: "payable",
    inputs: [{ name: "_data", type: "bytes" }],
    outputs: [],
  },
] as const;

export const fdcRequestFeeConfigurationsAbi = [
  {
    type: "function",
    name: "getRequestFee",
    stateMutability: "view",
    inputs: [{ name: "_data", type: "bytes" }],
    outputs: [{ type: "uint256" }],
  },
] as const;

export const flareSystemsManagerAbi = [
  {
    type: "function",
    name: "firstVotingRoundStartTs",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint64" }],
  },
  {
    type: "function",
    name: "votingEpochDurationSeconds",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint64" }],
  },
] as const;
