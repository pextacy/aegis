import { describe, expect, it } from "vitest";
import { classifyOutcome, delivered, TES_SUCCESS, XRPL_EPOCH_OFFSET_SECONDS } from "../src/xrpl.js";
import type { XrplTxLookup } from "../src/xrpl.js";

const LAST_LEDGER = 900_000;

describe("classifyOutcome", () => {
  it("settles a validated transaction", () => {
    const lookup: XrplTxLookup = { kind: "validated", ledgerIndex: 899_998, transactionResult: TES_SUCCESS };
    expect(classifyOutcome(lookup, 899_999, LAST_LEDGER)).toEqual({
      kind: "validated",
      ledgerIndex: 899_998,
      transactionResult: TES_SUCCESS,
    });
  });

  it("settles a validated transaction that failed on the ledger", () => {
    const lookup: XrplTxLookup = { kind: "validated", ledgerIndex: 899_998, transactionResult: "tecUNFUNDED_PAYMENT" };
    expect(classifyOutcome(lookup, 899_999, LAST_LEDGER)).toEqual({
      kind: "validated",
      ledgerIndex: 899_998,
      transactionResult: "tecUNFUNDED_PAYMENT",
    });
  });

  it("waits while the transaction is absent and the deadline has not passed", () => {
    expect(classifyOutcome({ kind: "missing" }, LAST_LEDGER - 1, LAST_LEDGER)).toBeUndefined();
  });

  it("still waits in the deadline ledger itself", () => {
    // XRPL applies a transaction up to and including LastLedgerSequence.
    expect(classifyOutcome({ kind: "missing" }, LAST_LEDGER, LAST_LEDGER)).toBeUndefined();
  });

  it("expires once the network is past the deadline", () => {
    expect(classifyOutcome({ kind: "missing" }, LAST_LEDGER + 1, LAST_LEDGER)).toEqual({
      kind: "expired",
      lastLedgerSequence: LAST_LEDGER,
      currentLedgerIndex: LAST_LEDGER + 1,
    });
  });

  it("does not expire a transaction that is sitting in an open ledger", () => {
    // Present but unvalidated past the deadline is not a conclusion: the next
    // close resolves it, and calling it absent would release a window spend for
    // a payment that is about to land.
    expect(classifyOutcome({ kind: "pending" }, LAST_LEDGER + 5, LAST_LEDGER)).toBeUndefined();
  });
});

describe("delivered", () => {
  it("is true only for tesSUCCESS", () => {
    expect(delivered({ kind: "validated", ledgerIndex: 1, transactionResult: TES_SUCCESS })).toBe(true);
    expect(delivered({ kind: "validated", ledgerIndex: 1, transactionResult: "tecPATH_DRY" })).toBe(false);
    expect(delivered({ kind: "expired", lastLedgerSequence: 1, currentLedgerIndex: 2 })).toBe(false);
  });
});

describe("the XRPL epoch", () => {
  it("is 2000-01-01 in Unix seconds", () => {
    expect(new Date(XRPL_EPOCH_OFFSET_SECONDS * 1000).toISOString()).toBe("2000-01-01T00:00:00.000Z");
  });
});
