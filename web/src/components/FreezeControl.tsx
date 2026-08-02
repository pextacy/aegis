"use client";

import { useState } from "react";

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
    <Card
      title="Guardian freeze"
      subtitle="Stops every payment path at once. No threshold, no delay — that is the point of a guardian."
    >
      {!isGuardian ? (
        <p className="text-sm text-faint">
          You do not hold GUARDIAN on this treasury&apos;s policy, so you cannot freeze it.
        </p>
      ) : confirming ? (
        <div className="space-y-3">
          <Alert tone="warn" title={`Freeze treasury ${treasury.id.toString()}?`}>
            Every in-flight request stops where it is. Reversing this needs the policy&apos;s amendment approvals and
            its full timelock.
          </Alert>
          <div className="flex gap-3">
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
      ) : (
        <button type="button" className={buttonClass("danger")} onClick={() => setConfirming(true)}>
          Freeze treasury
        </button>
      )}

      <TxFeedback state={tx.state} doneMessage="Treasury frozen" />
    </Card>
  );
}
