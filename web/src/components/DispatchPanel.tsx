"use client";

import { useState } from "react";

import { TxFeedback } from "@/components/TxFeedback";
import { Alert, buttonClass, Card, Field, inputClass, KeyValue, Mono } from "@/components/ui";
import { useNow, usePolicyDigest, useWiring, useXrplFees, useXrplLedger } from "@/hooks/useAegis";
import { useAegisTx } from "@/hooks/useAegisTx";
import type { IdentifiedRequest } from "@/lib/chain-data";
import { isWired } from "@/lib/chain-data";
import { contractHandles, type Treasury } from "@/lib/contracts";
import { formatDrops, formatDuration } from "@/lib/format";

/**
 * Dispatch: the moment the whole policy is checked again and the instruction
 * goes to the TEE.
 *
 * The three values chosen here are not policy — they are XRPL facts. The first
 * ledger is where the payment could earliest appear, the last is where it
 * expires, and the fee is what the network is charging right now. All three are
 * read live rather than assumed, because a `LastLedgerSequence` in the past
 * produces a transaction that can never be included and never be proven absent.
 */
export function DispatchPanel({
  request,
  treasury,
  canDispatch,
}: {
  request: IdentifiedRequest;
  treasury: Treasury;
  canDispatch: boolean;
}) {
  const wiring = useWiring();
  const ledger = useXrplLedger();
  const fees = useXrplFees();
  const now = useNow();
  const tx = useAegisTx();
  const { paymentController } = contractHandles();

  const [ledgerMargin, setLedgerMargin] = useState("20");
  const [feeDrops, setFeeDrops] = useState("");

  const marginValue = /^\d+$/.test(ledgerMargin.trim()) ? Number(ledgerMargin.trim()) : null;
  const firstLedger = ledger.data;
  const lastLedger = firstLedger !== undefined && marginValue !== null ? firstLedger + marginValue : undefined;

  const suggestedFee = fees.data ? (fees.data.openLedgerFeeDrops > fees.data.baseFeeDrops ? fees.data.openLedgerFeeDrops : fees.data.baseFeeDrops) : undefined;
  const feeText = feeDrops.trim() === "" ? (suggestedFee?.toString() ?? "") : feeDrops.trim();
  const feeValue = /^\d+$/.test(feeText) && BigInt(feeText) > 0n ? BigInt(feeText) : null;

  const timelockElapsed = now >= request.eligibleAt;
  const senderWired = isWired(wiring.data?.controllerInstructionSender);

  const digest = usePolicyDigest(
    firstLedger !== undefined && lastLedger !== undefined && feeValue !== null
      ? {
          requestId: request.id,
          treasuryId: request.treasuryId,
          destinationAccountId: request.destinationAccountId,
          destinationTag: request.destinationTag,
          amountDrops: request.amountDrops,
          sequence: treasury.nextSequence,
          lastLedgerSequence: lastLedger,
          feeDrops: feeValue,
        }
      : undefined,
  );

  const ready =
    canDispatch &&
    timelockElapsed &&
    senderWired &&
    firstLedger !== undefined &&
    lastLedger !== undefined &&
    feeValue !== null &&
    !tx.isBusy;

  return (
    <Card
      title="Dispatch"
      subtitle="Re-runs the entire policy check against the price and the window as they are now, then sends the signing instruction."
    >
      {!senderWired && (
        <div className="mb-4">
          <Alert tone="warn" title="No instruction sender is wired">
            The controller has nowhere to send the signing instruction, so dispatch is refused.
          </Alert>
        </div>
      )}

      {!timelockElapsed && (
        <div className="mb-4">
          <Alert tone="warn" title="The timelock has not elapsed">
            {formatDuration(request.eligibleAt - now)} remaining. The contract checks this itself; the countdown here
            is only a convenience.
          </Alert>
        </div>
      )}

      <div className="grid gap-4 md:grid-cols-2">
        <Field
          label="Ledger margin"
          hint={
            firstLedger !== undefined
              ? `XRPL is on ledger ${firstLedger}. The payment expires after ${lastLedger ?? "…"}.`
              : "Reading the current XRPL ledger…"
          }
          error={marginValue === null ? "A whole number of ledgers." : null}
        >
          <input
            className={inputClass}
            inputMode="numeric"
            value={ledgerMargin}
            onChange={(event) => setLedgerMargin(event.target.value)}
          />
        </Field>

        <Field
          label="Fee (drops)"
          hint={
            fees.data
              ? `XRPL reference fee ${formatDrops(fees.data.baseFeeDrops)}, open-ledger ${formatDrops(
                  fees.data.openLedgerFeeDrops,
                )}.`
              : "Reading current XRPL fees…"
          }
          error={feeValue === null && feeText !== "" ? "A fee is a whole number of drops, above zero." : null}
        >
          <input
            className={inputClass}
            inputMode="numeric"
            placeholder={suggestedFee?.toString() ?? ""}
            value={feeDrops}
            onChange={(event) => setFeeDrops(event.target.value)}
          />
        </Field>
      </div>

      <dl className="mt-4">
        <KeyValue label="XRPL sequence" hint="Taken from the registry, not from the ledger — the registry only advances it on a proof.">
          <Mono>{treasury.nextSequence}</Mono>
        </KeyValue>
        <KeyValue
          label="Ledger range"
          hint="The lower bound is what lets a non-execution proof cover every ledger the payment could have reached."
        >
          <Mono>
            {firstLedger ?? "…"} – {lastLedger ?? "…"}
          </Mono>
        </KeyValue>
        <KeyValue
          label="Policy digest"
          hint="The enclave recomputes this from the fields it decodes and refuses to sign on any mismatch."
        >
          <Mono className="break-all">{digest.data ?? "…"}</Mono>
        </KeyValue>
      </dl>

      <div className="mt-4 flex items-center gap-3">
        <button
          type="button"
          className={buttonClass("primary")}
          disabled={!ready}
          onClick={() => {
            if (firstLedger === undefined || lastLedger === undefined || feeValue === null) return;
            void tx.run({
              address: paymentController.address,
              abi: paymentController.abi,
              functionName: "dispatch",
              args: [request.id, firstLedger, lastLedger, feeValue],
            });
          }}
        >
          {tx.isBusy ? "Working…" : "Dispatch to the TEE"}
        </button>
        {!canDispatch && <span className="text-xs text-faint">Dispatch takes the PROPOSER role.</span>}
      </div>

      <TxFeedback state={tx.state} doneMessage="Dispatched — the instruction is with the TEE" />
    </Card>
  );
}
