"use client";

import { inputClass, selectClass } from "@/components/ui";

/**
 * A duration, entered in whatever unit the person thinks in.
 *
 * Contracts store seconds. People say "two days". The conversion happens here so
 * that a timelock is never mistyped by three orders of magnitude, which is the
 * kind of error that only shows up when a payment unlocks a year late.
 */

const UNITS = [
  { key: "seconds", label: "seconds", seconds: 1 },
  { key: "minutes", label: "minutes", seconds: 60 },
  { key: "hours", label: "hours", seconds: 3600 },
  { key: "days", label: "days", seconds: 86400 },
] as const;

export type DurationUnit = (typeof UNITS)[number]["key"];

export type Duration = { amount: string; unit: DurationUnit };

/** Total seconds, or null when the amount is not a whole number. */
export function durationSeconds(duration: Duration): number | null {
  const text = duration.amount.trim();
  if (!/^\d+$/.test(text)) return null;
  const unit = UNITS.find((candidate) => candidate.key === duration.unit);
  if (!unit) return null;
  return Number(text) * unit.seconds;
}

export function DurationInput({
  value,
  onChange,
  id,
}: {
  value: Duration;
  onChange: (next: Duration) => void;
  id?: string;
}) {
  return (
    <div className="flex gap-2">
      <input
        id={id}
        className={`${inputClass} w-28`}
        inputMode="numeric"
        value={value.amount}
        onChange={(event) => onChange({ ...value, amount: event.target.value })}
      />
      <select
        className={`${selectClass} w-32`}
        value={value.unit}
        onChange={(event) => onChange({ ...value, unit: event.target.value as DurationUnit })}
      >
        {UNITS.map((unit) => (
          <option key={unit.key} value={unit.key}>
            {unit.label}
          </option>
        ))}
      </select>
    </div>
  );
}
