"use client";

import Link from "next/link";

import { IconTreasury } from "@/components/icons";
import { XrplAccountLink } from "@/components/links";
import { Badge, Empty, tableClass, tdClass, theadClass, thClass, trClass } from "@/components/ui";
import { WindowBar } from "@/components/WindowGauge";
import { useCommittedUsd, usePolicy, useXrplAccount } from "@/hooks/useAegis";
import type { Treasury } from "@/lib/contracts";
import { formatXrp } from "@/lib/format";
import { bytes32ToClassicAddress } from "@/lib/xrpl-address";

/** Every treasury, one row each. */
export function TreasuryTable({ treasuries }: { treasuries: Treasury[] }) {
  if (treasuries.length === 0) {
    return <Empty>No treasuries yet.</Empty>;
  }

  return (
    <div className="custom-scroll overflow-x-auto">
      <table className={tableClass}>
        <thead className={theadClass}>
          <tr>
            <th className={thClass}>Treasury</th>
            <th className={thClass}>XRPL address</th>
            <th className={`${thClass} text-right`}>XRP balance</th>
            <th className={thClass}>Rolling window</th>
          </tr>
        </thead>
        <tbody>
          {treasuries.map((treasury) => (
            <TreasuryRow key={treasury.id.toString()} treasury={treasury} />
          ))}
        </tbody>
      </table>
    </div>
  );
}

function TreasuryRow({ treasury }: { treasury: Treasury }) {
  const policy = usePolicy(treasury.policyId);
  const committed = useCommittedUsd(treasury.id);
  const address = safeAddress(treasury.xrplAccountId);
  const account = useXrplAccount(address);

  return (
    <tr className={trClass}>
      <td className={tdClass}>
        <div className="flex items-center gap-3">
          <span
            className={`flex size-10 shrink-0 items-center justify-center rounded-lg border ${
              treasury.frozen ? "border-bad/30 bg-bad-dim text-bad" : "border-line bg-raised text-accent"
            }`}
          >
            <IconTreasury className="size-5" />
          </span>
          <div>
            <Link href={`/treasuries/${treasury.id}`} className="font-semibold text-ink hover:text-accent">
              Treasury {treasury.id.toString()}
            </Link>
            <div className="mt-1.5 flex flex-wrap items-center gap-2">
              {treasury.frozen ? (
                <Badge tone="bad" dot>
                  Frozen
                </Badge>
              ) : (
                <Badge tone="good" dot>
                  Active
                </Badge>
              )}
              <span className="text-xs text-faint">
                Policy <span className="numeric">{treasury.policyId.toString()}</span>
              </span>
            </div>
          </div>
        </div>
      </td>

      <td className={tdClass}>
        {address ? (
          <XrplAccountLink address={address} />
        ) : (
          <span className="text-sm text-faint">Not bound — the key has not been generated yet.</span>
        )}
      </td>

      <td className={`${tdClass} numeric text-right`}>
        {!address ? (
          <span className="text-faint">—</span>
        ) : account.isPending ? (
          <span className="text-faint">…</span>
        ) : account.data ? (
          formatXrp(account.data.balanceDrops)
        ) : (
          <span className="text-faint">unfunded</span>
        )}
      </td>

      <td className={tdClass}>
        {policy.data && committed.data !== undefined ? (
          <WindowBar committedUsd={committed.data} capUsd={policy.data.rollingWindowUsd} />
        ) : (
          <span className="text-faint">…</span>
        )}
      </td>
    </tr>
  );
}

function safeAddress(accountId: string): string | null {
  try {
    return bytes32ToClassicAddress(accountId as `0x${string}`);
  } catch {
    return null;
  }
}
