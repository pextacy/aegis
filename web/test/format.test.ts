import { describe, expect, it } from "vitest";

import {
  AmountParseError,
  formatDrops,
  formatDuration,
  formatUsd,
  formatWindow,
  formatXrp,
  parseUsdToWad,
  parseWhole,
  parseXrpToDrops,
  percentOf,
} from "@/lib/format";

describe("XRP amounts", () => {
  it("keeps all six decimal places, because the drop is the unit that moves", () => {
    expect(formatXrp(1_234_567n)).toBe("1.234567");
    expect(formatXrp(1n)).toBe("0.000001");
    expect(formatXrp(0n)).toBe("0.000000");
  });

  it("groups drops so a magnitude error is visible", () => {
    expect(formatDrops(100_000_000n)).toBe("100,000,000");
  });

  it("parses a decimal XRP amount into drops without touching a float", () => {
    expect(parseXrpToDrops("1.234567")).toBe(1_234_567n);
    expect(parseXrpToDrops("100")).toBe(100_000_000n);
    expect(parseXrpToDrops(".5")).toBe(500_000n);
    expect(parseXrpToDrops("0.1")).toBe(100_000n);
  });

  it("survives a value no double can hold exactly", () => {
    expect(parseXrpToDrops("9007199254.740993")).toBe(9_007_199_254_740_993n);
  });

  it("refuses an amount finer than a drop rather than rounding it", () => {
    expect(() => parseXrpToDrops("0.0000001")).toThrow(AmountParseError);
  });

  it("refuses anything that is not a decimal number", () => {
    for (const bad of ["", "abc", "1.2.3", "-5", "1e6", "0x10"]) {
      expect(() => parseXrpToDrops(bad)).toThrow(AmountParseError);
    }
  });
});

describe("USD amounts", () => {
  it("renders 18-decimal USD at cent precision, truncating rather than rounding up", () => {
    expect(formatUsd(1_234_569_999_999_999_999n)).toBe("1.23");
    expect(formatUsd(10_000n * 10n ** 18n)).toBe("10,000.00");
  });

  it("parses to 18 decimals exactly", () => {
    expect(parseUsdToWad("10000")).toBe(10_000n * 10n ** 18n);
    expect(parseUsdToWad("0.01")).toBe(10n ** 16n);
  });

  it("refuses more than 18 decimal places", () => {
    expect(() => parseUsdToWad(`0.${"0".repeat(18)}1`)).toThrow(AmountParseError);
  });
});

describe("whole numbers", () => {
  it("parses a destination tag", () => {
    expect(parseWhole("4294967295", "a destination tag")).toBe(4_294_967_295n);
  });

  it("refuses a decimal", () => {
    expect(() => parseWhole("1.5", "a destination tag")).toThrow(AmountParseError);
  });
});

describe("durations", () => {
  it("counts down in units a person reads at a glance", () => {
    expect(formatDuration(0n)).toBe("00s");
    expect(formatDuration(59n)).toBe("59s");
    expect(formatDuration(61n)).toBe("1m 01s");
    expect(formatDuration(3661n)).toBe("1h 1m 01s");
    expect(formatDuration(90061n)).toBe("1d 1h 1m 01s");
  });

  it("phrases a policy window the way the policy was written", () => {
    expect(formatWindow(86400)).toBe("24 hours");
    expect(formatWindow(172800)).toBe("2 days");
    expect(formatWindow(3600)).toBe("1 hour");
    expect(formatWindow(90)).toBe("90 seconds");
  });
});

describe("gauge arithmetic", () => {
  it("never reports more than a full window", () => {
    expect(percentOf(3n, 2n)).toBe(100);
  });

  it("reports nothing consumed against a zero budget instead of dividing by it", () => {
    expect(percentOf(1n, 0n)).toBe(0);
  });

  it("keeps precision on figures far beyond a double", () => {
    expect(percentOf(10n ** 30n, 4n * 10n ** 30n)).toBe(25);
  });
});
