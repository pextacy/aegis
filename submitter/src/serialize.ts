/**
 * XRPL transaction serialisation, for assembling a k-of-n signature.
 *
 * Assembly needs no secret and grants no authority: every share already covers
 * the whole transaction, so an assembler that reorders, drops or forges one
 * produces a blob XRPL rejects rather than a payment nobody authorised. That is
 * what lets it run out here rather than in an enclave — and why anyone can run
 * a submitter.
 *
 * This is a third implementation of the same format, after the enclave's and
 * XRPL's own. It is validated against blobs taken off XRPL rather than against
 * the other two, so agreement between them means something.
 */

import { createHash } from "node:crypto";

/** Field type codes, from the XRPL binary format definitions. */
const TYPE_UINT16 = 1;
const TYPE_UINT32 = 2;
const TYPE_AMOUNT = 6;
const TYPE_BLOB = 7;
const TYPE_ACCOUNT_ID = 8;
const TYPE_ST_OBJECT = 14;
const TYPE_ST_ARRAY = 15;

/** Field codes within each type. */
const FIELD_TRANSACTION_TYPE = 2;
const FIELD_FLAGS = 2;
const FIELD_SEQUENCE = 4;
const FIELD_DESTINATION_TAG = 14;
const FIELD_LAST_LEDGER_SEQUENCE = 27;
const FIELD_AMOUNT = 1;
const FIELD_FEE = 8;
const FIELD_SIGNING_PUB_KEY = 3;
const FIELD_TXN_SIGNATURE = 4;
const FIELD_MEMO_TYPE = 12;
const FIELD_MEMO_DATA = 13;
const FIELD_MEMO_FORMAT = 14;
const FIELD_ACCOUNT = 1;
const FIELD_DESTINATION = 3;
const FIELD_SIGNERS = 3;
const FIELD_MEMOS = 9;
const FIELD_MEMO = 10;
const FIELD_SIGNER = 16;
const FIELD_END_MARKER = 1;

const TX_TYPE_PAYMENT = 0;

/** Forbids the malleable signature form. Every Aegis transaction sets it. */
export const TF_FULLY_CANONICAL_SIG = 0x80000000;

/** Transaction id prefix, "TXN\0". */
const PREFIX_TRANSACTION_ID = Buffer.from([0x54, 0x58, 0x4e, 0x00]);

/** The largest blob the variable-length prefix can express. */
const MAX_VL_LENGTH = 918744;

/** The most signatures XRPL accepts on one transaction. */
export const MAX_SIGNERS = 32;

/** One memo. Aegis populates only `data`, with the on-chain request reference. */
export interface Memo {
  readonly type?: Buffer;
  readonly data?: Buffer;
  readonly format?: Buffer;
}

/** One enclave's share of a multi-signed transaction. */
export interface Signer {
  /** The signer's own 20-byte AccountID. */
  readonly account: Buffer;
  readonly signingPubKey: Buffer;
  readonly txnSignature: Buffer;
}

/** An XRPL Payment in the fields this system produces. */
export interface Payment {
  readonly account: Buffer;
  readonly destination: Buffer;
  readonly amountDrops: bigint;
  readonly feeDrops: bigint;
  readonly sequence: number;
  readonly lastLedgerSequence: number;
  readonly destinationTag?: number;
  readonly flags?: number;
  readonly memos?: readonly Memo[];
  /** Present on the single-signed form only; a multi-signed one carries none. */
  readonly signingPubKey?: Buffer;
  readonly txnSignature?: Buffer;
}

interface Field {
  readonly typeCode: number;
  readonly fieldCode: number;
  readonly payload: Buffer;
}

/**
 * Encodes a field id.
 *
 * The high nibble carries the type code and the low nibble the field code, but
 * only when each fits in four bits; anything larger moves to its own trailing
 * byte and leaves its nibble zero. `LastLedgerSequence` (27) and `Signer` (16)
 * are the fields here that take the two-byte form.
 */
function header(typeCode: number, fieldCode: number): Buffer {
  const high = typeCode < 16 ? typeCode << 4 : 0;
  const low = fieldCode < 16 ? fieldCode : 0;

  const out = [high | low];
  if (typeCode >= 16) out.push(typeCode);
  if (fieldCode >= 16) out.push(fieldCode);
  return Buffer.from(out);
}

function encode(field: Field): Buffer {
  return Buffer.concat([header(field.typeCode, field.fieldCode), field.payload]);
}

/**
 * Orders by (typeCode, fieldCode). This is the canonical order — not
 * alphabetical by name, and not the order the fields were built in.
 */
function sortFields(fields: Field[]): Field[] {
  return [...fields].sort((a, b) => (a.typeCode !== b.typeCode ? a.typeCode - b.typeCode : a.fieldCode - b.fieldCode));
}

/** Encodes a variable-length prefix. Three ranges, so a short blob costs a byte. */
function vlPrefix(n: number): Buffer {
  if (n < 0) throw new Error(`negative length ${n}`);
  if (n <= 192) return Buffer.from([n]);
  if (n <= 12480) {
    const v = n - 193;
    return Buffer.from([193 + Math.floor(v / 256), v % 256]);
  }
  if (n <= MAX_VL_LENGTH) {
    const v = n - 12481;
    return Buffer.from([241 + Math.floor(v / 65536), (v >> 8) % 256, v % 256]);
  }
  throw new Error(`blob of ${n} bytes exceeds the maximum ${MAX_VL_LENGTH}`);
}

function blobField(typeCode: number, fieldCode: number, data: Buffer): Field {
  return { typeCode, fieldCode, payload: Buffer.concat([vlPrefix(data.length), data]) };
}

function uint16Field(fieldCode: number, value: number): Field {
  const payload = Buffer.alloc(2);
  payload.writeUInt16BE(value);
  return { typeCode: TYPE_UINT16, fieldCode, payload };
}

function uint32Field(fieldCode: number, value: number): Field {
  const payload = Buffer.alloc(4);
  payload.writeUInt32BE(value >>> 0);
  return { typeCode: TYPE_UINT32, fieldCode, payload };
}

/** The total XRP supply in drops — 100 billion XRP. */
const MAX_DROPS = 100_000_000_000n * 1_000_000n;

/**
 * Builds an XRP amount. Bit 62 marks the value as XRP rather than an issued
 * currency; bit 63 is the sign bit, left clear because an amount is never
 * negative.
 */
function xrpAmountField(fieldCode: number, drops: bigint): Field {
  if (drops < 0n) throw new Error(`negative amount ${drops}`);
  if (drops > MAX_DROPS) throw new Error(`amount ${drops} drops exceeds the total XRP supply`);
  const payload = Buffer.alloc(8);
  payload.writeBigUInt64BE(drops | 0x4000000000000000n);
  return { typeCode: TYPE_AMOUNT, fieldCode, payload };
}

function requireAccountId(value: Buffer, what: string): Buffer {
  if (value.length !== 20) throw new Error(`${what} must be a 20-byte AccountID, got ${value.length}`);
  if (value.every((byte) => byte === 0)) throw new Error(`${what} is zero`);
  return value;
}

/** Builds the Memos STArray. */
function memosField(memos: readonly Memo[]): Field {
  const parts: Buffer[] = [];

  memos.forEach((memo, index) => {
    const inner: Field[] = [];
    if (memo.type?.length) inner.push(blobField(TYPE_BLOB, FIELD_MEMO_TYPE, memo.type));
    if (memo.data?.length) inner.push(blobField(TYPE_BLOB, FIELD_MEMO_DATA, memo.data));
    if (memo.format?.length) inner.push(blobField(TYPE_BLOB, FIELD_MEMO_FORMAT, memo.format));
    if (inner.length === 0) throw new Error(`memo ${index} is empty`);

    parts.push(header(TYPE_ST_OBJECT, FIELD_MEMO));
    for (const field of sortFields(inner)) parts.push(encode(field));
    parts.push(header(TYPE_ST_OBJECT, FIELD_END_MARKER));
  });

  parts.push(header(TYPE_ST_ARRAY, FIELD_END_MARKER));
  return { typeCode: TYPE_ST_ARRAY, fieldCode: FIELD_MEMOS, payload: Buffer.concat(parts) };
}

/** Builds the Signers STArray. */
function signersField(signers: readonly Signer[]): Field {
  const parts: Buffer[] = [];

  signers.forEach((signer, index) => {
    if (signer.signingPubKey.length === 0) throw new Error(`signer ${index} has no public key`);
    if (signer.txnSignature.length === 0) throw new Error(`signer ${index} has no signature`);
    requireAccountId(signer.account, `signer ${index}`);

    const inner = sortFields([
      blobField(TYPE_BLOB, FIELD_SIGNING_PUB_KEY, signer.signingPubKey),
      blobField(TYPE_BLOB, FIELD_TXN_SIGNATURE, signer.txnSignature),
      blobField(TYPE_ACCOUNT_ID, FIELD_ACCOUNT, signer.account),
    ]);

    parts.push(header(TYPE_ST_OBJECT, FIELD_SIGNER));
    for (const field of inner) parts.push(encode(field));
    parts.push(header(TYPE_ST_OBJECT, FIELD_END_MARKER));
  });

  parts.push(header(TYPE_ST_ARRAY, FIELD_END_MARKER));
  return { typeCode: TYPE_ST_ARRAY, fieldCode: FIELD_SIGNERS, payload: Buffer.concat(parts) };
}

/**
 * Puts the shares in the order XRPL requires, refusing any set it would reject.
 *
 * Sorting here rather than trusting the caller makes the order a property of
 * the format instead of of whoever collected the shares — and the contract
 * emits them in arrival order, which is not it.
 */
export function canonicalSigners(signers: readonly Signer[], account: Buffer): Signer[] {
  if (signers.length === 0) throw new Error("a multi-signed transaction needs at least one signer");
  if (signers.length > MAX_SIGNERS) throw new Error(`a transaction accepts at most ${MAX_SIGNERS} signers`);

  const ordered = [...signers].sort((a, b) => Buffer.compare(a.account, b.account));

  for (const signer of ordered) {
    requireAccountId(signer.account, "signer");
    if (signer.account.equals(account)) throw new Error("the sending account cannot be one of its own signers");
  }
  for (let i = 1; i < ordered.length; i += 1) {
    // Non-null: the loop bounds guarantee both indices exist.
    if (ordered[i]!.account.equals(ordered[i - 1]!.account)) throw new Error("the same account signed twice");
  }

  return ordered;
}

/** Which signature-carrying fields a serialisation includes. */
export type PaymentForm = "signed" | "multiSigned";

/**
 * Serialises a Payment.
 *
 * A multi-signed transaction still carries SigningPubKey, as the empty blob.
 * Omitting the field entirely is a different serialisation and a different
 * hash, and XRPL reads the emptiness — not the absence — as "authorise this
 * against the SignerList".
 */
export function serializePayment(payment: Payment, form: PaymentForm, signers: readonly Signer[] = []): Buffer {
  const fields: Field[] = [
    uint16Field(FIELD_TRANSACTION_TYPE, TX_TYPE_PAYMENT),
    uint32Field(FIELD_SEQUENCE, payment.sequence),
    uint32Field(FIELD_LAST_LEDGER_SEQUENCE, payment.lastLedgerSequence),
  ];

  if (payment.flags) fields.push(uint32Field(FIELD_FLAGS, payment.flags));
  // Omitted entirely when zero: serialising a zero tag produces a different
  // hash than omitting it, and omitting is what XRPL does.
  if (payment.destinationTag) fields.push(uint32Field(FIELD_DESTINATION_TAG, payment.destinationTag));

  fields.push(xrpAmountField(FIELD_AMOUNT, payment.amountDrops));
  fields.push(xrpAmountField(FIELD_FEE, payment.feeDrops));

  const signingPubKey = form === "multiSigned" ? Buffer.alloc(0) : (payment.signingPubKey ?? Buffer.alloc(0));
  fields.push(blobField(TYPE_BLOB, FIELD_SIGNING_PUB_KEY, signingPubKey));

  if (form === "signed") {
    if (!payment.txnSignature?.length) throw new Error("a signed transaction needs a TxnSignature");
    fields.push(blobField(TYPE_BLOB, FIELD_TXN_SIGNATURE, payment.txnSignature));
  }

  fields.push(blobField(TYPE_ACCOUNT_ID, FIELD_ACCOUNT, requireAccountId(payment.account, "account")));
  fields.push(blobField(TYPE_ACCOUNT_ID, FIELD_DESTINATION, requireAccountId(payment.destination, "destination")));

  if (payment.memos?.length) fields.push(memosField(payment.memos));
  if (form === "multiSigned") fields.push(signersField(signers));

  return Buffer.concat(sortFields(fields).map(encode));
}

/** SHA-512Half — SHA-512 then the first 32 bytes. Not SHA-256. */
function sha512Half(prefix: Buffer, data: Buffer): Buffer {
  return createHash("sha512")
    .update(prefix)
    .update(data)
    .digest()
    .subarray(0, 32);
}

/** The XRPL transaction id of a signed blob. */
export function transactionId(signedBlob: Buffer): Buffer {
  return sha512Half(PREFIX_TRANSACTION_ID, signedBlob);
}

/** A blob ready to submit, with the id XRPL will know it by. */
export interface AssembledTransaction {
  readonly signedBlob: Buffer;
  readonly txHash: Buffer;
}

/** Combines collected shares into a submittable multi-signed transaction. */
export function assembleMultisigned(payment: Payment, signers: readonly Signer[]): AssembledTransaction {
  if (payment.lastLedgerSequence === 0) {
    // A transaction without an expiry can never be proven non-existent, which
    // breaks the only path that releases a stuck payment's window spend.
    throw new Error("LastLedgerSequence is required");
  }
  if (payment.amountDrops <= 0n) throw new Error("amount must be greater than zero");
  if (payment.feeDrops <= 0n) throw new Error("fee must be greater than zero");

  const ordered = canonicalSigners(signers, payment.account);
  const signedBlob = serializePayment(payment, "multiSigned", ordered);
  return { signedBlob, txHash: transactionId(signedBlob) };
}
