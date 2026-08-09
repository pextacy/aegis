import type { ReactNode } from "react";

import { explainFailure } from "@/lib/errors";

/**
 * The dashboard's shared surfaces, in the Lumina Prime design system.
 *
 * White cards on a soft wash, one azure accent for anything interactive, navy
 * for the panels that carry a verdict. Status is always a tinted chip with
 * same-hue text, never colour alone — an approver checking a payment against a
 * policy should be able to read every state as words.
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

const TONE_CHIP: Record<Tone, string> = {
  neutral: "bg-sunken text-muted",
  good: "bg-good-dim text-good",
  warn: "bg-warn-dim text-warn",
  bad: "bg-bad-dim text-bad",
  info: "bg-info-dim text-info",
  accent: "bg-accent-dim text-accent",
};

const TONE_ALERT: Record<Tone, string> = {
  neutral: "border-line bg-raised",
  good: "border-good/25 bg-good-dim/50",
  warn: "border-warn/25 bg-warn-dim/50",
  bad: "border-bad/25 bg-bad-dim/40",
  info: "border-accent/25 bg-accent-dim/60",
  accent: "border-accent/25 bg-accent-dim/60",
};

export function Card({
  title,
  subtitle,
  actions,
  children,
  className = "",
  bodyClassName = "",
}: {
  title?: ReactNode;
  subtitle?: ReactNode;
  actions?: ReactNode;
  children: ReactNode;
  className?: string;
  bodyClassName?: string;
}) {
  return (
    <section className={`rounded-lg border border-line bg-surface ${className}`}>
      {(title || actions) && (
        <header className="flex flex-wrap items-start justify-between gap-4 border-b border-line px-6 py-4">
          <div>
            {title && <h2 className="text-lg font-semibold tracking-tight text-ink">{title}</h2>}
            {subtitle && <p className="mt-1 max-w-2xl text-sm text-muted">{subtitle}</p>}
          </div>
          {actions && <div className="flex shrink-0 items-center gap-2">{actions}</div>}
        </header>
      )}
      <div className={bodyClassName || "px-6 py-5"}>{children}</div>
    </section>
  );
}

/** The navy panel the design reserves for a verdict, not for data. */
export function DarkPanel({
  title,
  icon,
  children,
  className = "",
}: {
  title?: ReactNode;
  icon?: ReactNode;
  children: ReactNode;
  className?: string;
}) {
  return (
    <section className={`rounded-lg bg-navy p-6 text-white ${className}`}>
      {title && (
        <div className="label-caps flex items-center gap-2 text-white/70">
          {icon}
          {title}
        </div>
      )}
      <div className={title ? "mt-4" : ""}>{children}</div>
    </section>
  );
}

export function Badge({ tone = "neutral", dot = false, children }: { tone?: Tone; dot?: boolean; children: ReactNode }) {
  return (
    <span
      className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-semibold ${TONE_CHIP[tone]}`}
    >
      {dot && <span className="size-1.5 rounded-full bg-current" />}
      {children}
    </span>
  );
}

export function PageHeader({
  title,
  description,
  actions,
  breadcrumb,
}: {
  title: ReactNode;
  description?: ReactNode;
  actions?: ReactNode;
  breadcrumb?: ReactNode;
}) {
  return (
    <header className="flex flex-wrap items-end justify-between gap-4">
      <div className="min-w-0">
        {breadcrumb && <div className="mb-1.5">{breadcrumb}</div>}
        <h1 className="text-3xl font-semibold tracking-tight text-ink">{title}</h1>
        {description && <p className="mt-2 max-w-2xl text-sm text-muted">{description}</p>}
      </div>
      {actions && <div className="flex shrink-0 flex-wrap items-center gap-3">{actions}</div>}
    </header>
  );
}

export function Breadcrumb({ items }: { items: { label: string; href?: string }[] }) {
  return (
    <nav className="label-caps flex flex-wrap items-center gap-2 text-faint">
      {items.map((item, index) => (
        <span key={`${item.label}-${index}`} className="flex items-center gap-2">
          {index > 0 && <span className="text-line-strong">›</span>}
          {item.href ? (
            <a href={item.href} className="hover:text-accent">
              {item.label}
            </a>
          ) : (
            <span className={index === items.length - 1 ? "text-ink" : undefined}>{item.label}</span>
          )}
        </span>
      ))}
    </nav>
  );
}

/** A figure in its own bordered card — the row across the top of a list page. */
export function StatCard({
  label,
  value,
  hint,
  icon,
  tone = "neutral",
}: {
  label: ReactNode;
  value: ReactNode;
  hint?: ReactNode;
  icon?: ReactNode;
  tone?: Tone;
}) {
  return (
    <div className="rounded-lg border border-line bg-surface px-5 py-4">
      <div className="flex items-start justify-between gap-3">
        <div className="label-caps text-faint">{label}</div>
        {icon && <span className="text-accent">{icon}</span>}
      </div>
      <div className={`numeric mt-2 text-2xl font-medium ${tone === "neutral" ? "text-ink" : TONE_TEXT[tone]}`}>
        {value}
      </div>
      {hint && <div className="mt-1 text-sm text-muted">{hint}</div>}
    </div>
  );
}

/** A figure inside a card, on the sunken inset the design uses for account facts. */
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
    <div className="rounded-lg bg-raised px-4 py-3">
      <div className="label-caps text-faint">{label}</div>
      <div className={`numeric mt-1.5 text-xl ${tone === "neutral" ? "text-ink" : TONE_TEXT[tone]}`}>{value}</div>
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
  return (
    <div className={`rounded-lg border px-4 py-3 text-sm ${TONE_ALERT[tone]}`}>
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
    <div className="rounded-lg border border-bad/25 bg-bad-dim/40 px-4 py-3 text-sm">
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
  return <p className="py-8 text-center text-sm text-faint">{children}</p>;
}

export function Loading({ what }: { what: string }) {
  return (
    <p className="py-8 text-center text-sm text-faint" role="status">
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
      <span className="text-sm font-medium text-ink">{label}</span>
      <div className="mt-1.5">{children}</div>
      {error ? (
        <span className="mt-1.5 block text-xs text-bad">{error}</span>
      ) : (
        hint && <span className="mt-1.5 block text-xs text-faint">{hint}</span>
      )}
    </label>
  );
}

/** A rule and whether it currently holds — the Policy Check rail. */
export function CheckRow({
  state,
  title,
  children,
}: {
  state: "pass" | "fail" | "pending";
  title: ReactNode;
  children?: ReactNode;
}) {
  const colour =
    state === "pass" ? "text-good" : state === "fail" ? "text-bad" : "text-faint";
  const mark = state === "pass" ? "✓" : state === "fail" ? "✕" : "…";
  return (
    <div className="flex gap-3 rounded-lg border border-line bg-surface px-4 py-3">
      <span className={`numeric mt-0.5 text-sm font-semibold ${colour}`} aria-hidden="true">
        {mark}
      </span>
      <div className="min-w-0">
        <div className="text-sm font-semibold text-ink">{title}</div>
        {children && <div className="mt-0.5 text-sm text-muted">{children}</div>}
      </div>
    </div>
  );
}

export const inputClass =
  "numeric w-full rounded-lg border border-line bg-raised px-3.5 py-2.5 text-sm text-ink outline-none " +
  "placeholder:text-faint focus:border-accent focus:bg-surface";

export const checkboxClass = "mt-0.5 size-4 shrink-0 accent-accent";

export const selectClass =
  "w-full rounded-lg border border-line bg-raised px-3.5 py-2.5 text-sm text-ink outline-none " +
  "focus:border-accent focus:bg-surface";

export function buttonClass(variant: "primary" | "secondary" | "danger" | "ghost" | "navy" = "secondary"): string {
  const base =
    "inline-flex items-center justify-center gap-2 rounded-lg px-4 py-2.5 text-sm font-semibold " +
    "transition-colors disabled:cursor-not-allowed disabled:opacity-40";
  const variants = {
    primary: "bg-accent text-white hover:bg-accent-strong",
    secondary: "border border-navy bg-surface text-navy hover:bg-raised",
    navy: "bg-navy text-white hover:bg-navy-soft",
    danger: "border border-bad bg-surface text-bad hover:bg-bad-dim/50",
    ghost: "text-muted hover:text-accent",
  };
  return `${base} ${variants[variant]}`;
}

/** Table parts. Figures always land in a monospace cell. */
export const tableClass = "w-full min-w-[44rem] border-collapse text-left";
export const theadClass = "label-caps border-y border-line bg-raised text-faint";
export const thClass = "px-6 py-3 font-semibold";
export const trClass = "border-b border-line last:border-b-0 hover:bg-raised/60";
export const tdClass = "px-6 py-4 align-middle text-sm text-ink";
