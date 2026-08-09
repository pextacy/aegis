/**
 * Turning a collected quorum into a transaction XRPL will accept.
 *
 * A k-of-n payment never produces a blob on-chain: each enclave publishes its
 * own signature and nothing else, because one machine under k-of-n has
 * authorised nothing. Someone has to put them together, and that someone holds
 * no authority — every share already covers the whole transaction, so an
 * assembler that reorders, drops or forges one produces a blob the ledger
 * rejects rather than a payment nobody approved.
 *
 * Every input comes from chain data. Nothing here decides anything about the
 * payment; it decides only how to spell what the contract already authorised.
 */

import { encodeAbiParameters, keccak256 } from "viem";
import type { Address, Hex } from "viem";
import { paymentControllerAbi, treasuryRegistryAbi } from "./abi.js";
import type { Clients } from "./clients.js";
import type { Config } from "./config.js";
import { assembleMultisigned, TF_FULLY_CANONICAL_SIG } from "./serialize.js";
import type { Payment, Signer } from "./serialize.js";
import type { SignedPayment } from "./settle.js";

/** A bytes32 carrying a left-aligned 20-byte AccountID, as Solidity holds one. */
export function accountIdFromWord(word: Hex, what: string): Buffer {
  const bytes = Buffer.from(word.slice(2), "hex");
  if (bytes.length !== 32) throw new Error(`${what} is not a bytes32`);

  // The trailing twelve bytes must be zero. A non-zero tail means something
  // other than an AccountID was packed, and truncating it silently would build
  // a payment for an account nobody chose.
  if (!bytes.subarray(20).every((byte) => byte === 0)) {
    throw new Error(`${what} is not a left-aligned 20-byte AccountID`);
  }

  const id = bytes.subarray(0, 20);
  if (id.every((byte) => byte === 0)) throw new Error(`${what} is zero`);
  return id;
}

/**
 * The memo that links an XRPL transaction to the request that authorised it.
 *
 * `ExecutionVerifier` matches the FDC payment reference against
 * keccak256(abi.encode(requestId)), and the enclave builds the same value. All
 * three must agree or a settled payment can never be proven.
 */
export function requestReference(requestId: bigint): Buffer {
  return Buffer.from(keccak256(encodeAbiParameters([{ type: "uint256" }], [requestId])).slice(2), "hex");
}

/** One share, as the contract publishes it. */
export interface PartialSignature {
  readonly signerAccountId: Hex;
  readonly signerPubKey: Hex;
  readonly signature: Hex;
}

/** Converts published shares into the form the serialiser takes. */
export function toSigners(shares: readonly PartialSignature[]): Signer[] {
  return shares.map((share, index) => ({
    account: accountIdFromWord(share.signerAccountId, `share ${index} signer`),
    signingPubKey: Buffer.from(share.signerPubKey.slice(2), "hex"),
    txnSignature: Buffer.from(share.signature.slice(2), "hex"),
  }));
}

/** The request fields the assembler needs, as `getRequest` returns them. */
export interface QuorumRequest {
  readonly treasuryId: bigint;
  readonly destinationAccountId: Hex;
  readonly destinationTag: number;
  readonly amountDrops: bigint;
  readonly sequence: number;
  readonly lastLedgerSequence: number;
  readonly feeDrops: bigint;
  readonly quorumRequired: number;
}

/**
 * Builds the transaction every enclave signed.
 *
 * It has to be byte-identical to what they hashed, or none of the signatures
 * verify. That is why nothing here is a choice: the flags, the memo and the
 * field set all come from the same rules the enclave follows.
 */
export function paymentFromRequest(requestId: bigint, request: QuorumRequest, sourceAccountId: Hex): Payment {
  return {
    account: accountIdFromWord(sourceAccountId, "treasury account"),
    destination: accountIdFromWord(request.destinationAccountId, "destination"),
    amountDrops: request.amountDrops,
    feeDrops: request.feeDrops,
    sequence: request.sequence,
    lastLedgerSequence: request.lastLedgerSequence,
    destinationTag: request.destinationTag,
    flags: TF_FULLY_CANONICAL_SIG,
    memos: [{ data: requestReference(requestId) }],
  };
}

/**
 * Assembles a quorum payment from chain data alone.
 *
 * Reads the request, the treasury's XRPL account and the published shares, and
 * returns exactly what the single-signature path gets from `PaymentSigned`, so
 * everything downstream — submission, confirmation, the FDC proof — is the same
 * code taking the same input.
 */
export async function assembleQuorumPayment(
  clients: Clients,
  config: Config,
  requestId: bigint,
): Promise<SignedPayment> {
  const request = (await clients.publicClient.readContract({
    address: config.paymentController,
    abi: paymentControllerAbi,
    functionName: "getRequest",
    args: [requestId],
  })) as unknown as QuorumRequest;

  if (request.quorumRequired === 0) {
    throw new Error(`request ${requestId} was not dispatched to a quorum`);
  }

  const registry = (await clients.publicClient.readContract({
    address: config.paymentController,
    abi: paymentControllerAbi,
    functionName: "TREASURY_REGISTRY",
  })) as Address;

  const treasury = (await clients.publicClient.readContract({
    address: registry,
    abi: treasuryRegistryAbi,
    functionName: "getTreasury",
    args: [request.treasuryId],
  })) as unknown as { xrplAccountId: Hex };

  const shares = (await clients.publicClient.readContract({
    address: config.paymentController,
    abi: paymentControllerAbi,
    functionName: "partialSignaturesOf",
    args: [requestId],
  })) as unknown as readonly PartialSignature[];

  if (shares.length < request.quorumRequired) {
    // Refuse rather than submit something short. XRPL would reject it, burning
    // the fee and consuming the sequence for a transaction that delivers
    // nothing — the one outcome worse than not submitting at all.
    throw new Error(`request ${requestId} has ${shares.length} of ${request.quorumRequired} signatures`);
  }

  const payment = paymentFromRequest(requestId, request, treasury.xrplAccountId);
  const { signedBlob, txHash } = assembleMultisigned(payment, toSigners(shares));

  return {
    requestId,
    signedBlob: `0x${signedBlob.toString("hex")}`,
    txHash: `0x${txHash.toString("hex")}`,
  };
}
