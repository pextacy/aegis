"use client";

import Link from "next/link";
import { useParams } from "next/navigation";
import { useAccount } from "wagmi";

import { AuditLogView } from "@/components/AuditLogView";
import { Countdown } from "@/components/Countdown";
import { DispatchPanel } from "@/components/DispatchPanel";
import { IconArrowLeft, IconClock, IconLock, IconShield } from "@/components/icons";
import { AddressLink, XrplAccountLink } from "@/components/links";
import { SettlementPanel } from "@/components/SettlementPanel";
import { TxFeedback } from "@/components/TxFeedback";
import {
  Alert,
  Badge,
  Breadcrumb,
  buttonClass,
  Card,
  DarkPanel,
  FailureAlert,
  KeyValue,
  Loading,
  Mono,
  type Tone,
} from "@/components/ui";
import {
  useApprovalStanding,
  useHasApproved,
  useNow,
  usePolicy,
  useQuoteUsd,
  usePartialSignatures,
  useRequest,
  useRoles,
  useTreasury,
  useXrplLedger,
} from "@/hooks/useAegis";
import { useAegisTx } from "@/hooks/useAegisTx";
import { contractHandles, type Tier } from "@/lib/contracts";
import { formatDrops, formatTimestamp, formatUsd, formatWindow, formatXrp, percentOf, shortHex } from "@/lib/format";
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
  const standing = useApprovalStanding(requestId, treasury.data?.policyId);
  const liveQuote = useQuoteUsd(request.data?.amountDrops);
  const ledger = useXrplLedger();
  const now = useNow();
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
              ? "You have already approved this request. You can withdraw that approval until it is dispatched."
              : null;

  // Deliberately not gated on the approver role or on the freeze, because the
  // contract does not gate them either. An address whose APPROVER role was taken
  // away still has its approval counted toward the threshold, and a frozen
  // treasury still holds the approvals collected before the freeze — so hiding
  // the control in either case would strand an approval the contract would
  // happily let its owner take back.
  const canRevoke = alreadyApproved && (state.key === "Proposed" || state.key === "Approved");

  const approvalPercent = percentOf(BigInt(data.approvals), BigInt(Math.max(data.requiredApprovals, 1)));
  // Approvals whose address has since lost the role. They still sit in the
  // stored count, and dispatch will not weigh them.
  const lapsedApprovals = standing.data ? standing.data.entries.length - standing.data.valid : 0;
  const timelockElapsed = now >= data.eligibleAt;
  const senderAddress = treasury.data ? safeAddress(treasury.data.xrplAccountId) : null;
  const ledgersLeft = ledger.data === undefined ? null : data.lastLedgerSequence - ledger.data;

  return (
    <div className="space-y-8">
      <header className="flex flex-wrap items-start justify-between gap-4">
        <div className="flex min-w-0 items-start gap-4">
          <Link
            href={`/treasuries/${data.treasuryId}`}
            aria-label={`Back to treasury ${data.treasuryId.toString()}`}
            className="mt-1 flex size-10 shrink-0 items-center justify-center rounded-lg border border-line bg-surface text-muted hover:text-accent"
          >
            <IconArrowLeft className="size-5" />
          </Link>
          <div className="min-w-0">
            <Breadcrumb
              items={[
                { label: "Treasuries", href: "/" },
                { label: `Treasury ${data.treasuryId.toString()}`, href: `/treasuries/${data.treasuryId}` },
                { label: `Request ${data.id.toString()}` },
              ]}
            />
            <h1 className="mt-1.5 flex flex-wrap items-center gap-3 text-3xl font-semibold tracking-tight text-ink">
              Payment request {data.id.toString()}
              <Badge tone={TONE[state.tone] ?? "neutral"} dot>
                {state.label}
              </Badge>
            </h1>
            <p className="mt-2 max-w-2xl text-sm text-muted">{state.description}</p>
          </div>
        </div>

        <div className="flex flex-wrap gap-3">
          {canRevoke && (
            <button
              type="button"
              className={buttonClass("secondary")}
              disabled={tx.isBusy}
              onClick={() => {
                void tx.run({
                  address: paymentController.address,
                  abi: paymentController.abi,
                  functionName: "revokeApproval",
                  args: [data.id],
                });
              }}
            >
              Withdraw approval
            </button>
          )}
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
        </div>
      </header>

      {approvalBlocker ? (
        <Alert tone="neutral" title="You cannot approve this request">
          {approvalBlocker}
        </Alert>
      ) : (
        <Alert tone="info" title="What you are approving">
          {formatXrp(data.amountDrops)} XRP to {destination ?? shortHex(data.destinationAccountId)}
          {data.destinationTag === 0 ? " with no destination tag" : ` with tag ${data.destinationTag}`}.
        </Alert>
      )}

      <TxFeedback state={tx.state} doneMessage="Recorded on-chain" />

      <div className="grid gap-6 lg:grid-cols-3">
        <div className="space-y-6 lg:col-span-2">
          <Card>
            <div className="flex flex-wrap items-start justify-between gap-6">
              <div>
                <div className="label-caps text-faint">Amount</div>
                <div className="numeric mt-2 text-4xl font-medium tracking-tight text-ink">
                  {formatXrp(data.amountDrops)} <span className="text-2xl text-muted">XRP</span>
                </div>
                <div className="numeric mt-1.5 text-sm text-muted">{formatDrops(data.amountDrops)} drops</div>
              </div>
              <div className="text-right">
                <div className="label-caps text-faint">Value, live from FTSO</div>
                <div
                  className={`numeric mt-2 text-2xl ${liveQuote.error ? "text-bad" : "text-ink"}`}
                >
                  {liveQuote.error ? "unavailable" : liveQuote.data !== undefined ? `$${formatUsd(liveQuote.data)}` : "…"}
                </div>
                <div className="numeric mt-1.5 text-sm text-faint">
                  ${formatUsd(data.amountUsdAtProposal)} at proposal
                </div>
              </div>
            </div>

            <div className="mt-6 grid gap-6 border-t border-line pt-6 sm:grid-cols-2">
              <div>
                <div className="label-caps text-faint">Sender</div>
                <div className="mt-2 rounded-lg bg-raised px-4 py-3">
                  <div className="text-sm font-semibold text-ink">Treasury {data.treasuryId.toString()}</div>
                  <div className="numeric mt-1 text-sm break-all text-muted">
                    {senderAddress ? (
                      <XrplAccountLink address={senderAddress} />
                    ) : (
                      <span className="text-faint">No XRPL account is bound to this treasury yet.</span>
                    )}
                  </div>
                </div>
              </div>

              <div>
                <div className="label-caps text-faint">Destination</div>
                <div className="mt-2 rounded-lg bg-raised px-4 py-3">
                  <div className="numeric text-sm break-all text-ink">
                    {destination ? <XrplAccountLink address={destination} /> : <Mono>{data.destinationAccountId}</Mono>}
                  </div>
                  <div className="mt-2 text-xs text-muted">
                    {data.destinationTag === 0 ? (
                      <>
                        No destination tag. The field is omitted from the transaction entirely, which hashes differently
                        from a zero.
                      </>
                    ) : (
                      <>
                        Destination tag <span className="numeric text-ink">{data.destinationTag}</span>, included in the
                        signed transaction.
                      </>
                    )}
                  </div>
                </div>
              </div>

              <div className="sm:col-span-2">
                <div className="label-caps text-faint">Policy &amp; metadata</div>
                <dl className="mt-2">
                  <KeyValue label="Tier at the current price">
                    {tier ? (
                      <>
                        <Mono>${formatUsd(tier.maxAmountUsd)}</Mono> ceiling · {tier.requiredApprovals} approval(s) ·{" "}
                        {tier.timelockSeconds === 0 ? "no timelock" : formatWindow(tier.timelockSeconds)}
                      </>
                    ) : liveQuote.error ? (
                      <span className="text-bad">The price feed is not usable right now.</span>
                    ) : (
                      "…"
                    )}
                  </KeyValue>
                  <KeyValue label="Proposed by">
                    <AddressLink address={data.proposer} />
                  </KeyValue>
                  <KeyValue label="Treasury">
                    <Link
                      href={`/treasuries/${data.treasuryId}`}
                      className="font-medium text-accent underline underline-offset-2"
                    >
                      Treasury {data.treasuryId.toString()}
                    </Link>
                    {frozen && <span className="ml-2 text-bad">frozen</span>}
                    {treasury.data && (
                      <>
                        {" · "}
                        <Link
                          href={`/policies/${treasury.data.policyId}`}
                          className="font-medium text-accent underline underline-offset-2"
                        >
                          policy {treasury.data.policyId.toString()}
                        </Link>
                      </>
                    )}
                  </KeyValue>
                </dl>
              </div>
            </div>
          </Card>

          {data.state >= 2 && (
            <Card
              title="What was sent to the enclave"
              subtitle="Fixed at dispatch. The TEE recomputes the digest from these exact fields and refuses to sign on any mismatch."
            >
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
                <KeyValue
                  label="Policy digest"
                  hint="keccak256 over request, treasury, destination, tag, amount, sequence, expiry and fee."
                >
                  <Mono className="break-all">{data.policyDigest}</Mono>
                </KeyValue>
                {data.quorumRequired > 0 && (
                  <KeyValue
                    label="Multi-sign digest"
                    hint="keccak256(policyDigest, treasury account). A signer key does not know which treasury it signs for, so the account has to travel with the instruction — and be proven."
                  >
                    <Mono className="break-all">{data.multiSignDigest}</Mono>
                  </KeyValue>
                )}
              </dl>
            </Card>
          )}

          {data.quorumRequired > 0 && <QuorumSignatures requestId={data.id} quorum={data.quorumRequired} />}
        </div>

        <div className="space-y-4">
          <Card>
            <div className="label-caps flex items-center justify-between text-faint">
              Approvals
              <IconShield className="size-4 text-accent" />
            </div>
            <div className="numeric mt-2 text-3xl font-medium text-ink">
              {data.approvals}
              <span className="text-lg text-muted"> / {data.requiredApprovals} required</span>
            </div>
            <div className="mt-3 h-1.5 w-full overflow-hidden rounded-full bg-sunken">
              <div
                className={data.approvals >= data.requiredApprovals ? "h-full bg-good" : "h-full bg-accent"}
                style={{ width: `${approvalPercent}%` }}
                aria-hidden
              />
            </div>
            {standing.data && standing.data.entries.length > 0 && (
              <ul className="mt-4 space-y-2 border-t border-line pt-3">
                {standing.data.entries.map((entry) => (
                  <li key={entry.approver} className="flex items-center justify-between gap-2 text-xs">
                    <AddressLink address={entry.approver} />
                    {entry.stillHoldsRole ? (
                      <span className="text-faint">holds APPROVER</span>
                    ) : (
                      <Badge tone="warn">role revoked</Badge>
                    )}
                  </li>
                ))}
              </ul>
            )}
            {lapsedApprovals > 0 ? (
              <p className="mt-3 text-xs text-warn">
                {lapsedApprovals === 1 ? "One approval no longer counts" : `${lapsedApprovals} approvals no longer count`}
                , because the address lost the APPROVER role after approving. The contract counts {standing.data?.valid}{" "}
                of {data.requiredApprovals} at dispatch and will refuse below that.
              </p>
            ) : (
              <p className="mt-3 text-xs text-faint">
                Collected from addresses other than the proposer, each counted once. Dispatch re-checks that every one
                of them still holds the role.
              </p>
            )}
          </Card>

          <Card>
            <div className="label-caps flex items-center justify-between text-faint">
              Unlock delay
              <IconLock className="size-4 text-accent" />
            </div>
            <div className="mt-2 text-lg">
              <Countdown eligibleAt={data.eligibleAt} />
            </div>
            <p className="mt-3 text-xs text-faint">
              Dispatchable from {formatTimestamp(data.eligibleAt)}. The contract re-checks the whole policy at that
              moment — a countdown at zero is not permission.
            </p>
          </Card>

          {data.state >= 2 && (
            <Card>
              <div className="label-caps flex items-center justify-between text-faint">
                Ledger expiry
                <IconClock className="size-4 text-accent" />
              </div>
              <div
                className={`numeric mt-2 text-3xl font-medium ${
                  ledgersLeft !== null && ledgersLeft <= 0 ? "text-bad" : "text-ink"
                }`}
              >
                {ledgersLeft === null ? "…" : ledgersLeft > 0 ? `${ledgersLeft} ledgers` : "expired"}
              </div>
              <p className="mt-3 text-xs text-faint">
                Valid through ledger <span className="numeric text-ink">{data.lastLedgerSequence}</span>
                {ledger.data !== undefined && (
                  <>
                    ; XRPL is building <span className="numeric text-ink">{ledger.data}</span>
                  </>
                )}
                . After that the transaction can never be included, and the failure path proves it absent over{" "}
                <span className="numeric text-ink">
                  {data.firstLedgerSequence}–{data.lastLedgerSequence}
                </span>
                .
              </p>
            </Card>
          )}

          <DarkPanel title="Policy verification" icon={<IconShield className="size-4" />}>
            <ul className="space-y-3 text-sm">
              <VerificationRow
                ok={data.approvals >= data.requiredApprovals}
                label={`Approval threshold ${data.approvals}/${data.requiredApprovals}`}
              />
              <VerificationRow ok={timelockElapsed} label="Timelock elapsed" />
              <VerificationRow ok={!frozen} label="Treasury not frozen" />
              <VerificationRow
                ok={liveQuote.data !== undefined && !liveQuote.error}
                label="FTSO price fresh enough to price this"
              />
              <VerificationRow ok={tier !== null} label="Amount lands in a tier" />
            </ul>
            <p className="mt-4 border-t border-white/15 pt-3 text-xs text-white/60">
              Read from the chain now. Every one of these is checked again on-chain when the payment is dispatched.
            </p>
          </DarkPanel>
        </div>
      </div>

      {state.key === "Approved" && treasury.data && (
        <DispatchPanel request={data} treasury={treasury.data} canDispatch={hasRole(roles.data ?? 0, ROLE_PROPOSER)} />
      )}

      {data.state >= 2 && <SettlementPanel request={data} />}

      <AuditLogView title="Audit log for this request" filter={(entry) => entry.requestId === data.id} />
    </div>
  );
}

function VerificationRow({ ok, label }: { ok: boolean; label: string }) {
  return (
    <li className="flex items-start gap-3">
      <span className={`numeric mt-px text-sm font-semibold ${ok ? "text-good" : "text-white/40"}`} aria-hidden="true">
        {ok ? "✓" : "○"}
      </span>
      <span className={ok ? "text-white" : "text-white/60"}>{label}</span>
    </li>
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

/**
 * The shares collected towards a k-of-n signature.
 *
 * Each is one enclave's contribution and authorises nothing on its own — that is
 * what k-of-n buys, and showing a half-collected quorum as such is the honest
 * way to display it. Every share is published on-chain, so anyone can assemble
 * the transaction from this page's data and no service holds the pieces.
 */
function QuorumSignatures({ requestId, quorum }: { requestId: bigint; quorum: number }) {
  const shares = usePartialSignatures(requestId);
  const collected = shares.data?.length ?? 0;

  return (
    <Card
      title="Enclave signatures"
      subtitle="A quorum of machines, each of which checked the policy digest for itself before signing."
      actions={<Badge tone={collected >= quorum ? "good" : "warn"}>{`${collected} / ${quorum}`}</Badge>}
    >
      {collected === 0 ? (
        <p className="text-sm text-muted">
          No enclave has answered yet. Each machine in the signer set was sent the same instruction and signs only if
          both digests match the fields it decoded.
        </p>
      ) : (
        <ul className="space-y-3">
          {(shares.data ?? []).map((share) => {
            const address = safeAddress(share.signerAccountId);
            return (
              <li key={share.signerAccountId} className="border-b border-line pb-3 last:border-b-0 last:pb-0">
                {address ? <XrplAccountLink address={address} /> : <Mono>{share.signerAccountId}</Mono>}
                <Mono className="mt-1 block break-all text-xs text-faint">{share.signature}</Mono>
              </li>
            );
          })}
        </ul>
      )}
      <p className="mt-4 border-t border-line pt-3 text-xs text-faint">
        {collected >= quorum
          ? "Enough to submit. Assembling them needs no secret and grants no authority: every share covers the whole transaction, so a wrongly assembled one is refused by XRPL rather than paid out."
          : `${quorum - collected} more needed. A transaction submitted short of its quorum is rejected by XRPL, burning the fee and consuming the sequence for a payment that delivers nothing.`}
      </p>
    </Card>
  );
}
