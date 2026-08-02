"use client";

import Link from "next/link";
import { useParams } from "next/navigation";
import { useAccount } from "wagmi";

import { AmendmentPanel } from "@/components/AmendmentPanel";
import { AuditLogView } from "@/components/AuditLogView";
import { FreezeControl } from "@/components/FreezeControl";
import { KeygenPanel } from "@/components/KeygenPanel";
import { XrplAccountLink } from "@/components/links";
import { RequestList } from "@/components/RequestList";
import { Badge, buttonClass, Card, FailureAlert, Loading, Stat } from "@/components/ui";
import { WindowGauge } from "@/components/WindowGauge";
import { useCommittedUsd, usePolicy, useRequests, useRoles, useTreasury, useXrplAccount } from "@/hooks/useAegis";
import { formatDrops, formatUsd, formatWindow, formatXrp } from "@/lib/format";
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

  if (treasuryId === undefined) return <Card title="Not a treasury id">That is not a treasury id.</Card>;
  if (treasury.isPending) return <Loading what="the treasury" />;
  if (treasury.error) return <FailureAlert error={treasury.error} />;
  if (!treasury.data) return <Card title="No such treasury">Treasury {treasuryId.toString()} does not exist.</Card>;

  const data = treasury.data;
  const xrplAddress = safeAddress(data.xrplAccountId);
  const mask = roles.data ?? 0;
  const live = (requests.data ?? []).filter((request) => isLive(request.state));
  const requestIds = new Set((requests.data ?? []).map((request) => request.id.toString()));

  return (
    <div className="space-y-6">
      <header className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <div className="flex items-center gap-3">
            <h1 className="text-xl font-semibold text-ink">Treasury {data.id.toString()}</h1>
            {data.frozen ? <Badge tone="bad">Frozen</Badge> : <Badge tone="good">Active</Badge>}
          </div>
          <p className="mt-1 text-sm text-muted">
            Governed by{" "}
            <Link href={`/policies/${data.policyId}`} className="text-accent underline underline-offset-2">
              policy {data.policyId.toString()}
            </Link>
            {address && <> · your roles: {describeRoles(mask)}</>}
          </p>
        </div>
        <Link href={`/treasuries/${data.id}/propose`} className={buttonClass("primary")}>
          Propose a payment
        </Link>
      </header>

      <XrplPanel treasuryAddress={xrplAddress} nextSequence={data.nextSequence} />

      {!xrplAddress && <KeygenPanel treasury={data} canAdmin={hasRole(mask, ROLE_POLICY_ADMIN)} />}

      {policy.data && committed.data !== undefined && (
        <Card title="Rolling window">
          <WindowGauge
            committedUsd={committed.data}
            capUsd={policy.data.rollingWindowUsd}
            windowSeconds={policy.data.windowSeconds}
          />
          <p className="mt-3 text-xs text-faint">
            Spend is committed at dispatch, not at proposal, and returned only when a request is proven to have failed.
            Entries older than {formatWindow(policy.data.windowSeconds)} age out on the next call that touches this
            treasury.
          </p>
        </Card>
      )}

      <Card
        title="Payments in flight"
        subtitle="Proposed, approved, dispatched or signed — everything that has not reached a terminal outcome."
      >
        <RequestList requests={live} />
      </Card>

      <Card title="All payments">
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

function XrplPanel({ treasuryAddress, nextSequence }: { treasuryAddress: string | null; nextSequence: number }) {
  const account = useXrplAccount(treasuryAddress);

  return (
    <Card title="XRPL account">
      {!treasuryAddress ? (
        <p className="text-sm text-muted">
          No XRPL account is bound yet. The key is generated inside the enclave and the registry derives the AccountID
          from the public key on-chain, so the address below appears only once that binding has been verified.
        </p>
      ) : (
        <div className="grid gap-6 sm:grid-cols-3">
          <div className="sm:col-span-3">
            <div className="text-xs tracking-wide text-faint uppercase">Address</div>
            <div className="mt-1 text-sm break-all">
              <XrplAccountLink address={treasuryAddress} />
            </div>
          </div>

          <Stat
            label="Balance"
            value={
              account.isPending
                ? "…"
                : account.data
                  ? `${formatXrp(account.data.balanceDrops)} XRP`
                  : "unfunded"
            }
            hint={account.data ? `${formatDrops(account.data.balanceDrops)} drops` : "The ledger has no such account."}
          />
          <Stat
            label="Sequence, on Flare"
            value={nextSequence}
            hint="What the registry will sign next, advanced only by a proof."
          />
          <Stat
            label="Sequence, on XRPL"
            value={account.data ? account.data.sequence : "—"}
            hint="What the ledger expects next."
            tone={account.data && account.data.sequence !== nextSequence ? "warn" : "neutral"}
          />
        </div>
      )}
    </Card>
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
