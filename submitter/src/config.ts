/**
 * Configuration.
 *
 * Every value is read from the environment or from the deployed-addresses file
 * the rest of the repository already uses. Nothing has a default that could
 * stand in for a real value: a missing variable stops the process at startup
 * rather than producing a submitter that points at the wrong chain.
 */

import { readFileSync } from "node:fs";
import { getAddress, isAddress, isHex } from "viem";
import type { Address, Hex } from "viem";

/** One entry of `config/coston2/deployed-addresses.json`. */
interface DeployedAddress {
  name: string;
  contractName: string;
  address: string;
}

export interface Config {
  /** Chain id the submitter will only ever talk to. Coston2 is 114. */
  readonly chainId: number;
  /** HTTP RPC, used for calls and transactions. */
  readonly rpcUrl: string;
  /** Websocket RPC, used for the `PaymentSigned` subscription. */
  readonly wsUrl: string;
  /** Key that pays gas. It has no authority over any treasury. */
  readonly privateKey: Hex;

  readonly paymentController: Address;
  readonly executionVerifier: Address;

  readonly fdcHub: Address;
  readonly fdcRequestFeeConfigurations: Address;
  readonly flareSystemsManager: Address;

  /** XRPL Testnet websocket. */
  readonly xrplWsUrl: string;
  /** Base URL of the FDC verifier server that prepares attestation requests. */
  readonly fdcVerifierUrl: string;
  /** API key the verifier server requires. */
  readonly fdcVerifierApiKey: string;
  /** Base URL of the DA layer the Merkle proofs are retrieved from. */
  readonly daLayerUrl: string;

  /** File the last processed block is persisted to, so a restart replays. */
  readonly cursorFile: string;
  /** Block the contracts were deployed in. Used when no cursor exists yet. */
  readonly startBlock: bigint;
  /**
   * Blocks per `eth_getLogs` call during a replay. Coston2's public RPC caps
   * this at 30 whatever the sample configuration suggests.
   */
  readonly logChunkBlocks: bigint;

  /** How long to wait between DA layer polls, in milliseconds. */
  readonly proofPollIntervalMs: number;
  /** How long to keep polling the DA layer before giving up, in milliseconds. */
  readonly proofTimeoutMs: number;
  /**
   * Ledgers to keep polling XRPL past `LastLedgerSequence` before refusing to
   * decide. A transaction seen in an open ledger has to settle one way or the
   * other within a few closes; if it has not, concluding anything would be a
   * guess.
   */
  readonly confirmSlackLedgers: number;
}

export class ConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ConfigError";
  }
}

type Env = Record<string, string | undefined>;

function required(env: Env, name: string): string {
  const value = env[name];
  if (value === undefined || value.trim() === "") {
    throw new ConfigError(`${name} is not set`);
  }
  return value.trim();
}

function requiredUrl(env: Env, name: string, protocols: readonly string[]): string {
  const value = required(env, name);
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    throw new ConfigError(`${name} is not a URL: ${value}`);
  }
  if (!protocols.includes(parsed.protocol)) {
    throw new ConfigError(`${name} must use one of ${protocols.join(", ")} — got ${parsed.protocol}`);
  }
  return value;
}

function requiredAddress(env: Env, name: string): Address {
  const value = required(env, name);
  if (!isAddress(value)) throw new ConfigError(`${name} is not an address: ${value}`);
  return getAddress(value);
}

function requiredPrivateKey(env: Env, name: string): Hex {
  const raw = required(env, name);
  const value = raw.startsWith("0x") ? raw : `0x${raw}`;
  if (!isHex(value) || value.length !== 66) {
    throw new ConfigError(`${name} is not a 32-byte hex private key`);
  }
  return value as Hex;
}

function requiredInt(env: Env, name: string): number {
  const value = required(env, name);
  if (!/^\d+$/.test(value)) throw new ConfigError(`${name} is not a non-negative integer: ${value}`);
  return Number(value);
}

function requiredBigInt(env: Env, name: string): bigint {
  const value = required(env, name);
  if (!/^\d+$/.test(value)) throw new ConfigError(`${name} is not a non-negative integer: ${value}`);
  return BigInt(value);
}

function optionalInt(env: Env, name: string, fallback: number): number {
  const value = env[name];
  if (value === undefined || value.trim() === "") return fallback;
  if (!/^\d+$/.test(value.trim())) throw new ConfigError(`${name} is not a non-negative integer: ${value}`);
  return Number(value.trim());
}

/**
 * Looks a Flare system contract up by name in the deployed-addresses file.
 *
 * These addresses live in one file for one reason: when FCC ships and the system
 * contracts move to `FlareContractRegistry`, this function is the only thing
 * that changes.
 */
export function systemAddress(entries: readonly DeployedAddress[], name: string): Address {
  const entry = entries.find((candidate) => candidate.name === name);
  if (entry === undefined) throw new ConfigError(`${name} is not in the deployed-addresses file`);
  if (!isAddress(entry.address)) throw new ConfigError(`${name} has a malformed address: ${entry.address}`);
  return getAddress(entry.address);
}

/** Parses the deployed-addresses file, rejecting anything that is not the expected shape. */
export function parseDeployedAddresses(json: string): DeployedAddress[] {
  const parsed: unknown = JSON.parse(json);
  if (!Array.isArray(parsed)) throw new ConfigError("deployed-addresses file is not an array");

  return parsed.map((entry, index) => {
    if (typeof entry !== "object" || entry === null) {
      throw new ConfigError(`deployed-addresses entry ${index} is not an object`);
    }
    const record = entry as Record<string, unknown>;
    const { name, contractName, address } = record;
    if (typeof name !== "string" || typeof contractName !== "string" || typeof address !== "string") {
      throw new ConfigError(`deployed-addresses entry ${index} is missing name, contractName or address`);
    }
    return { name, contractName, address };
  });
}

/**
 * Builds the configuration from an environment and the deployed-addresses file.
 *
 * @param env The environment to read. Defaults to the process environment.
 * @param readFile How to read the addresses file. Injected so the parsing rules
 * can be tested without a fixture on disk.
 */
export function loadConfig(
  env: Env = process.env,
  readFile: (path: string) => string = (path) => readFileSync(path, "utf8"),
): Config {
  const addressesFile = required(env, "ADDRESSES_FILE");
  const entries = parseDeployedAddresses(readFile(addressesFile));

  return {
    chainId: requiredInt(env, "CHAIN_ID"),
    rpcUrl: requiredUrl(env, "CHAIN_URL", ["http:", "https:"]),
    wsUrl: requiredUrl(env, "CHAIN_WS_URL", ["ws:", "wss:"]),
    privateKey: requiredPrivateKey(env, "SUBMITTER_PRIVATE_KEY"),

    paymentController: requiredAddress(env, "PAYMENT_CONTROLLER"),
    executionVerifier: requiredAddress(env, "EXECUTION_VERIFIER"),

    fdcHub: systemAddress(entries, "FdcHub"),
    fdcRequestFeeConfigurations: systemAddress(entries, "FdcRequestFeeConfigurations"),
    flareSystemsManager: systemAddress(entries, "FlareSystemsManager"),

    xrplWsUrl: requiredUrl(env, "XRPL_WS_URL", ["ws:", "wss:"]),
    fdcVerifierUrl: requiredUrl(env, "FDC_VERIFIER_URL", ["http:", "https:"]),
    fdcVerifierApiKey: required(env, "FDC_VERIFIER_API_KEY"),
    daLayerUrl: requiredUrl(env, "FDC_DA_LAYER_URL", ["http:", "https:"]),

    cursorFile: required(env, "SUBMITTER_CURSOR_FILE"),
    startBlock: requiredBigInt(env, "SUBMITTER_START_BLOCK"),
    logChunkBlocks: BigInt(optionalInt(env, "SUBMITTER_LOG_CHUNK_BLOCKS", 30)),

    proofPollIntervalMs: optionalInt(env, "FDC_PROOF_POLL_INTERVAL_MS", 10_000),
    proofTimeoutMs: optionalInt(env, "FDC_PROOF_TIMEOUT_MS", 900_000),
    confirmSlackLedgers: optionalInt(env, "XRPL_CONFIRM_SLACK_LEDGERS", 4),
  };
}
