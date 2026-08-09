import { zeroAddress } from "viem";
import type { Address, Hex, PublicClient } from "viem";

import {
  contractHandles,
  wiredHandles,
  SIGNER_SET_INSTALLED,
  SIGNER_SET_LOCKED,
  type Amendment,
  type PartialSignature,
  type PaymentRequest,
  type Policy,
  type SignerSet,
  type Tier,
  type Treasury,
} from "./contracts";
import { hasRole, ROLE_APPROVER } from "./roles";

/** One request's approvals, each marked with whether it still carries authority. */
export type ApprovalStanding = {
  entries: { approver: Address; stillHoldsRole: boolean }[];
  /** What `dispatch` will count. Lower than `entries.length` once a role lapses. */
  valid: number;
};

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

/**
 * One entry of an `allowFailure` multicall.
 *
 * viem infers this precisely for a homogeneous, statically known call list. The
 * lists here are built at runtime from an id range, so the shape is named once
 * and the results are cast at the point of use rather than fought with generics
 * at every call site.
 */
type MulticallEntry = { status: "success"; result: unknown } | { status: "failure"; error: Error };

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
    const results = (await client.multicall({
      allowFailure: true,
      contracts: group.map((id) => ({
        address: handle.address,
        abi: handle.abi,
        functionName,
        args: [id],
      })) as never,
    })) as MulticallEntry[];

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

/**
 * One address's role mask on many policies at once.
 *
 * Keyed by policy id as a string, because a bigint key would compare by
 * identity in a Map.
 */
export async function rolesForAccount(
  client: PublicClient,
  account: Address,
  policyIds: bigint[],
): Promise<Map<string, number>> {
  const { policyEngine } = contractHandles();
  const masks = new Map<string, number>();

  for (const group of chunk(policyIds, BATCH_SIZE)) {
    const results = (await client.multicall({
      allowFailure: true,
      contracts: group.map((policyId) => ({
        address: policyEngine.address,
        abi: policyEngine.abi,
        functionName: "rolesOf",
        args: [policyId, account],
      })) as never,
    })) as MulticallEntry[];

    results.forEach((result, index) => {
      const policyId = group[index];
      if (policyId === undefined || result.status !== "success") return;
      masks.set(policyId.toString(), Number(result.result));
    });
  }

  return masks;
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

// --- Signer sets -----------------------------------------------------------

/**
 * Reads a treasury's k-of-n arrangement.
 *
 * A treasury that signs with one enclave key has a zeroed set, which is not an
 * error — it is the v1 arrangement, and the state is what says so.
 */
export async function getSignerSet(client: PublicClient, treasuryId: bigint): Promise<SignerSet> {
  const { treasuryRegistry } = contractHandles();
  return (await client.readContract({
    ...treasuryRegistry,
    functionName: "getSignerSet",
    args: [treasuryId],
  })) as unknown as SignerSet;
}

/** The enclave signer accounts bound to a treasury, in the order they were bound. */
export async function signersOf(client: PublicClient, treasuryId: bigint): Promise<readonly Hex[]> {
  const { treasuryRegistry } = contractHandles();
  return (await client.readContract({
    ...treasuryRegistry,
    functionName: "signersOf",
    args: [treasuryId],
  })) as readonly Hex[];
}

/**
 * Whether a treasury's payments are authorised by quorum.
 *
 * True from the moment the signer list is live, not from the moment the master
 * key is retired: the list is what XRPL checks a multi-signed transaction
 * against, and retiring the key removes the alternative, which is a separate and
 * later fact.
 */
export function signsByQuorum(set: SignerSet): boolean {
  return set.state === SIGNER_SET_INSTALLED || set.state === SIGNER_SET_LOCKED;
}

/**
 * The shares collected towards a request's k-of-n signature.
 *
 * Published individually so a quorum can be assembled from chain data alone,
 * with no Aegis service running — which is what makes the assembler powerless
 * rather than trusted.
 */
export async function partialSignaturesOf(
  client: PublicClient,
  requestId: bigint,
): Promise<readonly PartialSignature[]> {
  const { paymentController } = contractHandles();
  return (await client.readContract({
    ...paymentController,
    functionName: "partialSignaturesOf",
    args: [requestId],
  })) as unknown as readonly PartialSignature[];
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

/**
 * Who has approved a request, and how many of those approvals still carry
 * authority.
 *
 * The two figures come apart when an approver's role is revoked after they
 * approved: `getRequest().approvals` still counts them, and `dispatch` does not.
 * Showing only the raw count would tell an operator a payment is ready when the
 * contract is about to refuse it.
 */
export async function approvalStanding(
  client: PublicClient,
  requestId: bigint,
  policyId: bigint,
): Promise<ApprovalStanding> {
  const { paymentController } = contractHandles();
  const [approvers, valid] = await Promise.all([
    client.readContract({
      ...paymentController,
      functionName: "approversOf",
      args: [requestId],
    }) as Promise<readonly Address[]>,
    client.readContract({
      ...paymentController,
      functionName: "validApprovals",
      args: [requestId],
    }) as Promise<number>,
  ]);

  // Which approvals lapsed, not just how many. The contract only reports the
  // count, so the individual standing is re-derived from the same role the
  // contract reads.
  const entries = await Promise.all(
    approvers.map(async (approver) => ({
      approver,
      stillHoldsRole: hasRole(await rolesOf(client, policyId, approver), ROLE_APPROVER),
    })),
  );
  return { entries, valid };
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

// --- Wiring ----------------------------------------------------------------

/**
 * Which signer and which verifier the contracts actually trust.
 *
 * Both are set once and exposed as public getters, so this is read from the
 * chain rather than configured. An address of zero is a real state — phase 4's
 * verifier is wired after the phase 3 signer — and the dashboard says so instead
 * of hiding a half-built deployment behind an empty screen.
 */
export type Wiring = {
  registryInstructionSender: Address;
  registryExecutionVerifier: Address;
  controllerInstructionSender: Address;
  controllerExecutionVerifier: Address;
  /** The FCC extension id, once `setExtensionId()` has found it. */
  extensionId: bigint | null;
};

/** Whether an address is the zero address, i.e. not wired. */
export function isWired(address: Address | undefined): boolean {
  return address !== undefined && address.toLowerCase() !== zeroAddress;
}

export async function readWiring(client: PublicClient): Promise<Wiring> {
  const { treasuryRegistry, paymentController } = contractHandles();

  const [registryInstructionSender, registryExecutionVerifier, controllerInstructionSender, controllerExecutionVerifier] =
    (await Promise.all([
      client.readContract({ ...treasuryRegistry, functionName: "instructionSender" }),
      client.readContract({ ...treasuryRegistry, functionName: "executionVerifier" }),
      client.readContract({ ...paymentController, functionName: "instructionSender" }),
      client.readContract({ ...paymentController, functionName: "executionVerifier" }),
    ])) as [Address, Address, Address, Address];

  let extensionId: bigint | null = null;
  if (isWired(registryInstructionSender)) {
    try {
      extensionId = (await client.readContract({
        ...wiredHandles(registryInstructionSender, zeroAddress).instructionSender,
        functionName: "extensionId",
      })) as bigint;
    } catch {
      // `extensionId()` reverts until setExtensionId() has scanned the registry.
      // That is a stage of deployment, not a failure, and the panel reports it.
      extensionId = null;
    }
  }

  return {
    registryInstructionSender,
    registryExecutionVerifier,
    controllerInstructionSender,
    controllerExecutionVerifier,
    extensionId,
  };
}

/** The reference a settled payment must carry in its XRPL memo. */
export async function requestReference(
  client: PublicClient,
  executionVerifier: Address,
  requestId: bigint,
): Promise<Hex> {
  return (await client.readContract({
    ...wiredHandles(zeroAddress, executionVerifier).executionVerifier,
    functionName: "requestReference",
    args: [requestId],
  })) as Hex;
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
