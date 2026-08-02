/**
 * Money and time formatting.
 *
 * Every amount in this system is an integer — drops on XRPL, 18-decimal USD on
 * Flare. Nothing here converts to `number` on the way to the screen: a float
 * that rounds a treasury balance is a lie told confidently, and the dashboard's
 * entire job is to show an approver the same figures the contract checked.
 */

/** Drops per XRP, matching PaymentController.DROPS_PER_XRP. */
export const DROPS_PER_XRP = 1_000_000n;

/** Decimals of the USD figures the policy engine stores. */
export const USD_DECIMALS = 18;

/** An amount the user typed that cannot be represented exactly. */
export class AmountParseError extends Error {}

function groupThousands(digits: string): string {
  return digits.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

/**
 * Renders a fixed-point integer with a fixed number of decimal places.
 *
 * Truncates rather than rounds. A displayed amount must never exceed the amount
 * the contract will move.
 */
export function formatFixed(value: bigint, decimals: number, displayDecimals: number): string {
  const negative = value < 0n;
  const magnitude = negative ? -value : value;
  const scale = 10n ** BigInt(decimals);
  const whole = magnitude / scale;
  const fraction = magnitude % scale;

  let text = groupThousands(whole.toString());
  if (displayDecimals > 0) {
    const padded = fraction.toString().padStart(decimals, "0");
    text += `.${padded.slice(0, displayDecimals).padEnd(displayDecimals, "0")}`;
  }
  return negative ? `-${text}` : text;
}

/** `12,000,000` — the exact drop count, which is what gets signed. */
export function formatDrops(drops: bigint): string {
  return groupThousands(drops.toString());
}

/** `12.000000` — drops rendered as XRP, all six decimal places kept. */
export function formatXrp(drops: bigint): string {
  return formatFixed(drops, 6, 6);
}

/** `1,234.56` — an 18-decimal USD figure at cent precision. */
export function formatUsd(usd18: bigint, displayDecimals = 2): string {
  return formatFixed(usd18, USD_DECIMALS, displayDecimals);
}

/**
 * Parses an XRP amount into drops.
 *
 * @throws {AmountParseError} if the input is not a decimal number, is negative,
 * or carries more than six decimal places — the drop is XRPL's smallest unit and
 * anything finer cannot be paid.
 */
export function parseXrpToDrops(input: string): bigint {
  return parseDecimal(input, 6, "XRP");
}

/**
 * Parses a USD amount into an 18-decimal integer.
 *
 * @throws {AmountParseError} if the input is not a decimal number, is negative,
 * or carries more than 18 decimal places.
 */
export function parseUsdToWad(input: string): bigint {
  return parseDecimal(input, USD_DECIMALS, "USD");
}

function parseDecimal(input: string, decimals: number, unit: string): bigint {
  const text = input.trim().replace(/,/g, "");
  if (text === "") throw new AmountParseError(`Enter an amount in ${unit}.`);
  if (!/^\d*(\.\d*)?$/.test(text)) {
    throw new AmountParseError(`"${input}" is not a ${unit} amount. Use digits and at most one decimal point.`);
  }

  const [wholeText = "", fractionText = ""] = text.split(".");
  if (fractionText.length > decimals) {
    throw new AmountParseError(
      `${unit} has ${decimals} decimal places; "${input}" has ${fractionText.length} and cannot be represented exactly.`,
    );
  }
  const whole = wholeText === "" ? 0n : BigInt(wholeText);
  const fraction = fractionText === "" ? 0n : BigInt(fractionText.padEnd(decimals, "0"));
  return whole * 10n ** BigInt(decimals) + fraction;
}

/** Parses a whole number, used for tags, sequences and counts. */
export function parseWhole(input: string, field: string): bigint {
  const text = input.trim().replace(/,/g, "");
  if (text === "") throw new AmountParseError(`Enter ${field}.`);
  if (!/^\d+$/.test(text)) throw new AmountParseError(`${field} must be a whole number.`);
  return BigInt(text);
}

/** `0x1234…cdef` — enough of a hash to recognise, short enough to scan. */
export function shortHex(value: string, lead = 6, tail = 4): string {
  if (value.length <= lead + tail + 1) return value;
  return `${value.slice(0, lead)}…${value.slice(-tail)}`;
}

/** `2d 4h 11m 09s` — a duration in whole seconds, no unit smaller. */
export function formatDuration(totalSeconds: bigint): string {
  const negative = totalSeconds < 0n;
  let remaining = negative ? -totalSeconds : totalSeconds;

  const days = remaining / 86400n;
  remaining %= 86400n;
  const hours = remaining / 3600n;
  remaining %= 3600n;
  const minutes = remaining / 60n;
  const seconds = remaining % 60n;

  const parts: string[] = [];
  if (days > 0n) parts.push(`${days}d`);
  if (days > 0n || hours > 0n) parts.push(`${hours}h`);
  if (days > 0n || hours > 0n || minutes > 0n) parts.push(`${minutes}m`);
  parts.push(`${seconds.toString().padStart(2, "0")}s`);

  const text = parts.join(" ");
  return negative ? `-${text}` : text;
}

/** A policy's window length, phrased the way a person would say it. */
export function formatWindow(seconds: number): string {
  if (seconds % 86400 === 0) {
    const days = seconds / 86400;
    return days === 1 ? "24 hours" : `${days} days`;
  }
  if (seconds % 3600 === 0) {
    const hours = seconds / 3600;
    return hours === 1 ? "1 hour" : `${hours} hours`;
  }
  if (seconds % 60 === 0) {
    const minutes = seconds / 60;
    return minutes === 1 ? "1 minute" : `${minutes} minutes`;
  }
  return `${seconds} seconds`;
}

/** A unix timestamp as an unambiguous UTC string. */
export function formatTimestamp(unixSeconds: bigint): string {
  if (unixSeconds === 0n) return "—";
  const date = new Date(Number(unixSeconds) * 1000);
  return `${date.toISOString().replace("T", " ").slice(0, 19)} UTC`;
}

/** Percentage of a budget consumed, as an integer 0–100 for a gauge width. */
export function percentOf(part: bigint, whole: bigint): number {
  if (whole <= 0n) return 0;
  if (part >= whole) return 100;
  return Number((part * 10000n) / whole) / 100;
}
