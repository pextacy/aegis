import type { Address, Hex, PublicClient } from "viem";

import {
  contractHandles,
  type Amendment,
  type PaymentRequest,
  type Policy,
  type Tier,
  type Treasury,
} from "./contracts";

/**
 * Reads of Aegis state, straight from the contracts.
 *
 * There is no Aegis backend and no indexer between the dashboard and the chain.
 * Every id space runs sequentially from 1 and every contract exposes its next
 * id, so a client can walk the whole system with `eth_call` alone — which is
 * what makes "reconstruct the history with no Aegis service running" true rather
 * than aspirational.
 *
 * Calls are batched through Multicall3. viem returns structs as objects keyed by
 * their Solidity field names; the casts below name the shape once so the rest of
 * the app is typed.
 */

/** Multicall3 handles far more, but a batch this size keeps one call under any RPC's response cap. */
const BATCH_SIZE = 100;

function idRange(nextId: bigint): bigint[] {
  const ids: bigint[] = [];
  for (let id = 1n; id < nextId; id += 1n) ids.push(id);
  return ids;
}

function chunk<T>(items: T[], size: number): T[][] {
  const chunks: T[][] = [];
  for (let i = 0; i < items.length; i += size) chunks.push(items.slice(i, i + size));
  return chunks;
}

async function batchRead<T>(
  client: PublicClient,
  handle: { address: Address; abi: readonly unknown[] },
  functionName: string,
  ids: bigint[],
): Promise<Map<string, T>> {
  const found = new Map<string, T>();

  for (const group of chunk(ids, BATCH_SIZE)) {
    const results = await client.multicall({
      allowFailure: true,
      contracts: group.map((id) => ({
        address: handle.address,
        abi: handle.abi,
        functionName,
        args: [id],
      })) as never,
    });

    results.forEach((result, index) => {
      const id = group[index];
      if (id === undefined) return;
      if (result.status !== "success") return;
      found.set(id.toString(), result.result as T);
    });
  }

  return found;
}

// --- Policies --------------------------------------------------------------

/** The id the next policy will take, and therefore the enumeration bound. */
export async function nextPolicyId(client: PublicClient): Promise<bigint> {
  const { policyEngine } = contractHandles();
  return (await client.readContract({ ...policyEngine, functionName: "nextPolicyId" })) as bigint;
}

/** Reads one policy. */
export async function getPolicy(client: PublicClient, policyId: bigint): Promise<Policy> {
  const { policyEngine } = contractHandles();
  return (await client.readContract({
    ...policyEngine,
    functionName: "getPolicy",
    args: [policyId],
  })) as unknown as Policy;
}

/** Every policy ever created, lowest id first. */
export async function listPolicies(client: PublicClient): Promise<Policy[]> {
  const { policyEngine } = contractHandles();
  const ids = idRange(await nextPolicyId(client));
  const byId = await batchRead<Policy>(client, policyEngine, "getPolicy", ids);
  return ids.map((id) => byId.get(id.toString())).filter((policy): policy is Policy => policy !== undefined);
}

/** The lowest tier whose ceiling covers an amount. Reverts above the hard cap. */
export async function resolveTier(client: PublicClient, policyId: bigint, amountUsd: bigint): Promise<Tier> {
  const { policyEngine } = contractHandles();
  return (await client.readContract({
    ...policyEngine,
    functionName: "resolveTier",
    args: [policyId, amountUsd],
  })) as unknown as Tier;
}

/** Whether a policy permits a destination and tag. */
export async function isDestinationAllowed(
  client: PublicClient,
  policyId: bigint,
  accountId: Hex,
  tag: number,
): Promise<boolean> {
  const { policyEngine } = contractHandles();
  return (await client.readContract({
    ...policyEngine,
    functionName: "isDestinationAllowed",
    args: [policyId, accountId, tag],
  })) as boolean;
}

/** An address's complete role mask on a policy. */
export async function rolesOf(client: PublicClient, policyId: bigint, account: Address): Promise<number> {
  const { policyEngine } = contractHandles();
  return (await client.readContract({
    ...policyEngine,
    functionName: "rolesOf",
    args: [policyId, account],
  })) as number;
}

/** The guardians of a policy — the cosigner set the TEE instruction carries. */
export async function guardiansOf(client: PublicClient, policyId: bigint): Promise<readonly Address[]> {
  const { policyEngine } = contractHandles();
  return (await client.readContract({
    ...policyEngine,
    functionName: "guardiansOf",
    args: [policyId],
  })) as readonly Address[];
}

// --- Treasuries ------------------------------------------------------------

/** The id the next treasury will take. */
export async function nextTreasuryId(client: PublicClient): Promise<bigint> {
  const { treasuryRegistry } = contractHandles();
  return (await client.readContract({ ...treasuryRegistry, functionName: "nextTreasuryId" })) as bigint;
}

/** Reads one treasury. */
export async function getTreasury(client: PublicClient, treasuryId: bigint): Promise<Treasury> {
  const { treasuryRegistry } = contractHandles();
  return (await client.readContract({
    ...treasuryRegistry,
    functionName: "getTreasury",
    args: [treasuryId],
  })) as unknown as Treasury;
}

/** Every treasury, lowest id first. */
export async function listTreasuries(client: PublicClient): Promise<Treasury[]> {
  const { treasuryRegistry } = contractHandles();
  const ids = idRange(await nextTreasuryId(client));
  const byId = await batchRead<Treasury>(client, treasuryRegistry, "getTreasury", ids);
  return ids.map((id) => byId.get(id.toString())).filter((t): t is Treasury => t !== undefined);
}

// --- Amendments ------------------------------------------------------------

/** An amendment together with its id, since the struct does not carry one. */
export type IdentifiedAmendment = Amendment & { id: bigint };

/** Every amendment, optionally narrowed to one treasury. */
export async function listAmendments(client: PublicClient, treasuryId?: bigint): Promise<IdentifiedAmendment[]> {
  const { treasuryRegistry } = contractHandles();
  const next = (await client.readContract({ ...treasuryRegistry, functionName: "nextAmendmentId" })) as bigint;
  const ids = idRange(next);
  const byId = await batchRead<Amendment>(client, treasuryRegistry, "getAmendment", ids);

  const amendments: IdentifiedAmendment[] = [];
  for (const id of ids) {
    const amendment = byId.get(id.toString());
    if (!amendment) continue;
    if (treasuryId !== undefined && amendment.treasuryId !== treasuryId) continue;
    amendments.push({ ...amendment, id });
  }
  return amendments;
}

// --- Payment requests ------------------------------------------------------

/** The id the next payment request will take. */
export async function nextRequestId(client: PublicClient): Promise<bigint> {
  const { paymentController } = contractHandles();
  return (await client.readContract({ ...paymentController, functionName: "nextRequestId" })) as bigint;
}

/** A request together with its id, since the struct does not carry one. */
export type IdentifiedRequest = PaymentRequest & { id: bigint };

/** Reads one payment request. */
export async function getRequest(client: PublicClient, requestId: bigint): Promise<IdentifiedRequest> {
  const { paymentController } = contractHandles();
  const request = (await client.readContract({
    ...paymentController,
    functionName: "getRequest",
    args: [requestId],
  })) as unknown as PaymentRequest;
  return { ...request, id: requestId };
}

/** Every payment request, optionally narrowed to one treasury, newest first. */
export async function listRequests(client: PublicClient, treasuryId?: bigint): Promise<IdentifiedRequest[]> {
  const { paymentController } = contractHandles();
  const ids = idRange(await nextRequestId(client));
  const byId = await batchRead<PaymentRequest>(client, paymentController, "getRequest", ids);

  const requests: IdentifiedRequest[] = [];
  for (const id of ids) {
    const request = byId.get(id.toString());
    if (!request) continue;
    if (treasuryId !== undefined && request.treasuryId !== treasuryId) continue;
    requests.push({ ...request, id });
  }
  return requests.reverse();
}

/** Whether an address has already approved a request. */
export async function hasApproved(client: PublicClient, requestId: bigint, account: Address): Promise<boolean> {
  const { paymentController } = contractHandles();
  return (await client.readContract({
    ...paymentController,
    functionName: "hasApproved",
    args: [requestId, account],
  })) as boolean;
}

/** Whether an address has already approved an amendment. */
export async function hasApprovedAmendment(
  client: PublicClient,
  amendmentId: bigint,
  account: Address,
): Promise<boolean> {
  const { treasuryRegistry } = contractHandles();
  return (await client.readContract({
    ...treasuryRegistry,
    functionName: "hasApprovedAmendment",
    args: [amendmentId, account],
  })) as boolean;
}

/** USD committed inside a treasury's current rolling window. */
export async function committedUsd(client: PublicClient, treasuryId: bigint): Promise<bigint> {
  const { paymentController } = contractHandles();
  return (await client.readContract({
    ...paymentController,
    functionName: "committedUsd",
    args: [treasuryId],
  })) as bigint;
}

/**
 * Prices drops in USD at the current FTSO value.
 *
 * `quoteUsd` reads a feed and so is not a `view` function; this is an `eth_call`
 * against it, which is the same computation `propose` will run. A stale feed
 * reverts here exactly as it would there, which is the point: the dashboard
 * shows the refusal before anyone pays gas for it.
 */
export async function quoteUsd(client: PublicClient, amountDrops: bigint): Promise<bigint> {
  const { paymentController } = contractHandles();
  const { result } = await client.simulateContract({
    ...paymentController,
    functionName: "quoteUsd",
    args: [amountDrops],
  });
  return result as bigint;
}

/** The digest the TEE recomputes before it will sign. */
export async function policyDigest(
  client: PublicClient,
  args: {
    requestId: bigint;
    treasuryId: bigint;
    destinationAccountId: Hex;
    destinationTag: number;
    amountDrops: bigint;
    sequence: number;
    lastLedgerSequence: number;
    feeDrops: bigint;
  },
): Promise<Hex> {
  const { paymentController } = contractHandles();
  return (await client.readContract({
    ...paymentController,
    functionName: "policyDigest",
    args: [
      args.requestId,
      args.treasuryId,
      args.destinationAccountId,
      args.destinationTag,
      args.amountDrops,
      args.sequence,
      args.lastLedgerSequence,
      args.feeDrops,
    ],
  })) as Hex;
}
