"use client";

import Link from "next/link";
import { useState } from "react";

import { Countdown } from "@/components/Countdown";
import { IconSearch } from "@/components/icons";
import {
  Badge,
  Empty,
  inputClass,
  tableClass,
  tdClass,
  theadClass,
  thClass,
  trClass,
  type Tone,
} from "@/components/ui";
import type { IdentifiedRequest } from "@/lib/chain-data";
import { formatUsd, formatXrp, shortHex } from "@/lib/format";
import { requestState } from "@/lib/states";
import { bytes32ToClassicAddress } from "@/lib/xrpl-address";

const TONE: Record<string, Tone> = {
  pending: "warn",
  ready: "accent",
  active: "info",
  good: "good",
  bad: "bad",
  muted: "neutral",
};

/** The payment requests of a treasury, newest first. */
export function RequestList({
  requests,
  emptyMessage,
  searchable = false,
}: {
  requests: IdentifiedRequest[];
  emptyMessage?: string;
  /** Adds a filter over the rows already loaded. It never fetches anything more. */
  searchable?: boolean;
}) {
  const [search, setSearch] = useState("");
  const needle = search.trim().toLowerCase();

  const shown =
    needle === ""
      ? requests
      : requests.filter((request) => {
          const destination = safeAddress(request.destinationAccountId);
          return (
            request.id.toString().includes(needle) ||
            (destination !== null && destination.toLowerCase().includes(needle)) ||
            requestState(request.state).label.toLowerCase().includes(needle) ||
            formatXrp(request.amountDrops).includes(needle)
          );
        });

  if (requests.length === 0) {
    return <Empty>{emptyMessage ?? "No payments have been proposed from this treasury."}</Empty>;
  }

  return (
    <>
      {searchable && (
        <div className="relative px-6 pt-5 pb-1">
          <IconSearch className="pointer-events-none absolute top-1/2 left-9.5 size-4 -translate-y-1/2 text-faint" />
          <input
            className={`${inputClass} pl-10`}
            placeholder="Filter by request, destination, amount or status…"
            value={search}
            onChange={(event) => setSearch(event.target.value)}
          />
        </div>
      )}

      {shown.length === 0 ? (
        <Empty>Nothing matches that filter.</Empty>
      ) : (
        <RequestTable requests={shown} />
      )}
    </>
  );
}

function RequestTable({ requests }: { requests: IdentifiedRequest[] }) {
  return (
    <div className="custom-scroll overflow-x-auto">
      <table className={tableClass}>
        <thead className={theadClass}>
          <tr>
            <th className={thClass}>Request</th>
            <th className={thClass}>Recipient</th>
            <th className={`${thClass} text-right`}>Amount</th>
            <th className={`${thClass} text-right`}>Approvals</th>
            <th className={thClass}>Status</th>
            <th className={thClass}>Timelock</th>
          </tr>
        </thead>
        <tbody>
          {requests.map((request) => {
            const state = requestState(request.state);
            const destination = safeAddress(request.destinationAccountId);
            return (
              <tr key={request.id.toString()} className={trClass}>
                <td className={tdClass}>
                  <Link href={`/requests/${request.id}`} className="numeric font-semibold text-accent hover:underline">
                    #{request.id.toString()}
                  </Link>
                </td>

                <td className={tdClass}>
                  <span className="numeric text-sm text-ink">
                    {destination ? shortHex(destination, 8, 4) : "unreadable"}
                  </span>
                  <span className="block text-xs text-faint">
                    {request.destinationTag === 0 ? "no destination tag" : `tag ${request.destinationTag}`}
                  </span>
                </td>

                <td className={`${tdClass} numeric text-right`}>
                  {formatXrp(request.amountDrops)} XRP
                  <span className="block text-xs text-faint">
                    ${formatUsd(request.amountUsdAtProposal)} at proposal
                  </span>
                </td>

                <td className={`${tdClass} numeric text-right`}>
                  {request.approvals} / {request.requiredApprovals}
                </td>

                <td className={tdClass}>
                  <Badge tone={TONE[state.tone] ?? "neutral"} dot>
                    {state.label}
                  </Badge>
                </td>

                <td className={`${tdClass} text-xs`}>
                  <Countdown eligibleAt={request.eligibleAt} />
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

function safeAddress(word: string): string | null {
  try {
    return bytes32ToClassicAddress(word as `0x${string}`);
  } catch {
    return null;
  }
}
