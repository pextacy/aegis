"use client";

import { TxLink } from "@/components/links";
import { Alert, FailureAlert } from "@/components/ui";
import { txStatusLabel, type TxState } from "@/hooks/useAegisTx";

/** The state of an in-flight or finished transaction, including why it failed. */
export function TxFeedback({ state, doneMessage }: { state: TxState; doneMessage?: string }) {
  if (state.status === "idle") return null;

  if (state.status === "failed") {
    return (
      <div className="mt-4">
        <FailureAlert error={state.error} />
      </div>
    );
  }

  if (state.status === "done") {
    return (
      <div className="mt-4">
        <Alert tone="good" title={doneMessage ?? "Confirmed"}>
          {state.hash && (
            <>
              Recorded on-chain in <TxLink hash={state.hash} />.
            </>
          )}
        </Alert>
      </div>
    );
  }

  return (
    <div className="mt-4">
      <Alert tone="info" title={txStatusLabel(state.status)}>
        {state.hash ? <TxLink hash={state.hash} /> : "Nothing has been sent to the chain yet."}
      </Alert>
    </div>
  );
}
