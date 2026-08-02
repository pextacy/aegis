"use client";

import Link from "next/link";

import { XrplAccountLink } from "@/components/links";
import { Badge, Mono } from "@/components/ui";
import { WindowGauge } from "@/components/WindowGauge";
import { useCommittedUsd, usePolicy, useXrplAccount } from "@/hooks/useAegis";
import type { Treasury } from "@/lib/contracts";
import { formatXrp } from "@/lib/format";
import { bytes32ToClassicAddress } from "@/lib/xrpl-address";

/** One treasury, as much of it as fits on a list row. */
export function TreasuryCard({ treasury }: { treasury: Treasury }) {
  const policy = usePolicy(treasury.policyId);
  const committed = useCommittedUsd(treasury.id);

  const address = safeAddress(treasury.xrplAccountId);
  const account = useXrplAccount(address);

  return (
    <Link
      href={`/treasuries/${treasury.id}`}
      className="block rounded-lg border border-line bg-surface p-5 transition-colors hover:border-accent/40"
    >
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-3">
          <h3 className="text-base font-semibold text-ink">Treasury {treasury.id.toString()}</h3>
          {treasury.frozen ? <Badge tone="bad">Frozen</Badge> : <Badge tone="good">Active</Badge>}
          {!address && <Badge tone="warn">No XRPL account</Badge>}
        </div>
        <div className="text-sm text-muted">
          Policy <Mono className="text-ink">{treasury.policyId.toString()}</Mono>
        </div>
      </div>

      <div className="mt-3 grid gap-4 sm:grid-cols-2">
        <div>
          <div className="text-xs tracking-wide text-faint uppercase">XRPL account</div>
          <div className="mt-1 text-sm break-all">
            {address ? (
              <span onClick={(event) => event.stopPropagation()}>
                <XrplAccountLink address={address} />
              </span>
            ) : (
              <span className="text-faint">Not bound yet — the key is generated in the enclave.</span>
            )}
          </div>
        </div>

        <div>
          <div className="text-xs tracking-wide text-faint uppercase">Balance</div>
          <div className="numeric mt-1 text-sm text-ink">
            {!address
              ? "—"
              : account.isPending
                ? "reading XRPL…"
                : account.data
                  ? `${formatXrp(account.data.balanceDrops)} XRP`
                  : "unfunded"}
          </div>
        </div>
      </div>

      {policy.data && committed.data !== undefined && (
        <div className="mt-4">
          <WindowGauge
            committedUsd={committed.data}
            capUsd={policy.data.rollingWindowUsd}
            windowSeconds={policy.data.windowSeconds}
          />
        </div>
      )}
    </Link>
  );
}

function safeAddress(accountId: string): string | null {
  try {
    return bytes32ToClassicAddress(accountId as `0x${string}`);
  } catch {
    return null;
  }
}
