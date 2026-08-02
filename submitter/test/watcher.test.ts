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

function watcherOver(logs: Log[], settler: RecordingSettler, cursorFile: string, chunk = 30n): Watcher {
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
