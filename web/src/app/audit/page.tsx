"use client";

import { AuditLogView } from "@/components/AuditLogView";
import { AddressLink } from "@/components/links";
import { Card, KeyValue, Mono } from "@/components/ui";
import { useWiring } from "@/hooks/useAegis";
import { isWired } from "@/lib/chain-data";
import { requireConfig } from "@/lib/config";

export default function AuditPage() {
  const config = requireConfig();
  const wiring = useWiring();

  return (
    <div className="space-y-6">
      <header>
        <h1 className="text-xl font-semibold text-ink">Audit log</h1>
        <p className="mt-1 text-sm text-muted">
          Every event the three Aegis contracts emitted, in the order the chain recorded them. Nothing here comes from
          an Aegis service, because there is none — the same history is available to anyone with an RPC endpoint.
        </p>
      </header>

      <Card title="This deployment" subtitle="Addresses read from the chain, not from configuration.">
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
          <KeyValue label="ExecutionVerifier" hint="The only address that may settle or fail a request, and only on a verified FDC proof.">
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

      <Card title="How this is read">
        <p className="text-sm text-muted">
          The dashboard fetches logs in chunks of {config.logChunkBlocks.toString()} blocks, because the public Coston2
          RPC refuses a wider <code className="numeric text-accent">eth_getLogs</code> range, and scans back{" "}
          {config.logLookbackBlocks.toString()} blocks from the head. Point{" "}
          <code className="numeric text-accent">NEXT_PUBLIC_RPC_URL</code> at an archive node without that cap and raise{" "}
          <code className="numeric text-accent">NEXT_PUBLIC_LOG_CHUNK_BLOCKS</code> to pull the entire history at once.
        </p>
      </Card>

      <AuditLogView title="Events" />
    </div>
  );
}
