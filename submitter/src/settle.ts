/**
 * One signed payment, carried to a proven end.
 *
 * Submit to XRPL, wait for a terminal outcome, get the matching FDC
 * attestation, and hand the proof to `ExecutionVerifier`. The submitter decides
 * *which* proof to fetch; it never decides what the proof says, and the contract
 * re-checks every field it authorised before it moves any state.
 */

import type { Hex } from "viem";
import { executionVerifierAbi, isTerminal, paymentControllerAbi, RequestState } from "./abi.js";
import type { Clients } from "./clients.js";
import type { Config } from "./config.js";
import {
  ATTESTATION_TYPE_NONEXISTENCE,
  ATTESTATION_TYPE_PAYMENT,
  decodeNonexistenceResponse,
  decodePaymentResponse,
  nonexistenceRequestBody,
  paymentRequestBody,
  prepareRequest,
  submitAttestationRequest,
  waitForProof,
} from "./fdc.js";
import type { FdcEndpoints } from "./fdc.js";
import { log } from "./log.js";
import { delivered, XrplClient } from "./xrpl.js";
import type { XrplOutcome } from "./xrpl.js";

/** A `PaymentSigned` event, decoded. */
export interface SignedPayment {
  readonly requestId: bigint;
  readonly signedBlob: Hex;
  readonly txHash: Hex;
}

/** Which `ExecutionVerifier` entry point a terminal XRPL outcome calls for. */
export type Confirmation = "confirmSettlement" | "confirmFailedExecution" | "confirmNonExecution";

/**
 * Maps a terminal XRPL outcome onto the proof that can settle it.
 *
 * A validated transaction always takes a `Payment` attestation, whether or not
 * it delivered — the transaction exists, and its sequence is spent either way.
 * Only a transaction that never reached a ledger takes the non-existence path.
 */
export function chooseConfirmation(outcome: XrplOutcome): Confirmation {
  if (outcome.kind === "expired") return "confirmNonExecution";
  return delivered(outcome) ? "confirmSettlement" : "confirmFailedExecution";
}

/** XRPL wants blobs and hashes as bare uppercase hex. */
export function toXrplHex(value: Hex): string {
  return value.slice(2).toUpperCase();
}

export class Settler {
  private readonly endpoints: FdcEndpoints;

  constructor(
    private readonly config: Config,
    private readonly clients: Clients,
  ) {
    this.endpoints = {
      verifierUrl: config.fdcVerifierUrl,
      verifierApiKey: config.fdcVerifierApiKey,
      daLayerUrl: config.daLayerUrl,
    };
  }

  /**
   * Carries one payment to a proven end.
   *
   * Returns without acting when the request is already terminal — which is what
   * a second submitter finds, and what this submitter finds after a restart.
   */
  async settle(payment: SignedPayment): Promise<void> {
    const request = await this.clients.publicClient.readContract({
      address: this.config.paymentController,
      abi: paymentControllerAbi,
      functionName: "getRequest",
      args: [payment.requestId],
    });

    const state = request.state as RequestState;
    if (isTerminal(state)) {
      log.info("request already finished", { requestId: payment.requestId, state });
      return;
    }
    if (state !== RequestState.Signed) {
      log.warn("request is not awaiting settlement", { requestId: payment.requestId, state });
      return;
    }

    const xrpl = await XrplClient.connect(this.config.xrplWsUrl);
    try {
      const outcome = await xrpl.submitAndConfirm(
        toXrplHex(payment.signedBlob),
        toXrplHex(payment.txHash),
        request.lastLedgerSequence,
        this.config.confirmSlackLedgers,
      );
      const confirmation = chooseConfirmation(outcome);
      log.info("xrpl outcome", { requestId: payment.requestId, outcome: outcome.kind, confirmation });

      const requestBytes =
        outcome.kind === "validated"
          ? await prepareRequest(this.endpoints, ATTESTATION_TYPE_PAYMENT, paymentRequestBody(payment.txHash))
          : await prepareRequest(
              this.endpoints,
              ATTESTATION_TYPE_NONEXISTENCE,
              nonexistenceRequestBody({
                firstLedgerSequence: request.firstLedgerSequence,
                lastLedgerSequence: request.lastLedgerSequence,
                deadlineTimestamp: await xrpl.ledgerCloseTime(request.lastLedgerSequence),
                destinationAddressHash: await this.addressHashOf(request.destinationAccountId),
                amountDrops: request.amountDrops,
                standardPaymentReference: await this.requestReference(payment.requestId),
              }),
            );

      const submission = await submitAttestationRequest(
        { publicClient: this.clients.publicClient, walletClient: this.clients.walletClient },
        {
          fdcHub: this.config.fdcHub,
          fdcRequestFeeConfigurations: this.config.fdcRequestFeeConfigurations,
          flareSystemsManager: this.config.flareSystemsManager,
        },
        requestBytes,
      );

      const proof = await waitForProof(this.endpoints, submission, {
        pollIntervalMs: this.config.proofPollIntervalMs,
        timeoutMs: this.config.proofTimeoutMs,
      });

      const hash = await this.confirm(payment.requestId, confirmation, proof.merkleProof, proof.responseHex);
      log.info("proof submitted", { requestId: payment.requestId, confirmation, transactionHash: hash });
    } finally {
      xrpl.close();
    }
  }

  private async addressHashOf(xrplAccountId: Hex): Promise<Hex> {
    return this.clients.publicClient.readContract({
      address: this.config.executionVerifier,
      abi: executionVerifierAbi,
      functionName: "addressHashOf",
      args: [xrplAccountId],
    });
  }

  private async requestReference(requestId: bigint): Promise<Hex> {
    return this.clients.publicClient.readContract({
      address: this.config.executionVerifier,
      abi: executionVerifierAbi,
      functionName: "requestReference",
      args: [requestId],
    });
  }

  private async confirm(
    requestId: bigint,
    confirmation: Confirmation,
    merkleProof: readonly Hex[],
    responseHex: Hex,
  ): Promise<Hex> {
    const { walletClient, publicClient, chain } = this.clients;
    const account = walletClient.account;
    if (account === undefined) throw new Error("wallet client has no account");

    const hash =
      confirmation === "confirmNonExecution"
        ? await walletClient.writeContract({
            address: this.config.executionVerifier,
            abi: executionVerifierAbi,
            functionName: "confirmNonExecution",
            args: [requestId, { merkleProof: [...merkleProof], data: decodeNonexistenceResponse(responseHex) }],
            account,
            chain,
          })
        : await walletClient.writeContract({
            address: this.config.executionVerifier,
            abi: executionVerifierAbi,
            functionName: confirmation,
            args: [requestId, { merkleProof: [...merkleProof], data: decodePaymentResponse(responseHex) }],
            account,
            chain,
          });

    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") throw new Error(`${confirmation} reverted: ${hash}`);
    return hash;
  }
}
