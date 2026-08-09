"use client";

import Link from "next/link";
import { useParams } from "next/navigation";
import { useAccount } from "wagmi";

import { AllowlistEditor } from "@/components/AllowlistEditor";
import { IconClock, IconLayers, IconTreasury, IconWallet } from "@/components/icons";
import { RolesEditor } from "@/components/RolesEditor";
import {
  Badge,
  Breadcrumb,
  Card,
  FailureAlert,
  Loading,
  PageHeader,
  StatCard,
  tableClass,
  tdClass,
  theadClass,
  thClass,
  trClass,
} from "@/components/ui";
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
    <div className="space-y-8">
      <PageHeader
        breadcrumb={<Breadcrumb items={[{ label: "Policies", href: "/policies" }, { label: `Policy ${policyId}` }]} />}
        title={
          <span className="flex flex-wrap items-center gap-3">
            Policy {policyId.toString()}
            {data.allowlistEnforced ? (
              <Badge tone="good" dot>
                Allowlist enforced
              </Badge>
            ) : (
              <Badge tone="warn" dot>
                Any destination
              </Badge>
            )}
          </span>
        }
        description="The rules below are fixed for the life of this policy. Roles and the allowlist are membership, not rules, and a policy administrator may change them."
      />

      <div className="grid gap-4 sm:grid-cols-3">
        <StatCard
          label="Hard per-payment cap"
          value={`$${formatUsd(cap)}`}
          hint="The highest tier's ceiling. Nothing above it can be proposed."
          icon={<IconWallet className="size-5" />}
        />
        <StatCard
          label="Rolling window"
          value={`$${formatUsd(data.rollingWindowUsd)}`}
          hint={`Committed spend ages out after ${formatWindow(data.windowSeconds)}.`}
          icon={<IconClock className="size-5" />}
        />
        <StatCard
          label="Amendment threshold"
          value={`${data.amendApprovals} approvals`}
          hint={`Plus a ${formatWindow(data.amendTimelock)} timelock, to unfreeze or repoint a treasury.`}
          icon={<IconLayers className="size-5" />}
        />
      </div>

      <div className="grid gap-6 lg:grid-cols-3">
        <div className="space-y-6 lg:col-span-2">
          <Card
            title="Spending tiers"
            subtitle="The lowest tier whose ceiling covers the payment is the one that applies, re-resolved at dispatch."
            bodyClassName=""
          >
            <div className="custom-scroll overflow-x-auto">
              <table className={tableClass}>
                <thead className={theadClass}>
                  <tr>
                    <th className={thClass}>Tier</th>
                    <th className={thClass}>Covers payments up to</th>
                    <th className={`${thClass} text-right`}>Approvals</th>
                    <th className={thClass}>Timelock</th>
                  </tr>
                </thead>
                <tbody>
                  {data.tiers.map((tier, index) => (
                    <tr key={index} className={trClass}>
                      <td className={tdClass}>
                        <span className="font-semibold text-ink">Tier {index + 1}</span>
                      </td>
                      <td className={`${tdClass} numeric`}>${formatUsd(tier.maxAmountUsd)}</td>
                      <td className={`${tdClass} numeric text-right`}>{tier.requiredApprovals}</td>
                      <td className={`${tdClass} numeric`}>
                        {tier.timelockSeconds === 0 ? "none" : formatWindow(tier.timelockSeconds)}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </Card>

          <RolesEditor policyId={policyId} canEdit={canEdit} />
        </div>

        <div className="space-y-6">
          <AllowlistEditor policyId={policyId} canEdit={canEdit} />

          <Card title="Treasuries governed">
            {governed.length === 0 ? (
              <p className="text-sm text-faint">None yet.</p>
            ) : (
              <ul className="space-y-2">
                {governed.map((treasury) => (
                  <li key={treasury.id.toString()}>
                    <Link
                      href={`/treasuries/${treasury.id}`}
                      className="flex items-center gap-3 rounded-lg border border-line px-3 py-2.5 text-sm hover:border-accent"
                    >
                      <IconTreasury className="size-5 shrink-0 text-accent" />
                      <span className="font-medium text-ink">Treasury {treasury.id.toString()}</span>
                      {treasury.frozen && (
                        <Badge tone="bad" dot>
                          Frozen
                        </Badge>
                      )}
                    </Link>
                  </li>
                ))}
              </ul>
            )}
          </Card>
        </div>
      </div>
    </div>
  );
}

function parsePolicyId(raw: string | string[] | undefined): bigint | undefined {
  const text = Array.isArray(raw) ? raw[0] : raw;
  if (!text || !/^\d+$/.test(text)) return undefined;
  return BigInt(text);
}
