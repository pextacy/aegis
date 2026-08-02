"use client";

import { useNow } from "@/hooks/useAegis";
import { formatDuration, formatTimestamp } from "@/lib/format";

/**
 * A live timelock countdown.
 *
 * The countdown reaching zero is not authorisation — `dispatch` re-runs the
 * whole policy check against the price and the window as they are at that
 * moment. The unlock time is shown alongside so the reader sees a fact, not just
 * a number ticking down.
 */
export function Countdown({ eligibleAt, prefix = "Unlocks in" }: { eligibleAt: bigint; prefix?: string }) {
  const now = useNow();
  const remaining = eligibleAt - now;

  if (remaining <= 0n) {
    return (
      <span className="text-good">
        Timelock elapsed <span className="text-faint">at {formatTimestamp(eligibleAt)}</span>
      </span>
    );
  }

  return (
    <span className="text-warn">
      {prefix} <span className="numeric">{formatDuration(remaining)}</span>{" "}
      <span className="text-faint">at {formatTimestamp(eligibleAt)}</span>
    </span>
  );
}
