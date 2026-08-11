import { decodeEventLog, hexToString, type Address, type Hex, type Log, type PublicClient } from "viem";

import {
  aegisInstructionSenderAbi,
  executionVerifierAbi,
  paymentControllerAbi,
  policyEngineAbi,
  treasuryRegistryAbi,
} from "./abi";
import type { AegisConfig } from "./config";
import { formatDrops, formatUsd, formatXrp, shortHex } from "./format";
import { describeRoles } from "./roles";
import { bytes32ToClassicAddress } from "./xrpl-address";

/**
 * The audit log, read from event logs.
 *
 * Nothing is stored off-chain, so the history is whatever the chain emitted. The
 * public Coston2 RPC refuses an `eth_getLogs` range wider than 30 blocks, which
 * is why this scans in chunks and reports the block it reached rather than
 * pretending the result is the whole history. Point the app at an archive node
 * and raise NEXT_PUBLIC_LOG_CHUNK_BLOCKS to pull everything in one call.
 */

export type AegisContract =
  | "PolicyEngine"
  | "TreasuryRegistry"
  | "PaymentController"
  | "AegisInstructionSender"
  | "ExecutionVerifier";

export type AuditEntry = {
  blockNumber: bigint;
  logIndex: number;
  txHash: Hex;
  contract: AegisContract;
  eventName: string;
  /** One sentence, in the vocabulary the docs use. */
  summary: string;
  policyId?: bigint;
  treasuryId?: bigint;
  requestId?: bigint;
  amendmentId?: bigint;
  /** The XRPL transaction id, on the event that produced a signature. */
  xrplTxHash?: Hex;
};

export type AuditScan = {
  entries: AuditEntry[];
  /** The lowest block scanned. */
  fromBlock: bigint;
  /** The highest block scanned. */
  toBlock: bigint;
  /** True when the scan reached the deployment block, so nothing is missing. */
  complete: boolean;
};

/** How many chunk requests are in flight at once. */
const CONCURRENCY = 8;

function isZero(address: Address): boolean {
  return /^0x0{40}$/i.test(address);
}

function argsOf(decoded: { args?: unknown }): Record<string, unknown> {
  return (decoded.args as Record<string, unknown> | undefined) ?? {};
}

function asBigInt(value: unknown): bigint | undefined {
  if (typeof value === "bigint") return value;
  if (typeof value === "number") return BigInt(value);
  return undefined;
}

function destination(word: unknown, tag: unknown): string {
  if (typeof word !== "string") return "an unreadable destination";
  let address: string;
  try {
    address = bytes32ToClassicAddress(word as Hex) ?? shortHex(word);
  } catch {
    address = shortHex(word);
  }
  const tagValue = asBigInt(tag) ?? 0n;
  return tagValue === 0n ? address : `${address} (tag ${tagValue})`;
}

function reasonText(value: unknown): string {
  if (typeof value !== "string") return "no reason given";
  const text = hexToString(value as Hex, { size: 32 }).replace(/\0+$/, "");
  return text === "" ? "no reason given" : text;
}

function describe(contract: AegisContract, eventName: string, args: Record<string, unknown>): string {
  switch (`${contract}.${eventName}`) {
    case "PolicyEngine.PolicyCreated":
      return `Policy ${args.policyId} created with ${args.tierCount} tier(s) by ${shortHex(String(args.creator))}.`;
    case "PolicyEngine.RolesSet":
      return `${shortHex(String(args.account))} now holds ${describeRoles(Number(args.roleMask ?? 0))} on policy ${
        args.policyId
      }.`;
    case "PolicyEngine.AllowlistSet":
      return `${args.allowed ? "Allowed" : "Removed"} ${destination(
        args.accountId,
        args.destinationTag,
      )} on policy ${args.policyId}.`;

    case "TreasuryRegistry.TreasuryCreated":
      return `Treasury ${args.treasuryId} created under policy ${args.policyId} by ${shortHex(String(args.creator))}.`;
    case "TreasuryRegistry.XrplAccountBound":
      return `Treasury ${args.treasuryId} bound to XRPL account ${args.xrplAddress}, derived on-chain from the key the enclave generated.`;
    case "TreasuryRegistry.TreasuryFrozen":
      return `Guardian ${shortHex(String(args.guardian))} froze treasury ${args.treasuryId}.`;
    case "TreasuryRegistry.TreasuryUnfrozen":
      return `Treasury ${args.treasuryId} unfrozen by amendment ${args.amendmentId}.`;
    case "TreasuryRegistry.PolicyChanged":
      return `Treasury ${args.treasuryId} repointed from policy ${args.oldPolicyId} to policy ${args.newPolicyId}.`;
    case "TreasuryRegistry.AmendmentProposed":
      return `Amendment ${args.amendmentId} proposed for treasury ${args.treasuryId}.`;
    case "TreasuryRegistry.AmendmentApproved":
      return `${shortHex(String(args.approver))} approved amendment ${args.amendmentId} (${args.approvals} so far).`;
    case "TreasuryRegistry.AmendmentExecuted":
      return `Amendment ${args.amendmentId} executed.`;
    case "TreasuryRegistry.SequenceAdvanced":
      return `Treasury ${args.treasuryId} now expects XRPL sequence ${args.nextSequence}.`;
    case "TreasuryRegistry.SignerSetConfigured":
      return `Treasury ${args.treasuryId} committed to ${args.quorum}-of-${args.signerCount} signing.`;
    case "TreasuryRegistry.SignerKeyBound":
      return `Enclave signer ${args.signerAddress} bound to treasury ${args.treasuryId} (${args.bound} so far).`;
    case "TreasuryRegistry.SignerSetReady":
      return `Treasury ${args.treasuryId} collected all ${args.signerCount} signer keys; quorum is ${args.quorum}.`;
    case "TreasuryRegistry.SignerListInstalled":
      return `Treasury ${args.treasuryId} handed its XRPL account to its signer set, in transaction ${shortHex(
        String(args.xrplTxHash),
      )} at sequence ${args.sequence}.`;
    case "TreasuryRegistry.MasterKeyRetired":
      return `Treasury ${args.treasuryId} retired its master key in transaction ${shortHex(
        String(args.xrplTxHash),
      )} at sequence ${args.sequence}. The quorum is now the only authority over the account.`;

    case "PaymentController.PaymentProposed":
      return `Request ${args.requestId}: ${formatXrp(asBigInt(args.amountDrops) ?? 0n)} XRP to ${destination(
        args.destinationAccountId,
        args.destinationTag,
      )}, worth $${formatUsd(asBigInt(args.amountUsd) ?? 0n)}, needing ${args.requiredApprovals} approval(s).`;
    case "PaymentController.PaymentApproved":
      return `${shortHex(String(args.approver))} approved request ${args.requestId} (${args.approvals} of ${
        args.required
      }).`;
    case "PaymentController.PaymentApprovalRevoked":
      return `${shortHex(String(args.approver))} withdrew their approval of request ${args.requestId} (${
        args.approvals
      } of ${args.required} remaining).`;
    case "PaymentController.PaymentReady":
      return `Request ${args.requestId} reached its approval threshold.`;
    case "PaymentController.PaymentDispatched":
      return `Request ${args.requestId} dispatched to the TEE at sequence ${args.sequence}, valid over ledgers ${
        args.firstLedgerSequence
      }–${args.lastLedgerSequence}, fee ${formatDrops(asBigInt(args.feeDrops) ?? 0n)} drops.`;
    case "PaymentController.PaymentSigned":
      return `The enclave returned a signed transaction for request ${args.requestId}.`;
    case "PaymentController.PaymentPartiallySigned":
      return `An enclave contributed its share of request ${args.requestId}'s signature (${args.collected} collected).`;
    case "PaymentController.PaymentMultiSigned":
      return `Request ${args.requestId} reached its quorum: ${args.collected} of ${args.quorum} enclaves signed.`;
    case "PaymentController.PartialSignatureIgnored":
      return `A late share for request ${args.requestId} arrived after its quorum closed and was ignored.`;
    case "PaymentController.PaymentSettled":
      return `Request ${args.requestId} settled on XRPL at sequence ${args.sequence}, confirmed by an FDC proof.`;
    case "PaymentController.PaymentFailed":
      return `Request ${args.requestId} failed: ${reasonText(args.reason)}.`;
    case "PaymentController.PaymentCancelled":
      return `Request ${args.requestId} cancelled by its proposer.`;
    case "PaymentController.WindowSpendReleased":
      return `$${formatUsd(
        asBigInt(args.amountUsd) ?? 0n,
      )} returned to treasury ${args.treasuryId}'s rolling window from request ${args.requestId}.`;

    case "AegisInstructionSender.SignerKeygenRequested":
      return `Asked ${args.machines} enclaves for their signer keys for treasury ${args.treasuryId}.`;
    case "AegisInstructionSender.SignerKeygenResultSubmitted":
      return `An enclave returned signer key ${args.signerAddress} for treasury ${args.treasuryId}.`;
    case "AegisInstructionSender.MultiSignatureRequested":
      return `Request ${args.requestId} sent to ${args.machines} enclaves for a quorum signature.`;
    case "AegisInstructionSender.PartialSignatureResultSubmitted":
      return `Share ${args.answered} relayed for request ${args.requestId}.`;
    case "AegisInstructionSender.SetupRequested":
      return `Asked the TEE to sign ${
        Number(args.kind) === 0 ? "treasury " + args.treasuryId + "'s signer list" : "the retirement of treasury " + args.treasuryId + "'s master key"
      }.`;
    case "AegisInstructionSender.SetupTransactionSigned":
      return `The enclave signed ${
        Number(args.kind) === 0 ? "the signer list" : "the master key retirement"
      } for treasury ${args.treasuryId}, XRPL transaction ${shortHex(String(args.txHash))}.`;

    case "AegisInstructionSender.KeygenRequested":
      return `Asked the TEE to generate a key for treasury ${args.treasuryId} (instruction ${shortHex(
        String(args.instructionId),
      )}).`;
    case "AegisInstructionSender.SignatureRequested":
      return `Asked the TEE to sign request ${args.requestId} for treasury ${args.treasuryId} (instruction ${shortHex(
        String(args.instructionId),
      )}).`;
    case "AegisInstructionSender.StatusRequested":
      return `Asked the TEE whether treasury ${args.treasuryId} holds a key.`;
    case "AegisInstructionSender.KeygenResultSubmitted":
      return `The enclave returned XRPL account ${args.classicAddress} for treasury ${args.treasuryId}.`;
    case "AegisInstructionSender.SignatureResultSubmitted":
      return `The enclave returned a signature for request ${args.requestId}.`;

    case "ExecutionVerifier.SettlementConfirmed":
      return `An FDC proof confirmed request ${args.requestId} settled on XRPL at sequence ${args.sequence}.`;
    case "ExecutionVerifier.ExecutionFailed":
      return `An FDC proof showed request ${args.requestId} reached a ledger and failed there with status ${args.status}. The sequence was consumed, so it advances.`;
    case "ExecutionVerifier.NonExecutionConfirmed":
      return `An FDC proof showed request ${args.requestId} never appeared between ledgers ${args.minimalBlockNumber} and ${args.deadlineBlockNumber}. The sequence was not consumed, so it does not advance.`;
    case "ExecutionVerifier.ProofAlreadyConsumed":
      return `A proof arrived for request ${args.requestId}, which had already reached a terminal state. Two submitters racing is expected.`;

    case "PolicyEngine.ContractWired":
    case "TreasuryRegistry.ContractWired":
    case "PaymentController.ContractWired":
    case "AegisInstructionSender.ContractWired":
      return `Wired ${reasonText(args.what)} to ${shortHex(String(args.addr))}.`;

    default:
      return `${eventName}(${Object.entries(args)
        .map(([key, value]) => `${key}=${String(value)}`)
        .join(", ")})`;
  }
}

function toEntry(contract: AegisContract, log: Log, abi: readonly unknown[]): AuditEntry | null {
  let decoded: { eventName: string; args?: unknown };
  try {
    decoded = decodeEventLog({
      abi: abi as never,
      data: log.data,
      topics: log.topics,
    }) as { eventName: string; args?: unknown };
  } catch {
    // A log this ABI cannot decode is not ours to interpret. Dropping it is
    // correct: the alternative is inventing a description for bytes we did not
    // emit.
    return null;
  }

  const args = argsOf(decoded);
  if (log.blockNumber === null || log.logIndex === null || log.transactionHash === null) return null;

  return {
    blockNumber: log.blockNumber,
    logIndex: log.logIndex,
    txHash: log.transactionHash,
    contract,
    eventName: decoded.eventName,
    summary: describe(contract, decoded.eventName, args),
    policyId: asBigInt(args.policyId),
    treasuryId: asBigInt(args.treasuryId),
    requestId: asBigInt(args.requestId),
    amendmentId: asBigInt(args.amendmentId),
    xrplTxHash: typeof args.txHash === "string" ? (args.txHash as Hex) : undefined,
  };
}

type Ranges = { from: bigint; to: bigint }[];

function planRanges(from: bigint, to: bigint, chunk: bigint): Ranges {
  const ranges: Ranges = [];
  for (let start = from; start <= to; start += chunk) {
    const end = start + chunk - 1n > to ? to : start + chunk - 1n;
    ranges.push({ from: start, to: end });
  }
  return ranges;
}

async function mapWithConcurrency<T, R>(items: T[], limit: number, worker: (item: T) => Promise<R>): Promise<R[]> {
  const results = new Array<R>(items.length);
  let cursor = 0;

  async function run(): Promise<void> {
    for (;;) {
      const index = cursor;
      cursor += 1;
      const item = items[index];
      if (item === undefined) return;
      results[index] = await worker(item);
    }
  }

  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, run));
  return results;
}

/**
 * Scans the configured lookback window for Aegis events.
 *
 * @param client A public client for the configured chain.
 * @param config The validated dashboard configuration.
 */
export async function scanAuditLog(
  client: PublicClient,
  config: AegisConfig,
  wired?: { instructionSender?: Address; executionVerifier?: Address },
): Promise<AuditScan> {
  const head = await client.getBlockNumber();
  const lowestUseful = head > config.logLookbackBlocks ? head - config.logLookbackBlocks : 0n;
  const fromBlock = lowestUseful > config.deploymentBlock ? lowestUseful : config.deploymentBlock;

  const byAddress = new Map<string, { contract: AegisContract; abi: readonly unknown[] }>([
    [config.policyEngine.toLowerCase(), { contract: "PolicyEngine", abi: policyEngineAbi }],
    [config.treasuryRegistry.toLowerCase(), { contract: "TreasuryRegistry", abi: treasuryRegistryAbi }],
    [config.paymentController.toLowerCase(), { contract: "PaymentController", abi: paymentControllerAbi }],
  ]);

  // The signer and the verifier are wired into the contracts rather than
  // configured here, so they join the scan only once they exist.
  if (wired?.instructionSender && !isZero(wired.instructionSender)) {
    byAddress.set(wired.instructionSender.toLowerCase(), {
      contract: "AegisInstructionSender",
      abi: aegisInstructionSenderAbi,
    });
  }
  if (wired?.executionVerifier && !isZero(wired.executionVerifier)) {
    byAddress.set(wired.executionVerifier.toLowerCase(), {
      contract: "ExecutionVerifier",
      abi: executionVerifierAbi,
    });
  }

  const addresses = [...byAddress.keys()] as Address[];

  const ranges = planRanges(fromBlock, head, config.logChunkBlocks);
  const batches = await mapWithConcurrency(ranges, CONCURRENCY, async (range) =>
    client.getLogs({ address: addresses, fromBlock: range.from, toBlock: range.to }),
  );

  const entries: AuditEntry[] = [];
  for (const logs of batches) {
    for (const log of logs) {
      const source = byAddress.get(log.address.toLowerCase());
      if (!source) continue;
      const entry = toEntry(source.contract, log, source.abi);
      if (entry) entries.push(entry);
    }
  }

  entries.sort((a, b) =>
    a.blockNumber === b.blockNumber ? b.logIndex - a.logIndex : a.blockNumber > b.blockNumber ? -1 : 1,
  );

  return {
    entries,
    fromBlock,
    toBlock: head,
    complete: fromBlock <= config.deploymentBlock,
  };
}
