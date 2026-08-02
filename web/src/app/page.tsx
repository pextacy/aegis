"use client";

import Link from "next/link";
import { useState } from "react";
import { useAccount } from "wagmi";

import { TreasuryCard } from "@/components/TreasuryCard";
import { TxFeedback } from "@/components/TxFeedback";
import { buttonClass, Card, Loading, selectClass } from "@/components/ui";
import { usePolicies, useRolesForAccount, useTreasuries } from "@/hooks/useAegis";
import { useAegisTx } from "@/hooks/useAegisTx";
import { contractHandles } from "@/lib/contracts";
import { ROLE_POLICY_ADMIN, hasRole } from "@/lib/roles";

export default function TreasuriesPage() {
  const treasuries = useTreasuries();
  const policies = usePolicies();
  const { address } = useAccount();
  const roles = useRolesForAccount(address, policies.data?.map((policy) => policy.id));

  const adminPolicies = (policies.data ?? []).filter((policy) =>
    hasRole(roles.data?.get(policy.id.toString()) ?? 0, ROLE_POLICY_ADMIN),
  );

  return (
    <div className="space-y-6">
      <header className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="text-xl font-semibold text-ink">Treasuries</h1>
          <p className="mt-1 text-sm text-muted">
            Each treasury holds an XRPL account whose key exists only inside a TEE, and spends only what its policy
            allows.
          </p>
        </div>
        <Link href="/policies/new" className={buttonClass("secondary")}>
          New policy
        </Link>
      </header>

      {adminPolicies.length > 0 && <CreateTreasury policyIds={adminPolicies.map((policy) => policy.id)} />}

      {treasuries.isPending ? (
        <Loading what="treasuries" />
      ) : treasuries.data && treasuries.data.length > 0 ? (
        <div className="grid gap-4">
          {treasuries.data.map((treasury) => (
            <TreasuryCard key={treasury.id.toString()} treasury={treasury} />
          ))}
        </div>
      ) : (
        <Card title="No treasuries yet">
          <p className="text-sm text-muted">
            A treasury needs a policy first — the policy is what decides how much may leave it, to whom, and with how
            many approvals.{" "}
            <Link href="/policies/new" className="text-accent underline underline-offset-2">
              Create a policy
            </Link>
            , then come back here.
          </p>
        </Card>
      )}
    </div>
  );
}

function CreateTreasury({ policyIds }: { policyIds: bigint[] }) {
  const [policyId, setPolicyId] = useState<string>(policyIds[0]?.toString() ?? "");
  const tx = useAegisTx();
  const { treasuryRegistry } = contractHandles();

  const selected = policyIds.find((id) => id.toString() === policyId) ?? policyIds[0];

  return (
    <Card
      title="Create a treasury"
      subtitle="You hold POLICY_ADMIN on the policies listed here, which is what createTreasury requires."
    >
      <div className="flex flex-wrap items-end gap-3">
        <label className="block">
          <span className="text-xs font-medium tracking-wide text-muted uppercase">Governed by policy</span>
          <select
            className={`${selectClass} mt-1.5 w-48`}
            value={policyId}
            onChange={(event) => setPolicyId(event.target.value)}
          >
            {policyIds.map((id) => (
              <option key={id.toString()} value={id.toString()}>
                Policy {id.toString()}
              </option>
            ))}
          </select>
        </label>

        <button
          type="button"
          className={buttonClass("primary")}
          disabled={tx.isBusy || selected === undefined}
          onClick={() => {
            if (selected === undefined) return;
            void tx.run({
              address: treasuryRegistry.address,
              abi: treasuryRegistry.abi,
              functionName: "createTreasury",
              args: [selected],
            });
          }}
        >
          {tx.isBusy ? "Working…" : "Create treasury"}
        </button>
      </div>

      <p className="mt-3 text-xs text-faint">
        The XRPL account does not exist yet at this point. It is created when the enclave generates the treasury&apos;s
        key and the registry verifies the address against it.
      </p>

      <TxFeedback state={tx.state} doneMessage="Treasury created" />
    </Card>
  );
}
