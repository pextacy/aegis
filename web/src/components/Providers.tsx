"use client";

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useState, type ReactNode } from "react";
import { WagmiProvider } from "wagmi";

import { readConfig } from "@/lib/config";
import { wagmiConfig } from "@/lib/wagmi";

/**
 * Chain access for the whole app.
 *
 * If the environment is incomplete the app renders the problem instead of the
 * dashboard. A half-configured treasury console is worse than none: it would
 * show empty lists that look like "no payments" rather than "not connected to
 * anything".
 */
export function Providers({ children }: { children: ReactNode }) {
  const [queryClient] = useState(
    () =>
      new QueryClient({
        defaultOptions: {
          queries: {
            // Chain state is cheap to re-read and expensive to be wrong about.
            staleTime: 4_000,
            retry: 1,
            refetchOnWindowFocus: true,
          },
        },
      }),
  );

  const result = readConfig();
  if (!result.ok) {
    return <ConfigurationProblems problems={result.problems} />;
  }

  return (
    <WagmiProvider config={wagmiConfig()}>
      <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
    </WagmiProvider>
  );
}

function ConfigurationProblems({ problems }: { problems: { variable: string; problem: string }[] }) {
  return (
    <main className="mx-auto max-w-2xl px-6 py-16">
      <h1 className="text-lg font-semibold text-ink">The dashboard is not configured</h1>
      <p className="mt-2 text-sm text-muted">
        Aegis reads its contract addresses from the environment and has no defaults for them. Copy{" "}
        <code className="numeric text-accent">web/.env.example</code> to{" "}
        <code className="numeric text-accent">web/.env.local</code> and fill in your deployment, or run{" "}
        <code className="numeric text-accent">./scripts/sync-web-env.sh</code> to write it from the deployment record.
      </p>
      <ul className="mt-6 space-y-2">
        {problems.map((problem) => (
          <li key={problem.variable} className="rounded-md border border-bad/30 bg-bad/5 px-4 py-3 text-sm">
            <span className="numeric text-bad">{problem.variable}</span>
            <span className="text-muted"> — {problem.problem}</span>
          </li>
        ))}
      </ul>
    </main>
  );
}
