import { defineChain, type Chain } from "viem";

/**
 * The Flare networks Aegis runs on.
 *
 * The table is explicit rather than derived from a chain-id registry so that a
 * mistyped id is a configuration error instead of an unnamed network the
 * dashboard would happily connect to.
 */
type ChainProfile = {
  name: string;
  currency: { name: string; symbol: string };
};

const PROFILES: Record<number, ChainProfile> = {
  14: { name: "Flare", currency: { name: "Flare", symbol: "FLR" } },
  16: { name: "Flare Coston", currency: { name: "Coston Flare", symbol: "CFLR" } },
  114: { name: "Flare Coston2", currency: { name: "Coston2 Flare", symbol: "C2FLR" } },
};

/** Whether the dashboard knows this chain id. */
export function isSupportedChainId(chainId: number): boolean {
  return chainId in PROFILES;
}

/** Every chain id the dashboard knows, for error messages. */
export function supportedChainIds(): number[] {
  return Object.keys(PROFILES).map(Number);
}

/** Builds the viem chain for a configured id and RPC URL. */
export function buildChain(chainId: number, rpcUrl: string, explorerUrl: string): Chain {
  const profile = PROFILES[chainId];
  if (!profile) {
    throw new Error(`Chain id ${chainId} is not a Flare network Aegis supports.`);
  }
  return defineChain({
    id: chainId,
    name: profile.name,
    nativeCurrency: { decimals: 18, ...profile.currency },
    rpcUrls: { default: { http: [rpcUrl] } },
    blockExplorers: { default: { name: `${profile.name} Explorer`, url: explorerUrl } },
    contracts: {
      multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" },
    },
  });
}
