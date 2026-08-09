"use client";

import { useState } from "react";

import { IconAlert, IconFreeze } from "@/components/icons";
import { TxFeedback } from "@/components/TxFeedback";
import { Alert, buttonClass, Card } from "@/components/ui";
import { useAegisTx } from "@/hooks/useAegisTx";
import { contractHandles, type Treasury } from "@/lib/contracts";

/**
 * The guardian freeze.
 *
 * One guardian, one transaction, no threshold and no delay — stopping payments
 * on suspicion should be instant. The confirmation step exists because it is
 * also irreversible without the policy's amendment threshold and timelock, and
 * that asymmetry should be visible at the moment of clicking.
 */
export function FreezeControl({ treasury, isGuardian }: { treasury: Treasury; isGuardian: boolean }) {
  const { treasuryRegistry } = contractHandles();
  const tx = useAegisTx();
  const [confirming, setConfirming] = useState(false);

  if (treasury.frozen) {
    return (
      <Card title="Frozen">
        <Alert tone="bad" title="This treasury is frozen">
          Proposing, approving and dispatching are all refused while it is frozen. Unfreezing takes the policy&apos;s
          amendment threshold and timelock — propose an Unfreeze amendment below.
        </Alert>
      </Card>
    );
  }

  return (
    <section className="rounded-lg border border-bad/30 bg-bad-dim/25 p-6">
      <div className="flex flex-wrap items-start gap-4">
        <span className="flex size-11 shrink-0 items-center justify-center rounded-lg bg-bad-dim text-bad">
          <IconAlert className="size-6" />
        </span>

        <div className="min-w-0 flex-1">
          <h2 className="text-lg font-semibold tracking-tight text-bad">Danger zone</h2>
          <p className="mt-1 max-w-2xl text-sm text-muted">
            Freezing stops proposing, approving and dispatching at once — no threshold, no delay, which is the point of
            a guardian. Reversing it needs the policy&apos;s amendment approvals and its full timelock.
          </p>

          {!isGuardian ? (
            <p className="mt-4 text-sm text-faint">
              You do not hold GUARDIAN on this treasury&apos;s policy, so you cannot freeze it.
            </p>
          ) : confirming ? (
            <div className="mt-4 space-y-3">
              <Alert tone="warn" title={`Freeze treasury ${treasury.id.toString()}?`}>
                Every in-flight request stops where it is.
              </Alert>
              <div className="flex flex-wrap gap-3">
                <button
                  type="button"
                  className={buttonClass("danger")}
                  disabled={tx.isBusy}
                  onClick={async () => {
                    const frozen = await tx.run({
                      address: treasuryRegistry.address,
                      abi: treasuryRegistry.abi,
                      functionName: "freeze",
                      args: [treasury.id],
                    });
                    if (frozen) setConfirming(false);
                  }}
                >
                  {tx.isBusy ? "Freezing…" : "Yes, freeze it"}
                </button>
                <button type="button" className={buttonClass("ghost")} onClick={() => setConfirming(false)}>
                  Cancel
                </button>
              </div>
            </div>
          ) : null}

          <TxFeedback state={tx.state} doneMessage="Treasury frozen" />
        </div>

        {isGuardian && !confirming && (
          <button type="button" className={buttonClass("danger")} onClick={() => setConfirming(true)}>
            <IconFreeze className="size-4" />
            Freeze treasury
          </button>
        )}
      </div>
    </section>
  );
}
