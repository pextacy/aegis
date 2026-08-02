import { bytesToHex, hexToBytes, sha256, type Hex } from "viem";

/**
 * XRPL classic address encoding, in the browser.
 *
 * The contracts store a destination as a 20-byte AccountID left-aligned in a
 * `bytes32`. People know their counterparties as `r...` addresses. This module is
 * the conversion between the two, and it verifies the base58check checksum on
 * the way in — a typo in a destination address must be caught in the form, not
 * discovered after a payment lands in an account nobody controls.
 *
 * It mirrors contracts/lib/XrplAddress.sol, which does the same derivation
 * on-chain when a treasury binds the key its enclave generated.
 */

/** The XRPL base58 alphabet — deliberately not the Bitcoin one. */
const ALPHABET = "rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz";

/** Version byte prefixed to an AccountID before base58check encoding. */
const ACCOUNT_PREFIX = 0x00;

const ACCOUNT_ID_BYTES = 20;
const PAYLOAD_BYTES = 1 + ACCOUNT_ID_BYTES + 4;

/** A classic address that is not a valid XRPL account address. */
export class XrplAddressError extends Error {}

function base58Decode(text: string): Uint8Array {
  let value = 0n;
  for (const character of text) {
    const index = ALPHABET.indexOf(character);
    if (index < 0) {
      throw new XrplAddressError(`"${character}" is not a character in the XRPL base58 alphabet.`);
    }
    value = value * 58n + BigInt(index);
  }

  const digits: number[] = [];
  while (value > 0n) {
    digits.unshift(Number(value & 0xffn));
    value >>= 8n;
  }

  let leadingZeros = 0;
  for (const character of text) {
    if (character !== ALPHABET[0]) break;
    leadingZeros += 1;
  }

  return Uint8Array.from([...Array<number>(leadingZeros).fill(0), ...digits]);
}

function base58Encode(bytes: Uint8Array): string {
  let value = 0n;
  for (const byte of bytes) {
    value = (value << 8n) | BigInt(byte);
  }

  let text = "";
  while (value > 0n) {
    text = ALPHABET[Number(value % 58n)] + text;
    value /= 58n;
  }

  for (const byte of bytes) {
    if (byte !== 0) break;
    text = ALPHABET[0] + text;
  }

  return text;
}

function checksum(payload: Uint8Array): Uint8Array {
  return sha256(sha256(payload, "bytes"), "bytes").slice(0, 4);
}

/**
 * Decodes a classic address to its 20-byte AccountID.
 *
 * @throws {XrplAddressError} on a bad alphabet character, wrong length, wrong
 * version byte, or a checksum that does not match.
 */
export function classicAddressToAccountId(address: string): Hex {
  const trimmed = address.trim();
  if (trimmed === "") throw new XrplAddressError("Enter an XRPL address.");
  if (!trimmed.startsWith("r")) {
    throw new XrplAddressError("An XRPL classic address begins with 'r'.");
  }

  const decoded = base58Decode(trimmed);
  if (decoded.length !== PAYLOAD_BYTES) {
    throw new XrplAddressError(
      `An XRPL classic address decodes to ${PAYLOAD_BYTES} bytes; "${trimmed}" decodes to ${decoded.length}.`,
    );
  }
  if (decoded[0] !== ACCOUNT_PREFIX) {
    throw new XrplAddressError("That is an XRPL identifier, but not an account address.");
  }

  const payload = decoded.slice(0, PAYLOAD_BYTES - 4);
  const expected = checksum(payload);
  const actual = decoded.slice(PAYLOAD_BYTES - 4);
  for (let i = 0; i < 4; i += 1) {
    if (expected[i] !== actual[i]) {
      throw new XrplAddressError("Checksum failed — that address contains a typo.");
    }
  }

  return bytesToHex(payload.slice(1));
}

/** Encodes a 20-byte AccountID as a classic address. */
export function accountIdToClassicAddress(accountId: Hex): string {
  const bytes = hexToBytes(accountId);
  if (bytes.length !== ACCOUNT_ID_BYTES) {
    throw new XrplAddressError(`An AccountID is ${ACCOUNT_ID_BYTES} bytes; got ${bytes.length}.`);
  }
  const payload = Uint8Array.from([ACCOUNT_PREFIX, ...bytes]);
  return base58Encode(Uint8Array.from([...payload, ...checksum(payload)]));
}

/** Left-aligns an AccountID into the `bytes32` the contracts store. */
export function accountIdToBytes32(accountId: Hex): Hex {
  const bytes = hexToBytes(accountId);
  if (bytes.length !== ACCOUNT_ID_BYTES) {
    throw new XrplAddressError(`An AccountID is ${ACCOUNT_ID_BYTES} bytes; got ${bytes.length}.`);
  }
  const padded = new Uint8Array(32);
  padded.set(bytes, 0);
  return bytesToHex(padded);
}

/** Reads the AccountID back out of a left-aligned `bytes32`. */
export function bytes32ToAccountId(word: Hex): Hex {
  const bytes = hexToBytes(word);
  if (bytes.length !== 32) {
    throw new XrplAddressError(`Expected a 32-byte word; got ${bytes.length} bytes.`);
  }
  return bytesToHex(bytes.slice(0, ACCOUNT_ID_BYTES));
}

/** Convenience: classic address straight to the stored `bytes32`. */
export function classicAddressToBytes32(address: string): Hex {
  return accountIdToBytes32(classicAddressToAccountId(address));
}

/**
 * Convenience: stored `bytes32` straight back to a classic address.
 *
 * Returns `null` for the zero word, which is how the contracts spell "no XRPL
 * account is bound to this treasury yet".
 */
export function bytes32ToClassicAddress(word: Hex): string | null {
  const accountId = bytes32ToAccountId(word);
  if (/^0x0{40}$/.test(accountId)) return null;
  return accountIdToClassicAddress(accountId);
}

/** Whether a string is a well-formed classic address, checksum included. */
export function isValidClassicAddress(address: string): boolean {
  try {
    classicAddressToAccountId(address);
    return true;
  } catch {
    return false;
  }
}
