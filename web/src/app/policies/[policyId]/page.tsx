"use client";

import Link from "next/link";
import { useParams } from "next/navigation";
import { useAccount } from "wagmi";

import { AllowlistEditor } from "@/components/AllowlistEditor";
import { RolesEditor } from "@/components/RolesEditor";
import { Badge, Card, FailureAlert, Loading, Stat } from "@/components/ui";
import { usePolicy, useRoles, useTreasuries } from "@/hooks/useAegis";
import { formatUsd, formatWindow } from "@/lib/format";
import { hasRole, ROLE_POLICY_ADMIN } from "@/lib/roles";

export default function PolicyPage() {
  const params = useParams<{ policyId: string }>();
  const policyId = parsePolicyId(params.policyId);

  const policy = usePolicy(policyId);
  const treasuries = useTreasuries();
  const { address } = useAccount();
  const roles = useRoles(policyId, address);

  const canEdit = hasRole(roles.data ?? 0, ROLE_POLICY_ADMIN);

  if (policyId === undefined) {
    return <Card title="Not a policy id">That is not a policy id.</Card>;
  }
  if (policy.isPending) return <Loading what="the policy" />;
  if (policy.error) return <FailureAlert error={policy.error} />;
  if (!policy.data) return <Card title="No such policy">Policy {policyId.toString()} does not exist.</Card>;

  const data = policy.data;
  const cap = data.tiers[data.tiers.length - 1]?.maxAmountUsd ?? 0n;
  const governed = (treasuries.data ?? []).filter((treasury) => treasury.policyId === policyId);

  return (
    <div className="space-y-6">
      <header className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="text-xl font-semibold text-ink">Policy {policyId.toString()}</h1>
          <p className="mt-1 text-sm text-muted">
            The rules below are fixed for the life of this policy. Roles and the allowlist are membership, not rules,
            and a policy administrator may change them.
          </p>
        </div>
        {data.allowlistEnforced ? (
          <Badge tone="good">Allowlist enforced</Badge>
        ) : (
          <Badge tone="warn">Any destination permitted</Badge>
        )}
      </header>

      <Card title="Rules">
        <div className="grid gap-6 sm:grid-cols-3">
          <Stat label="Hard per-payment cap" value={`$${formatUsd(cap)}`} hint="The highest tier's ceiling." />
          <Stat
            label="Rolling window"
            value={`$${formatUsd(data.rollingWindowUsd)}`}
            hint={`Committed spend ages out after ${formatWindow(data.windowSeconds)}.`}
          />
          <Stat
            label="Amendment"
            value={`${data.amendApprovals} approvals`}
            hint={`Plus a ${formatWindow(data.amendTimelock)} timelock, to unfreeze or repoint a treasury.`}
          />
        </div>

        <div className="mt-6 overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-line text-left text-xs tracking-wide text-faint uppercase">
                <th className="py-2 pr-4 font-medium">Tier</th>
                <th className="py-2 pr-4 font-medium">Covers payments up to</th>
                <th className="py-2 pr-4 font-medium">Approvals</th>
                <th className="py-2 font-medium">Timelock</th>
              </tr>
            </thead>
            <tbody>
              {data.tiers.map((tier, index) => (
                <tr key={index} className="border-b border-line last:border-b-0">
                  <td className="numeric py-2 pr-4 text-muted">{index + 1}</td>
                  <td className="numeric py-2 pr-4 text-ink">${formatUsd(tier.maxAmountUsd)}</td>
                  <td className="numeric py-2 pr-4 text-ink">{tier.requiredApprovals}</td>
                  <td className="numeric py-2 text-ink">
                    {tier.timelockSeconds === 0 ? "none" : formatWindow(tier.timelockSeconds)}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Card>

      <RolesEditor policyId={policyId} canEdit={canEdit} />
      <AllowlistEditor policyId={policyId} canEdit={canEdit} />

      <Card title="Treasuries governed by this policy">
        {governed.length === 0 ? (
          <p className="text-sm text-faint">None yet.</p>
        ) : (
          <ul className="space-y-2 text-sm">
            {governed.map((treasury) => (
              <li key={treasury.id.toString()}>
                <Link href={`/treasuries/${treasury.id}`} className="text-accent underline underline-offset-2">
                  Treasury {treasury.id.toString()}
                </Link>
                {treasury.frozen && <span className="ml-2 text-bad">frozen</span>}
              </li>
            ))}
          </ul>
        )}
      </Card>
    </div>
  );
}

function parsePolicyId(raw: string | string[] | undefined): bigint | undefined {
  const text = Array.isArray(raw) ? raw[0] : raw;
  if (!text || !/^\d+$/.test(text)) return undefined;
  return BigInt(text);
}
