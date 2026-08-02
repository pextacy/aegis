/**
 * Chain clients.
 *
 * The chain is described from configuration rather than imported from viem's
 * chain list, so pointing the submitter at a different Flare network is a
 * configuration change and never a code change.
 */

import { createPublicClient, createWalletClient, defineChain, http, webSocket } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import type { Chain, PublicClient, WalletClient } from "viem";
import type { Config } from "./config.js";

export function chainFrom(config: Config): Chain {
  return defineChain({
    id: config.chainId,
    name: `flare-${config.chainId}`,
    nativeCurrency: { name: "Coston2 Flare", symbol: "C2FLR", decimals: 18 },
    rpcUrls: { default: { http: [config.rpcUrl], webSocket: [config.wsUrl] } },
  });
}

export interface Clients {
  readonly chain: Chain;
  /** Calls and receipts, over HTTP. */
  readonly publicClient: PublicClient;
  /** The `PaymentSigned` subscription, over websocket. */
  readonly wsClient: PublicClient;
  /** Sends the attestation request and the confirmation, paying gas only. */
  readonly walletClient: WalletClient;
}

export function createClients(config: Config): Clients {
  const chain = chainFrom(config);
  const account = privateKeyToAccount(config.privateKey);

  return {
    chain,
    publicClient: createPublicClient({ chain, transport: http(config.rpcUrl) }),
    wsClient: createPublicClient({ chain, transport: webSocket(config.wsUrl) }),
    walletClient: createWalletClient({ chain, account, transport: http(config.rpcUrl) }),
  };
}
