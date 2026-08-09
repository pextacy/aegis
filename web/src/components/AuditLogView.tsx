"use client";

import { useState } from "react";

import { IconSearch } from "@/components/icons";
import { TxLink, XrplTxLink } from "@/components/links";
import { Badge, Card, Empty, inputClass, Loading, type Tone } from "@/components/ui";
import { useAuditLog } from "@/hooks/useAegis";
import type { AegisContract, AuditEntry } from "@/lib/logs";

/**
 * The audit log.
 *
 * Everything here came out of an event log, so it can be reproduced by anyone
 * with an RPC endpoint and no Aegis service running. The scanned range is stated
 * rather than implied: the public Coston2 RPC caps `eth_getLogs` at 30 blocks,
 * so a bounded scan is a fact about the infrastructure and should not be
 * mistaken for a complete history. Filtering here narrows what was scanned; it
 * never widens it, and the range stays on screen while you filter.
 */

const CONTRACTS: { key: AegisContract | "all"; label: string }[] = [
  { key: "all", label: "All events" },
  { key: "PolicyEngine", label: "Policy" },
  { key: "TreasuryRegistry", label: "Treasury" },
  { key: "PaymentController", label: "Payments" },
  { key: "AegisInstructionSender", label: "Enclave" },
  { key: "ExecutionVerifier", label: "Settlement" },
];

/** How an event reads: a refusal, a completion, or a step along the way. */
function toneOf(entry: AuditEntry): Tone {
  switch (entry.eventName) {
    case "PaymentFailed":
    case "ExecutionFailed":
    case "NonExecutionConfirmed":
    case "TreasuryFrozen":
    case "ProofAlreadyConsumed":
    case "PaymentCancelled":
      return "bad";
    case "PaymentSettled":
    case "SettlementConfirmed":
    case "TreasuryUnfrozen":
      return "good";
    case "PaymentSigned":
    case "PaymentDispatched":
    case "PaymentReady":
      return "accent";
    default:
      return "info";
  }
}

const DOT: Record<Tone, string> = {
  neutral: "bg-line-strong",
  good: "bg-good",
  warn: "bg-warn",
  bad: "bg-bad",
  info: "bg-accent",
  accent: "bg-accent",
};

export function AuditLogView({
  title = "Audit log",
  filter,
}: {
  title?: string;
  filter?: (entry: AuditEntry) => boolean;
}) {
  const log = useAuditLog();
  const [contract, setContract] = useState<AegisContract | "all">("all");
  const [search, setSearch] = useState("");

  const entries = log.data ? (filter ? log.data.entries.filter(filter) : log.data.entries) : [];

  const needle = search.trim().toLowerCase();
  const shown = entries.filter((entry) => {
    if (contract !== "all" && entry.contract !== contract) return false;
    if (needle === "") return true;
    return (
      entry.summary.toLowerCase().includes(needle) ||
      entry.eventName.toLowerCase().includes(needle) ||
      entry.txHash.toLowerCase().includes(needle) ||
      entry.blockNumber.toString().includes(needle)
    );
  });

  return (
    <Card
      title={title}
      subtitle={
        log.data
          ? log.data.complete
            ? `Complete, from the deployment block ${log.data.fromBlock} to ${log.data.toBlock}.`
            : `Blocks ${log.data.fromBlock} to ${log.data.toBlock}. Earlier events exist but are outside the configured lookback.`
          : undefined
      }
      actions={
        log.data ? (
          <div className="text-right">
            <div className="label-caps text-faint">Highest block scanned</div>
            <div className="numeric text-lg text-ink">{log.data.toBlock.toString()}</div>
          </div>
        ) : undefined
      }
    >
      <div className="flex flex-wrap items-center gap-3">
        <div className="relative min-w-[16rem] flex-1">
          <IconSearch className="pointer-events-none absolute top-1/2 left-3.5 size-4 -translate-y-1/2 text-faint" />
          <input
            className={`${inputClass} pl-10`}
            placeholder="Search event, summary, hash or block…"
            value={search}
            onChange={(event) => setSearch(event.target.value)}
          />
        </div>

        <div className="flex flex-wrap gap-2">
          {CONTRACTS.map((option) => (
            <button
              key={option.key}
              type="button"
              onClick={() => setContract(option.key)}
              className={`rounded-lg px-3 py-2 text-sm font-semibold transition-colors ${
                contract === option.key
                  ? "bg-accent text-white"
                  : "border border-line bg-surface text-muted hover:text-ink"
              }`}
            >
              {option.label}
            </button>
          ))}
        </div>
      </div>

      <div className="mt-6">
        {log.isPending ? (
          <Loading what="event logs" />
        ) : shown.length === 0 ? (
          <Empty>
            {entries.length === 0
              ? "Nothing in the scanned range."
              : "Nothing matches that filter within the scanned range."}
          </Empty>
        ) : (
          <ol className="relative space-y-3 border-l border-line pl-6">
            {shown.map((entry) => {
              const tone = toneOf(entry);
              return (
                <li key={`${entry.txHash}-${entry.logIndex}`} className="relative">
                  <span
                    className={`absolute top-5 -left-[1.8125rem] size-2.5 rounded-full ring-4 ring-surface ${DOT[tone]}`}
                    aria-hidden
                  />
                  <div
                    className={`rounded-lg border px-4 py-3 ${
                      tone === "bad" ? "border-bad/25 bg-bad-dim/25" : "border-line bg-surface"
                    }`}
                  >
                    <div className="flex flex-wrap items-center justify-between gap-2">
                      <div className="flex flex-wrap items-center gap-2">
                        <span className="text-sm font-semibold text-ink">{entry.eventName}</span>
                        <Badge tone={tone}>{entry.contract}</Badge>
                      </div>
                      <span className="numeric text-xs text-faint">block {entry.blockNumber.toString()}</span>
                    </div>

                    <p className="mt-1.5 text-sm text-muted">{entry.summary}</p>

                    <div className="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1 text-xs">
                      <span className="text-faint">
                        Flare <TxLink hash={entry.txHash} />
                      </span>
                      {entry.xrplTxHash && (
                        <span className="text-faint">
                          XRPL <XrplTxLink hash={entry.xrplTxHash} />
                        </span>
                      )}
                    </div>
                  </div>
                </li>
              );
            })}
          </ol>
        )}
      </div>
    </Card>
  );
}
