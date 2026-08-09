"use client";

import Link from "next/link";
import { useAccount } from "wagmi";

import { IconLayers, IconPlus, IconPolicy, IconUsers } from "@/components/icons";
import {
  Badge,
  buttonClass,
  Card,
  Loading,
  PageHeader,
  StatCard,
  tableClass,
  tdClass,
  theadClass,
  thClass,
  trClass,
} from "@/components/ui";
import { usePolicies, useRolesForAccount } from "@/hooks/useAegis";
import { formatUsd, formatWindow } from "@/lib/format";
import { rolesIn } from "@/lib/roles";

export default function PoliciesPage() {
  const policies = usePolicies();
  const { address } = useAccount();
  const roles = useRolesForAccount(address, policies.data?.map((policy) => policy.id));

  const list = policies.data ?? [];
  const enforcing = list.filter((policy) => policy.allowlistEnforced).length;
  const withAuthority = list.filter((policy) => (roles.data?.get(policy.id.toString()) ?? 0) !== 0).length;

  return (
    <div className="space-y-8">
      <PageHeader
        title="Policies"
        description="A policy is a fixed rule set: amount tiers, a rolling spend ceiling, a destination allowlist and roles. The rules never change — only membership does."
        actions={
          <Link href="/policies/new" className={buttonClass("primary")}>
            <IconPlus className="size-4" />
            New policy
          </Link>
        }
      />

      <div className="grid gap-4 sm:grid-cols-3">
        <StatCard
          label="Policies"
          value={policies.isPending ? "…" : list.length}
          hint="Each one is a fixed rule set; only its membership can change."
          icon={<IconPolicy className="size-5" />}
        />
        <StatCard
          label="Allowlist enforced"
          value={policies.isPending ? "…" : `${enforcing} / ${list.length}`}
          hint="The rest accept any well-formed XRPL destination."
          icon={<IconLayers className="size-5" />}
        />
        <StatCard
          label="Your authority"
          value={!address ? "—" : roles.isPending ? "…" : withAuthority}
          hint={address ? "Policies where you hold at least one role." : "Connect a wallet to see your roles."}
          icon={<IconUsers className="size-5" />}
        />
      </div>

      <Card title="All policies" bodyClassName="">
        {policies.isPending ? (
          <div className="px-6">
            <Loading what="policies" />
          </div>
        ) : list.length === 0 ? (
          <div className="px-6 py-8 text-sm text-muted">
            Nothing can be created until a policy exists — a treasury without rules is just a wallet.
          </div>
        ) : (
          <div className="custom-scroll overflow-x-auto">
            <table className={tableClass}>
              <thead className={theadClass}>
                <tr>
                  <th className={thClass}>Policy</th>
                  <th className={`${thClass} text-right`}>Tiers</th>
                  <th className={`${thClass} text-right`}>Hard cap</th>
                  <th className={thClass}>Rolling window</th>
                  <th className={thClass}>Your roles</th>
                  <th className={thClass}>Destinations</th>
                </tr>
              </thead>
              <tbody>
                {list.map((policy) => {
                  const mask = roles.data?.get(policy.id.toString()) ?? 0;
                  const cap = policy.tiers[policy.tiers.length - 1]?.maxAmountUsd ?? 0n;
                  return (
                    <tr key={policy.id.toString()} className={trClass}>
                      <td className={tdClass}>
                        <Link href={`/policies/${policy.id}`} className="font-semibold text-ink hover:text-accent">
                          Policy {policy.id.toString()}
                        </Link>
                        <div className="mt-1 text-xs text-faint">
                          Amendment: <span className="numeric">{policy.amendApprovals}</span> approvals ·{" "}
                          {formatWindow(policy.amendTimelock)}
                        </div>
                      </td>
                      <td className={`${tdClass} numeric text-right`}>{policy.tiers.length}</td>
                      <td className={`${tdClass} numeric text-right`}>${formatUsd(cap)}</td>
                      <td className={`${tdClass} numeric`}>
                        ${formatUsd(policy.rollingWindowUsd)}
                        <span className="text-faint"> / {formatWindow(policy.windowSeconds)}</span>
                      </td>
                      <td className={tdClass}>
                        {!address ? (
                          <span className="text-faint">—</span>
                        ) : mask === 0 ? (
                          <span className="text-faint">none</span>
                        ) : (
                          <span className="flex flex-wrap gap-1.5">
                            {rolesIn(mask).map((role) => (
                              <Badge key={role.key} tone="accent">
                                {role.label}
                              </Badge>
                            ))}
                          </span>
                        )}
                      </td>
                      <td className={tdClass}>
                        {policy.allowlistEnforced ? (
                          <Badge tone="good" dot>
                            Allowlisted only
                          </Badge>
                        ) : (
                          <Badge tone="warn" dot>
                            Any destination
                          </Badge>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </Card>
    </div>
  );
}
