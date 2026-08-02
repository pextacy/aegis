"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import type { ReactNode } from "react";

import { ConnectButton } from "@/components/ConnectButton";
import { requireConfig } from "@/lib/config";
import { shortHex } from "@/lib/format";

const NAV = [
  { href: "/", label: "Treasuries" },
  { href: "/policies", label: "Policies" },
  { href: "/audit", label: "Audit log" },
];

export function AppShell({ children }: { children: ReactNode }) {
  const config = requireConfig();
  const pathname = usePathname();

  return (
    <div className="min-h-screen">
      <header className="border-b border-line bg-surface/60 backdrop-blur">
        <div className="mx-auto flex max-w-6xl flex-wrap items-center gap-x-6 gap-y-3 px-6 py-3">
          <Link href="/" className="flex items-baseline gap-2">
            <span className="text-base font-semibold tracking-[0.2em] text-accent">AEGIS</span>
            <span className="hidden text-xs text-faint sm:inline">rule-governed XRPL treasury</span>
          </Link>

          <nav className="flex items-center gap-1">
            {NAV.map((item) => {
              const active = item.href === "/" ? pathname === "/" : pathname.startsWith(item.href);
              return (
                <Link
                  key={item.href}
                  href={item.href}
                  className={`rounded px-2.5 py-1.5 text-sm transition-colors ${
                    active ? "bg-raised text-ink" : "text-muted hover:text-ink"
                  }`}
                >
                  {item.label}
                </Link>
              );
            })}
          </nav>

          <div className="ml-auto flex items-center gap-3">
            <span className="numeric hidden text-xs text-faint lg:inline">
              chain {config.chainId} · controller {shortHex(config.paymentController, 6, 4)}
            </span>
            <ConnectButton />
          </div>
        </div>
      </header>

      <main className="mx-auto max-w-6xl px-6 py-8">{children}</main>

      <footer className="mx-auto max-w-6xl px-6 pt-4 pb-10 text-xs text-faint">
        Every figure on this screen is read from Flare {config.chainId} and XRPL directly. Aegis runs no service between
        you and the chain, so this page can be reproduced from chain data alone.
      </footer>
    </div>
  );
}
