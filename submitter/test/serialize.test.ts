/**
 * The assembler, checked against XRPL's own bytes.
 *
 * The vectors are the same ones the enclave's serialiser is validated against,
 * and they come from the network rather than from either implementation. Two
 * independent codebases agreeing with a third party is evidence; two agreeing
 * with each other is not.
 */

import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  assembleMultisigned,
  canonicalSigners,
  serializePayment,
  transactionId,
  TF_FULLY_CANONICAL_SIG,
} from "../src/serialize.js";
import type { Payment, Signer } from "../src/serialize.js";

const VECTORS = "../../go/internal/xrpl/testdata";

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
    flags: number;
    signers: Array<{ accountId: string; signingPubKey: string; txnSignature: string }>;
    blob: string;
  };
}

interface SingleVector {
  hash: string;
  accountId: string;
  destinationId: string;
  amountDrops: number;
  feeDrops: number;
  sequence: number;
  lastLedgerSequence: number;
  signingPubKey: string;
  txnSignature: string;
  memoType: string;
  memoData: string;
  blob: string;
}

function load<T>(name: string): T {
  return JSON.parse(readFileSync(new URL(`${VECTORS}/${name}`, import.meta.url), "utf8")) as T;
}

const hex = (value: string): Buffer => Buffer.from(value, "hex");
const upper = (value: Buffer): string => value.toString("hex").toUpperCase();

const multisign = load<MultisignVector>("multisign_reference.json");
const single = load<SingleVector>("payment_reference.json");

function referencePayment(): Payment {
  const p = multisign.payment;
  return {
    account: hex(p.accountId),
    destination: hex(p.destinationId),
    amountDrops: BigInt(p.amountDrops),
    feeDrops: BigInt(p.feeDrops),
    sequence: p.sequence,
    destinationTag: p.destinationTag,
    lastLedgerSequence: p.lastLedgerSequence,
    flags: p.flags,
  };
}

function referenceSigners(): Signer[] {
  return multisign.payment.signers.map((s) => ({
    account: hex(s.accountId),
    signingPubKey: hex(s.signingPubKey),
    txnSignature: hex(s.txnSignature),
  }));
}

describe("assembling a multi-signed payment", () => {
  it("reproduces XRPL's own blob and hash", () => {
    const { signedBlob, txHash } = assembleMultisigned(referencePayment(), referenceSigners());

    expect(upper(signedBlob)).toBe(multisign.payment.blob);
    expect(upper(txHash)).toBe(multisign.payment.hash);
  });

  it("puts the shares in XRPL's order whatever order they arrived in", () => {
    // The contract emits shares as machines answer, which is not sorted.
    const reversed = [...referenceSigners()].reverse();

    const forward = assembleMultisigned(referencePayment(), referenceSigners());
    const backward = assembleMultisigned(referencePayment(), reversed);

    expect(upper(backward.signedBlob)).toBe(upper(forward.signedBlob));
    expect(upper(backward.signedBlob)).toBe(multisign.payment.blob);
  });

  it("refuses a set XRPL would reject", () => {
    const payment = referencePayment();
    const [first] = referenceSigners();
    if (first === undefined) throw new Error("the vector has no signers");

    expect(() => assembleMultisigned(payment, [])).toThrow(/at least one signer/);
    expect(() => assembleMultisigned(payment, [first, first])).toThrow(/signed twice/);
    expect(() => assembleMultisigned(payment, [{ ...first, account: payment.account }])).toThrow(
      /its own signers/,
    );
    expect(() => assembleMultisigned(payment, [{ ...first, txnSignature: Buffer.alloc(0) }])).toThrow(
      /no signature/,
    );
  });

  it("refuses a transaction that could never be proven absent", () => {
    const payment = { ...referencePayment(), lastLedgerSequence: 0 };
    expect(() => assembleMultisigned(payment, referenceSigners())).toThrow(/LastLedgerSequence/);
  });

  it("refuses a zero amount or a zero fee", () => {
    expect(() => assembleMultisigned({ ...referencePayment(), amountDrops: 0n }, referenceSigners())).toThrow(
      /amount/,
    );
    expect(() => assembleMultisigned({ ...referencePayment(), feeDrops: 0n }, referenceSigners())).toThrow(/fee/);
  });

  it("caps the shares at what XRPL accepts", () => {
    const payment = referencePayment();
    const many = Array.from({ length: 33 }, (_, i) => {
      const account = Buffer.alloc(20);
      account.writeUInt32BE(i + 1, 16);
      return { account, signingPubKey: Buffer.alloc(33, 2), txnSignature: Buffer.alloc(70, 3) };
    });
    expect(() => canonicalSigners(many, payment.account)).toThrow(/at most 32/);
  });
});

describe("the single-signed form", () => {
  /**
   * Not a path the submitter takes — the enclave produces those blobs whole —
   * but the same serialiser produces both, and this vector carries a Memos
   * array and omits DestinationTag and Flags. Aegis' own payments carry a memo,
   * so without this the assembler's memo handling would rest on nothing.
   */
  it("reproduces a validated payment carrying memos", () => {
    const payment: Payment = {
      account: hex(single.accountId),
      destination: hex(single.destinationId),
      amountDrops: BigInt(single.amountDrops),
      feeDrops: BigInt(single.feeDrops),
      sequence: single.sequence,
      lastLedgerSequence: single.lastLedgerSequence,
      signingPubKey: hex(single.signingPubKey),
      txnSignature: hex(single.txnSignature),
      memos: [{ type: hex(single.memoType), data: hex(single.memoData) }],
    };

    const blob = serializePayment(payment, "signed");
    expect(upper(blob)).toBe(single.blob);
    expect(upper(transactionId(blob))).toBe(single.hash);
  });

  /**
   * A zero DestinationTag is omitted, not serialised as zero. The two produce
   * different hashes, and omitting is what XRPL does.
   */
  it("omits a zero destination tag rather than writing one", () => {
    const base = referencePayment();
    const withZero = serializePayment({ ...base, destinationTag: 0 }, "multiSigned", referenceSigners());
    const withTag = serializePayment({ ...base, destinationTag: 1 }, "multiSigned", referenceSigners());

    expect(upper(withZero)).not.toBe(upper(withTag));
    expect(withZero.length).toBeLessThan(withTag.length);
  });

  /**
   * The empty SigningPubKey is what tells XRPL to authorise against the signer
   * list. Omitting the field entirely is a different serialisation and would be
   * a different transaction.
   */
  it("keeps SigningPubKey as an empty blob when multi-signed", () => {
    const blob = serializePayment(referencePayment(), "multiSigned", referenceSigners());
    // Field id 0x73 (Blob, field 3) followed by a length of zero.
    expect(blob.includes(Buffer.from([0x73, 0x00]))).toBe(true);
  });

  it("sets the canonical-signature flag on Aegis' own payments", () => {
    // Not enforced by the serialiser, which writes what it is given — asserted
    // here because the reference transaction sets it and ours must too.
    expect((multisign.payment.flags & TF_FULLY_CANONICAL_SIG) >>> 0).toBe(TF_FULLY_CANONICAL_SIG);
  });
});
