"use client";

import { AuditLogView } from "@/components/AuditLogView";
import { IconShield } from "@/components/icons";
import { AddressLink } from "@/components/links";
import { Card, KeyValue, Mono, PageHeader } from "@/components/ui";
import { useAuditLog, useWiring } from "@/hooks/useAegis";
import { isWired } from "@/lib/chain-data";
import { requireConfig } from "@/lib/config";

export default function AuditPage() {
  const config = requireConfig();
  const wiring = useWiring();
  const log = useAuditLog();

  return (
    <div className="space-y-8">
      <PageHeader
        title="Audit log"
        description="Every event the Aegis contracts emitted, in the order the chain recorded them. Nothing here comes from an Aegis service, because there is none — the same history is available to anyone with an RPC endpoint."
      />

      <section className="rounded-lg border border-line bg-surface px-6 py-5">
        <div className="flex flex-wrap items-start justify-between gap-6">
          <div className="max-w-2xl">
            <div className="flex items-center gap-2 text-sm font-semibold text-accent">
              <IconShield className="size-4" />
              Read directly from Flare {config.chainId}
            </div>
            <h2 className="mt-2 text-2xl font-semibold tracking-tight text-ink">
              {log.data
                ? log.data.complete
                  ? "The whole history is on this page"
                  : "Scanning a bounded window of history"
                : "Scanning history"}
            </h2>
            <p className="mt-2 text-sm text-muted">
              Logs are fetched in chunks of {config.logChunkBlocks.toString()} blocks, because the public Coston2 RPC
              refuses a wider <code className="numeric text-accent">eth_getLogs</code> range, and the scan reaches back{" "}
              {config.logLookbackBlocks.toString()} blocks from the head. Point{" "}
              <code className="numeric text-accent">NEXT_PUBLIC_RPC_URL</code> at an archive node without that cap and
              raise <code className="numeric text-accent">NEXT_PUBLIC_LOG_CHUNK_BLOCKS</code> to pull everything at
              once.
            </p>
          </div>

          <div className="text-right">
            <div className="label-caps text-faint">Lowest block scanned</div>
            <div className="numeric mt-1 text-3xl font-medium text-ink">
              {log.data ? log.data.fromBlock.toString() : "…"}
            </div>
            <div className="mt-2 h-1 w-40 rounded-full bg-accent" aria-hidden />
            <div className="mt-2 text-xs text-faint">
              {log.data
                ? log.data.complete
                  ? "Reaches the deployment block."
                  : "Earlier events exist outside this window."
                : "Reading event logs…"}
            </div>
          </div>
        </div>
      </section>

      <AuditLogView title="Events" />

      <div className="grid gap-6 lg:grid-cols-2">
        <Card title="This deployment" subtitle="Configured addresses, and the two the contracts name themselves.">
          <dl>
            <KeyValue label="PolicyEngine">
              <AddressLink address={config.policyEngine} />
            </KeyValue>
            <KeyValue label="TreasuryRegistry">
              <AddressLink address={config.treasuryRegistry} />
            </KeyValue>
            <KeyValue label="PaymentController">
              <AddressLink address={config.paymentController} />
            </KeyValue>
            <KeyValue
              label="AegisInstructionSender"
              hint="The only address that may deliver a TEE result. Wired into the registry and the controller once each."
            >
              {isWired(wiring.data?.registryInstructionSender) ? (
                <AddressLink address={wiring.data?.registryInstructionSender as string} />
              ) : (
                <span className="text-warn">not wired</span>
              )}
            </KeyValue>
            <KeyValue
              label="ExecutionVerifier"
              hint="The only address that may settle or fail a request, and only on a verified FDC proof."
            >
              {isWired(wiring.data?.registryExecutionVerifier) ? (
                <AddressLink address={wiring.data?.registryExecutionVerifier as string} />
              ) : (
                <span className="text-warn">not wired</span>
              )}
            </KeyValue>
            <KeyValue label="FCC extension id">
              {wiring.data?.extensionId != null ? (
                <Mono>{wiring.data.extensionId.toString()}</Mono>
              ) : (
                <span className="text-warn">not set</span>
              )}
            </KeyValue>
          </dl>
        </Card>

        <Card title="What an entry proves" subtitle="And what it does not.">
          <ul className="space-y-3 text-sm text-muted">
            <li>
              <span className="font-semibold text-ink">A Flare transaction hash</span> is the record that the contract
              accepted the call. Follow it to the explorer and the same event is there.
            </li>
            <li>
              <span className="font-semibold text-ink">An XRPL transaction id</span> appears on the events that produced
              or settled a signature. Until an FDC proof lands, a signature existing is not a payment happening.
            </li>
            <li>
              <span className="font-semibold text-ink">A gap in this list</span> means the scan did not reach that far
              back — not that nothing happened. The block range above says exactly how far it reached.
            </li>
          </ul>
        </Card>
      </div>
    </div>
  );
}
