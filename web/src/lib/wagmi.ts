"use client";

import { createConfig, http, type Config } from "wagmi";
import { injected } from "wagmi/connectors/injected";

import { buildChain } from "./chains";
import { requireConfig } from "./config";

/**
 * The wagmi configuration, built from the validated environment.
 *
 * Only the injected connector is offered. WalletConnect would need a project id
 * this repository does not have, and a connector configured with a stand-in id
 * is a connector that fails at the worst moment.
 *
 * `injected` is imported from `wagmi/connectors/injected` rather than the
 * `wagmi/connectors` barrel. The barrel pulls in every connector wagmi ships,
 * including SDKs this app does not offer and whose optional dependencies do not
 * always resolve; the subpath export brings in one connector and nothing else.
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
