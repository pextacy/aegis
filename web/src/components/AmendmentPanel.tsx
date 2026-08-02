"use client";

import { useState } from "react";
import type { Address } from "viem";

import { Countdown } from "@/components/Countdown";
import { AddressLink } from "@/components/links";
import { TxFeedback } from "@/components/TxFeedback";
import { Badge, buttonClass, Card, Empty, Field, inputClass, selectClass } from "@/components/ui";
import { useAmendments, useHasApprovedAmendment, useNow } from "@/hooks/useAegis";
import { useAegisTx } from "@/hooks/useAegisTx";
import type { IdentifiedAmendment } from "@/lib/chain-data";
import { AMENDMENT_CHANGE_POLICY, AMENDMENT_UNFREEZE, contractHandles, type Policy } from "@/lib/contracts";
import { formatWindow } from "@/lib/format";

/**
 * Governed changes to a treasury: unfreezing it, or moving it to another policy.
 *
 * Both take the current policy's amendment approvals and its timelock, and both
 * refuse the proposer's own approval. The panel shows the same three facts the
 * contract checks — threshold, timelock, and who has already approved.
 */
export function AmendmentPanel({
  treasuryId,
  policy,
  account,
  canPropose,
}: {
  treasuryId: bigint;
  policy: Policy;
  account: Address | undefined;
  canPropose: boolean;
}) {
  const { treasuryRegistry } = contractHandles();
  const amendments = useAmendments(treasuryId);
  const tx = useAegisTx();

  const [kind, setKind] = useState<string>(String(AMENDMENT_UNFREEZE));
  const [newPolicyId, setNewPolicyId] = useState("");

  const changingPolicy = Number(kind) === AMENDMENT_CHANGE_POLICY;
  const targetPolicy = /^\d+$/.test(newPolicyId.trim()) ? BigInt(newPolicyId.trim()) : null;
  const ready = !changingPolicy || (targetPolicy !== null && targetPolicy !== policy.id);

  return (
    <Card
      title="Amendments"
      subtitle={`${policy.amendApprovals} approval(s) and a ${formatWindow(
        policy.amendTimelock,
      )} timelock, from the policy governing this treasury.`}
    >
      {canPropose && (
        <div className="mb-6 grid gap-4 md:grid-cols-[14rem_1fr_auto] md:items-end">
          <Field label="Amendment">
            <select className={selectClass} value={kind} onChange={(event) => setKind(event.target.value)}>
              <option value={String(AMENDMENT_UNFREEZE)}>Unfreeze the treasury</option>
              <option value={String(AMENDMENT_CHANGE_POLICY)}>Move to another policy</option>
            </select>
          </Field>

          {changingPolicy ? (
            <Field
              label="New policy id"
              error={
                newPolicyId.trim() !== "" && targetPolicy === null
                  ? "A policy id is a whole number."
                  : targetPolicy !== null && targetPolicy === policy.id
                    ? "The treasury is already on that policy."
                    : null
              }
            >
              <input
                className={inputClass}
                inputMode="numeric"
                value={newPolicyId}
                onChange={(event) => setNewPolicyId(event.target.value)}
              />
            </Field>
          ) : (
            <p className="text-xs text-faint md:pb-2.5">
              Freezing took one guardian and no delay. Undoing it takes the full threshold.
            </p>
          )}

          <button
            type="button"
            className={buttonClass("primary")}
            disabled={!ready || tx.isBusy}
            onClick={() => {
              void tx.run({
                address: treasuryRegistry.address,
                abi: treasuryRegistry.abi,
                functionName: "proposeAmendment",
                args: [treasuryId, Number(kind), changingPolicy ? (targetPolicy as bigint) : 0n],
              });
            }}
          >
            Propose
          </button>
        </div>
      )}

      {amendments.isPending ? (
        <Empty>Reading amendments…</Empty>
      ) : amendments.data && amendments.data.length > 0 ? (
        <ul className="space-y-3">
          {amendments.data.map((amendment) => (
            <AmendmentRow
              key={amendment.id.toString()}
              amendment={amendment}
              policy={policy}
              account={account}
              onAction={(request) => void tx.run(request)}
              busy={tx.isBusy}
            />
          ))}
        </ul>
      ) : (
        <Empty>No amendment has been proposed for this treasury.</Empty>
      )}

      <TxFeedback state={tx.state} doneMessage="Recorded" />
    </Card>
  );
}

function AmendmentRow({
  amendment,
  policy,
  account,
  onAction,
  busy,
}: {
  amendment: IdentifiedAmendment;
  policy: Policy;
  account: Address | undefined;
  onAction: (request: {
    address: Address;
    abi: readonly unknown[];
    functionName: string;
    args: readonly unknown[];
  }) => void;
  busy: boolean;
}) {
  const { treasuryRegistry } = contractHandles();
  const now = useNow();
  const approved = useHasApprovedAmendment(amendment.id, account);

  const isProposer = account !== undefined && account.toLowerCase() === amendment.proposer.toLowerCase();
  const thresholdMet = amendment.approvals >= policy.amendApprovals;
  const timelockElapsed = now >= amendment.eligibleAt;

  return (
    <li className="rounded-md border border-line bg-raised p-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-2">
          <span className="numeric text-sm text-ink">Amendment {amendment.id.toString()}</span>
          <Badge tone={amendment.kind === AMENDMENT_UNFREEZE ? "warn" : "info"}>
            {amendment.kind === AMENDMENT_UNFREEZE
              ? "Unfreeze"
              : `Move to policy ${amendment.newPolicyId.toString()}`}
          </Badge>
          {amendment.executed && <Badge tone="good">Executed</Badge>}
        </div>
        <div className="numeric text-sm text-muted">
          {amendment.approvals} / {policy.amendApprovals} approvals
        </div>
      </div>

      <div className="mt-2 text-xs text-faint">
        Proposed by <AddressLink address={amendment.proposer} /> ·{" "}
        <Countdown eligibleAt={amendment.eligibleAt} prefix="Executable in" />
      </div>

      {!amendment.executed && (
        <div className="mt-3 flex flex-wrap items-center gap-3">
          <button
            type="button"
            className={buttonClass("secondary")}
            disabled={busy || !account || isProposer || approved.data === true}
            onClick={() =>
              onAction({
                address: treasuryRegistry.address,
                abi: treasuryRegistry.abi,
                functionName: "approveAmendment",
                args: [amendment.id],
              })
            }
          >
            {approved.data === true ? "You approved" : isProposer ? "Proposer cannot approve" : "Approve"}
          </button>

          <button
            type="button"
            className={buttonClass("primary")}
            disabled={busy || !thresholdMet || !timelockElapsed}
            onClick={() =>
              onAction({
                address: treasuryRegistry.address,
                abi: treasuryRegistry.abi,
                functionName: "executeAmendment",
                args: [amendment.id],
              })
            }
          >
            Execute
          </button>

          {!thresholdMet && <span className="text-xs text-faint">Needs more approvals.</span>}
          {thresholdMet && !timelockElapsed && <span className="text-xs text-faint">Timelock has not elapsed.</span>}
        </div>
      )}
    </li>
  );
}
