"use client";

import { formatUsd, formatWindow, percentOf } from "@/lib/format";

/**
 * The rolling window, as a bar.
 *
 * Committed spend is what the contract has already reserved; the pending segment
 * is what the payment being considered would add. Showing them separately is the
 * difference between "there is room" and "there is room for this".
 */
export function WindowGauge({
  committedUsd,
  capUsd,
  windowSeconds,
  pendingUsd = 0n,
}: {
  committedUsd: bigint;
  capUsd: bigint;
  windowSeconds: number;
  pendingUsd?: bigint;
}) {
  const committedPercent = percentOf(committedUsd, capUsd);
  const pendingPercent = Math.max(0, Math.min(100 - committedPercent, percentOf(pendingUsd, capUsd)));
  const remaining = capUsd > committedUsd + pendingUsd ? capUsd - committedUsd - pendingUsd : 0n;
  const over = committedUsd + pendingUsd > capUsd;

  return (
    <div>
      <div className="flex items-baseline justify-between text-sm">
        <span className="text-muted">Rolling window, {formatWindow(windowSeconds)}</span>
        <span className={`numeric ${over ? "text-bad" : "text-ink"}`}>
          ${formatUsd(committedUsd + pendingUsd)} / ${formatUsd(capUsd)}
        </span>
      </div>

      <div className="mt-2 h-2 w-full overflow-hidden rounded-full bg-raised">
        <div className="flex h-full">
          <div
            className={over ? "h-full bg-bad" : "h-full bg-accent"}
            style={{ width: `${committedPercent}%` }}
            aria-hidden
          />
          {pendingPercent > 0 && (
            <div className="h-full bg-accent/40" style={{ width: `${pendingPercent}%` }} aria-hidden />
          )}
        </div>
      </div>

      <p className="mt-2 text-xs text-faint">
        {over
          ? `Over the window by $${formatUsd(committedUsd + pendingUsd - capUsd)} — a dispatch would be refused.`
          : `$${formatUsd(remaining)} left before the window refuses the next payment.`}
      </p>
    </div>
  );
}
