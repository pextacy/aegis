import type { Hex } from "viem";
import { describe, expect, it } from "vitest";
import { chooseConfirmation, toXrplHex } from "../src/settle.js";
import { TES_SUCCESS } from "../src/xrpl.js";

describe("chooseConfirmation", () => {
  it("settles a delivered payment", () => {
    expect(chooseConfirmation({ kind: "validated", ledgerIndex: 1, transactionResult: TES_SUCCESS })).toBe(
      "confirmSettlement",
    );
  });

  // A tec-coded transaction is in a ledger: it burned the fee and consumed the
  // sequence without delivering. Proving it absent would leave the treasury
  // reusing a sequence XRPL has already passed, which wedges it permanently.
  it("takes the Payment path for a transaction that failed on the ledger", () => {
    expect(chooseConfirmation({ kind: "validated", ledgerIndex: 1, transactionResult: "tecUNFUNDED_PAYMENT" })).toBe(
      "confirmFailedExecution",
    );
    expect(chooseConfirmation({ kind: "validated", ledgerIndex: 1, transactionResult: "tecNO_DST" })).toBe(
      "confirmFailedExecution",
    );
  });

  it("proves non-execution only when nothing reached a ledger", () => {
    expect(chooseConfirmation({ kind: "expired", lastLedgerSequence: 900_000, currentLedgerIndex: 900_001 })).toBe(
      "confirmNonExecution",
    );
  });
});

describe("toXrplHex", () => {
  it("strips the prefix and upper-cases, which is what submit takes", () => {
    expect(toXrplHex("0x12000022800000002400000001" as Hex)).toBe("12000022800000002400000001");
    expect(toXrplHex("0xabcdef" as Hex)).toBe("ABCDEF");
  });

  it("leaves an empty blob empty rather than producing 0x", () => {
    expect(toXrplHex("0x" as Hex)).toBe("");
  });
});
