import { describe, expect, it } from "vitest";

import { ALL_ABIS } from "@/lib/contracts";
import { EXPLAINED_ERROR_NAMES, explainFailure, unexplainedErrorNames } from "@/lib/errors";

/**
 * The dashboard promises that every rejection names the rule that fired. That
 * promise is only worth something if it is checked mechanically against the
 * deployed ABIs — a custom error added to a contract without a matching
 * explanation would otherwise reach a user as a bare selector.
 */
describe("error coverage", () => {
  it("explains every custom error in every Aegis contract", () => {
    const missing = unexplainedErrorNames(ALL_ABIS as unknown as { type: string; name?: string }[][]);
    expect(missing).toEqual([]);
  });

  it("covers the rules the plan calls out by name", () => {
    for (const name of [
      "AmountExceedsPolicyCap",
      "RollingWindowExceeded",
      "DestinationNotAllowed",
      "ProposerCannotApprove",
      "AlreadyApproved",
      "TimelockNotElapsed",
      "StalePrice",
      "TreasuryIsFrozen",
      "InsufficientApprovals",
    ]) {
      expect(EXPLAINED_ERROR_NAMES).toContain(name);
    }
  });
});

describe("explaining a failure", () => {
  it("passes an unrecognised failure through rather than inventing one", () => {
    const explained = explainFailure(new Error("connection reset"));
    expect(explained.detail).toBe("connection reset");
    expect(explained.errorName).toBeNull();
  });

  it("handles something that is not an Error at all", () => {
    expect(explainFailure("nope").detail).toBe("nope");
  });
});
