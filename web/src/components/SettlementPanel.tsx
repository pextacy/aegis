"use client";

import { AddressLink, XrplTxLink } from "@/components/links";
import { Alert, Card, KeyValue, Mono } from "@/components/ui";
import { useAuditLog, useRequestReference, useWiring } from "@/hooks/useAegis";
import type { IdentifiedRequest } from "@/lib/chain-data";
import { isWired } from "@/lib/chain-data";
import { requestState } from "@/lib/states";

/**
 * What happens after the enclave signs.
 *
 * The signed transaction is public, and anyone can submit it — the submitter is
 * a liveness helper, not an authority. What moves the on-chain state is an FDC
 * proof, and the two facts a reader needs to check that proof themselves are on
 * this panel: the XRPL transaction id and the payment reference the memo must
 * carry.
 */
export function SettlementPanel({ request }: { request: IdentifiedRequest }) {
  const wiring = useWiring();
  const verifier = wiring.data?.registryExecutionVerifier;
  const reference = useRequestReference(isWired(verifier) ? verifier : undefined, request.id);
  const log = useAuditLog();

  const state = requestState(request.state);
  const xrplTxHash = log.data?.entries.find(
    (entry) => entry.requestId === request.id && entry.xrplTxHash !== undefined,
  )?.xrplTxHash;

  return (
    <Card
      title="Settlement"
      subtitle="Only a verified FDC proof moves this request to a terminal state. Nothing here is taken on the submitter's word."
    >
      {!isWired(verifier) && (
        <div className="mb-4">
          <Alert tone="warn" title="No execution verifier is wired">
            Until one is, a payment can be signed and submitted but its outcome cannot be proven on Flare.
          </Alert>
        </div>
      )}

      <dl>
        <KeyValue label="Current outcome">
          <span className="text-ink">{state.label}</span>
          <span className="mt-1 block text-xs text-faint">{state.description}</span>
        </KeyValue>

        <KeyValue label="Execution verifier">
          {isWired(verifier) ? <AddressLink address={verifier as string} /> : <span className="text-warn">not wired</span>}
        </KeyValue>

        <KeyValue
          label="Payment reference"
          hint="keccak256(abi.encode(requestId)), carried in the XRPL memo. This is what links the ledger transaction to this request in the proof."
        >
          <Mono className="break-all">{reference.data ?? "—"}</Mono>
        </KeyValue>

        <KeyValue
          label="XRPL transaction"
          hint={
            xrplTxHash
              ? "Taken from the signature the enclave returned, so it is the transaction id of the exact blob that was signed."
              : "Appears once the enclave has returned a signature within the scanned log range."
          }
        >
          {xrplTxHash ? <XrplTxLink hash={xrplTxHash} /> : "—"}
        </KeyValue>

        {request.sequence !== 0 && (
          <KeyValue
            label="Sequence and expiry"
            hint="A transaction that reached a ledger consumed its sequence even if it delivered nothing; one that expired did not."
          >
            <Mono>
              sequence {request.sequence}, ledgers {request.firstLedgerSequence} – {request.lastLedgerSequence}
            </Mono>
          </KeyValue>
        )}
      </dl>
    </Card>
  );
}
