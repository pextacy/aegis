"use client";

import { useQuery, type UseQueryResult } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import type { Address, Hex, PublicClient } from "viem";
import { usePublicClient } from "wagmi";

import * as chain from "@/lib/chain-data";
import { requireConfig } from "@/lib/config";
import type { Policy, Treasury } from "@/lib/contracts";
import { scanAuditLog, type AuditScan } from "@/lib/logs";
import { fetchAccount, fetchCurrentLedger, fetchFees, type XrplAccount, type XrplFees } from "@/lib/xrpl-client";

/**
 * Chain reads, wrapped for React.
 *
 * Nothing here caches across a page load beyond react-query's own window, and
 * nothing is written to storage. The dashboard is a view of the chain, not a
 * copy of it — if it disagrees with the chain the chain is right, and the way to
 * keep that true is never to keep a second copy.
 */

/** Poll intervals, in milliseconds. Coston2 produces a block roughly every 1.8s. */
const FAST = 6_000;
const SLOW = 20_000;

function useClient(): PublicClient | undefined {
  return usePublicClient() as PublicClient | undefined;
}

export function usePolicies(): UseQueryResult<Policy[]> {
  const client = useClient();
  return useQuery({
    queryKey: ["policies"],
    enabled: Boolean(client),
    refetchInterval: SLOW,
    queryFn: async () => chain.listPolicies(client as PublicClient),
  });
}

export function usePolicy(policyId: bigint | undefined): UseQueryResult<Policy> {
  const client = useClient();
  return useQuery({
    queryKey: ["policy", policyId?.toString()],
    enabled: Boolean(client) && policyId !== undefined,
    refetchInterval: SLOW,
    queryFn: async () => chain.getPolicy(client as PublicClient, policyId as bigint),
  });
}

export function useTreasuries(): UseQueryResult<Treasury[]> {
  const client = useClient();
  return useQuery({
    queryKey: ["treasuries"],
    enabled: Boolean(client),
    refetchInterval: FAST,
    queryFn: async () => chain.listTreasuries(client as PublicClient),
  });
}

export function useTreasury(treasuryId: bigint | undefined): UseQueryResult<Treasury> {
  const client = useClient();
  return useQuery({
    queryKey: ["treasury", treasuryId?.toString()],
    enabled: Boolean(client) && treasuryId !== undefined,
    refetchInterval: FAST,
    queryFn: async () => chain.getTreasury(client as PublicClient, treasuryId as bigint),
  });
}

export function useRequests(treasuryId?: bigint): UseQueryResult<chain.IdentifiedRequest[]> {
  const client = useClient();
  return useQuery({
    queryKey: ["requests", treasuryId?.toString() ?? "all"],
    enabled: Boolean(client),
    refetchInterval: FAST,
    queryFn: async () => chain.listRequests(client as PublicClient, treasuryId),
  });
}

export function useRequest(requestId: bigint | undefined): UseQueryResult<chain.IdentifiedRequest> {
  const client = useClient();
  return useQuery({
    queryKey: ["request", requestId?.toString()],
    enabled: Boolean(client) && requestId !== undefined,
    refetchInterval: FAST,
    queryFn: async () => chain.getRequest(client as PublicClient, requestId as bigint),
  });
}

export function useAmendments(treasuryId?: bigint): UseQueryResult<chain.IdentifiedAmendment[]> {
  const client = useClient();
  return useQuery({
    queryKey: ["amendments", treasuryId?.toString() ?? "all"],
    enabled: Boolean(client),
    refetchInterval: FAST,
    queryFn: async () => chain.listAmendments(client as PublicClient, treasuryId),
  });
}

export function useCommittedUsd(treasuryId: bigint | undefined): UseQueryResult<bigint> {
  const client = useClient();
  return useQuery({
    queryKey: ["committedUsd", treasuryId?.toString()],
    enabled: Boolean(client) && treasuryId !== undefined,
    refetchInterval: FAST,
    queryFn: async () => chain.committedUsd(client as PublicClient, treasuryId as bigint),
  });
}

export function useRoles(policyId: bigint | undefined, account: Address | undefined): UseQueryResult<number> {
  const client = useClient();
  return useQuery({
    queryKey: ["roles", policyId?.toString(), account],
    enabled: Boolean(client) && policyId !== undefined && Boolean(account),
    refetchInterval: SLOW,
    queryFn: async () => chain.rolesOf(client as PublicClient, policyId as bigint, account as Address),
  });
}

/** The connected account's role mask on every policy, keyed by policy id. */
export function useRolesForAccount(
  account: Address | undefined,
  policyIds: bigint[] | undefined,
): UseQueryResult<Map<string, number>> {
  const client = useClient();
  return useQuery({
    queryKey: ["rolesForAccount", account, policyIds?.map((id) => id.toString()).join(",")],
    enabled: Boolean(client) && Boolean(account) && Boolean(policyIds),
    refetchInterval: SLOW,
    queryFn: async () =>
      chain.rolesForAccount(client as PublicClient, account as Address, policyIds as bigint[]),
  });
}

export function useGuardians(policyId: bigint | undefined): UseQueryResult<readonly Address[]> {
  const client = useClient();
  return useQuery({
    queryKey: ["guardians", policyId?.toString()],
    enabled: Boolean(client) && policyId !== undefined,
    refetchInterval: SLOW,
    queryFn: async () => chain.guardiansOf(client as PublicClient, policyId as bigint),
  });
}

export function useHasApproved(
  requestId: bigint | undefined,
  account: Address | undefined,
): UseQueryResult<boolean> {
  const client = useClient();
  return useQuery({
    queryKey: ["hasApproved", requestId?.toString(), account],
    enabled: Boolean(client) && requestId !== undefined && Boolean(account),
    refetchInterval: FAST,
    queryFn: async () => chain.hasApproved(client as PublicClient, requestId as bigint, account as Address),
  });
}

export function useHasApprovedAmendment(
  amendmentId: bigint | undefined,
  account: Address | undefined,
): UseQueryResult<boolean> {
  const client = useClient();
  return useQuery({
    queryKey: ["hasApprovedAmendment", amendmentId?.toString(), account],
    enabled: Boolean(client) && amendmentId !== undefined && Boolean(account),
    refetchInterval: FAST,
    queryFn: async () =>
      chain.hasApprovedAmendment(client as PublicClient, amendmentId as bigint, account as Address),
  });
}

export function useDestinationAllowed(
  policyId: bigint | undefined,
  accountId: Hex | undefined,
  tag: number,
): UseQueryResult<boolean> {
  const client = useClient();
  return useQuery({
    queryKey: ["destinationAllowed", policyId?.toString(), accountId, tag],
    enabled: Boolean(client) && policyId !== undefined && Boolean(accountId),
    queryFn: async () =>
      chain.isDestinationAllowed(client as PublicClient, policyId as bigint, accountId as Hex, tag),
  });
}

/**
 * Prices an amount in USD at the live FTSO value.
 *
 * This is the same call `propose` makes, so a stale feed surfaces here as the
 * error it will be on-chain rather than as a stale number on screen.
 */
export function useQuoteUsd(amountDrops: bigint | undefined): UseQueryResult<bigint> {
  const client = useClient();
  return useQuery({
    queryKey: ["quoteUsd", amountDrops?.toString()],
    enabled: Boolean(client) && amountDrops !== undefined && amountDrops > 0n,
    refetchInterval: SLOW,
    retry: false,
    queryFn: async () => chain.quoteUsd(client as PublicClient, amountDrops as bigint),
  });
}

/** Which signer and verifier the contracts trust, read from the chain. */
export function useWiring(): UseQueryResult<chain.Wiring> {
  const client = useClient();
  return useQuery({
    queryKey: ["wiring"],
    enabled: Boolean(client),
    refetchInterval: SLOW,
    queryFn: async () => chain.readWiring(client as PublicClient),
  });
}

/** The reference an FDC proof must carry to settle a request. */
export function useRequestReference(
  executionVerifier: Address | undefined,
  requestId: bigint | undefined,
): UseQueryResult<Hex> {
  const client = useClient();
  return useQuery({
    queryKey: ["requestReference", executionVerifier, requestId?.toString()],
    enabled: Boolean(client) && Boolean(executionVerifier) && requestId !== undefined,
    queryFn: async () =>
      chain.requestReference(client as PublicClient, executionVerifier as Address, requestId as bigint),
  });
}

/** The digest the enclave will recompute, previewed before dispatch. */
export function usePolicyDigest(
  args:
    | {
        requestId: bigint;
        treasuryId: bigint;
        destinationAccountId: Hex;
        destinationTag: number;
        amountDrops: bigint;
        sequence: number;
        lastLedgerSequence: number;
        feeDrops: bigint;
      }
    | undefined,
): UseQueryResult<Hex> {
  const client = useClient();
  return useQuery({
    queryKey: ["policyDigest", args ? JSON.stringify(args, (_, value) => (typeof value === "bigint" ? value.toString() : value)) : null],
    enabled: Boolean(client) && args !== undefined,
    queryFn: async () =>
      chain.policyDigest(client as PublicClient, args as NonNullable<typeof args>),
  });
}

export function useAuditLog(): UseQueryResult<AuditScan> {
  const client = useClient();
  const config = requireConfig();
  const wiring = useWiring();

  // The signer and the verifier are discovered, so the scan can only include
  // their events once they are known. Keying on them re-scans when they appear.
  const extraAddresses = [wiring.data?.registryInstructionSender, wiring.data?.registryExecutionVerifier];

  return useQuery({
    queryKey: ["auditLog", ...extraAddresses],
    enabled: Boolean(client),
    refetchInterval: SLOW,
    queryFn: async () =>
      scanAuditLog(client as PublicClient, config, {
        instructionSender: wiring.data?.registryInstructionSender,
        executionVerifier: wiring.data?.registryExecutionVerifier,
      }),
  });
}

// --- XRPL ------------------------------------------------------------------

export function useXrplAccount(address: string | null | undefined): UseQueryResult<XrplAccount | null> {
  const config = requireConfig();
  return useQuery({
    queryKey: ["xrplAccount", address],
    enabled: Boolean(address),
    refetchInterval: SLOW,
    queryFn: async () => fetchAccount(config.xrplRpcUrl, address as string),
  });
}

export function useXrplLedger(): UseQueryResult<number> {
  const config = requireConfig();
  return useQuery({
    queryKey: ["xrplLedger"],
    refetchInterval: FAST,
    queryFn: async () => fetchCurrentLedger(config.xrplRpcUrl),
  });
}

export function useXrplFees(): UseQueryResult<XrplFees> {
  const config = requireConfig();
  return useQuery({
    queryKey: ["xrplFees"],
    refetchInterval: SLOW,
    queryFn: async () => fetchFees(config.xrplRpcUrl),
  });
}

// --- Clock -----------------------------------------------------------------

/**
 * The current unix time, ticking once a second.
 *
 * Timelocks are compared against `block.timestamp`, and the browser clock is
 * close enough to it to count down with — but a countdown that reaches zero is
 * not permission to dispatch. The contract re-checks, which is why every screen
 * that shows a countdown also shows what the contract will check.
 */
export function useNow(): bigint {
  const [now, setNow] = useState<bigint>(() => BigInt(Math.floor(Date.now() / 1000)));

  useEffect(() => {
    const timer = setInterval(() => setNow(BigInt(Math.floor(Date.now() / 1000))), 1000);
    return () => clearInterval(timer);
  }, []);

  return now;
}
