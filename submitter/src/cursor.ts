/**
 * Where the watcher left off.
 *
 * A submitter that restarts must not skip a `PaymentSigned` it never handled,
 * and must not re-run one it already settled. The first is solved here by
 * replaying from the last fully-processed block; the second is solved on-chain,
 * where a request that already reached a terminal state ignores further proofs.
 */

import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

export class CursorError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CursorError";
  }
}

/** Parses the persisted cursor file. */
export function parseCursor(json: string): bigint {
  let parsed: unknown;
  try {
    parsed = JSON.parse(json);
  } catch {
    throw new CursorError("cursor file is not JSON");
  }
  if (typeof parsed !== "object" || parsed === null) throw new CursorError("cursor file is not an object");

  const value = (parsed as Record<string, unknown>)["lastProcessedBlock"];
  if (typeof value !== "string" || !/^\d+$/.test(value)) {
    throw new CursorError("cursor file has no lastProcessedBlock");
  }
  return BigInt(value);
}

/** Renders the cursor file. Block numbers are strings so JSON keeps them exact. */
export function serialiseCursor(lastProcessedBlock: bigint): string {
  return `${JSON.stringify({ lastProcessedBlock: lastProcessedBlock.toString() }, null, 2)}\n`;
}

/** A cursor backed by a file, written atomically so a crash cannot truncate it. */
export class FileCursor {
  constructor(private readonly path: string) {}

  /**
   * Reads the cursor, falling back to the deployment block the first time.
   *
   * A malformed file is an error rather than a reason to start from the
   * beginning: silently replaying from block zero would take hours and look
   * like a hang.
   */
  read(fallback: bigint): bigint {
    let contents: string;
    try {
      contents = readFileSync(this.path, "utf8");
    } catch (error) {
      if (isNotFound(error)) return fallback;
      throw error;
    }
    return parseCursor(contents);
  }

  write(lastProcessedBlock: bigint): void {
    mkdirSync(dirname(this.path), { recursive: true });
    const temporary = `${this.path}.tmp`;
    writeFileSync(temporary, serialiseCursor(lastProcessedBlock), "utf8");
    renameSync(temporary, this.path);
  }
}

function isNotFound(error: unknown): boolean {
  return typeof error === "object" && error !== null && (error as { code?: unknown }).code === "ENOENT";
}
