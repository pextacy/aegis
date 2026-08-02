/**
 * Structured logging.
 *
 * One line of JSON per event, so a submitter run can be replayed from its log
 * and compared against chain state. Nothing this service handles is secret —
 * the signed blob and its hash are already public in `PaymentSigned` — but the
 * private key is never a field of anything logged here.
 */

export type LogLevel = "debug" | "info" | "warn" | "error";

const ORDER: Record<LogLevel, number> = { debug: 0, info: 1, warn: 2, error: 3 };

function threshold(): LogLevel {
  const raw = process.env["LOG_LEVEL"]?.toLowerCase();
  if (raw === "debug" || raw === "info" || raw === "warn" || raw === "error") return raw;
  return "info";
}

/** A value that survives JSON.stringify without a replacer. */
export type Loggable = string | number | boolean | null | undefined | bigint | Loggable[] | { [key: string]: Loggable };

function serialise(fields: Record<string, Loggable>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(fields)) {
    out[key] = typeof value === "bigint" ? value.toString() : value;
  }
  return out;
}

function emit(level: LogLevel, message: string, fields: Record<string, Loggable>): void {
  if (ORDER[level] < ORDER[threshold()]) return;
  const line = JSON.stringify({ level, message, ...serialise(fields) });
  if (level === "error" || level === "warn") {
    process.stderr.write(`${line}\n`);
  } else {
    process.stdout.write(`${line}\n`);
  }
}

export const log = {
  debug: (message: string, fields: Record<string, Loggable> = {}): void => emit("debug", message, fields),
  info: (message: string, fields: Record<string, Loggable> = {}): void => emit("info", message, fields),
  warn: (message: string, fields: Record<string, Loggable> = {}): void => emit("warn", message, fields),
  error: (message: string, fields: Record<string, Loggable> = {}): void => emit("error", message, fields),
};

/** Renders an unknown thrown value as a log field without losing the message. */
export function describeError(error: unknown): string {
  if (error instanceof Error) return error.message;
  return String(error);
}
