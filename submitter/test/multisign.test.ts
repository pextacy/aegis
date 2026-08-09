/**
 * Assembling a quorum from chain data alone.
 *
 * Everything the assembler needs is published on-chain, which is what lets
 * anyone run a submitter and what makes the assembler powerless: it decides how
 * to spell a payment the contract already authorised, and nothing else.
 */

import { readFileSync } from "node:fs";
import { encodeAbiParameters, keccak256 } from "viem";
import type { Address, Hex } from "viem";
import { describe, expect, it } from "vitest";
import type { Clients } from "../src/clients.js";
import type { Config } from "../src/config.js";
import {
  accountIdFromWord,
  assembleQuorumPayment,
  paymentFromRequest,
  requestReference,
  toSigners,
} from "../src/multisign.js";
import type { PartialSignature, QuorumRequest } from "../src/multisign.js";
import { assembleMultisigned } from "../src/serialize.js";

const CONTROLLER = "0xaEd2aCa19C6F54926F8482648A694E7cb62baA22" as Address;
const REGISTRY = "0x1111111111111111111111111111111111111111" as Address;

interface MultisignVector {
  payment: {
    hash: string;
    accountId: string;
    destinationId: string;
    amountDrops: number;
    feeDrops: number;
    sequence: number;
    destinationTag: number;
    lastLedgerSequence: number;
    signers: Array<{ accountId: string; signingPubKey: string; txnSignature: string }>;
    blob: string;
  };
}

const vector = JSON.parse(
  readFileSync(new URL("../../go/internal/xrpl/testdata/multisign_reference.json", import.meta.url), "utf8"),
) as MultisignVector;

const word = (hex20: string): Hex => `0x${hex20.toLowerCase()}${"00".repeat(12)}`;

const REQUEST: QuorumRequest = {
  treasuryId: 1n,
  destinationAccountId: word(vector.payment.destinationId),
  destinationTag: vector.payment.destinationTag,
  amountDrops: BigInt(vector.payment.amountDrops),
  sequence: vector.payment.sequence,
  lastLedgerSequence: vector.payment.lastLedgerSequence,
  feeDrops: BigInt(vector.payment.feeDrops),
  quorumRequired: 2,
};

const SHARES: PartialSignature[] = vector.payment.signers.map((s) => ({
  signerAccountId: word(s.accountId),
  signerPubKey: `0x${s.signingPubKey.toLowerCase()}`,
  signature: `0x${s.txnSignature.toLowerCase()}`,
}));

/** A public client answering the four reads the assembler makes. */
function clientsFor(overrides: {
  request?: Partial<QuorumRequest>;
  shares?: PartialSignature[];
  treasuryAccount?: Hex;
}): Clients {
  return {
    publicClient: {
      readContract: async ({ functionName }: { functionName: string }): Promise<unknown> => {
        if (functionName === "getRequest") return { ...REQUEST, ...overrides.request };
        if (functionName === "TREASURY_REGISTRY") return REGISTRY;
        if (functionName === "getTreasury") {
          return { xrplAccountId: overrides.treasuryAccount ?? word(vector.payment.accountId) };
        }
        if (functionName === "partialSignaturesOf") return overrides.shares ?? SHARES;
        throw new Error(`unexpected read: ${functionName}`);
      },
    },
  } as unknown as Clients;
}

const CONFIG = { paymentController: CONTROLLER } as unknown as Config;

describe("reading an AccountID out of a bytes32", () => {
  it("takes the leading twenty bytes", () => {
    expect(accountIdFromWord(word(vector.payment.accountId), "account").toString("hex").toUpperCase()).toBe(
      vector.payment.accountId,
    );
  });

  /**
   * A non-zero tail means something other than an AccountID was packed.
   * Truncating it silently would build a payment for an account nobody chose,
   * which is the failure this refusal exists to prevent.
   */
  it("refuses a word that is not a left-aligned AccountID", () => {
    const rightAligned = `0x${"00".repeat(12)}${vector.payment.accountId.toLowerCase()}` as Hex;
    expect(() => accountIdFromWord(rightAligned, "account")).toThrow(/left-aligned/);
  });

  it("refuses a zero account", () => {
    expect(() => accountIdFromWord(`0x${"00".repeat(32)}`, "account")).toThrow(/zero/);
  });
});

describe("the memo that links a payment to its request", () => {
  /**
   * `ExecutionVerifier` matches the FDC payment reference against
   * keccak256(abi.encode(requestId)), and the enclave builds the same value.
   * All three have to agree or a settled payment can never be proven.
   */
  it("is keccak256 of the abi-encoded request id", () => {
    const expected = keccak256(encodeAbiParameters([{ type: "uint256" }], [42n]));
    expect(`0x${requestReference(42n).toString("hex")}`).toBe(expected);
  });

  it("appears in the transaction the assembler builds", () => {
    const payment = paymentFromRequest(42n, REQUEST, word(vector.payment.accountId));
    expect(payment.memos?.[0]?.data?.toString("hex")).toBe(requestReference(42n).toString("hex"));
  });
});

describe("assembling from chain data", () => {
  /**
   * The strongest check available without an enclave: the shares from a real
   * multi-signed transaction, carried through the contract's published shapes,
   * come back out as XRPL's own bytes.
   */
  it("reproduces the reference transaction from published shares", async () => {
    // The reference carries no memo, so this asserts the assembly rather than
    // Aegis' own memo; the memo path is covered above and in serialize.test.ts.
    const { memos: _memos, ...withoutMemo } = paymentFromRequest(1n, REQUEST, word(vector.payment.accountId));
    const payment = withoutMemo;
    const { signedBlob, txHash } = assembleMultisigned(payment, toSigners(SHARES));

    expect(signedBlob.toString("hex").toUpperCase()).toBe(vector.payment.blob);
    expect(txHash.toString("hex").toUpperCase()).toBe(vector.payment.hash);
  });

  it("returns the same shape the single-key path produces", async () => {
    const payment = await assembleQuorumPayment(clientsFor({}), CONFIG, 7n);

    expect(payment.requestId).toBe(7n);
    expect(payment.signedBlob.startsWith("0x")).toBe(true);
    expect(payment.txHash).toHaveLength(66);
  });

  /**
   * XRPL would reject a transaction short of its quorum, burning the fee and
   * consuming the sequence for a payment that delivers nothing — worse than not
   * submitting at all, so the refusal is here rather than at the ledger.
   */
  it("refuses to submit fewer shares than the quorum", async () => {
    const short = SHARES.slice(0, 1);
    await expect(assembleQuorumPayment(clientsFor({ shares: short }), CONFIG, 7n)).rejects.toThrow(
      /1 of 2 signatures/,
    );
  });

  it("refuses a request that was never dispatched to a quorum", async () => {
    await expect(
      assembleQuorumPayment(clientsFor({ request: { quorumRequired: 0 } }), CONFIG, 7n),
    ).rejects.toThrow(/not dispatched to a quorum/);
  });

  /**
   * More shares than the quorum is not an error — every one of them is a valid
   * signature over the same transaction, and XRPL counts them all.
   */
  it("accepts more shares than the quorum asked for", async () => {
    const payment = await assembleQuorumPayment(
      clientsFor({ request: { quorumRequired: 1 } }),
      CONFIG,
      7n,
    );
    expect(payment.signedBlob.length).toBeGreaterThan(2);
  });

  it("refuses a treasury whose account is not bound", async () => {
    await expect(
      assembleQuorumPayment(clientsFor({ treasuryAccount: `0x${"00".repeat(32)}` }), CONFIG, 7n),
    ).rejects.toThrow(/zero/);
  });
});
