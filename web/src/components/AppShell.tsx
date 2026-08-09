"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import type { ReactNode } from "react";
import { useAccount } from "wagmi";

import { ConnectButton } from "@/components/ConnectButton";
import { IconAudit, IconPolicy, IconTreasury, IconWallet } from "@/components/icons";
import { requireConfig } from "@/lib/config";
import { shortHex } from "@/lib/format";

const NAV = [
  { href: "/", label: "Treasuries", Icon: IconTreasury },
  { href: "/policies", label: "Policies", Icon: IconPolicy },
  { href: "/audit", label: "Audit log", Icon: IconAudit },
];

/** A nav item is current when the page belongs to its section, not only when the path matches. */
function isCurrent(pathname: string, href: string): boolean {
  if (href === "/") return pathname === "/" || pathname.startsWith("/treasuries") || pathname.startsWith("/requests");
  return pathname === href || pathname.startsWith(`${href}/`);
}

export function AppShell({ children }: { children: ReactNode }) {
  const config = requireConfig();
  const pathname = usePathname();
  const { address } = useAccount();

  return (
    <div className="min-h-screen lg:flex">
      <aside className="hidden w-64 shrink-0 flex-col justify-between border-r border-line bg-surface lg:flex lg:h-screen lg:sticky lg:top-0">
        <div>
          <Link href="/" className="block px-6 py-7">
            <div className="text-2xl font-bold tracking-tight text-ink">AEGIS</div>
            <div className="label-caps mt-1 text-faint">Rule-governed treasury</div>
          </Link>

          <nav className="space-y-1 px-3">
            {NAV.map(({ href, label, Icon }) => {
              const current = isCurrent(pathname, href);
              return (
                <Link
                  key={href}
                  href={href}
                  aria-current={current ? "page" : undefined}
                  className={`flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-semibold transition-colors ${
                    current ? "bg-accent text-white" : "text-muted hover:bg-raised hover:text-ink"
                  }`}
                >
                  <Icon className="size-5 shrink-0" />
                  {label}
                </Link>
              );
            })}
          </nav>
        </div>

        <div className="border-t border-line p-4">
          <div className="flex items-center gap-3 rounded-lg bg-raised px-3 py-3">
            <span className="flex size-9 shrink-0 items-center justify-center rounded-lg bg-navy text-white">
              <IconWallet className="size-5" />
            </span>
            <div className="min-w-0">
              <div className="truncate text-sm font-semibold text-ink">
                {address ? <span className="numeric">{shortHex(address, 6, 4)}</span> : "No wallet"}
              </div>
              <div className="label-caps truncate text-faint">
                {address ? `Chain ${config.chainId}` : "Not connected"}
              </div>
            </div>
          </div>
        </div>
      </aside>

      <div className="min-w-0 flex-1">
        <header className="sticky top-0 z-10 border-b border-line bg-canvas/85 backdrop-blur">
          <div className="flex flex-wrap items-center gap-x-6 gap-y-3 px-6 py-3">
            <Link href="/" className="text-lg font-bold tracking-tight text-ink lg:hidden">
              AEGIS
            </Link>

            <nav className="flex items-center gap-1 lg:hidden">
              {NAV.map(({ href, label }) => {
                const current = isCurrent(pathname, href);
                return (
                  <Link
                    key={href}
                    href={href}
                    aria-current={current ? "page" : undefined}
                    className={`rounded-lg px-2.5 py-1.5 text-sm font-medium ${
                      current ? "bg-accent-dim text-accent" : "text-muted hover:text-ink"
                    }`}
                  >
                    {label}
                  </Link>
                );
              })}
            </nav>

            <div className="ml-auto flex items-center gap-3">
              <span className="numeric hidden text-xs text-faint xl:inline">
                chain {config.chainId} · controller {shortHex(config.paymentController, 6, 4)}
              </span>
              <ConnectButton />
            </div>
          </div>
        </header>

        <main className="mx-auto max-w-[1280px] px-6 py-8">{children}</main>

        <footer className="mx-auto max-w-[1280px] border-t border-line px-6 py-6 text-xs text-faint">
          Every figure on this screen is read from Flare {config.chainId} and XRPL directly. Aegis runs no service
          between you and the chain, so this page can be reproduced from chain data alone.
        </footer>
      </div>
    </div>
  );
}
