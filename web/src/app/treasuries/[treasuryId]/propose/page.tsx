"use client";

import { useQuery } from "@tanstack/react-query";
import Link from "next/link";
import { useParams, useRouter } from "next/navigation";
import { useState } from "react";
import type { Hex, PublicClient } from "viem";
import { useAccount, usePublicClient } from "wagmi";

import { IconArrowRight, IconShield } from "@/components/icons";
import { TxFeedback } from "@/components/TxFeedback";
import {
  Alert,
  Breadcrumb,
  buttonClass,
  Card,
  CheckRow,
  Field,
  inputClass,
  Loading,
  PageHeader,
} from "@/components/ui";
import { WindowGauge } from "@/components/WindowGauge";
import {
  useCommittedUsd,
  useDestinationAllowed,
  usePolicy,
  useQuoteUsd,
  useRoles,
  useTreasury,
  useXrplAccount,
} from "@/hooks/useAegis";
import { useAegisTx } from "@/hooks/useAegisTx";
import { contractHandles, type Tier } from "@/lib/contracts";
import { explainFailure } from "@/lib/errors";
import { AmountParseError, formatDrops, formatUsd, formatWindow, formatXrp, parseXrpToDrops } from "@/lib/format";
import { hasRole, ROLE_PROPOSER } from "@/lib/roles";
import { bytes32ToClassicAddress, classicAddressToBytes32, XrplAddressError } from "@/lib/xrpl-address";

/**
 * Proposing a payment, checked before it costs anything.
 *
 * Every rule `propose` enforces is shown as its own line, evaluated against live
 * chain state, and the whole call is simulated before the button becomes usable.
 * A violating proposal is refused here rather than after it has spent gas and an
 * approver's attention.
 */
export default function ProposePage() {
  const params = useParams<{ treasuryId: string }>();
  const router = useRouter();
  const treasuryId = parseId(params.treasuryId);

  const treasury = useTreasury(treasuryId);
  const policy = usePolicy(treasury.data?.policyId);
  const committed = useCommittedUsd(treasuryId);
  const { address } = useAccount();
  const roles = useRoles(treasury.data?.policyId, address);
  const publicClient = usePublicClient();
  const tx = useAegisTx();
  const { paymentController } = contractHandles();

  // What the treasury actually holds, so an amount can be judged against it
  // before the contract is asked. The reserve makes the balance an upper bound
  // rather than a spendable figure, which is why nothing here fills the field in.
  const treasuryAddress = treasury.data ? safeAddress(treasury.data.xrplAccountId) : null;
  const balance = useXrplAccount(treasuryAddress);

  const [destination, setDestination] = useState("");
  const [tag, setTag] = useState("0");
  const [amountXrp, setAmountXrp] = useState("");

  // --- parse what was typed ------------------------------------------------

  let accountId: Hex | null = null;
  let destinationError: string | null = null;
  if (destination.trim() !== "") {
    try {
      accountId = classicAddressToBytes32(destination.trim());
    } catch (error) {
      destinationError = error instanceof XrplAddressError ? error.message : String(error);
    }
  }

  const tagValue = /^\d+$/.test(tag.trim()) ? Number(tag.trim()) : null;
  const tagError =
    tagValue === null
      ? "A destination tag is a whole number. Use 0 for none."
      : tagValue > 0xffffffff
        ? "A destination tag is a 32-bit number."
        : null;

  let amountDrops: bigint | null = null;
  let amountError: string | null = null;
  if (amountXrp.trim() !== "") {
    try {
      amountDrops = parseXrpToDrops(amountXrp);
      if (amountDrops === 0n) {
        amountError = "A payment of zero drops would consume a sequence number and move nothing.";
        amountDrops = null;
      }
    } catch (error) {
      amountError = error instanceof AmountParseError ? error.message : String(error);
    }
  }

  // --- check it against the chain -----------------------------------------

  const quote = useQuoteUsd(amountDrops ?? undefined);
  const allowed = useDestinationAllowed(treasury.data?.policyId, accountId ?? undefined, tagValue ?? 0);

  const tier = policy.data && quote.data !== undefined ? resolveTier(policy.data.tiers, quote.data) : undefined;
  const overCap = policy.data !== undefined && quote.data !== undefined && tier === null;

  const windowFits =
    policy.data && committed.data !== undefined && quote.data !== undefined
      ? committed.data + quote.data <= policy.data.rollingWindowUsd
      : undefined;

  const inputsReady = accountId !== null && tagValue !== null && amountDrops !== null;

  const simulation = useQuery({
    queryKey: ["simulatePropose", treasuryId?.toString(), accountId, tagValue, amountDrops?.toString(), address],
    enabled: Boolean(publicClient) && Boolean(address) && treasuryId !== undefined && inputsReady,
    retry: false,
    queryFn: async () => {
      await (publicClient as PublicClient).simulateContract({
        address: paymentController.address,
        abi: paymentController.abi,
        functionName: "propose",
        args: [treasuryId as bigint, accountId as Hex, tagValue as number, amountDrops as bigint],
        account: address,
      } as never);
      return true;
    },
  });

  if (treasuryId === undefined) return <Card title="Not a treasury id">That is not a treasury id.</Card>;
  if (treasury.isPending || policy.isPending) return <Loading what="the treasury and its policy" />;
  if (!treasury.data || !policy.data) return <Card title="No such treasury">Nothing to propose from.</Card>;

  const canPropose = hasRole(roles.data ?? 0, ROLE_PROPOSER);
  const ready = inputsReady && simulation.isSuccess && !tx.isBusy;

  return (
    <div className="space-y-8">
      <PageHeader
        breadcrumb={
          <Breadcrumb
            items={[
              { label: "Treasuries", href: "/" },
              { label: `Treasury ${treasury.data.id.toString()}`, href: `/treasuries/${treasury.data.id}` },
              { label: "Propose a payment" },
            ]}
          />
        }
        title="Propose a payment"
        description={
          <>
            Governed by{" "}
            <Link
              href={`/policies/${treasury.data.policyId}`}
              className="font-medium text-accent underline underline-offset-2"
            >
              policy {treasury.data.policyId.toString()}
            </Link>
            . Every rule on the right is checked now and again at dispatch — the price moves and the window is shared.
          </>
        }
      />

      <div className="grid gap-6 lg:grid-cols-3">
        <div className="lg:col-span-2">
          <Card>
            <Field
              label="Destination address"
              error={destinationError}
              hint="XRPL classic address. The checksum is verified before anything is sent."
            >
              <input
                className={inputClass}
                placeholder="r3ymjALibVQ6D7Rdy84NJovACu7TzBJjMX"
                value={destination}
                onChange={(event) => setDestination(event.target.value)}
              />
            </Field>

            <div className="mt-5 grid gap-5 sm:grid-cols-2">
              <Field
                label="Destination tag"
                error={tagError}
                hint={tagValue === 0 ? "Omitted from the transaction entirely." : "Included in the signed transaction."}
              >
                <input
                  className={inputClass}
                  inputMode="numeric"
                  value={tag}
                  onChange={(event) => setTag(event.target.value)}
                />
              </Field>

              <Field label="Asset" hint="A treasury holds XRP. Issued currencies are not in this version.">
                <div className="flex items-center gap-3 rounded-lg border border-line bg-sunken px-3.5 py-2.5 text-sm">
                  <span className="flex size-6 items-center justify-center rounded-full bg-navy text-xs font-bold text-white">
                    X
                  </span>
                  <span className="font-medium text-ink">XRP</span>
                </div>
              </Field>
            </div>

            <div className="mt-5">
              <div className="flex flex-wrap items-baseline justify-between gap-2">
                <span className="text-sm font-medium text-ink">Amount</span>
                <span className="numeric text-sm text-muted">
                  {balance.isPending
                    ? "reading the ledger…"
                    : balance.data
                      ? `Balance: ${formatXrp(balance.data.balanceDrops)} XRP`
                      : treasuryAddress
                        ? "Balance: account not funded"
                        : "Balance: no XRPL account bound"}
                </span>
              </div>
              <div className="mt-1.5">
                <div className="rounded-lg border border-line bg-raised px-4 py-4 focus-within:border-accent focus-within:bg-surface">
                  <div className="flex items-baseline gap-3">
                    <input
                      className="numeric w-full bg-transparent text-3xl text-ink outline-none placeholder:text-line-strong"
                      inputMode="decimal"
                      placeholder="0.000000"
                      value={amountXrp}
                      onChange={(event) => setAmountXrp(event.target.value)}
                    />
                    <span className="text-xl font-semibold text-muted">XRP</span>
                  </div>
                  <div className="mt-2 flex flex-wrap items-baseline justify-between gap-2 text-sm">
                    <span className="numeric text-faint">
                      {amountDrops === null ? "— drops" : `${formatDrops(amountDrops)} drops`}
                    </span>
                    <span className={`numeric ${quote.error ? "text-bad" : "text-muted"}`}>
                      {quote.isPending && amountDrops !== null
                        ? "pricing…"
                        : quote.error
                          ? explainFailure(quote.error).title
                          : quote.data !== undefined
                            ? `≈ $${formatUsd(quote.data)} at the live FTSO price`
                            : "≈ $0.00"}
                    </span>
                  </div>
                </div>
                {amountError ? (
                  <p className="mt-1.5 text-xs text-bad">{amountError}</p>
                ) : (
                  <p className="mt-1.5 text-xs text-faint">
                    Six decimal places. One drop is the smallest unit XRPL can move, and the ledger holds back a base
                    reserve, so the whole balance is never spendable.
                  </p>
                )}
              </div>
            </div>

            {tier && quote.data !== undefined && (
              <div className="mt-5">
                <Alert tone="info" title="If this is proposed">
                  It will need <strong>{tier.requiredApprovals}</strong> approval(s) from addresses other than yours,
                  and become dispatchable{" "}
                  {tier.timelockSeconds === 0 ? "immediately after" : `${formatWindow(tier.timelockSeconds)} after`} it
                  is proposed. The amount is {formatXrp(amountDrops ?? 0n)} XRP, worth ${formatUsd(quote.data)} right
                  now — and it will be re-priced at dispatch.
                </Alert>
              </div>
            )}

            <div className="mt-6 border-t border-line pt-6">
              <button
                type="button"
                className={`${buttonClass("primary")} w-full py-3.5 text-base`}
                disabled={!ready}
                onClick={async () => {
                  if (accountId === null || tagValue === null || amountDrops === null) return;
                  const proposed = await tx.run({
                    address: paymentController.address,
                    abi: paymentController.abi,
                    functionName: "propose",
                    args: [treasuryId, accountId, tagValue, amountDrops],
                  });
                  if (proposed) router.push(`/treasuries/${treasuryId}`);
                }}
              >
                {tx.isBusy ? "Working…" : "Propose payment"}
                <IconArrowRight className="size-4" />
              </button>
              {!ready && inputsReady && (
                <p className="mt-3 text-center text-xs text-faint">Every line in the policy check must pass first.</p>
              )}
              <TxFeedback state={tx.state} doneMessage="Payment proposed" />
            </div>
          </Card>
        </div>

        <div className="space-y-4">
          <section className="rounded-lg border border-line bg-raised p-5">
            <h2 className="flex items-center gap-2 text-lg font-semibold tracking-tight text-ink">
              <IconShield className="size-5 text-accent" />
              Policy check
            </h2>
            <p className="mt-1 text-xs text-faint">
              Read from the chain as you type. The last line is the contract itself, simulated.
            </p>

            <div className="mt-4 space-y-2.5">
              <CheckRow
                state={canPropose ? "pass" : address ? "fail" : "pending"}
                title="You hold PROPOSER on this policy"
              >
                {address
                  ? canPropose
                    ? undefined
                    : "Only an address with the PROPOSER role may propose a payment."
                  : "Connect a wallet to check."}
              </CheckRow>

              <CheckRow state={treasury.data.frozen ? "fail" : "pass"} title="The treasury is not frozen">
                {treasury.data.frozen
                  ? "A guardian froze it. Propose, approve and dispatch are all refused."
                  : undefined}
              </CheckRow>

              <CheckRow
                state={accountId === null ? "pending" : "pass"}
                title="The destination address is well formed"
              >
                {destinationError ?? undefined}
              </CheckRow>

              <CheckRow
                state={
                  !inputsReady || allowed.data === undefined ? "pending" : allowed.data ? "pass" : "fail"
                }
                title={
                  policy.data.allowlistEnforced
                    ? "The destination is allowlisted"
                    : "The policy does not enforce an allowlist"
                }
              >
                {allowed.data === false
                  ? "A policy administrator can add this account, either for one tag or for any tag."
                  : undefined}
              </CheckRow>

              <CheckRow
                state={quote.error ? "fail" : quote.data === undefined ? "pending" : "pass"}
                title="The XRP price is fresh enough to value the payment"
              >
                {quote.error
                  ? explainFailure(quote.error).detail
                  : "The feed must be under 180 seconds old. There is no cached fallback."}
              </CheckRow>

              <CheckRow
                state={overCap ? "fail" : tier ? "pass" : "pending"}
                title="The amount is inside the policy's hard cap"
              >
                {overCap
                  ? `No tier covers $${formatUsd(quote.data ?? 0n)}. The highest ceiling is $${formatUsd(
                      policy.data.tiers[policy.data.tiers.length - 1]?.maxAmountUsd ?? 0n,
                    )}.`
                  : tier
                    ? `Tier ceiling $${formatUsd(tier.maxAmountUsd)} — ${tier.requiredApprovals} approval(s), ${
                        tier.timelockSeconds === 0 ? "no timelock" : formatWindow(tier.timelockSeconds)
                      }.`
                    : undefined}
              </CheckRow>

              <CheckRow
                state={windowFits === undefined ? "pending" : windowFits ? "pass" : "fail"}
                title="It fits inside the rolling window"
              >
                {windowFits === false
                  ? "The window is already committed. Wait for earlier spend to age out, or split the payment."
                  : undefined}
              </CheckRow>

              <CheckRow
                state={
                  !inputsReady || !address || simulation.isPending
                    ? "pending"
                    : simulation.isSuccess
                      ? "pass"
                      : "fail"
                }
                title="The contract accepts this proposal"
              >
                {simulation.error ? explainFailure(simulation.error).detail : undefined}
              </CheckRow>
            </div>
          </section>

          {committed.data !== undefined && (
            <Card>
              <WindowGauge
                committedUsd={committed.data}
                capUsd={policy.data.rollingWindowUsd}
                windowSeconds={policy.data.windowSeconds}
                pendingUsd={quote.data ?? 0n}
              />
            </Card>
          )}
        </div>
      </div>
    </div>
  );
}

/** The lowest tier whose ceiling covers the amount, or null when none does. */
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
