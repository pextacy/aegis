"use client";

import { useQuery } from "@tanstack/react-query";
import Link from "next/link";
import { useParams, useRouter } from "next/navigation";
import { useState, type ReactNode } from "react";
import type { Hex, PublicClient } from "viem";
import { useAccount, usePublicClient } from "wagmi";

import { TxFeedback } from "@/components/TxFeedback";
import { Alert, buttonClass, Card, Field, inputClass, Loading, Stat } from "@/components/ui";
import { WindowGauge } from "@/components/WindowGauge";
import {
  useCommittedUsd,
  useDestinationAllowed,
  usePolicy,
  useQuoteUsd,
  useRoles,
  useTreasury,
} from "@/hooks/useAegis";
import { useAegisTx } from "@/hooks/useAegisTx";
import { contractHandles, type Tier } from "@/lib/contracts";
import { explainFailure } from "@/lib/errors";
import { AmountParseError, formatDrops, formatUsd, formatWindow, formatXrp, parseXrpToDrops } from "@/lib/format";
import { hasRole, ROLE_PROPOSER } from "@/lib/roles";
import { classicAddressToBytes32, XrplAddressError } from "@/lib/xrpl-address";

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
    <div className="space-y-6">
      <header>
        <h1 className="text-xl font-semibold text-ink">
          Propose a payment from treasury {treasury.data.id.toString()}
        </h1>
        <p className="mt-1 text-sm text-muted">
          Governed by{" "}
          <Link href={`/policies/${treasury.data.policyId}`} className="text-accent underline underline-offset-2">
            policy {treasury.data.policyId.toString()}
          </Link>
          . Every rule below is checked now and again at dispatch — the price moves and the window is shared.
        </p>
      </header>

      <Card title="Payment">
        <div className="grid gap-4 md:grid-cols-[1fr_10rem]">
          <Field
            label="Destination"
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
          <Field
            label="Destination tag"
            error={tagError}
            hint={tagValue === 0 ? "Omitted from the transaction." : "Included in the signed transaction."}
          >
            <input
              className={inputClass}
              inputMode="numeric"
              value={tag}
              onChange={(event) => setTag(event.target.value)}
            />
          </Field>
        </div>

        <div className="mt-4 grid gap-4 md:grid-cols-2">
          <Field label="Amount (XRP)" error={amountError} hint="Six decimal places. One drop is the smallest unit.">
            <input
              className={inputClass}
              inputMode="decimal"
              placeholder="100.000000"
              value={amountXrp}
              onChange={(event) => setAmountXrp(event.target.value)}
            />
          </Field>
          <div className="grid grid-cols-2 gap-4 md:pt-6">
            <Stat label="In drops" value={amountDrops === null ? "—" : formatDrops(amountDrops)} />
            <Stat
              label="At the live FTSO price"
              value={
                quote.isPending && amountDrops !== null
                  ? "…"
                  : quote.data !== undefined
                    ? `$${formatUsd(quote.data)}`
                    : "—"
              }
              hint={quote.error ? explainFailure(quote.error).title : undefined}
              tone={quote.error ? "bad" : "neutral"}
            />
          </div>
        </div>
      </Card>

      <Card
        title="What the contract will check"
        subtitle="Read from the chain as you type. The last line is the contract itself, simulated."
      >
        <ul className="space-y-2">
          <Check
            state={canPropose ? "pass" : address ? "fail" : "unknown"}
            label="You hold PROPOSER on this policy"
            detail={
              address
                ? canPropose
                  ? undefined
                  : "Only an address with the PROPOSER role may propose a payment."
                : "Connect a wallet to check."
            }
          />
          <Check
            state={treasury.data.frozen ? "fail" : "pass"}
            label="The treasury is not frozen"
            detail={treasury.data.frozen ? "A guardian froze it. Propose, approve and dispatch are all refused." : undefined}
          />
          <Check
            state={accountId === null ? "unknown" : "pass"}
            label="The destination address is well formed"
            detail={destinationError ?? undefined}
          />
          <Check
            state={
              !inputsReady
                ? "unknown"
                : allowed.data === undefined
                  ? "unknown"
                  : allowed.data
                    ? "pass"
                    : "fail"
            }
            label={
              policy.data.allowlistEnforced
                ? "The destination is allowlisted"
                : "The policy does not enforce an allowlist"
            }
            detail={
              allowed.data === false
                ? "A policy administrator can add this account, either for one tag or for any tag."
                : undefined
            }
          />
          <Check
            state={quote.error ? "fail" : quote.data === undefined ? "unknown" : "pass"}
            label="The XRP price is fresh enough to value the payment"
            detail={
              quote.error
                ? explainFailure(quote.error).detail
                : "The feed must be under 180 seconds old. There is no cached fallback."
            }
          />
          <Check
            state={overCap ? "fail" : tier ? "pass" : "unknown"}
            label="The amount is inside the policy's hard cap"
            detail={
              overCap
                ? `No tier covers $${formatUsd(quote.data ?? 0n)}. The highest ceiling is $${formatUsd(
                    policy.data.tiers[policy.data.tiers.length - 1]?.maxAmountUsd ?? 0n,
                  )}.`
                : tier
                  ? `Tier ceiling $${formatUsd(tier.maxAmountUsd)} — ${tier.requiredApprovals} approval(s), ${
                      tier.timelockSeconds === 0 ? "no timelock" : formatWindow(tier.timelockSeconds)
                    }.`
                  : undefined
            }
          />
          <Check
            state={windowFits === undefined ? "unknown" : windowFits ? "pass" : "fail"}
            label="It fits inside the rolling window"
            detail={
              windowFits === false
                ? "The window is already committed. Wait for earlier spend to age out, or split the payment."
                : undefined
            }
          />
          <Check
            state={
              !inputsReady || !address
                ? "unknown"
                : simulation.isPending
                  ? "unknown"
                  : simulation.isSuccess
                    ? "pass"
                    : "fail"
            }
            label="The contract accepts this proposal"
            detail={simulation.error ? explainFailure(simulation.error).detail : undefined}
          />
        </ul>

        {committed.data !== undefined && (
          <div className="mt-6">
            <WindowGauge
              committedUsd={committed.data}
              capUsd={policy.data.rollingWindowUsd}
              windowSeconds={policy.data.windowSeconds}
              pendingUsd={quote.data ?? 0n}
            />
          </div>
        )}
      </Card>

      {tier && quote.data !== undefined && (
        <Alert tone="info" title="If this is proposed">
          It will need <strong>{tier.requiredApprovals}</strong> approval(s) from addresses other than yours, and
          become dispatchable{" "}
          {tier.timelockSeconds === 0 ? "immediately after" : `${formatWindow(tier.timelockSeconds)} after`} it is
          proposed. The amount is {formatXrp(amountDrops ?? 0n)} XRP, worth ${formatUsd(quote.data)} right now — and it
          will be re-priced at dispatch.
        </Alert>
      )}

      <div className="flex items-center gap-3">
        <button
          type="button"
          className={buttonClass("primary")}
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
        </button>
        {!ready && inputsReady && <span className="text-xs text-faint">Every line above must pass first.</span>}
      </div>

      <TxFeedback state={tx.state} doneMessage="Payment proposed" />
    </div>
  );
}

type CheckState = "pass" | "fail" | "unknown";

function Check({ state, label, detail }: { state: CheckState; label: ReactNode; detail?: ReactNode }) {
  const mark = state === "pass" ? "✓" : state === "fail" ? "✕" : "·";
  const colour = state === "pass" ? "text-good" : state === "fail" ? "text-bad" : "text-faint";

  return (
    <li className="flex gap-3 text-sm">
      <span className={`numeric w-4 shrink-0 ${colour}`}>{mark}</span>
      <span>
        <span className={state === "fail" ? "text-ink" : "text-muted"}>{label}</span>
        {detail && <span className="mt-0.5 block text-xs text-faint">{detail}</span>}
      </span>
    </li>
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
