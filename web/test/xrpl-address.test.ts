import { describe, expect, it } from "vitest";

import {
  accountIdToClassicAddress,
  bytes32ToClassicAddress,
  classicAddressToAccountId,
  classicAddressToBytes32,
  isValidClassicAddress,
  XrplAddressError,
} from "@/lib/xrpl-address";

/**
 * Vectors taken from a validated XRPL Testnet Payment, not produced by this
 * code. The AccountIDs below were read out of XRPL's own serialisation of that
 * transaction — the `Account` (8,1) and `Destination` (8,3) fields of
 * go/internal/xrpl/testdata/payment_reference.json — so a bug in this encoder
 * cannot make its own test pass.
 *
 * Source transaction:
 * 2454A132CC0A080B04286D9931A515B7540206E0401AD988922898545D85F964
 */
const VECTORS = [
  {
    address: "rGA4xH5vc185At863xPbR4u6CMR3Cr5f71",
    accountId: "0xaed2aca19c6f54926f8482648a694e7cb62baa22",
  },
  {
    address: "r3ymjALibVQ6D7Rdy84NJovACu7TzBJjMX",
    accountId: "0x5785858b9d9ed76f5df23a9be03f9a2150a062d8",
  },
] as const;

describe("classic address decoding", () => {
  for (const vector of VECTORS) {
    it(`decodes ${vector.address} to the AccountID XRPL serialised`, () => {
      expect(classicAddressToAccountId(vector.address)).toBe(vector.accountId);
    });

    it(`re-encodes ${vector.accountId} to ${vector.address}`, () => {
      expect(accountIdToClassicAddress(vector.accountId)).toBe(vector.address);
    });
  }

  it("left-aligns the AccountID in the bytes32 the contracts store", () => {
    expect(classicAddressToBytes32(VECTORS[0].address)).toBe(`${VECTORS[0].accountId}${"0".repeat(24)}`);
  });

  it("reads the address back out of the stored word", () => {
    expect(bytes32ToClassicAddress(classicAddressToBytes32(VECTORS[1].address))).toBe(VECTORS[1].address);
  });

  it("reads the zero word as no account bound", () => {
    expect(bytes32ToClassicAddress(`0x${"0".repeat(64)}`)).toBeNull();
  });
});

describe("classic address validation", () => {
  it("rejects a single-character typo, because the checksum fails", () => {
    const typo = `${VECTORS[0].address.slice(0, -1)}2`;
    expect(typo).not.toBe(VECTORS[0].address);
    expect(() => classicAddressToAccountId(typo)).toThrow(XrplAddressError);
    expect(isValidClassicAddress(typo)).toBe(false);
  });

  it("rejects a character outside the XRPL alphabet", () => {
    // '0', 'I', 'O' and 'l' are deliberately absent from the XRPL alphabet.
    expect(() => classicAddressToAccountId("rGA4xH5vc185At863xPbR4u6CMR3Cr5f70")).toThrow(XrplAddressError);
  });

  it("rejects an address that does not begin with r", () => {
    expect(() => classicAddressToAccountId("nHUon2tpyJEHrrgAyKZjBGWNWTBKmYQuZ8UD8xB9BpJT4vDJmZzZ")).toThrow(
      XrplAddressError,
    );
  });

  it("rejects an empty address rather than returning the zero account", () => {
    expect(() => classicAddressToAccountId("   ")).toThrow(XrplAddressError);
  });

  it("accepts the reference addresses", () => {
    for (const vector of VECTORS) {
      expect(isValidClassicAddress(vector.address)).toBe(true);
    }
  });
});
