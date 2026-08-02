/**
 * XRPL Testnet client: submit a signed blob and wait for one of the two
 * terminal outcomes.
 *
 * There are exactly two: the transaction is validated in a ledger, or the
 * network moves past `LastLedgerSequence` without it. Anything else is "not yet
 * known", and this module refuses to turn that into a conclusion — an undecided
 * payment is retried later, never guessed at.
 *
 * `submit` is deliberately not treated as authoritative. Two submitters racing
 * on the same blob means one of them gets a duplicate-transaction error for a
 * payment that is about to settle perfectly well. Only the ledger decides.
 */

import WebSocket from "ws";
import { log } from "./log.js";

/** Seconds between the XRPL epoch (2000-01-01) and the Unix epoch. */
export const XRPL_EPOCH_OFFSET_SECONDS = 946_684_800;

/** The result code XRPL gives a payment that delivered. */
export const TES_SUCCESS = "tesSUCCESS";

/** What a `tx` lookup found. */
export type XrplTxLookup =
  | { readonly kind: "missing" }
  | { readonly kind: "pending" }
  | { readonly kind: "validated"; readonly ledgerIndex: number; readonly transactionResult: string };

/** A terminal outcome for a submitted payment. */
export type XrplOutcome =
  | { readonly kind: "validated"; readonly ledgerIndex: number; readonly transactionResult: string }
  | { readonly kind: "expired"; readonly lastLedgerSequence: number; readonly currentLedgerIndex: number };

export class XrplError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "XrplError";
  }
}

/** Raised when neither terminal outcome was reached within the polling budget. */
export class XrplUndecided extends Error {
  constructor(
    readonly lastLedgerSequence: number,
    readonly currentLedgerIndex: number,
  ) {
    super(
      `no terminal outcome by ledger ${currentLedgerIndex} for a transaction expiring at ${lastLedgerSequence}`,
    );
    this.name = "XrplUndecided";
  }
}

/**
 * Decides whether a lookup at a given ledger height is terminal.
 *
 * A transaction that is present but not yet validated is not terminal even past
 * its expiry: it is sitting in an open ledger and the next close resolves it
 * either way. A transaction that is absent once the network is past
 * `LastLedgerSequence` can never appear, because XRPL will not apply it.
 *
 * @returns The terminal outcome, or `undefined` while it is still undecided.
 */
export function classifyOutcome(
  lookup: XrplTxLookup,
  currentLedgerIndex: number,
  lastLedgerSequence: number,
): XrplOutcome | undefined {
  if (lookup.kind === "validated") {
    return { kind: "validated", ledgerIndex: lookup.ledgerIndex, transactionResult: lookup.transactionResult };
  }
  if (lookup.kind === "missing" && currentLedgerIndex > lastLedgerSequence) {
    return { kind: "expired", lastLedgerSequence, currentLedgerIndex };
  }
  return undefined;
}

/** Whether a validated outcome actually delivered the payment. */
export function delivered(outcome: XrplOutcome): boolean {
  return outcome.kind === "validated" && outcome.transactionResult === TES_SUCCESS;
}

function asRecord(value: unknown, what: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null) throw new XrplError(`${what} is not an object`);
  return value as Record<string, unknown>;
}

function asNumber(value: unknown, what: string): number {
  if (typeof value !== "number" || !Number.isFinite(value)) throw new XrplError(`${what} is not a number`);
  return value;
}

function asString(value: unknown, what: string): string {
  if (typeof value !== "string") throw new XrplError(`${what} is not a string`);
  return value;
}

interface PendingRequest {
  resolve: (result: Record<string, unknown>) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
}

interface LedgerWaiter {
  resolve: (ledgerIndex: number) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
}

/** Result of `submit`, kept for the log rather than for a decision. */
export interface XrplSubmitReport {
  readonly engineResult: string;
  readonly accepted: boolean;
}

export class XrplClient {
  private nextId = 1;
  private readonly pending = new Map<number, PendingRequest>();
  private readonly ledgerWaiters: LedgerWaiter[] = [];
  private latestLedgerIndex = 0;
  private closed = false;

  private constructor(
    private readonly socket: WebSocket,
    private readonly requestTimeoutMs: number,
  ) {
    socket.on("message", (raw: WebSocket.RawData) => this.onMessage(raw));
    socket.on("close", () => this.failAll(new XrplError("connection closed")));
    socket.on("error", (error: Error) => this.failAll(new XrplError(`connection error: ${error.message}`)));
  }

  /** Opens a connection and subscribes to ledger closes. */
  static async connect(url: string, requestTimeoutMs = 20_000): Promise<XrplClient> {
    const socket = new WebSocket(url);
    await new Promise<void>((resolve, reject) => {
      const onOpen = (): void => {
        socket.off("error", onError);
        resolve();
      };
      const onError = (error: Error): void => {
        socket.off("open", onOpen);
        reject(new XrplError(`could not connect to ${url}: ${error.message}`));
      };
      socket.once("open", onOpen);
      socket.once("error", onError);
    });

    const client = new XrplClient(socket, requestTimeoutMs);
    const subscription = await client.request("subscribe", { streams: ["ledger"] });
    client.latestLedgerIndex = asNumber(subscription["ledger_index"], "subscribe ledger_index");
    return client;
  }

  /** The most recent ledger index this client has observed. */
  get ledgerIndex(): number {
    return this.latestLedgerIndex;
  }

  close(): void {
    this.closed = true;
    this.socket.close();
  }

  /** Sends a command and resolves with its `result` object. */
  async request(command: string, params: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
    if (this.closed) throw new XrplError("client is closed");
    const id = this.nextId++;

    return new Promise<Record<string, unknown>>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new XrplError(`${command} timed out`));
      }, this.requestTimeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      this.socket.send(JSON.stringify({ id, command, ...params }));
    });
  }

  /** Broadcasts a signed transaction blob. */
  async submit(txBlob: string): Promise<XrplSubmitReport> {
    const result = await this.request("submit", { tx_blob: txBlob });
    return {
      engineResult: asString(result["engine_result"], "submit engine_result"),
      accepted: result["accepted"] === true,
    };
  }

  /** Looks a transaction up by hash. */
  async lookupTx(transactionHash: string): Promise<XrplTxLookup> {
    let result: Record<string, unknown>;
    try {
      result = await this.request("tx", { transaction: transactionHash, binary: false });
    } catch (error) {
      if (error instanceof XrplError && error.message.includes("txnNotFound")) return { kind: "missing" };
      throw error;
    }

    if (result["validated"] !== true) return { kind: "pending" };

    const meta = asRecord(result["meta"] ?? result["metaData"], "tx meta");
    return {
      kind: "validated",
      ledgerIndex: asNumber(result["ledger_index"], "tx ledger_index"),
      transactionResult: asString(meta["TransactionResult"], "tx meta.TransactionResult"),
    };
  }

  /** The Unix close time of a validated ledger. */
  async ledgerCloseTime(ledgerIndex: number): Promise<number> {
    const result = await this.request("ledger", { ledger_index: ledgerIndex });
    const ledger = asRecord(result["ledger"], "ledger");
    const closeTime = asNumber(ledger["close_time"], "ledger close_time");
    return closeTime + XRPL_EPOCH_OFFSET_SECONDS;
  }

  /**
   * Resolves when the next ledger closes.
   *
   * @param timeoutMs How long to wait. XRPL closes a ledger every three to five
   * seconds; a long silence means the connection is dead, not that the network
   * is quiet, so waiting forever would strand the payment.
   */
  async nextLedger(timeoutMs = 60_000): Promise<number> {
    if (this.closed) throw new XrplError("client is closed");
    return new Promise<number>((resolve, reject) => {
      const waiter: LedgerWaiter = {
        resolve,
        reject,
        timer: setTimeout(() => {
          const index = this.ledgerWaiters.indexOf(waiter);
          if (index >= 0) this.ledgerWaiters.splice(index, 1);
          reject(new XrplError(`no ledger closed within ${timeoutMs}ms`));
        }, timeoutMs),
      };
      this.ledgerWaiters.push(waiter);
    });
  }

  /**
   * Submits and waits for a terminal outcome.
   *
   * @param txBlob The signed transaction, hex.
   * @param transactionHash The transaction id the enclave computed.
   * @param lastLedgerSequence The ledger the transaction expires after.
   * @param slackLedgers How many closes past expiry to keep looking before
   * refusing to decide.
   */
  async submitAndConfirm(
    txBlob: string,
    transactionHash: string,
    lastLedgerSequence: number,
    slackLedgers: number,
  ): Promise<XrplOutcome> {
    const report = await this.submit(txBlob);
    log.info("submitted to xrpl", {
      txHash: transactionHash,
      engineResult: report.engineResult,
      accepted: report.accepted,
    });

    const giveUpAfter = lastLedgerSequence + slackLedgers;
    for (;;) {
      const lookup = await this.lookupTx(transactionHash);
      const outcome = classifyOutcome(lookup, this.latestLedgerIndex, lastLedgerSequence);
      if (outcome !== undefined) return outcome;

      if (this.latestLedgerIndex > giveUpAfter) {
        throw new XrplUndecided(lastLedgerSequence, this.latestLedgerIndex);
      }
      await this.nextLedger();
    }
  }

  private onMessage(raw: WebSocket.RawData): void {
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw.toString());
    } catch {
      log.warn("xrpl sent a message that is not JSON");
      return;
    }
    const message = parsed as Record<string, unknown>;

    if (message["type"] === "ledgerClosed") {
      this.latestLedgerIndex = asNumber(message["ledger_index"], "ledgerClosed ledger_index");
      const waiters = this.ledgerWaiters.splice(0, this.ledgerWaiters.length);
      for (const waiter of waiters) {
        clearTimeout(waiter.timer);
        waiter.resolve(this.latestLedgerIndex);
      }
      return;
    }

    const id = message["id"];
    if (typeof id !== "number") return;
    const entry = this.pending.get(id);
    if (entry === undefined) return;
    this.pending.delete(id);
    clearTimeout(entry.timer);

    if (message["status"] === "success") {
      entry.resolve(asRecord(message["result"], "response result"));
      return;
    }
    const code = typeof message["error"] === "string" ? message["error"] : "unknown";
    const detail = typeof message["error_message"] === "string" ? message["error_message"] : "";
    entry.reject(new XrplError(`xrpl returned ${code}${detail === "" ? "" : `: ${detail}`}`));
  }

  private failAll(error: Error): void {
    const entries = [...this.pending.values()];
    this.pending.clear();
    for (const entry of entries) {
      clearTimeout(entry.timer);
      entry.reject(error);
    }

    // A waiter left hanging on a dead socket is a payment left in limbo.
    const waiters = this.ledgerWaiters.splice(0, this.ledgerWaiters.length);
    for (const waiter of waiters) {
      clearTimeout(waiter.timer);
      waiter.reject(error);
    }
  }
}
