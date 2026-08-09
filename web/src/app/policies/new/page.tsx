"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

import { DurationInput, durationSeconds, type Duration } from "@/components/DurationInput";
import { IconPlus, IconTrash } from "@/components/icons";
import { TxFeedback } from "@/components/TxFeedback";
import { Alert, Breadcrumb, buttonClass, Card, Field, inputClass, PageHeader } from "@/components/ui";
import { useAegisTx } from "@/hooks/useAegisTx";
import { contractHandles } from "@/lib/contracts";
import { AmountParseError, formatUsd, formatWindow, parseUsdToWad } from "@/lib/format";

/**
 * Policy authoring.
 *
 * Everything the contract will reject is rejected here first, in the words the
 * rule uses. A form that lets you submit an unsorted tier list and then shows
 * `TiersNotAscending(2)` has taught you nothing except that you wasted gas.
 */

type TierRow = {
  maxAmountUsd: string;
  requiredApprovals: string;
  timelock: Duration;
};

const MAX_TIERS = 16;

const EMPTY_TIER: TierRow = {
  maxAmountUsd: "",
  requiredApprovals: "1",
  timelock: { amount: "0", unit: "hours" },
};

type ParsedTier = { maxAmountUsd: bigint; requiredApprovals: number; timelockSeconds: number };

type Validation = {
  tierErrors: (string | null)[];
  fieldErrors: Record<string, string | null>;
  warnings: string[];
  parsed: {
    tiers: ParsedTier[];
    rollingWindowUsd: bigint;
    windowSeconds: number;
    allowlistEnforced: boolean;
    amendApprovals: number;
    amendTimelock: number;
  } | null;
};

export default function NewPolicyPage() {
  const router = useRouter();
  const tx = useAegisTx();
  const { policyEngine } = contractHandles();

  const [tiers, setTiers] = useState<TierRow[]>([{ ...EMPTY_TIER }]);
  const [rollingWindowUsd, setRollingWindowUsd] = useState("");
  const [windowLength, setWindowLength] = useState<Duration>({ amount: "24", unit: "hours" });
  const [allowlistEnforced, setAllowlistEnforced] = useState(true);
  const [amendApprovals, setAmendApprovals] = useState("2");
  const [amendTimelock, setAmendTimelock] = useState<Duration>({ amount: "24", unit: "hours" });

  const validation = validate({
    tiers,
    rollingWindowUsd,
    windowLength,
    allowlistEnforced,
    amendApprovals,
    amendTimelock,
  });

  function updateTier(index: number, patch: Partial<TierRow>) {
    setTiers((current) => current.map((tier, i) => (i === index ? { ...tier, ...patch } : tier)));
  }

  function discardDraft() {
    setTiers([{ ...EMPTY_TIER }]);
    setRollingWindowUsd("");
    setWindowLength({ amount: "24", unit: "hours" });
    setAllowlistEnforced(true);
    setAmendApprovals("2");
    setAmendTimelock({ amount: "24", unit: "hours" });
    tx.reset();
  }

  return (
    <div className="space-y-8">
      <PageHeader
        breadcrumb={<Breadcrumb items={[{ label: "Policies", href: "/policies" }, { label: "Create new policy" }]} />}
        title="Policy configuration"
        description="A policy is immutable once created. Changing a rule means creating a new policy and repointing the treasury, which takes the current policy's amendment threshold and timelock — so the numbers below are worth getting right."
      />

      <Card
        title="Spending tiers"
        subtitle="Ascending ceilings in USD. A payment takes the lowest tier that covers it; the highest ceiling is the hard per-payment cap."
        actions={
          <button
            type="button"
            className="inline-flex items-center gap-1.5 text-sm font-semibold text-accent hover:text-accent-strong disabled:opacity-40"
            disabled={tiers.length >= MAX_TIERS}
            onClick={() => setTiers((current) => [...current, { ...EMPTY_TIER }])}
          >
            <IconPlus className="size-4" />
            Add tier
          </button>
        }
      >
        <div className="space-y-4">
          {tiers.map((tier, index) => (
            <div key={index} className="rounded-lg border border-line bg-raised p-5">
              <div className="flex items-center justify-between">
                <span className="label-caps text-faint">Tier {index + 1}</span>
                {tiers.length > 1 && (
                  <button
                    type="button"
                    aria-label={`Remove tier ${index + 1}`}
                    className="flex size-8 items-center justify-center rounded-lg text-faint hover:bg-bad-dim hover:text-bad"
                    onClick={() => setTiers((current) => current.filter((_, i) => i !== index))}
                  >
                    <IconTrash className="size-4" />
                  </button>
                )}
              </div>

              <div className="mt-3 grid gap-4 md:grid-cols-3">
                <Field label="Ceiling (USD)" hint="Payments up to this value take this tier.">
                  <input
                    className={inputClass}
                    inputMode="decimal"
                    placeholder="10000"
                    value={tier.maxAmountUsd}
                    onChange={(event) => updateTier(index, { maxAmountUsd: event.target.value })}
                  />
                </Field>
                <Field label="Required approvals" hint="Approvals from addresses other than the proposer.">
                  <input
                    className={inputClass}
                    inputMode="numeric"
                    value={tier.requiredApprovals}
                    onChange={(event) => updateTier(index, { requiredApprovals: event.target.value })}
                  />
                </Field>
                <Field label="Timelock" hint="Wait between the last approval and dispatch.">
                  <DurationInput value={tier.timelock} onChange={(next) => updateTier(index, { timelock: next })} />
                </Field>
              </div>

              {validation.tierErrors[index] && (
                <p className="mt-2 text-xs text-bad">{validation.tierErrors[index]}</p>
              )}
            </div>
          ))}
        </div>
      </Card>

      <div className="grid gap-6 lg:grid-cols-2">
        <Card
          title="Rolling window"
          subtitle="Total USD that may be committed inside one window, across every payment."
        >
          <div className="grid gap-4 sm:grid-cols-2">
            <Field label="Window budget (USD)" error={validation.fieldErrors.rollingWindowUsd}>
              <input
                className={inputClass}
                inputMode="decimal"
                placeholder="50000"
                value={rollingWindowUsd}
                onChange={(event) => setRollingWindowUsd(event.target.value)}
              />
            </Field>
            <Field label="Window length" error={validation.fieldErrors.windowSeconds}>
              <DurationInput value={windowLength} onChange={setWindowLength} />
            </Field>
          </div>
        </Card>

        <Card title="Allowlist control" subtitle="Whether payments may only go to allowlisted XRPL accounts.">
          <div className="flex items-start justify-between gap-4">
            <div>
              <div className="text-sm font-semibold text-ink">Restrict destinations</div>
              <p className="mt-1 max-w-sm text-xs text-faint">
                With this off, any XRPL account may be paid as long as the amount rules pass. A policy administrator can
                edit the allowlist afterwards; the rules themselves cannot change.
              </p>
            </div>
            <button
              type="button"
              role="switch"
              aria-checked={allowlistEnforced}
              aria-label="Enforce the destination allowlist"
              onClick={() => setAllowlistEnforced((current) => !current)}
              className={`relative h-7 w-12 shrink-0 rounded-full transition-colors ${
                allowlistEnforced ? "bg-accent" : "bg-line-strong"
              }`}
            >
              <span
                className={`absolute top-1 size-5 rounded-full bg-white transition-all ${
                  allowlistEnforced ? "left-6" : "left-1"
                }`}
              />
            </button>
          </div>
          <p className="mt-4 rounded-lg bg-raised px-4 py-3 text-xs text-muted">
            {allowlistEnforced
              ? "Every destination must be added to the allowlist before it can be paid. Tag 0 permits any tag on that account."
              : "Any well-formed XRPL destination will pass the allowlist check."}
          </p>
        </Card>
      </div>

      <Card
        title="Amendments"
        subtitle="What it takes to unfreeze this treasury or move it to a different policy."
      >
        <div className="grid gap-4 md:grid-cols-2">
          <Field
            label="Amendment approvals"
            error={validation.fieldErrors.amendApprovals}
            hint="Approvers other than the proposer of the amendment."
          >
            <input
              className={inputClass}
              inputMode="numeric"
              value={amendApprovals}
              onChange={(event) => setAmendApprovals(event.target.value)}
            />
          </Field>
          <Field label="Amendment timelock" error={validation.fieldErrors.amendTimelock}>
            <DurationInput value={amendTimelock} onChange={setAmendTimelock} />
          </Field>
        </div>
        <p className="mt-3 text-xs text-faint">
          Freezing is instant and takes one guardian. Unfreezing takes these. Stopping payments on suspicion should be
          fast; resuming them should not be.
        </p>
      </Card>

      {validation.warnings.length > 0 && (
        <Alert tone="warn" title="Worth a second look">
          <ul className="list-disc space-y-1 pl-4">
            {validation.warnings.map((warning) => (
              <li key={warning}>{warning}</li>
            ))}
          </ul>
        </Alert>
      )}

      <div className="flex flex-wrap items-center justify-end gap-3 border-t border-line pt-6">
        {validation.parsed === null && (
          <span className="mr-auto text-xs text-faint">Fix the fields above before the policy can be created.</span>
        )}
        <button type="button" className={buttonClass("ghost")} disabled={tx.isBusy} onClick={discardDraft}>
          Discard draft
        </button>
        <button
          type="button"
          className={buttonClass("primary")}
          disabled={validation.parsed === null || tx.isBusy}
          onClick={async () => {
            const parsed = validation.parsed;
            if (!parsed) return;
            const created = await tx.run({
              address: policyEngine.address,
              abi: policyEngine.abi,
              functionName: "createPolicy",
              args: [
                parsed.tiers,
                parsed.rollingWindowUsd,
                parsed.windowSeconds,
                parsed.allowlistEnforced,
                parsed.amendApprovals,
                parsed.amendTimelock,
              ],
            });
            if (created) router.push("/policies");
          }}
        >
          {tx.isBusy ? "Working…" : "Create policy"}
        </button>
      </div>

      <TxFeedback state={tx.state} doneMessage="Policy created" />
    </div>
  );
}

function validate(input: {
  tiers: TierRow[];
  rollingWindowUsd: string;
  windowLength: Duration;
  allowlistEnforced: boolean;
  amendApprovals: string;
  amendTimelock: Duration;
}): Validation {
  const tierErrors: (string | null)[] = [];
  const fieldErrors: Record<string, string | null> = {};
  const warnings: string[] = [];

  const parsedTiers: ParsedTier[] = [];
  let previousCeiling: bigint | null = null;
  let tiersOk = true;

  input.tiers.forEach((tier, index) => {
    let error: string | null = null;
    let ceiling: bigint | null = null;

    try {
      ceiling = parseUsdToWad(tier.maxAmountUsd);
      if (ceiling === 0n) error = "A ceiling of zero would refuse every payment.";
    } catch (parseError) {
      error = parseError instanceof AmountParseError ? parseError.message : String(parseError);
    }

    const approvals = Number(tier.requiredApprovals.trim());
    if (!error) {
      if (!Number.isInteger(approvals) || approvals < 1) {
        error = "A tier needs at least one approval — otherwise a proposer could pay themselves unchecked.";
      } else if (approvals > 255) {
        error = "A tier cannot need more than 255 approvals.";
      }
    }

    const timelockSeconds = durationSeconds(tier.timelock);
    if (!error) {
      if (timelockSeconds === null) error = "The timelock must be a whole number of time units.";
      else if (timelockSeconds > 0xffffffff) error = "That timelock is longer than the contract can store.";
    }

    if (!error && ceiling !== null && previousCeiling !== null && ceiling <= previousCeiling) {
      error = `Tier ${index + 1} must have a higher ceiling than tier ${index}. Tiers ascend, and the last one is the hard cap.`;
    }

    if (error) {
      tiersOk = false;
    } else if (ceiling !== null && timelockSeconds !== null) {
      previousCeiling = ceiling;
      parsedTiers.push({ maxAmountUsd: ceiling, requiredApprovals: approvals, timelockSeconds });
    }

    tierErrors.push(error);
  });

  if (input.tiers.length === 0) tiersOk = false;
  if (input.tiers.length > MAX_TIERS) tiersOk = false;

  let rollingWindowUsd: bigint | null = null;
  try {
    rollingWindowUsd = parseUsdToWad(input.rollingWindowUsd);
    if (rollingWindowUsd === 0n) {
      fieldErrors.rollingWindowUsd = "A window of zero would refuse every payment.";
      rollingWindowUsd = null;
    }
  } catch (parseError) {
    fieldErrors.rollingWindowUsd = parseError instanceof AmountParseError ? parseError.message : String(parseError);
  }

  const windowSeconds = durationSeconds(input.windowLength);
  if (windowSeconds === null || windowSeconds === 0) {
    fieldErrors.windowSeconds = "The window needs a length, or no spend could ever age out of it.";
  } else if (windowSeconds > 0xffffffff) {
    fieldErrors.windowSeconds = "That window is longer than the contract can store.";
  }

  const amendApprovals = Number(input.amendApprovals.trim());
  if (!Number.isInteger(amendApprovals) || amendApprovals < 1) {
    fieldErrors.amendApprovals = "With zero amendment approvals, one address could unfreeze the treasury alone.";
  } else if (amendApprovals > 255) {
    fieldErrors.amendApprovals = "An amendment cannot need more than 255 approvals.";
  }

  const amendTimelock = durationSeconds(input.amendTimelock);
  if (amendTimelock === null) {
    fieldErrors.amendTimelock = "The amendment timelock must be a whole number of time units.";
  } else if (amendTimelock > 0xffffffff) {
    fieldErrors.amendTimelock = "That timelock is longer than the contract can store.";
  }

  const topTier = parsedTiers[parsedTiers.length - 1];
  if (rollingWindowUsd !== null && topTier && rollingWindowUsd < topTier.maxAmountUsd) {
    warnings.push(
      `The window budget of $${formatUsd(rollingWindowUsd)} is below the highest tier ceiling of $${formatUsd(
        topTier.maxAmountUsd,
      )}, so a payment at that ceiling could never be dispatched.`,
    );
  }
  if (windowSeconds !== null && windowSeconds > 0 && topTier && topTier.timelockSeconds > windowSeconds) {
    warnings.push(
      `The highest tier waits longer than the ${formatWindow(
        windowSeconds,
      )} window, so its own spend ages out before it can be dispatched twice.`,
    );
  }

  const ok =
    tiersOk &&
    parsedTiers.length === input.tiers.length &&
    parsedTiers.length > 0 &&
    rollingWindowUsd !== null &&
    windowSeconds !== null &&
    windowSeconds > 0 &&
    Number.isInteger(amendApprovals) &&
    amendApprovals >= 1 &&
    amendTimelock !== null;

  return {
    tierErrors,
    fieldErrors,
    warnings,
    parsed: ok
      ? {
          tiers: parsedTiers,
          rollingWindowUsd: rollingWindowUsd as bigint,
          windowSeconds: windowSeconds as number,
          allowlistEnforced: input.allowlistEnforced,
          amendApprovals,
          amendTimelock: amendTimelock as number,
        }
      : null,
  };
}
