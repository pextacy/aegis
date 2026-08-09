"use client";

import Link from "next/link";
import { useState } from "react";
import { useAccount } from "wagmi";

import { IconPlus, IconPolicy, IconTreasury, IconWallet } from "@/components/icons";
import { TreasuryTable } from "@/components/TreasuryTable";
import { TxFeedback } from "@/components/TxFeedback";
import { buttonClass, Card, Loading, PageHeader, selectClass, StatCard } from "@/components/ui";
import { usePolicies, useRolesForAccount, useTreasuries, useXrplAccounts } from "@/hooks/useAegis";
import { useAegisTx } from "@/hooks/useAegisTx";
import { contractHandles } from "@/lib/contracts";
import { formatXrp } from "@/lib/format";
import { ROLE_POLICY_ADMIN, hasRole } from "@/lib/roles";
import { bytes32ToClassicAddress } from "@/lib/xrpl-address";

export default function TreasuriesPage() {
  const treasuries = useTreasuries();
  const policies = usePolicies();
  const { address } = useAccount();
  const roles = useRolesForAccount(address, policies.data?.map((policy) => policy.id));

  const list = treasuries.data ?? [];
  const accounts = useXrplAccounts(list.map((treasury) => safeAddress(treasury.xrplAccountId)));

  const funded = accounts.filter((account) => account.data);
  const heldDrops = funded.reduce((total, account) => total + (account.data?.balanceDrops ?? 0n), 0n);
  const frozen = list.filter((treasury) => treasury.frozen).length;

  const adminPolicies = (policies.data ?? []).filter((policy) =>
    hasRole(roles.data?.get(policy.id.toString()) ?? 0, ROLE_POLICY_ADMIN),
  );

  return (
    <div className="space-y-8">
      <PageHeader
        title="Treasuries"
        description="Each treasury holds an XRPL account whose key exists only inside a TEE, and spends only what its policy allows."
        actions={
          <Link href="/policies/new" className={buttonClass("primary")}>
            <IconPlus className="size-4" />
            New policy
          </Link>
        }
      />

      <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
        <StatCard
          label="XRP held"
          value={treasuries.isPending ? "…" : `${formatXrp(heldDrops)} XRP`}
          hint={`Read from XRPL across ${funded.length} funded ${funded.length === 1 ? "account" : "accounts"}.`}
          icon={<IconWallet className="size-5" />}
        />
        <StatCard
          label="Treasuries"
          value={treasuries.isPending ? "…" : list.length}
          hint={frozen === 0 ? "None frozen." : `${frozen} frozen by a guardian.`}
          tone={frozen > 0 ? "bad" : "neutral"}
          icon={<IconTreasury className="size-5" />}
        />
        <StatCard
          label="Policies"
          value={policies.isPending ? "…" : (policies.data?.length ?? 0)}
          hint="Every treasury is governed by exactly one."
          icon={<IconPolicy className="size-5" />}
        />
      </div>

      {adminPolicies.length > 0 && <CreateTreasury policyIds={adminPolicies.map((policy) => policy.id)} />}

      <Card title="All treasuries" bodyClassName="">
        {treasuries.isPending ? (
          <div className="px-6">
            <Loading what="treasuries" />
          </div>
        ) : list.length > 0 ? (
          <TreasuryTable treasuries={list} />
        ) : (
          <div className="px-6 py-8 text-sm text-muted">
            A treasury needs a policy first — the policy is what decides how much may leave it, to whom, and with how
            many approvals.{" "}
            <Link href="/policies/new" className="font-medium text-accent underline underline-offset-2">
              Create a policy
            </Link>
            , then come back here.
          </div>
        )}
      </Card>
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
          <span className="text-sm font-medium text-ink">Governed by policy</span>
          <select
            className={`${selectClass} mt-1.5 w-56`}
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

function safeAddress(accountId: string): string | null {
  try {
    return bytes32ToClassicAddress(accountId as `0x${string}`);
  } catch {
    return null;
  }
}
