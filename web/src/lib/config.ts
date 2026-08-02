import type { Address } from "viem";

import { isSupportedChainId, supportedChainIds } from "./chains";

/**
 * Runtime configuration for the dashboard.
 *
 * Every contract address is required. There is no default and no fallback: a
 * dashboard that guessed an address would show a treasury that is not yours, and
 * the person reading it would have no way to tell. An unset value is reported as
 * a configuration error and the app refuses to render chain data until it is
 * fixed.
 */
export type AegisConfig = {
  chainId: number;
  rpcUrl: string;
  explorerUrl: string;
  policyEngine: Address;
  treasuryRegistry: Address;
  paymentController: Address;
  deploymentBlock: bigint;
  xrplRpcUrl: string;
  xrplExplorerUrl: string;
  logChunkBlocks: bigint;
  logLookbackBlocks: bigint;
};

/** A configuration value that is missing or cannot be parsed. */
export type ConfigProblem = {
  variable: string;
  problem: string;
};

export type ConfigResult = { ok: true; config: AegisConfig } | { ok: false; problems: ConfigProblem[] };

// Next.js inlines process.env.NEXT_PUBLIC_* only where the full expression is
// written out literally, so these cannot be looked up through a variable key.
const RAW = {
  NEXT_PUBLIC_CHAIN_ID: process.env.NEXT_PUBLIC_CHAIN_ID,
  NEXT_PUBLIC_RPC_URL: process.env.NEXT_PUBLIC_RPC_URL,
  NEXT_PUBLIC_EXPLORER_URL: process.env.NEXT_PUBLIC_EXPLORER_URL,
  NEXT_PUBLIC_POLICY_ENGINE_ADDRESS: process.env.NEXT_PUBLIC_POLICY_ENGINE_ADDRESS,
  NEXT_PUBLIC_TREASURY_REGISTRY_ADDRESS: process.env.NEXT_PUBLIC_TREASURY_REGISTRY_ADDRESS,
  NEXT_PUBLIC_PAYMENT_CONTROLLER_ADDRESS: process.env.NEXT_PUBLIC_PAYMENT_CONTROLLER_ADDRESS,
  NEXT_PUBLIC_DEPLOYMENT_BLOCK: process.env.NEXT_PUBLIC_DEPLOYMENT_BLOCK,
  NEXT_PUBLIC_XRPL_RPC_URL: process.env.NEXT_PUBLIC_XRPL_RPC_URL,
  NEXT_PUBLIC_XRPL_EXPLORER_URL: process.env.NEXT_PUBLIC_XRPL_EXPLORER_URL,
  NEXT_PUBLIC_LOG_CHUNK_BLOCKS: process.env.NEXT_PUBLIC_LOG_CHUNK_BLOCKS,
  NEXT_PUBLIC_LOG_LOOKBACK_BLOCKS: process.env.NEXT_PUBLIC_LOG_LOOKBACK_BLOCKS,
} as const;

const ADDRESS_PATTERN = /^0x[0-9a-fA-F]{40}$/;

function readAddress(variable: keyof typeof RAW, problems: ConfigProblem[]): Address {
  const value = RAW[variable]?.trim();
  if (!value) {
    problems.push({ variable, problem: "not set" });
    return "0x" as Address;
  }
  if (!ADDRESS_PATTERN.test(value)) {
    problems.push({ variable, problem: `not a 20-byte address: ${value}` });
    return "0x" as Address;
  }
  return value as Address;
}

function readUrl(variable: keyof typeof RAW, problems: ConfigProblem[]): string {
  const value = RAW[variable]?.trim();
  if (!value) {
    problems.push({ variable, problem: "not set" });
    return "";
  }
  try {
    new URL(value);
  } catch {
    problems.push({ variable, problem: `not a URL: ${value}` });
    return "";
  }
  return value.replace(/\/$/, "");
}

function readBigInt(variable: keyof typeof RAW, problems: ConfigProblem[], minimum: bigint): bigint {
  const value = RAW[variable]?.trim();
  if (!value) {
    problems.push({ variable, problem: "not set" });
    return minimum;
  }
  let parsed: bigint;
  try {
    parsed = BigInt(value);
  } catch {
    problems.push({ variable, problem: `not an integer: ${value}` });
    return minimum;
  }
  if (parsed < minimum) {
    problems.push({ variable, problem: `must be at least ${minimum}, got ${parsed}` });
    return minimum;
  }
  return parsed;
}

function readChainId(problems: ConfigProblem[]): number {
  const value = RAW.NEXT_PUBLIC_CHAIN_ID?.trim();
  if (!value) {
    problems.push({ variable: "NEXT_PUBLIC_CHAIN_ID", problem: "not set" });
    return 0;
  }
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    problems.push({ variable: "NEXT_PUBLIC_CHAIN_ID", problem: `not a chain id: ${value}` });
    return 0;
  }
  if (!isSupportedChainId(parsed)) {
    problems.push({
      variable: "NEXT_PUBLIC_CHAIN_ID",
      problem: `${parsed} is not a Flare network Aegis supports (${supportedChainIds().join(", ")})`,
    });
    return 0;
  }
  return parsed;
}

let cached: ConfigResult | undefined;

/** Reads and validates the environment, reporting every problem at once. */
export function readConfig(): ConfigResult {
  if (cached) return cached;

  const problems: ConfigProblem[] = [];
  const config: AegisConfig = {
    chainId: readChainId(problems),
    rpcUrl: readUrl("NEXT_PUBLIC_RPC_URL", problems),
    explorerUrl: readUrl("NEXT_PUBLIC_EXPLORER_URL", problems),
    policyEngine: readAddress("NEXT_PUBLIC_POLICY_ENGINE_ADDRESS", problems),
    treasuryRegistry: readAddress("NEXT_PUBLIC_TREASURY_REGISTRY_ADDRESS", problems),
    paymentController: readAddress("NEXT_PUBLIC_PAYMENT_CONTROLLER_ADDRESS", problems),
    deploymentBlock: readBigInt("NEXT_PUBLIC_DEPLOYMENT_BLOCK", problems, 0n),
    xrplRpcUrl: readUrl("NEXT_PUBLIC_XRPL_RPC_URL", problems),
    xrplExplorerUrl: readUrl("NEXT_PUBLIC_XRPL_EXPLORER_URL", problems),
    logChunkBlocks: readBigInt("NEXT_PUBLIC_LOG_CHUNK_BLOCKS", problems, 1n),
    logLookbackBlocks: readBigInt("NEXT_PUBLIC_LOG_LOOKBACK_BLOCKS", problems, 1n),
  };

  cached = problems.length > 0 ? { ok: false, problems } : { ok: true, config };
  return cached;
}

/**
 * The validated configuration.
 *
 * @throws if the environment is incomplete. Call {@link readConfig} where the
 * caller intends to render the problem rather than propagate it.
 */
export function requireConfig(): AegisConfig {
  const result = readConfig();
  if (!result.ok) {
    const detail = result.problems.map((p) => `${p.variable}: ${p.problem}`).join("; ");
    throw new Error(`Aegis dashboard is not configured — ${detail}`);
  }
  return result.config;
}

/** Link to a transaction on the Flare block explorer. */
export function explorerTxUrl(config: AegisConfig, hash: string): string {
  return `${config.explorerUrl}/tx/${hash}`;
}

/** Link to an address on the Flare block explorer. */
export function explorerAddressUrl(config: AegisConfig, address: string): string {
  return `${config.explorerUrl}/address/${address}`;
}

/** Link to a transaction on the XRPL explorer. */
export function xrplTxUrl(config: AegisConfig, hash: string): string {
  return `${config.xrplExplorerUrl}/transactions/${hash}`;
}

/** Link to an account on the XRPL explorer. */
export function xrplAccountUrl(config: AegisConfig, address: string): string {
  return `${config.xrplExplorerUrl}/accounts/${address}`;
}
