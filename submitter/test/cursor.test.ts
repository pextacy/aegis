import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { CursorError, FileCursor, parseCursor, serialiseCursor } from "../src/cursor.js";

describe("cursor encoding", () => {
  it("round-trips a block number", () => {
    expect(parseCursor(serialiseCursor(20_000_001n))).toBe(20_000_001n);
  });

  it("keeps block numbers as strings so JSON cannot round them", () => {
    const huge = 9_007_199_254_740_993n; // one past Number.MAX_SAFE_INTEGER
    expect(parseCursor(serialiseCursor(huge))).toBe(huge);
  });

  it("refuses a file it cannot trust", () => {
    expect(() => parseCursor("not json")).toThrow(CursorError);
    expect(() => parseCursor("[]")).toThrow(CursorError);
    expect(() => parseCursor('{"lastProcessedBlock": 42}')).toThrow(CursorError);
  });
});

describe("FileCursor", () => {
  let directory: string;

  beforeEach(() => {
    directory = mkdtempSync(join(tmpdir(), "aegis-cursor-"));
  });

  afterEach(() => {
    rmSync(directory, { recursive: true, force: true });
  });

  it("starts from the deployment block when nothing was written yet", () => {
    const cursor = new FileCursor(join(directory, "nested", "cursor.json"));
    expect(cursor.read(20_000_000n)).toBe(20_000_000n);
  });

  it("remembers where the watcher stopped", () => {
    const cursor = new FileCursor(join(directory, "cursor.json"));
    cursor.write(20_000_123n);
    expect(new FileCursor(join(directory, "cursor.json")).read(0n)).toBe(20_000_123n);
  });

  it("creates the directory it was pointed at", () => {
    const path = join(directory, "deep", "state", "cursor.json");
    new FileCursor(path).write(7n);
    expect(readFileSync(path, "utf8")).toContain('"7"');
  });

  // Starting over from block zero after a corrupt write would look like a hang
  // rather than a failure, so it is an error instead.
  it("refuses to silently restart from the beginning", () => {
    const path = join(directory, "cursor.json");
    writeFileSync(path, "{ truncated", "utf8");
    expect(() => new FileCursor(path).read(20_000_000n)).toThrow(CursorError);
  });
});
