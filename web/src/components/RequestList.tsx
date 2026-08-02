"use client";

import Link from "next/link";

import { Countdown } from "@/components/Countdown";
import { Badge, Empty, type Tone } from "@/components/ui";
import type { IdentifiedRequest } from "@/lib/chain-data";
import { formatUsd, formatXrp } from "@/lib/format";
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
export function RequestList({ requests }: { requests: IdentifiedRequest[] }) {
  if (requests.length === 0) {
    return <Empty>No payments have been proposed from this treasury.</Empty>;
  }

  return (
    <div className="overflow-x-auto">
      <table className="w-full text-sm">
        <thead>
          <tr className="border-b border-line text-left text-xs tracking-wide text-faint uppercase">
            <th className="py-2 pr-4 font-medium">Request</th>
            <th className="py-2 pr-4 font-medium">Amount</th>
            <th className="py-2 pr-4 font-medium">Destination</th>
            <th className="py-2 pr-4 font-medium">Approvals</th>
            <th className="py-2 pr-4 font-medium">State</th>
            <th className="py-2 font-medium">Timelock</th>
          </tr>
        </thead>
        <tbody>
          {requests.map((request) => {
            const state = requestState(request.state);
            const destination = safeAddress(request.destinationAccountId);
            return (
              <tr key={request.id.toString()} className="border-b border-line last:border-b-0 hover:bg-raised/60">
                <td className="numeric py-2.5 pr-4">
                  <Link href={`/requests/${request.id}`} className="text-accent underline underline-offset-2">
                    #{request.id.toString()}
                  </Link>
                </td>
                <td className="numeric py-2.5 pr-4 text-ink">
                  {formatXrp(request.amountDrops)} XRP
                  <span className="block text-xs text-faint">
                    ${formatUsd(request.amountUsdAtProposal)} at proposal
                  </span>
                </td>
                <td className="numeric py-2.5 pr-4 text-muted">
                  {destination ?? "unreadable"}
                  {request.destinationTag !== 0 && (
                    <span className="block text-xs text-faint">tag {request.destinationTag}</span>
                  )}
                </td>
                <td className="numeric py-2.5 pr-4 text-ink">
                  {request.approvals} / {request.requiredApprovals}
                </td>
                <td className="py-2.5 pr-4">
                  <Badge tone={TONE[state.tone] ?? "neutral"}>{state.label}</Badge>
                </td>
                <td className="py-2.5 text-xs">
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
