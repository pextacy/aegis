"use client";

import { injected } from "@wagmi/core";
import { createConfig, http, type Config } from "wagmi";

import { buildChain } from "./chains";
import { requireConfig } from "./config";

/**
 * The wagmi configuration, built from the validated environment.
 *
 * Only the injected connector is offered. WalletConnect would need a project id
 * this repository does not have, and a connector configured with a stand-in id
 * is a connector that fails at the worst moment.
 *
 * `injected` comes from @wagmi/core rather than the `wagmi/connectors` barrel:
 * that barrel drags in the Base Account SDK, whose own optional dependencies do
 * not resolve, and a bundle should not fail over a connector this app does not
 * offer.
 */
let cached: Config | undefined;

export function wagmiConfig(): Config {
  if (cached) return cached;

  const config = requireConfig();
  const chain = buildChain(config.chainId, config.rpcUrl, config.explorerUrl);

  cached = createConfig({
    chains: [chain],
    connectors: [injected()],
    transports: { [chain.id]: http(config.rpcUrl) },
    ssr: true,
  });

  return cached;
}
