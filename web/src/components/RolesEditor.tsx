"use client";

import { useState } from "react";
import { isAddress, type Address } from "viem";

import { AddressLink } from "@/components/links";
import { TxFeedback } from "@/components/TxFeedback";
import { Badge, buttonClass, Card, checkboxClass, Empty, Field, inputClass } from "@/components/ui";
import { useGuardians, useRoles } from "@/hooks/useAegis";
import { useAegisTx } from "@/hooks/useAegisTx";
import { contractHandles } from "@/lib/contracts";
import { describeRoles, maskOf, ROLES } from "@/lib/roles";

/**
 * Role membership for a policy.
 *
 * The mask is written whole, never toggled — so what an address may do is a
 * single fact on screen rather than something inferred from a history of grants
 * and revokes. Loading an address shows its current authority before anything is
 * changed.
 */
export function RolesEditor({ policyId, canEdit }: { policyId: bigint; canEdit: boolean }) {
  const { policyEngine } = contractHandles();
  const tx = useAegisTx();
  const guardians = useGuardians(policyId);

  const [account, setAccount] = useState("");
  const [selected, setSelected] = useState<number[]>([]);
  const [loadedFor, setLoadedFor] = useState<string | null>(null);

  const valid = isAddress(account.trim());
  const target = valid ? (account.trim() as Address) : undefined;
  const current = useRoles(policyId, target);

  // Show the address's existing authority the moment it becomes readable, so an
  // edit starts from what is true rather than from an empty form.
  if (valid && current.data !== undefined && loadedFor !== account.trim()) {
    setLoadedFor(account.trim());
    setSelected(ROLES.filter((role) => (current.data & role.bit) === role.bit).map((role) => role.bit));
  }

  return (
    <Card
      title="Roles"
      subtitle="One address may hold several. Guardians are also the cosigners the TEE instruction carries."
    >
      <div className="mb-5">
        <div className="label-caps text-faint">Guardians</div>
        {guardians.isPending ? (
          <p className="mt-1 text-sm text-faint">Reading…</p>
        ) : guardians.data && guardians.data.length > 0 ? (
          <ul className="mt-1 flex flex-wrap gap-2">
            {guardians.data.map((guardian) => (
              <li key={guardian}>
                <Badge tone="accent">
                  <AddressLink address={guardian} />
                </Badge>
              </li>
            ))}
          </ul>
        ) : (
          <Empty>No guardian holds this policy. Nobody can freeze a treasury governed by it.</Empty>
        )}
      </div>

      {canEdit ? (
        <>
          <Field
            label="Address"
            error={account.trim() !== "" && !valid ? "That is not a 20-byte address." : null}
            hint={
              valid && current.data !== undefined
                ? `Currently holds: ${describeRoles(current.data)}`
                : "Paste the address whose authority you are setting."
            }
          >
            <input
              className={inputClass}
              placeholder="0x…"
              value={account}
              onChange={(event) => setAccount(event.target.value)}
            />
          </Field>

          <div className="mt-4 grid gap-2 sm:grid-cols-2">
            {ROLES.map((role) => (
              <label
                key={role.key}
                className={`flex items-start gap-3 rounded-lg border px-4 py-3 text-sm transition-colors ${
                  selected.includes(role.bit) ? "border-accent bg-accent-dim" : "border-line bg-surface"
                }`}
              >
                <input
                  type="checkbox"
                  className={checkboxClass}
                  checked={selected.includes(role.bit)}
                  onChange={(event) =>
                    setSelected((current_) =>
                      event.target.checked
                        ? [...current_, role.bit]
                        : current_.filter((bit) => bit !== role.bit),
                    )
                  }
                />
                <span>
                  <span className="text-ink">{role.label}</span>
                  <span className="mt-0.5 block text-xs text-faint">{role.description}</span>
                </span>
              </label>
            ))}
          </div>

          <div className="mt-4 flex items-center gap-3">
            <button
              type="button"
              className={buttonClass("primary")}
              disabled={!valid || tx.isBusy}
              onClick={() => {
                if (!target) return;
                void tx.run({
                  address: policyEngine.address,
                  abi: policyEngine.abi,
                  functionName: "setRoles",
                  args: [policyId, target, maskOf(selected)],
                });
              }}
            >
              {tx.isBusy ? "Working…" : "Set roles"}
            </button>
            <span className="text-xs text-faint">
              Writes the complete mask: {selected.length === 0 ? "no authority" : describeRoles(maskOf(selected))}.
            </span>
          </div>

          <TxFeedback state={tx.state} doneMessage="Roles written" />
        </>
      ) : (
        <p className="text-sm text-faint">Only a POLICY_ADMIN of this policy may change roles.</p>
      )}
    </Card>
  );
}
