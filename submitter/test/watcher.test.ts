import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { encodeAbiParameters, encodeEventTopics } from "viem";
import type { Address, Hex, Log } from "viem";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { paymentControllerAbi } from "../src/abi.js";
import type { Clients } from "../src/clients.js";
import type { Config } from "../src/config.js";
import { FileCursor } from "../src/cursor.js";
import type { Settler, SignedPayment } from "../src/settle.js";
import { chunkRange, readSignedPayment, Watcher } from "../src/watcher.js";

const CONTROLLER = "0xaEd2aCa19C6F54926F8482648A694E7cb62baA22" as Address;
const BLOB = "0x120000228000000024000000016140000000000f4240" as Hex;
const TX_HASH = `0x${"ab".repeat(32)}` as Hex;

/** Builds a `PaymentSigned` log the way the chain would emit it. */
function signedLog(requestId: bigint, blockNumber: bigint, logIndex: number): Log {
  // `requestId` is the only indexed argument, so every topic is a plain value.
  const topics = encodeEventTopics({
    abi: paymentControllerAbi,
    eventName: "PaymentSigned",
    args: { requestId },
  }) as [Hex, ...Hex[]];

  return {
    address: CONTROLLER,
    topics,
    data: encodeAbiParameters([{ type: "bytes" }, { type: "bytes32" }], [BLOB, TX_HASH]),
    blockNumber,
    blockHash: `0x${"11".repeat(32)}` as Hex,
    transactionHash: `0x${"22".repeat(32)}` as Hex,
    transactionIndex: 0,
    logIndex,
    removed: false,
  };
}

/** A settler the test drives, standing in for the XRPL and FDC round trip. */
class RecordingSettler {
  readonly seen: SignedPayment[] = [];
  private release: (() => void) | undefined;

  constructor(private readonly block = false) {}

  async settle(payment: SignedPayment): Promise<void> {
    this.seen.push(payment);
    if (!this.block) return;
    await new Promise<void>((resolve) => {
      this.release = resolve;
    });
  }

  finish(): void {
    this.release?.();
  }
}

/**
 * Builds a `PaymentMultiSigned` log. It carries no blob: the shares are
 * published one by one and putting them together is the submitter's job.
 */
function multiSignedLog(requestId: bigint, blockNumber: bigint, logIndex: number): Log {
  const topics = encodeEventTopics({
    abi: paymentControllerAbi,
    eventName: "PaymentMultiSigned",
    args: { requestId, treasuryId: 1n },
  }) as [Hex, ...Hex[]];

  return {
    address: CONTROLLER,
    topics,
    data: encodeAbiParameters([{ type: "uint8" }, { type: "uint8" }], [2, 2]),
    blockNumber,
    blockHash: `0x${"11".repeat(32)}` as Hex,
    transactionHash: `0x${"33".repeat(32)}` as Hex,
    transactionIndex: 0,
    logIndex,
    removed: false,
  };
}

/** The chain reads the assembler makes, answered from a real reference. */
const QUORUM_READS: Record<string, unknown> = {
  getRequest: {
    treasuryId: 1n,
    destinationAccountId: `0x${"350f40a56d86d57ed58408028117b8f29a99281c"}${"00".repeat(12)}`,
    destinationTag: 96372801,
    amountDrops: 10982337n,
    sequence: 382435,
    lastLedgerSequence: 106193253,
    feeDrops: 50000n,
    quorumRequired: 2,
  },
  TREASURY_REGISTRY: "0x1111111111111111111111111111111111111111",
  getTreasury: { xrplAccountId: `0x${"8421a3546bbe20c59c18c9d03c3ed146e967520b"}${"00".repeat(12)}` },
  partialSignaturesOf: [
    {
      signerAccountId: `0x${"e6deed4ec3c93ab52c5334f33e645775fd5f58d7"}${"00".repeat(12)}`,
      signerPubKey: "0x028a4e362a90b01687cf26f2351fdfd1725fe7638f341453a2601dc562ce83f91d",
      signature:
        "0x3045022100a42b08693b348f2f6a7e1cfd21f2c5ba0477c901fb1dbafa62ee96410abbc21002203588d202c8074bdb0f88a85143fe77089b354d452a6a284bae62fc720c2e5aa3",
    },
    {
      signerAccountId: `0x${"ee218394f528741b2de1ff8b9922c2b2df23f4fb"}${"00".repeat(12)}`,
      signerPubKey: "0x02c6478ef003b4cf203a1040e6784a5fee2cf5fea34ea7420e3ae1538c38bd26ba",
      signature:
        "0x3044022059080417c896697ee10484be72c0643c5f1d67426241665d0f5a34312a5a8a63022075af9844112fa3b83706b46fc3d7543250bb108e94b7c5038878bcd5847acbef",
    },
  ],
};

function watcherOver(
  logs: Log[],
  settler: RecordingSettler,
  cursorFile: string,
  chunk = 30n,
  reads: Record<string, unknown> = QUORUM_READS,
): Watcher {
  const config = {
    paymentController: CONTROLLER,
    cursorFile,
    startBlock: 100n,
    logChunkBlocks: chunk,
  } as unknown as Config;

  const clients = {
    publicClient: {
      getLogs: async ({ fromBlock, toBlock }: { fromBlock: bigint; toBlock: bigint }): Promise<Log[]> =>
        logs.filter((entry) => entry.blockNumber !== null && entry.blockNumber >= fromBlock && entry.blockNumber <= toBlock),
      readContract: async ({ functionName }: { functionName: string }): Promise<unknown> => {
        if (!(functionName in reads)) throw new Error(`unexpected read: ${functionName}`);
        return reads[functionName];
      },
    },
  } as unknown as Clients;

  return new Watcher(config, clients, settler as unknown as Settler);
}

describe("chunkRange", () => {
  // The public Coston2 RPC caps eth_getLogs at 30 blocks, so a long outage has
  // to be walked rather than asked for in one call.
  it("splits a wide range into windows the RPC will serve", () => {
    expect(chunkRange(1n, 65n, 30n)).toEqual([
      { from: 1n, to: 30n },
      { from: 31n, to: 60n },
      { from: 61n, to: 65n },
    ]);
  });

  it("returns a single window when the range already fits", () => {
    expect(chunkRange(10n, 12n, 30n)).toEqual([{ from: 10n, to: 12n }]);
  });

  it("handles a single block", () => {
    expect(chunkRange(10n, 10n, 30n)).toEqual([{ from: 10n, to: 10n }]);
  });

  it("refuses a zero window rather than looping forever", () => {
    expect(() => chunkRange(1n, 10n, 0n)).toThrow(/chunk size must be positive/);
  });
});

describe("readSignedPayment", () => {
  it("reads a decoded log", () => {
    expect(readSignedPayment({ requestId: 7n, signedBlob: BLOB, txHash: TX_HASH })).toEqual({
      requestId: 7n,
      signedBlob: BLOB,
      txHash: TX_HASH,
    });
  });

  it("refuses a log whose arguments did not decode", () => {
    expect(() => readSignedPayment({ requestId: 7n, signedBlob: BLOB })).toThrow(/missing an argument/);
  });
});

describe("replay", () => {
  let directory: string;
  let cursorFile: string;

  beforeEach(() => {
    directory = mkdtempSync(join(tmpdir(), "aegis-watcher-"));
    cursorFile = join(directory, "cursor.json");
  });

  afterEach(() => {
    rmSync(directory, { recursive: true, force: true });
  });

  it("hands every signature in the range to the settler", async () => {
    const settler = new RecordingSettler();
    const watcher = watcherOver([signedLog(1n, 100n, 0), signedLog(2n, 140n, 0)], settler, cursorFile);

    await watcher.replay(100n, 140n);

    expect(settler.seen.map((payment) => payment.requestId)).toEqual([1n, 2n]);
    expect(settler.seen[0]?.signedBlob).toBe(BLOB);
    expect(settler.seen[0]?.txHash).toBe(TX_HASH);
  });

  it("records how far it got, so a restart does not replay from the deployment", async () => {
    const settler = new RecordingSettler();
    const watcher = watcherOver([signedLog(1n, 100n, 0)], settler, cursorFile);

    await watcher.replay(100n, 160n);

    expect(new FileCursor(cursorFile).read(0n)).toBe(160n);
  });

  it("does nothing when the head has not moved", async () => {
    const settler = new RecordingSettler();
    const watcher = watcherOver([signedLog(1n, 100n, 0)], settler, cursorFile);

    await watcher.replay(101n, 100n);

    expect(settler.seen).toEqual([]);
  });

  // Two submitters is the expected deployment; two overlapping passes inside
  // one is what a reconnect produces. Neither may start the same payment twice.
  it("does not start a request that is already in flight", async () => {
    const settler = new RecordingSettler(true);
    const watcher = watcherOver([signedLog(1n, 100n, 0)], settler, cursorFile);

    const first = watcher.replay(100n, 100n);
    await Promise.resolve();
    const second = watcher.replay(100n, 100n);

    settler.finish();
    await Promise.all([first, second]);

    expect(settler.seen).toHaveLength(1);
  });

  it("keeps going when one payment cannot be carried to a proof", async () => {
    const failing = {
      seen: [] as SignedPayment[],
      async settle(payment: SignedPayment): Promise<void> {
        this.seen.push(payment);
        if (payment.requestId === 1n) throw new Error("DA layer unreachable");
      },
    };
    const watcher = watcherOver(
      [signedLog(1n, 100n, 0), signedLog(2n, 101n, 0)],
      failing as unknown as RecordingSettler,
      cursorFile,
    );

    await watcher.replay(100n, 101n);

    expect(failing.seen.map((payment) => payment.requestId)).toEqual([1n, 2n]);
  });
});

describe("the quorum path", () => {
  let directory: string;
  let cursorFile: string;

  beforeEach(() => {
    directory = mkdtempSync(join(tmpdir(), "aegis-watcher-quorum-"));
    cursorFile = join(directory, "cursor.json");
  });

  afterEach(() => {
    rmSync(directory, { recursive: true, force: true });
  });

  /**
   * A k-of-n payment reaches the settler as the same `SignedPayment` a
   * single-key one does, so submission, confirmation and the FDC proof are one
   * code path rather than two that can drift.
   */
  it("assembles a collected quorum and hands it on like any other signature", async () => {
    const settler = new RecordingSettler();
    const watcher = watcherOver([multiSignedLog(9n, 100n, 0)], settler, cursorFile);

    await watcher.replay(100n, 100n);

    expect(settler.seen).toHaveLength(1);
    expect(settler.seen[0]?.requestId).toBe(9n);
    expect(settler.seen[0]?.signedBlob.startsWith("0x12000022")).toBe(true);
    expect(settler.seen[0]?.txHash).toHaveLength(66);
  });

  it("carries both kinds of signature in one pass", async () => {
    const settler = new RecordingSettler();
    const watcher = watcherOver([signedLog(1n, 100n, 0), multiSignedLog(9n, 101n, 0)], settler, cursorFile);

    await watcher.replay(100n, 101n);

    expect(settler.seen.map((payment) => payment.requestId)).toEqual([1n, 9n]);
  });

  /**
   * An assembly that cannot complete leaves the request where it is and is
   * retried on the next replay. Submitting a transaction short of its quorum
   * would burn the fee and consume the sequence for a payment XRPL refuses.
   */
  it("submits nothing when the shares fall short of the quorum", async () => {
    const settler = new RecordingSettler();
    const short = {
      ...QUORUM_READS,
      partialSignaturesOf: (QUORUM_READS.partialSignaturesOf as unknown[]).slice(0, 1),
    };
    const watcher = watcherOver([multiSignedLog(9n, 100n, 0)], settler, cursorFile, 30n, short);

    await watcher.replay(100n, 100n);

    expect(settler.seen).toEqual([]);
  });

  it("keeps going when one quorum cannot be assembled", async () => {
    const settler = new RecordingSettler();
    const broken = { ...QUORUM_READS, getRequest: { ...(QUORUM_READS.getRequest as object), quorumRequired: 0 } };
    const watcher = watcherOver(
      [multiSignedLog(9n, 100n, 0), signedLog(2n, 101n, 0)],
      settler,
      cursorFile,
      30n,
      broken,
    );

    await watcher.replay(100n, 101n);

    expect(settler.seen.map((payment) => payment.requestId)).toEqual([2n]);
  });
});
