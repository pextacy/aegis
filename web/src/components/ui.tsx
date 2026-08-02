import type { ReactNode } from "react";

import { explainFailure } from "@/lib/errors";

/**
 * The dashboard's shared surfaces.
 *
 * Deliberately plain. This screen exists so an approver can check a payment
 * against a policy, and every visual decision here is in service of that: one
 * accent colour, tabular figures, and no motion that would pull attention away
 * from a number.
 */

export type Tone = "neutral" | "good" | "warn" | "bad" | "info" | "accent";

const TONE_TEXT: Record<Tone, string> = {
  neutral: "text-muted",
  good: "text-good",
  warn: "text-warn",
  bad: "text-bad",
  info: "text-info",
  accent: "text-accent",
};

const TONE_BADGE: Record<Tone, string> = {
  neutral: "border-line text-muted",
  good: "border-good/40 text-good",
  warn: "border-warn/40 text-warn",
  bad: "border-bad/40 text-bad",
  info: "border-info/40 text-info",
  accent: "border-accent/40 text-accent",
};

export function Card({
  title,
  subtitle,
  actions,
  children,
  className = "",
}: {
  title?: ReactNode;
  subtitle?: ReactNode;
  actions?: ReactNode;
  children: ReactNode;
  className?: string;
}) {
  return (
    <section className={`rounded-lg border border-line bg-surface ${className}`}>
      {(title || actions) && (
        <header className="flex items-start justify-between gap-4 border-b border-line px-5 py-4">
          <div>
            {title && <h2 className="text-sm font-semibold tracking-wide text-ink uppercase">{title}</h2>}
            {subtitle && <p className="mt-1 text-sm text-muted">{subtitle}</p>}
          </div>
          {actions && <div className="flex shrink-0 items-center gap-2">{actions}</div>}
        </header>
      )}
      <div className="px-5 py-4">{children}</div>
    </section>
  );
}

export function Badge({ tone = "neutral", children }: { tone?: Tone; children: ReactNode }) {
  return (
    <span
      className={`inline-flex items-center rounded border px-2 py-0.5 text-xs font-medium tracking-wide ${TONE_BADGE[tone]}`}
    >
      {children}
    </span>
  );
}

export function Stat({
  label,
  value,
  hint,
  tone = "neutral",
}: {
  label: ReactNode;
  value: ReactNode;
  hint?: ReactNode;
  tone?: Tone;
}) {
  return (
    <div>
      <div className="text-xs tracking-wide text-faint uppercase">{label}</div>
      <div className={`numeric mt-1 text-lg ${tone === "neutral" ? "text-ink" : TONE_TEXT[tone]}`}>{value}</div>
      {hint && <div className="mt-1 text-xs text-faint">{hint}</div>}
    </div>
  );
}

export function KeyValue({ label, children, hint }: { label: ReactNode; children: ReactNode; hint?: ReactNode }) {
  return (
    <div className="grid grid-cols-1 gap-1 border-b border-line py-3 last:border-b-0 sm:grid-cols-[14rem_1fr] sm:gap-4">
      <dt className="text-sm text-muted">{label}</dt>
      <dd className="text-sm text-ink">
        {children}
        {hint && <div className="mt-1 text-xs text-faint">{hint}</div>}
      </dd>
    </div>
  );
}

export function Mono({ children, className = "" }: { children: ReactNode; className?: string }) {
  return <span className={`numeric ${className}`}>{children}</span>;
}

export function Alert({
  tone = "info",
  title,
  children,
}: {
  tone?: Tone;
  title?: ReactNode;
  children?: ReactNode;
}) {
  const border: Record<Tone, string> = {
    neutral: "border-line bg-raised",
    good: "border-good/30 bg-good/5",
    warn: "border-warn/30 bg-warn/5",
    bad: "border-bad/30 bg-bad/5",
    info: "border-info/30 bg-info/5",
    accent: "border-accent/30 bg-accent/5",
  };
  return (
    <div className={`rounded-md border px-4 py-3 text-sm ${border[tone]}`}>
      {title && <div className={`font-semibold ${TONE_TEXT[tone]}`}>{title}</div>}
      {children && <div className="mt-1 text-muted">{children}</div>}
    </div>
  );
}

/**
 * A refusal, named.
 *
 * Every rejection the dashboard shows says which rule fired — that is the
 * product's promise, and this component is where it is kept.
 */
export function FailureAlert({ error }: { error: unknown }) {
  const failure = explainFailure(error);
  return (
    <div className="rounded-md border border-bad/30 bg-bad/5 px-4 py-3 text-sm">
      <div className="font-semibold text-bad">{failure.title}</div>
      <div className="mt-1 text-ink">{failure.detail}</div>
      {failure.remedy && <div className="mt-1 text-muted">{failure.remedy}</div>}
      <div className="mt-2 text-xs text-faint">
        Rule: {failure.rule}
        {failure.errorName ? ` · ${failure.errorName}` : ""}
      </div>
    </div>
  );
}

export function Empty({ children }: { children: ReactNode }) {
  return <p className="py-6 text-center text-sm text-faint">{children}</p>;
}

export function Loading({ what }: { what: string }) {
  return (
    <p className="py-6 text-center text-sm text-faint" role="status">
      Reading {what} from the chain…
    </p>
  );
}

export function Field({
  label,
  hint,
  error,
  children,
}: {
  label: ReactNode;
  hint?: ReactNode;
  error?: string | null;
  children: ReactNode;
}) {
  return (
    <label className="block">
      <span className="text-xs font-medium tracking-wide text-muted uppercase">{label}</span>
      <div className="mt-1.5">{children}</div>
      {error ? (
        <span className="mt-1 block text-xs text-bad">{error}</span>
      ) : (
        hint && <span className="mt-1 block text-xs text-faint">{hint}</span>
      )}
    </label>
  );
}

export const inputClass =
  "numeric w-full rounded-md border border-line bg-canvas px-3 py-2 text-sm text-ink outline-none " +
  "placeholder:text-faint focus:border-accent/60 focus:ring-1 focus:ring-accent/30";

export const selectClass =
  "w-full rounded-md border border-line bg-canvas px-3 py-2 text-sm text-ink outline-none " +
  "focus:border-accent/60 focus:ring-1 focus:ring-accent/30";

export function buttonClass(variant: "primary" | "secondary" | "danger" | "ghost" = "secondary"): string {
  const base =
    "inline-flex items-center justify-center gap-2 rounded-md px-3.5 py-2 text-sm font-medium " +
    "transition-colors disabled:cursor-not-allowed disabled:opacity-40";
  const variants = {
    primary: "bg-accent text-canvas hover:bg-accent/90",
    secondary: "border border-line-strong bg-raised text-ink hover:border-accent/50",
    danger: "border border-bad/50 bg-bad/10 text-bad hover:bg-bad/20",
    ghost: "text-muted hover:text-ink",
  };
  return `${base} ${variants[variant]}`;
}
