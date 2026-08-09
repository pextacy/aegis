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
  const used = committedPercent + pendingPercent;

  return (
    <div>
      <div className="flex flex-wrap items-end justify-between gap-2">
        <div>
          <div className="text-lg font-semibold tracking-tight text-ink">Rolling window</div>
          <div className="text-sm text-muted">{formatWindow(windowSeconds)} liquidity outflow limit</div>
        </div>
        <div className="text-right">
          <div className={`numeric text-xl ${over ? "text-bad" : "text-ink"}`}>
            ${formatUsd(committedUsd + pendingUsd)} <span className="text-faint">/</span> ${formatUsd(capUsd)}
          </div>
          <div className="label-caps mt-0.5 text-faint">{used.toFixed(1)}% committed</div>
        </div>
      </div>

      <div className="mt-4 flex h-10 w-full overflow-hidden rounded-lg bg-sunken">
        <div
          className={`flex h-full items-center justify-center ${over ? "bg-bad" : "bg-accent"}`}
          style={{ width: `${committedPercent}%` }}
        >
          {committedPercent >= 18 && (
            <span className="label-caps text-white">Committed {committedPercent.toFixed(0)}%</span>
          )}
        </div>
        {pendingPercent > 0 && (
          <div
            className="flex h-full items-center justify-center bg-accent/35"
            style={{ width: `${pendingPercent}%` }}
          >
            {pendingPercent >= 18 && (
              <span className="label-caps text-accent">This payment {pendingPercent.toFixed(0)}%</span>
            )}
          </div>
        )}
      </div>

      <p className="mt-3 text-sm text-muted">
        {over ? (
          <>
            Over the window by{" "}
            <span className="numeric font-semibold text-bad">${formatUsd(committedUsd + pendingUsd - capUsd)}</span> — a
            dispatch would be refused.
          </>
        ) : (
          <>
            Headroom <span className="numeric font-semibold text-good">${formatUsd(remaining)}</span> before the window
            refuses the next payment.
          </>
        )}
      </p>
    </div>
  );
}

/** The same figure at list density: a limit, a thin bar, a percentage. */
export function WindowBar({ committedUsd, capUsd }: { committedUsd: bigint; capUsd: bigint }) {
  const percent = percentOf(committedUsd, capUsd);
  const over = committedUsd > capUsd;

  return (
    <div className="min-w-[9rem]">
      <div className="flex items-baseline justify-between gap-3">
        <span className="label-caps text-faint">Cap ${formatUsd(capUsd, 0)}</span>
        <span className={`numeric text-xs ${over ? "text-bad" : "text-muted"}`}>{percent.toFixed(1)}%</span>
      </div>
      <div className="mt-1.5 h-1.5 w-full overflow-hidden rounded-full bg-sunken">
        <div className={over ? "h-full bg-bad" : "h-full bg-accent"} style={{ width: `${percent}%` }} aria-hidden />
      </div>
    </div>
  );
}
