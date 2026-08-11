"use client";

import Link from "next/link";
import { useParams } from "next/navigation";
import { useAccount } from "wagmi";

import { AmendmentPanel } from "@/components/AmendmentPanel";
import { AuditLogView } from "@/components/AuditLogView";
import { CopyButton } from "@/components/CopyButton";
import { FreezeControl } from "@/components/FreezeControl";
import { IconPlus, IconShield } from "@/components/icons";
import { KeygenPanel } from "@/components/KeygenPanel";
import { XrplAccountLink } from "@/components/links";
import { RequestList } from "@/components/RequestList";
import { SignerSetPanel } from "@/components/SignerSetPanel";
import { StartingSequencePanel } from "@/components/StartingSequencePanel";
import {
  Badge,
  Breadcrumb,
  buttonClass,
  Card,
  DarkPanel,
  FailureAlert,
  Loading,
  PageHeader,
  Stat,
} from "@/components/ui";
import { WindowGauge } from "@/components/WindowGauge";
import { useCommittedUsd, usePolicy, useRequests, useRoles, useTreasury, useXrplAccount } from "@/hooks/useAegis";
import type { Policy } from "@/lib/contracts";
import { formatDrops, formatWindow, formatXrp } from "@/lib/format";
import { describeRoles, hasRole, ROLE_GUARDIAN, ROLE_POLICY_ADMIN } from "@/lib/roles";
import { isLive } from "@/lib/states";
import { bytes32ToClassicAddress } from "@/lib/xrpl-address";

export default function TreasuryPage() {
  const params = useParams<{ treasuryId: string }>();
  const treasuryId = parseId(params.treasuryId);

  const treasury = useTreasury(treasuryId);
  const policy = usePolicy(treasury.data?.policyId);
  const committed = useCommittedUsd(treasuryId);
  const requests = useRequests(treasuryId);
  const { address } = useAccount();
  const roles = useRoles(treasury.data?.policyId, address);
  // Read once here rather than inside XrplPanel: the starting-sequence panel
  // needs the same answer, and asking the ledger twice for it would be silly.
  const boundAddress = treasury.data ? safeAddress(treasury.data.xrplAccountId) : null;
  const xrplAccount = useXrplAccount(boundAddress);

  if (treasuryId === undefined) return <Card title="Not a treasury id">That is not a treasury id.</Card>;
  if (treasury.isPending) return <Loading what="the treasury" />;
  if (treasury.error) return <FailureAlert error={treasury.error} />;
  if (!treasury.data) return <Card title="No such treasury">Treasury {treasuryId.toString()} does not exist.</Card>;

  const data = treasury.data;
  const xrplAddress = boundAddress;
  const mask = roles.data ?? 0;
  const live = (requests.data ?? []).filter((request) => isLive(request.state));
  const requestIds = new Set((requests.data ?? []).map((request) => request.id.toString()));

  return (
    <div className="space-y-8">
      <PageHeader
        breadcrumb={
          <Breadcrumb
            items={[{ label: "Treasuries", href: "/" }, { label: `Treasury ${data.id.toString()}` }]}
          />
        }
        title={
          <span className="flex flex-wrap items-center gap-3">
            Treasury {data.id.toString()}
            {data.frozen ? (
              <Badge tone="bad" dot>
                Frozen
              </Badge>
            ) : (
              <Badge tone="good" dot>
                Active
              </Badge>
            )}
          </span>
        }
        description={
          <>
            Governed by{" "}
            <Link href={`/policies/${data.policyId}`} className="font-medium text-accent underline underline-offset-2">
              policy {data.policyId.toString()}
            </Link>
            {address && <> · your roles: {describeRoles(mask)}</>}
          </>
        }
        actions={
          <Link href={`/treasuries/${data.id}/propose`} className={buttonClass("primary")}>
            <IconPlus className="size-4" />
            Propose a payment
          </Link>
        }
      />

      <div className="grid gap-4 lg:grid-cols-3">
        <XrplPanel
          treasuryAddress={xrplAddress}
          nextSequence={data.nextSequence}
          sequenceConfirmed={data.sequenceConfirmed}
          account={xrplAccount}
        />
        <GovernancePanel policy={policy.data} policyId={data.policyId} roleMask={mask} connected={Boolean(address)} />
      </div>

      {!xrplAddress && <KeygenPanel treasury={data} canAdmin={hasRole(mask, ROLE_POLICY_ADMIN)} />}

      {xrplAddress && (
        <StartingSequencePanel
          treasury={data}
          xrplSequence={xrplAccount.data ? xrplAccount.data.sequence : null}
          canAdmin={hasRole(mask, ROLE_POLICY_ADMIN)}
        />
      )}

      {xrplAddress && (
        <SignerSetPanel treasury={data} canAdmin={hasRole(mask, ROLE_POLICY_ADMIN)} />
      )}

      {policy.data && committed.data !== undefined && (
        <Card>
          <WindowGauge
            committedUsd={committed.data}
            capUsd={policy.data.rollingWindowUsd}
            windowSeconds={policy.data.windowSeconds}
          />
          <p className="mt-4 border-t border-line pt-4 text-xs text-faint">
            Spend is committed at dispatch, not at proposal, and returned only when a request is proven to have failed.
            Entries older than {formatWindow(policy.data.windowSeconds)} age out on the next call that touches this
            treasury.
          </p>
        </Card>
      )}

      <Card
        title="Payments in flight"
        subtitle="Proposed, approved, dispatched or signed — everything that has not reached a terminal outcome."
        bodyClassName=""
      >
        <RequestList requests={live} emptyMessage="Nothing is in flight from this treasury." searchable />
      </Card>

      <Card title="All payments" bodyClassName="">
        <RequestList requests={requests.data ?? []} />
      </Card>

      <FreezeControl treasury={data} isGuardian={hasRole(mask, ROLE_GUARDIAN)} />

      {policy.data && (
        <AmendmentPanel
          treasuryId={data.id}
          policy={policy.data}
          account={address}
          canPropose={hasRole(mask, ROLE_POLICY_ADMIN)}
        />
      )}

      <AuditLogView
        title="Audit log for this treasury"
        filter={(entry) =>
          entry.treasuryId === data.id ||
          (entry.requestId !== undefined && requestIds.has(entry.requestId.toString()))
        }
      />
    </div>
  );
}

function XrplPanel({
  treasuryAddress,
  nextSequence,
  sequenceConfirmed,
  account,
}: {
  treasuryAddress: string | null;
  nextSequence: number;
  sequenceConfirmed: boolean;
  account: ReturnType<typeof useXrplAccount>;
}) {
  const drifted = Boolean(account.data && account.data.sequence !== nextSequence);

  return (
    <section className="rounded-lg border border-line bg-surface p-6 lg:col-span-2">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="label-caps text-faint">XRPL account</div>
          {treasuryAddress ? (
            <div className="mt-2 flex items-center gap-2">
              <span className="numeric text-xl break-all text-ink">
                <XrplAccountLink address={treasuryAddress} />
              </span>
              <CopyButton value={treasuryAddress} label="Copy the XRPL address" />
            </div>
          ) : (
            <p className="mt-2 max-w-xl text-sm text-muted">
              No XRPL account is bound yet. The key is generated inside the enclave and the registry derives the
              AccountID from the public key on-chain, so the address below appears only once that binding has been
              verified.
            </p>
          )}
        </div>
        {treasuryAddress &&
          (account.isPending ? (
            <Badge tone="neutral">Reading ledger…</Badge>
          ) : account.data ? (
            <Badge tone="good" dot>
              Funded on XRPL
            </Badge>
          ) : (
            <Badge tone="warn" dot>
              Unfunded
            </Badge>
          ))}
      </div>

      {treasuryAddress && (
        <div className="mt-5 grid gap-3 sm:grid-cols-3">
          <Stat
            label="Balance"
            value={account.isPending ? "…" : account.data ? `${formatXrp(account.data.balanceDrops)} XRP` : "unfunded"}
            hint={
              account.data ? `${formatDrops(account.data.balanceDrops)} drops` : "The ledger has no such account yet."
            }
          />
          <Stat
            label="Sequence, on Flare"
            value={nextSequence === 0 ? "not recorded" : `#${nextSequence}`}
            hint={sequenceConfirmed ? "Fixed — XRPL has consumed one." : "Still adjustable until XRPL consumes one."}
          />
          <Stat
            label="Sequence, on XRPL"
            value={account.data ? `#${account.data.sequence}` : "—"}
            hint="What the ledger expects next."
            tone={drifted ? "warn" : "neutral"}
          />
        </div>
      )}
    </section>
  );
}

/** What governs this treasury, as the contracts have it. */
function GovernancePanel({
  policy,
  policyId,
  roleMask,
  connected,
}: {
  policy: Policy | undefined;
  policyId: bigint;
  roleMask: number;
  connected: boolean;
}) {
  return (
    <DarkPanel title="Governance" icon={<IconShield className="size-4" />}>
      <div className="numeric text-3xl font-medium">Policy {policyId.toString()}</div>

      <dl className="mt-5 space-y-3 text-sm">
        <div className="flex items-baseline justify-between gap-4">
          <dt className="text-white/60">Tiers</dt>
          <dd className="numeric">{policy ? policy.tiers.length : "…"}</dd>
        </div>
        <div className="flex items-baseline justify-between gap-4">
          <dt className="text-white/60">Allowlist</dt>
          <dd>{policy ? (policy.allowlistEnforced ? "Enforced" : "Not enforced") : "…"}</dd>
        </div>
        <div className="flex items-baseline justify-between gap-4">
          <dt className="text-white/60">Amendment threshold</dt>
          <dd className="numeric">{policy ? policy.amendApprovals : "…"}</dd>
        </div>
        <div className="flex items-baseline justify-between gap-4">
          <dt className="text-white/60">Amendment timelock</dt>
          <dd>{policy ? formatWindow(policy.amendTimelock) : "…"}</dd>
        </div>
      </dl>

      <div className="mt-5 border-t border-white/15 pt-4 text-sm">
        <div className="label-caps text-white/60">Your authority</div>
        <div className="mt-1.5">{connected ? describeRoles(roleMask) : "No wallet connected"}</div>
      </div>

      <Link
        href={`/policies/${policyId}`}
        className="mt-5 inline-flex w-full items-center justify-center rounded-lg bg-white px-4 py-2.5 text-sm font-semibold text-navy hover:bg-white/90"
      >
        Open the policy
      </Link>
    </DarkPanel>
  );
}

function parseId(raw: string | string[] | undefined): bigint | undefined {
  const text = Array.isArray(raw) ? raw[0] : raw;
  if (!text || !/^\d+$/.test(text)) return undefined;
  return BigInt(text);
}

function safeAddress(word: string): string | null {
  try {
    return bytes32ToClassicAddress(word as `0x${string}`);
  } catch {
    return null;
  }
}
