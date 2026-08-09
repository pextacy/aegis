/**
 * The signature subscription.
 *
 * Two paths reach the same handler: a replay of everything between the cursor
 * and the current head, and a live websocket subscription from there on. The
 * replay is what makes a restart safe — a signature emitted while the process
 * was down is picked up rather than lost — and the on-chain terminal-state check
 * is what makes the overlap between the two harmless.
 *
 * Two events reach it too. `PaymentSigned` carries a finished blob from a
 * single-key treasury; `PaymentMultiSigned` says a quorum has been collected
 * and carries nothing, because assembling the shares is this process's job.
 * Both converge on the same `SignedPayment`, so everything downstream —
 * submission, confirmation, the FDC proof — is one code path.
 */

import { parseEventLogs } from "viem";
import type { Address, Hex, Log } from "viem";
import { paymentControllerAbi } from "./abi.js";
import type { Clients } from "./clients.js";
import type { Config } from "./config.js";
import { FileCursor } from "./cursor.js";
import { describeError, log } from "./log.js";
import { assembleQuorumPayment } from "./multisign.js";
import type { SignedPayment, Settler } from "./settle.js";

/** Reads a `PaymentSigned` log, rejecting one whose arguments did not decode. */
export function readSignedPayment(args: {
  requestId?: bigint | undefined;
  signedBlob?: Hex | undefined;
  txHash?: Hex | undefined;
}): SignedPayment {
  const { requestId, signedBlob, txHash } = args;
  if (requestId === undefined || signedBlob === undefined || txHash === undefined) {
    throw new Error("PaymentSigned log is missing an argument");
  }
  return { requestId, signedBlob, txHash };
}

/**
 * Splits a block range into windows the RPC will actually serve.
 *
 * Coston2's public RPC caps `eth_getLogs` at 30 blocks regardless of what the
 * sample configuration suggests, so a replay after a long outage has to be
 * walked rather than asked for in one call.
 */
export function chunkRange(fromBlock: bigint, toBlock: bigint, size: bigint): Array<{ from: bigint; to: bigint }> {
  if (size <= 0n) throw new Error("chunk size must be positive");
  const chunks: Array<{ from: bigint; to: bigint }> = [];
  for (let from = fromBlock; from <= toBlock; from += size) {
    const to = from + size - 1n;
    chunks.push({ from, to: to > toBlock ? toBlock : to });
  }
  return chunks;
}

export class Watcher {
  private readonly cursor: FileCursor;
  private readonly inFlight = new Set<string>();
  private stopped = false;
  private unwatch: (() => void) | undefined;

  constructor(
    private readonly config: Config,
    private readonly clients: Clients,
    private readonly settler: Settler,
  ) {
    this.cursor = new FileCursor(config.cursorFile);
  }

  /** Replays what was missed, then follows the head until `stop`. */
  async start(): Promise<void> {
    const head = await this.clients.publicClient.getBlockNumber();
    const from = this.cursor.read(this.config.startBlock);
    log.info("replaying", { fromBlock: from, toBlock: head });
    await this.replay(from, head);

    // Subscribed by address rather than by event, so both the single-key and
    // the quorum path arrive on one subscription and neither can be forgotten
    // when the other is changed.
    this.unwatch = this.clients.wsClient.watchContractEvent({
      address: this.config.paymentController,
      abi: paymentControllerAbi,
      onLogs: (logs) => {
        void this.onLogs(logs);
      },
      onError: (error) => {
        log.error("subscription error", { reason: describeError(error) });
      },
    });
    log.info("watching for signatures", { address: this.config.paymentController });
  }

  stop(): void {
    this.stopped = true;
    this.unwatch?.();
    this.unwatch = undefined;
  }

  /** Walks a closed block range, handling every `PaymentSigned` in it. */
  async replay(fromBlock: bigint, toBlock: bigint): Promise<void> {
    if (fromBlock > toBlock) return;

    for (const chunk of chunkRange(fromBlock, toBlock, this.config.logChunkBlocks)) {
      if (this.stopped) return;
      const logs = await this.clients.publicClient.getLogs({
        address: this.config.paymentController as Address,
        fromBlock: chunk.from,
        toBlock: chunk.to,
      });
      await this.onLogs(logs);
      this.cursor.write(chunk.to);
    }
  }

  private async onLogs(logs: readonly Log[]): Promise<void> {
    const signed = parseEventLogs({ abi: paymentControllerAbi, eventName: "PaymentSigned", logs: [...logs] });
    for (const entry of signed) {
      await this.handle(readSignedPayment(entry.args));
      if (entry.blockNumber !== null) this.cursor.write(entry.blockNumber);
    }

    const quorums = parseEventLogs({ abi: paymentControllerAbi, eventName: "PaymentMultiSigned", logs: [...logs] });
    for (const entry of quorums) {
      await this.handleQuorum(entry.args.requestId);
      if (entry.blockNumber !== null) this.cursor.write(entry.blockNumber);
    }
  }

  /**
   * Assembles a collected quorum, then carries it exactly as a single-key
   * signature is carried.
   *
   * An assembly that fails leaves the request in `Signed` and is retried on the
   * next replay, like every other recoverable failure here. Submitting a
   * transaction short of its quorum would be the opposite of recoverable: XRPL
   * rejects it, burning the fee and consuming the sequence for a payment that
   * delivers nothing.
   */
  private async handleQuorum(requestId: bigint | undefined): Promise<void> {
    if (requestId === undefined) {
      log.error("PaymentMultiSigned log is missing its request id");
      return;
    }

    const key = requestId.toString();
    if (this.inFlight.has(key)) {
      log.debug("already working on this request", { requestId });
      return;
    }

    let payment: SignedPayment;
    try {
      payment = await assembleQuorumPayment(this.clients, this.config, requestId);
    } catch (error) {
      log.error("could not assemble the quorum signature", { requestId, reason: describeError(error) });
      return;
    }

    log.info("assembled a quorum signature", { requestId, txHash: payment.txHash });
    await this.handle(payment);
  }

  private async handle(payment: SignedPayment): Promise<void> {
    const key = payment.requestId.toString();
    if (this.inFlight.has(key)) {
      log.debug("already working on this request", { requestId: payment.requestId });
      return;
    }
    this.inFlight.add(key);

    try {
      await this.settler.settle(payment);
    } catch (error) {
      // A payment that could not be carried to a proof stays in `Signed` and is
      // picked up on the next replay. Guessing an outcome here would be the one
      // thing this system must never do.
      log.error("settlement did not complete", {
        requestId: payment.requestId,
        reason: describeError(error),
      });
    } finally {
      this.inFlight.delete(key);
    }
  }
}
