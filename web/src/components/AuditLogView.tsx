"use client";

import { TxLink, XrplTxLink } from "@/components/links";
import { Card, Empty, Loading } from "@/components/ui";
import { useAuditLog } from "@/hooks/useAegis";
import type { AuditEntry } from "@/lib/logs";

/**
 * The audit log.
 *
 * Everything here came out of an event log, so it can be reproduced by anyone
 * with an RPC endpoint and no Aegis service running. The scanned range is stated
 * rather than implied: the public Coston2 RPC caps `eth_getLogs` at 30 blocks,
 * so a bounded scan is a fact about the infrastructure and should not be
 * mistaken for a complete history.
 */
export function AuditLogView({
  title = "Audit log",
  filter,
}: {
  title?: string;
  filter?: (entry: AuditEntry) => boolean;
}) {
  const log = useAuditLog();

  const entries = log.data ? (filter ? log.data.entries.filter(filter) : log.data.entries) : [];

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
    >
      {log.isPending ? (
        <Loading what="event logs" />
      ) : entries.length === 0 ? (
        <Empty>Nothing in the scanned range.</Empty>
      ) : (
        <ol className="space-y-3">
          {entries.map((entry) => (
            <li
              key={`${entry.txHash}-${entry.logIndex}`}
              className="grid gap-1 border-b border-line pb-3 last:border-b-0 last:pb-0 sm:grid-cols-[10rem_1fr] sm:gap-4"
            >
              <div className="numeric text-xs text-faint">
                <div>block {entry.blockNumber.toString()}</div>
                <TxLink hash={entry.txHash} />
              </div>
              <div className="text-sm">
                <div className="text-ink">{entry.summary}</div>
                <div className="mt-1 text-xs text-faint">
                  {entry.contract}.{entry.eventName}
                  {entry.xrplTxHash && (
                    <>
                      {" · XRPL "}
                      <XrplTxLink hash={entry.xrplTxHash} />
                    </>
                  )}
                </div>
              </div>
            </li>
          ))}
        </ol>
      )}
    </Card>
  );
}
