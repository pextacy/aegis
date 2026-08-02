"use client";

import Link from "next/link";
import { useParams } from "next/navigation";
import { useAccount } from "wagmi";

import { AuditLogView } from "@/components/AuditLogView";
import { Countdown } from "@/components/Countdown";
import { DispatchPanel } from "@/components/DispatchPanel";
import { SettlementPanel } from "@/components/SettlementPanel";
import { AddressLink, XrplAccountLink } from "@/components/links";
import { TxFeedback } from "@/components/TxFeedback";
import { Badge, buttonClass, Card, FailureAlert, KeyValue, Loading, Mono, Stat, type Tone } from "@/components/ui";
import {
  useHasApproved,
  usePolicy,
  useQuoteUsd,
  useRequest,
  useRoles,
  useTreasury,
} from "@/hooks/useAegis";
import { useAegisTx } from "@/hooks/useAegisTx";
import { contractHandles, type Tier } from "@/lib/contracts";
import { formatDrops, formatTimestamp, formatUsd, formatWindow, formatXrp, shortHex } from "@/lib/format";
import { hasRole, ROLE_APPROVER, ROLE_PROPOSER } from "@/lib/roles";
import { requestState } from "@/lib/states";
import { bytes32ToClassicAddress } from "@/lib/xrpl-address";

const TONE: Record<string, Tone> = {
  pending: "warn",
  ready: "accent",
  active: "info",
  good: "good",
  bad: "bad",
  muted: "neutral",
};

/**
 * The approval screen.
 *
 * This is the product's most important surface. An approver who cannot see the
 * destination, the tag, all three amounts, the tier, the threshold and the
 * unlock time is approving a description rather than a fact — which is the exact
 * failure Aegis exists to prevent. Everything the contract will check is on this
 * page, read from the chain, with nothing summarised away.
 */
export default function RequestPage() {
  const params = useParams<{ requestId: string }>();
  const requestId = parseId(params.requestId);

  const request = useRequest(requestId);
  const treasury = useTreasury(request.data?.treasuryId);
  const policy = usePolicy(treasury.data?.policyId);
  const { address } = useAccount();
  const roles = useRoles(treasury.data?.policyId, address);
  const approved = useHasApproved(requestId, address);
  const liveQuote = useQuoteUsd(request.data?.amountDrops);
  const tx = useAegisTx();
  const { paymentController } = contractHandles();

  if (requestId === undefined) return <Card title="Not a request id">That is not a request id.</Card>;
  if (request.isPending) return <Loading what="the payment request" />;
  if (request.error) return <FailureAlert error={request.error} />;
  if (!request.data) return <Card title="No such request">Request {requestId.toString()} does not exist.</Card>;

  const data = request.data;
  const state = requestState(data.state);
  const destination = safeAddress(data.destinationAccountId);
  const tier = policy.data && liveQuote.data !== undefined ? resolveTier(policy.data.tiers, liveQuote.data) : null;

  const isProposer = address !== undefined && address.toLowerCase() === data.proposer.toLowerCase();
  const isApprover = hasRole(roles.data ?? 0, ROLE_APPROVER);
  const alreadyApproved = approved.data === true;
  const frozen = treasury.data?.frozen === true;

  const approvalBlocker = !address
    ? "Connect a wallet to approve."
    : state.key !== "Proposed"
      ? `This request is ${state.label}. Approvals are only collected while it is Proposed.`
      : frozen
        ? "The treasury is frozen, so approvals are refused."
        : !isApprover
          ? "You do not hold APPROVER on this policy."
          : isProposer
            ? "You proposed this payment. A proposer cannot approve their own request."
            : alreadyApproved
              ? "You have already approved this request."
              : null;

  return (
    <div className="space-y-6">
      <header className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <div className="flex items-center gap-3">
            <h1 className="text-xl font-semibold text-ink">Payment request {data.id.toString()}</h1>
            <Badge tone={TONE[state.tone] ?? "neutral"}>{state.label}</Badge>
          </div>
          <p className="mt-1 text-sm text-muted">{state.description}</p>
        </div>
        <Link href={`/treasuries/${data.treasuryId}`} className={buttonClass("secondary")}>
          Treasury {data.treasuryId.toString()}
        </Link>
      </header>

      <Card title="What is being paid">
        <div className="grid gap-6 sm:grid-cols-3">
          <Stat label="Drops" value={formatDrops(data.amountDrops)} hint="Exactly what the signed transaction moves." />
          <Stat label="XRP" value={formatXrp(data.amountDrops)} />
          <Stat
            label="USD, live"
            value={liveQuote.data !== undefined ? `$${formatUsd(liveQuote.data)}` : "…"}
            hint={`$${formatUsd(data.amountUsdAtProposal)} at proposal`}
            tone={liveQuote.error ? "bad" : "neutral"}
          />
        </div>

        <dl className="mt-6">
          <KeyValue label="Destination">
            {destination ? (
              <XrplAccountLink address={destination} />
            ) : (
              <Mono>{data.destinationAccountId}</Mono>
            )}
          </KeyValue>
          <KeyValue
            label="Destination tag"
            hint={
              data.destinationTag === 0
                ? "No tag. The field is omitted from the transaction entirely, which hashes differently from a zero."
                : "Included in the signed transaction."
            }
          >
            <Mono>{data.destinationTag === 0 ? "none" : data.destinationTag}</Mono>
          </KeyValue>
          <KeyValue label="Proposed by">
            <AddressLink address={data.proposer} />
          </KeyValue>
        </dl>
      </Card>

      <Card title="What the policy requires">
        <dl>
          <KeyValue
            label="Approvals"
            hint="Collected from addresses other than the proposer, each counted once."
          >
            <Mono className={data.approvals >= data.requiredApprovals ? "text-good" : "text-warn"}>
              {data.approvals} of {data.requiredApprovals}
            </Mono>
          </KeyValue>
          <KeyValue
            label="Tier at the current price"
            hint="Re-resolved at dispatch. A price move can change which tier applies."
          >
            {tier ? (
              <>
                <Mono>${formatUsd(tier.maxAmountUsd)}</Mono> ceiling · {tier.requiredApprovals} approval(s) ·{" "}
                {tier.timelockSeconds === 0 ? "no timelock" : formatWindow(tier.timelockSeconds)}
              </>
            ) : liveQuote.error ? (
              <span className="text-bad">The price feed is not usable right now, so no tier can be resolved.</span>
            ) : (
              "…"
            )}
          </KeyValue>
          <KeyValue label="Dispatchable from" hint={formatTimestamp(data.eligibleAt)}>
            <Countdown eligibleAt={data.eligibleAt} />
          </KeyValue>
          <KeyValue label="Treasury">
            <Link href={`/treasuries/${data.treasuryId}`} className="text-accent underline underline-offset-2">
              Treasury {data.treasuryId.toString()}
            </Link>
            {frozen && <span className="ml-2 text-bad">frozen</span>}
            {treasury.data && (
              <>
                {" · "}
                <Link
                  href={`/policies/${treasury.data.policyId}`}
                  className="text-accent underline underline-offset-2"
                >
                  policy {treasury.data.policyId.toString()}
                </Link>
              </>
            )}
          </KeyValue>
        </dl>
      </Card>

      {data.state >= 2 && (
        <Card title="What was sent to the enclave" subtitle="Fixed at dispatch. The TEE recomputes the digest from these exact fields and refuses to sign on any mismatch.">
          <dl>
            <KeyValue label="XRPL sequence">
              <Mono>{data.sequence}</Mono>
            </KeyValue>
            <KeyValue label="Ledger range" hint="Nothing outside this range can be this payment.">
              <Mono>
                {data.firstLedgerSequence} – {data.lastLedgerSequence}
              </Mono>
            </KeyValue>
            <KeyValue label="Fee">
              <Mono>{formatDrops(data.feeDrops)} drops</Mono>
            </KeyValue>
            <KeyValue label="Policy digest" hint="keccak256 over request, treasury, destination, tag, amount, sequence, expiry and fee.">
              <Mono className="break-all">{data.policyDigest}</Mono>
            </KeyValue>
          </dl>
        </Card>
      )}

      <Card title="Approve">
        {approvalBlocker ? (
          <p className="text-sm text-muted">{approvalBlocker}</p>
        ) : (
          <p className="text-sm text-muted">
            You are approving the exact facts above: {formatXrp(data.amountDrops)} XRP to{" "}
            {destination ?? shortHex(data.destinationAccountId)}
            {data.destinationTag === 0 ? " with no destination tag" : ` with tag ${data.destinationTag}`}.
          </p>
        )}

        <div className="mt-4 flex flex-wrap gap-3">
          <button
            type="button"
            className={buttonClass("primary")}
            disabled={approvalBlocker !== null || tx.isBusy}
            onClick={() => {
              void tx.run({
                address: paymentController.address,
                abi: paymentController.abi,
                functionName: "approve",
                args: [data.id],
              });
            }}
          >
            {tx.isBusy ? "Working…" : "Approve payment"}
          </button>

          {isProposer && (state.key === "Proposed" || state.key === "Approved") && (
            <button
              type="button"
              className={buttonClass("danger")}
              disabled={tx.isBusy}
              onClick={() => {
                void tx.run({
                  address: paymentController.address,
                  abi: paymentController.abi,
                  functionName: "cancel",
                  args: [data.id],
                });
              }}
            >
              Cancel request
            </button>
          )}
        </div>

        <TxFeedback state={tx.state} doneMessage="Recorded on-chain" />
      </Card>

      {state.key === "Approved" && treasury.data && (
        <DispatchPanel
          request={data}
          treasury={treasury.data}
          canDispatch={hasRole(roles.data ?? 0, ROLE_PROPOSER)}
        />
      )}

      {data.state >= 2 && <SettlementPanel request={data} />}

      <AuditLogView title="Audit log for this request" filter={(entry) => entry.requestId === data.id} />
    </div>
  );
}

function resolveTier(tiers: readonly Tier[], amountUsd: bigint): Tier | null {
  for (const tier of tiers) {
    if (amountUsd <= tier.maxAmountUsd) return tier;
  }
  return null;
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
