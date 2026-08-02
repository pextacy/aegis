"use client";

import Link from "next/link";
import { useAccount } from "wagmi";

import { Badge, buttonClass, Card, Loading, Mono } from "@/components/ui";
import { usePolicies, useRolesForAccount } from "@/hooks/useAegis";
import { formatUsd, formatWindow } from "@/lib/format";
import { describeRoles } from "@/lib/roles";

export default function PoliciesPage() {
  const policies = usePolicies();
  const { address } = useAccount();
  const roles = useRolesForAccount(address, policies.data?.map((policy) => policy.id));

  return (
    <div className="space-y-6">
      <header className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="text-xl font-semibold text-ink">Policies</h1>
          <p className="mt-1 text-sm text-muted">
            A policy is a fixed rule set: amount tiers, a rolling spend ceiling, a destination allowlist and roles. The
            rules never change — only membership does.
          </p>
        </div>
        <Link href="/policies/new" className={buttonClass("primary")}>
          New policy
        </Link>
      </header>

      {policies.isPending ? (
        <Loading what="policies" />
      ) : policies.data && policies.data.length > 0 ? (
        <div className="grid gap-4">
          {policies.data.map((policy) => {
            const mask = roles.data?.get(policy.id.toString()) ?? 0;
            const cap = policy.tiers[policy.tiers.length - 1]?.maxAmountUsd ?? 0n;
            return (
              <Link
                key={policy.id.toString()}
                href={`/policies/${policy.id}`}
                className="block rounded-lg border border-line bg-surface p-5 transition-colors hover:border-accent/40"
              >
                <div className="flex flex-wrap items-center justify-between gap-3">
                  <h2 className="text-base font-semibold text-ink">Policy {policy.id.toString()}</h2>
                  <div className="flex items-center gap-2">
                    {policy.allowlistEnforced ? (
                      <Badge tone="good">Allowlist enforced</Badge>
                    ) : (
                      <Badge tone="warn">Any destination</Badge>
                    )}
                    {address && <Badge tone={mask === 0 ? "neutral" : "accent"}>You: {describeRoles(mask)}</Badge>}
                  </div>
                </div>

                <dl className="mt-4 grid gap-4 text-sm sm:grid-cols-4">
                  <div>
                    <dt className="text-xs tracking-wide text-faint uppercase">Tiers</dt>
                    <dd className="numeric mt-1 text-ink">{policy.tiers.length}</dd>
                  </div>
                  <div>
                    <dt className="text-xs tracking-wide text-faint uppercase">Hard cap</dt>
                    <dd className="numeric mt-1 text-ink">${formatUsd(cap)}</dd>
                  </div>
                  <div>
                    <dt className="text-xs tracking-wide text-faint uppercase">Rolling window</dt>
                    <dd className="numeric mt-1 text-ink">
                      ${formatUsd(policy.rollingWindowUsd)}
                      <span className="text-faint"> / {formatWindow(policy.windowSeconds)}</span>
                    </dd>
                  </div>
                  <div>
                    <dt className="text-xs tracking-wide text-faint uppercase">Amendment</dt>
                    <dd className="numeric mt-1 text-ink">
                      <Mono>{policy.amendApprovals}</Mono>
                      <span className="text-faint"> approvals · {formatWindow(policy.amendTimelock)}</span>
                    </dd>
                  </div>
                </dl>
              </Link>
            );
          })}
        </div>
      ) : (
        <Card title="No policies yet">
          <p className="text-sm text-muted">
            Nothing can be created until a policy exists — a treasury without rules is just a wallet.
          </p>
        </Card>
      )}
    </div>
  );
}
