"use client";

import { AddressLink } from "@/components/links";
import { TxFeedback } from "@/components/TxFeedback";
import { Alert, buttonClass, Card, KeyValue, Mono } from "@/components/ui";
import { useWiring } from "@/hooks/useAegis";
import { useAegisTx } from "@/hooks/useAegisTx";
import { isWired } from "@/lib/chain-data";
import { wiredHandles, type Treasury } from "@/lib/contracts";

/**
 * Creating a treasury's XRPL key.
 *
 * The key is generated inside the enclave and never imported. What comes back is
 * a public key and an address, and the registry re-derives the AccountID from
 * that key on-chain before it will bind anything — so the address shown here is
 * verified rather than reported.
 */
export function KeygenPanel({ treasury, canAdmin }: { treasury: Treasury; canAdmin: boolean }) {
  const wiring = useWiring();
  const tx = useAegisTx();

  const senderAddress = wiring.data?.registryInstructionSender;
  const senderReady = isWired(senderAddress) && wiring.data?.extensionId !== null;

  return (
    <Card
      title="Key generation"
      subtitle="Asks the TEE for this treasury's XRPL key. One binding per treasury, for its whole lifetime."
    >
      <dl className="mb-4">
        <KeyValue label="Instruction sender">
          {isWired(senderAddress) ? (
            <AddressLink address={senderAddress as string} />
          ) : (
            <span className="text-warn">not wired</span>
          )}
        </KeyValue>
        <KeyValue
          label="FCC extension id"
          hint="Found by setExtensionId(), which scans the registry from 0x10000 — ids below that are reserved for system extensions."
        >
          {wiring.data?.extensionId != null ? (
            <Mono>{wiring.data.extensionId.toString()}</Mono>
          ) : (
            <span className="text-warn">not set</span>
          )}
        </KeyValue>
      </dl>

      {!canAdmin ? (
        <p className="text-sm text-faint">Only a POLICY_ADMIN of this treasury&apos;s policy may request a key.</p>
      ) : !senderReady ? (
        <Alert tone="warn" title="Signing is not wired up yet">
          The instruction sender must be deployed, wired into the registry, and registered as an FCC extension before a
          key can be generated.
        </Alert>
      ) : (
        <>
          <button
            type="button"
            className={buttonClass("primary")}
            disabled={tx.isBusy}
            onClick={() => {
              if (!senderAddress) return;
              void tx.run({
                ...wiredHandles(senderAddress, senderAddress).instructionSender,
                functionName: "requestKeygen",
                args: [treasury.id],
              });
            }}
          >
            {tx.isBusy ? "Working…" : "Generate the XRPL key in the enclave"}
          </button>
          <p className="mt-3 text-xs text-faint">
            This sends an instruction to the TEE. The address appears here once the enclave answers and the registry
            has re-derived the AccountID from the returned public key — a reported address that does not match the key
            is refused on-chain.
          </p>
        </>
      )}

      <TxFeedback state={tx.state} doneMessage="Key generation requested" />
    </Card>
  );
}
