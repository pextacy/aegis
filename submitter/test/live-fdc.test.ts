import { createPublicClient, http } from "viem";
import { describe, expect, it } from "vitest";

import { flareSystemsManagerAbi } from "../src/abi.js";
import { votingRoundOf } from "../src/fdc.js";

/**
 * Checks the submitter's FDC arithmetic against Coston2 itself.
 *
 * Every other test of `votingRoundOf` supplies both the inputs and the expected
 * answer, so it can only show the function agrees with the test author. The
 * consequence of it being wrong is not subtle: an attestation requested for the
 * wrong round is a proof that never appears, so the submitter would poll the DA
 * layer until it timed out and every payment would stall in `Signed` — a
 * failure that looks like Flare being slow rather than like a bug here.
 *
 * Flare derives the same number on-chain, in `Relay.getVotingRoundId`. So this
 * reads the parameters from the real FlareSystemsManager, computes the round
 * our way, and asks the Relay for its answer to the same timestamp. Two
 * independent derivations, no expected value written down by hand.
 *
 * Reads only, so it costs nothing and needs no funded wallet. Skipped unless
 * COSTON2_RPC_URL is set, so the offline suite stays offline.
 */

const RPC = process.env.COSTON2_RPC_URL;
const FLARE_SYSTEMS_MANAGER = "0xA90Db6D10F856799b10ef2A77EBCbF460aC71e52" as const;
const RELAY = "0xa10B672D1c62e5457b17af63d4302add6A99d7dE" as const;

const RELAY_ABI = [
  {
    type: "function",
    name: "getVotingRoundId",
    stateMutability: "view",
    inputs: [{ name: "_timestamp", type: "uint256" }],
    outputs: [{ name: "_votingRoundId", type: "uint256" }],
  },
] as const;

describe.skipIf(!RPC)("the voting round, against Coston2", () => {
  // Built inside the tests rather than here: `describe.skipIf` still evaluates
  // the suite body, so constructing the client at this level throws
  // UrlRequiredError on a machine with no RPC configured — turning a skip into
  // a failed suite.
  const connect = () => createPublicClient({ transport: http(RPC) });

  async function parameters(): Promise<{ firstStart: bigint; epoch: bigint }> {
    const client = connect();
    const [firstStart, epoch] = (await Promise.all([
      client.readContract({
        address: FLARE_SYSTEMS_MANAGER,
        abi: flareSystemsManagerAbi,
        functionName: "firstVotingRoundStartTs",
      }),
      client.readContract({
        address: FLARE_SYSTEMS_MANAGER,
        abi: flareSystemsManagerAbi,
        functionName: "votingEpochDurationSeconds",
      }),
    ])) as [bigint, bigint];
    return { firstStart, epoch };
  }

  it("reads real parameters from the real FlareSystemsManager", async () => {
    const { firstStart, epoch } = await parameters();
    expect(firstStart).toBeGreaterThan(0n);
    expect(epoch).toBeGreaterThan(0n);
  });

  it("derives the same round the Relay does, for the current time", async () => {
    const client = connect();
    const { firstStart, epoch } = await parameters();
    const block = await client.getBlock();

    const ours = votingRoundOf(block.timestamp, firstStart, epoch);
    const theirs = (await client.readContract({
      address: RELAY,
      abi: RELAY_ABI,
      functionName: "getVotingRoundId",
      args: [block.timestamp],
    })) as bigint;

    expect(BigInt(ours)).toBe(theirs);
  });

  /**
   * A single agreeing sample could be a coincidence of rounding. Walking
   * backwards over many rounds, including timestamps that land exactly on a
   * boundary, is what would catch an off-by-one in the division.
   */
  it("agrees across a spread of timestamps, boundaries included", async () => {
    const client = connect();
    const { firstStart, epoch } = await parameters();
    const block = await client.getBlock();

    const samples: bigint[] = [];
    for (let i = 0n; i < 8n; i += 1n) {
      const round = (block.timestamp - firstStart) / epoch - i * 1000n;
      if (round < 0n) break;
      const start = firstStart + round * epoch;
      samples.push(start, start + 1n, start + epoch - 1n);
    }

    for (const timestamp of samples) {
      const ours = votingRoundOf(timestamp, firstStart, epoch);
      const theirs = (await client.readContract({
        address: RELAY,
        abi: RELAY_ABI,
        functionName: "getVotingRoundId",
        args: [timestamp],
      })) as bigint;
      expect(BigInt(ours), `timestamp ${timestamp}`).toBe(theirs);
    }
  });
});
