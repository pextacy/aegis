/**
 * Flare Data Connector: turn something that happened on XRPL into a proof
 * Coston2 will accept.
 *
 * Four steps, none of them skippable. The verifier server encodes the request
 * and vouches that it can be answered; `FdcHub` puts it into a voting round;
 * the round finalises; the DA layer serves the Merkle proof against the root
 * that was finalised. The submitter pays the request fee and nothing else — it
 * has no way to influence the answer.
 */

import { decodeAbiParameters, stringToHex } from "viem";
import type { Address, Hex, PublicClient, WalletClient } from "viem";
import {
  fdcHubAbi,
  fdcRequestFeeConfigurationsAbi,
  flareSystemsManagerAbi,
  nonexistenceResponseParameters,
  paymentResponseParameters,
} from "./abi.js";
import { log } from "./log.js";

/** The two attestation types Aegis uses, as FDC names them. */
export const ATTESTATION_TYPE_PAYMENT = "Payment";
export const ATTESTATION_TYPE_NONEXISTENCE = "ReferencedPaymentNonexistence";

/** FDC source id for XRPL Testnet. */
export const SOURCE_ID_TEST_XRP = "testXRP";

/** FDC identifies types and sources as right-padded UTF-8 in a bytes32. */
export function toBytes32Name(name: string): Hex {
  return stringToHex(name, { size: 32 });
}

export class FdcError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "FdcError";
  }
}

/** The `Payment` request body, as the verifier server takes it. */
export interface PaymentRequestBody {
  readonly transactionId: Hex;
  readonly inUtxo: string;
  readonly utxo: string;
}

/** The `ReferencedPaymentNonexistence` request body. */
export interface NonexistenceRequestBody {
  readonly minimalBlockNumber: string;
  readonly deadlineBlockNumber: string;
  readonly deadlineTimestamp: string;
  readonly destinationAddressHash: Hex;
  readonly amount: string;
  readonly standardPaymentReference: Hex;
  readonly checkSourceAddresses: boolean;
  readonly sourceAddressesRoot: Hex;
}

/** Builds the `Payment` request body for a transaction the enclave signed. */
export function paymentRequestBody(transactionId: Hex): PaymentRequestBody {
  return { transactionId, inUtxo: "0", utxo: "0" };
}

/**
 * Builds the `ReferencedPaymentNonexistence` request body for a request that
 * expired.
 *
 * The searched range is exactly the range the payment could have reached:
 * `firstLedgerSequence` is the ledger current when the payment was dispatched
 * and `lastLedgerSequence` is the one it expires after. `ExecutionVerifier`
 * checks both bounds, so a narrower range here is rejected on-chain rather than
 * quietly proving less than it appears to.
 */
export function nonexistenceRequestBody(args: {
  firstLedgerSequence: number;
  lastLedgerSequence: number;
  deadlineTimestamp: number;
  destinationAddressHash: Hex;
  amountDrops: bigint;
  standardPaymentReference: Hex;
}): NonexistenceRequestBody {
  return {
    minimalBlockNumber: String(args.firstLedgerSequence),
    deadlineBlockNumber: String(args.lastLedgerSequence),
    deadlineTimestamp: String(args.deadlineTimestamp),
    destinationAddressHash: args.destinationAddressHash,
    amount: args.amountDrops.toString(),
    standardPaymentReference: args.standardPaymentReference,
    checkSourceAddresses: false,
    sourceAddressesRoot: `0x${"0".repeat(64)}`,
  };
}

/** Where the verifier server exposes an attestation type for XRPL. */
export function prepareRequestUrl(baseUrl: string, attestationType: string): string {
  return `${baseUrl.replace(/\/+$/, "")}/verifier/xrp/${attestationType}/prepareRequest`;
}

/** Where the DA layer serves proofs. */
export function proofUrl(baseUrl: string): string {
  return `${baseUrl.replace(/\/+$/, "")}/api/v1/fdc/proof-by-request-round-raw`;
}

/** Reads `abiEncodedRequest` out of a verifier response, rejecting anything else. */
export function readPreparedRequest(payload: unknown): Hex {
  if (typeof payload !== "object" || payload === null) throw new FdcError("verifier response is not an object");
  const record = payload as Record<string, unknown>;

  const status = record["status"];
  if (status !== "VALID") {
    throw new FdcError(`verifier refused the request with status ${JSON.stringify(status)}`);
  }

  const encoded = record["abiEncodedRequest"];
  if (typeof encoded !== "string" || !encoded.startsWith("0x")) {
    throw new FdcError("verifier response has no abiEncodedRequest");
  }
  return encoded as Hex;
}

/** The DA layer's raw proof response. */
export interface RawProof {
  readonly merkleProof: readonly Hex[];
  readonly responseHex: Hex;
}

/** Reads a DA layer proof, rejecting a body that is not yet a complete proof. */
export function readRawProof(payload: unknown): RawProof {
  if (typeof payload !== "object" || payload === null) throw new FdcError("proof response is not an object");
  const record = payload as Record<string, unknown>;

  const responseHex = record["response_hex"];
  if (typeof responseHex !== "string" || !responseHex.startsWith("0x") || responseHex.length <= 2) {
    throw new FdcError("proof response has no response_hex");
  }

  const proof = record["proof"];
  if (!Array.isArray(proof)) throw new FdcError("proof response has no proof array");
  const merkleProof = proof.map((node, index) => {
    if (typeof node !== "string" || !node.startsWith("0x")) {
      throw new FdcError(`proof node ${index} is not hex`);
    }
    return node as Hex;
  });

  return { merkleProof, responseHex: responseHex as Hex };
}

/** The voting round an attestation request lands in. */
export function votingRoundOf(blockTimestamp: bigint, firstVotingRoundStartTs: bigint, epochSeconds: bigint): number {
  if (epochSeconds === 0n) throw new FdcError("voting epoch duration is zero");
  if (blockTimestamp < firstVotingRoundStartTs) {
    throw new FdcError("block predates the first voting round");
  }
  return Number((blockTimestamp - firstVotingRoundStartTs) / epochSeconds);
}

export interface FdcEndpoints {
  readonly verifierUrl: string;
  readonly verifierApiKey: string;
  readonly daLayerUrl: string;
}

type Fetch = typeof globalThis.fetch;

/** Asks the verifier server to encode and vouch for an attestation request. */
export async function prepareRequest(
  endpoints: FdcEndpoints,
  attestationType: string,
  requestBody: PaymentRequestBody | NonexistenceRequestBody,
  fetchImpl: Fetch = globalThis.fetch,
): Promise<Hex> {
  const response = await fetchImpl(prepareRequestUrl(endpoints.verifierUrl, attestationType), {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-API-KEY": endpoints.verifierApiKey },
    body: JSON.stringify({
      attestationType: toBytes32Name(attestationType),
      sourceId: toBytes32Name(SOURCE_ID_TEST_XRP),
      requestBody,
    }),
  });

  if (!response.ok) {
    throw new FdcError(`verifier returned ${response.status} for ${attestationType}: ${await response.text()}`);
  }
  return readPreparedRequest(await response.json());
}

export interface AttestationSubmission {
  readonly votingRoundId: number;
  readonly requestBytes: Hex;
  readonly transactionHash: Hex;
}

/**
 * Puts a prepared request into a voting round.
 *
 * The fee is read from `FdcRequestFeeConfigurations` for this exact request
 * rather than guessed, because an underpaid request is dropped silently by the
 * round and the payment would then look unprovable.
 */
export async function submitAttestationRequest(
  clients: { publicClient: PublicClient; walletClient: WalletClient },
  addresses: { fdcHub: Address; fdcRequestFeeConfigurations: Address; flareSystemsManager: Address },
  requestBytes: Hex,
): Promise<AttestationSubmission> {
  const { publicClient, walletClient } = clients;
  const account = walletClient.account;
  if (account === undefined) throw new FdcError("wallet client has no account");

  const fee = await publicClient.readContract({
    address: addresses.fdcRequestFeeConfigurations,
    abi: fdcRequestFeeConfigurationsAbi,
    functionName: "getRequestFee",
    args: [requestBytes],
  });

  const transactionHash = await walletClient.writeContract({
    address: addresses.fdcHub,
    abi: fdcHubAbi,
    functionName: "requestAttestation",
    args: [requestBytes],
    value: fee,
    account,
    chain: walletClient.chain ?? null,
  });

  const receipt = await publicClient.waitForTransactionReceipt({ hash: transactionHash });
  if (receipt.status !== "success") throw new FdcError(`attestation request reverted: ${transactionHash}`);

  const block = await publicClient.getBlock({ blockNumber: receipt.blockNumber });

  const [firstVotingRoundStartTs, epochSeconds] = await Promise.all([
    publicClient.readContract({
      address: addresses.flareSystemsManager,
      abi: flareSystemsManagerAbi,
      functionName: "firstVotingRoundStartTs",
    }),
    publicClient.readContract({
      address: addresses.flareSystemsManager,
      abi: flareSystemsManagerAbi,
      functionName: "votingEpochDurationSeconds",
    }),
  ]);

  const votingRoundId = votingRoundOf(block.timestamp, firstVotingRoundStartTs, epochSeconds);
  log.info("attestation requested", { votingRoundId, fee, transactionHash });

  return { votingRoundId, requestBytes, transactionHash };
}

/**
 * Polls the DA layer until the round is finalised and the proof is served.
 *
 * A round that never finalises times out rather than looping forever; the
 * request stays in `Signed` and is retried, which is the same refusal-to-guess
 * the rest of the system makes.
 */
export async function waitForProof(
  endpoints: FdcEndpoints,
  submission: AttestationSubmission,
  options: { pollIntervalMs: number; timeoutMs: number },
  fetchImpl: Fetch = globalThis.fetch,
  sleep: (ms: number) => Promise<void> = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  now: () => number = () => Date.now(),
): Promise<RawProof> {
  const deadline = now() + options.timeoutMs;

  for (;;) {
    const response = await fetchImpl(proofUrl(endpoints.daLayerUrl), {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-API-KEY": endpoints.verifierApiKey },
      body: JSON.stringify({ votingRoundId: submission.votingRoundId, requestBytes: submission.requestBytes }),
    });

    if (response.ok) {
      const payload: unknown = await response.json();
      try {
        return readRawProof(payload);
      } catch (error) {
        if (!(error instanceof FdcError)) throw error;
        log.debug("proof not served yet", { votingRoundId: submission.votingRoundId, reason: error.message });
      }
    } else if (response.status !== 404 && response.status !== 400) {
      throw new FdcError(`DA layer returned ${response.status}: ${await response.text()}`);
    }

    if (now() >= deadline) {
      throw new FdcError(`no proof for voting round ${submission.votingRoundId} within ${options.timeoutMs}ms`);
    }
    await sleep(options.pollIntervalMs);
  }
}

/** The decoded `Payment` response, in the shape `ExecutionVerifier` takes. */
export type PaymentResponse = ReturnType<typeof decodePaymentResponse>;
/** The decoded `ReferencedPaymentNonexistence` response. */
export type NonexistenceResponse = ReturnType<typeof decodeNonexistenceResponse>;

/** Decodes `abi.encode(IPayment.Response)`. */
export function decodePaymentResponse(responseHex: Hex) {
  const [response] = decodeAbiParameters(paymentResponseParameters, responseHex);
  return response;
}

/** Decodes `abi.encode(IReferencedPaymentNonexistence.Response)`. */
export function decodeNonexistenceResponse(responseHex: Hex) {
  const [response] = decodeAbiParameters(nonexistenceResponseParameters, responseHex);
  return response;
}
