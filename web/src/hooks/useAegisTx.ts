"use client";

import { useQueryClient } from "@tanstack/react-query";
import { useCallback, useState } from "react";
import type { Address, Hex } from "viem";
import { useAccount, usePublicClient, useWriteContract } from "wagmi";

/**
 * Sending a transaction, with the refusal shown before the wallet opens.
 *
 * Every call is simulated first. A policy violation then arrives as the decoded
 * custom error — "rolling window exhausted", not "execution reverted" — and the
 * wallet is never asked to sign something the contract has already refused. That
 * ordering is the whole point: an approver should learn which rule blocked a
 * payment without paying gas to find out.
 */

export type WriteRequest = {
  address: Address;
  abi: readonly unknown[];
  functionName: string;
  args: readonly unknown[];
  value?: bigint;
};

export type TxStatus = "idle" | "checking" | "signing" | "mining" | "done" | "failed";

export type TxState = {
  status: TxStatus;
  hash?: Hex;
  error?: unknown;
};

export type AegisTx = {
  state: TxState;
  /** Runs the call, returning true only if it was mined successfully. */
  run: (request: WriteRequest) => Promise<boolean>;
  reset: () => void;
  isBusy: boolean;
};

export function useAegisTx(): AegisTx {
  const [state, setState] = useState<TxState>({ status: "idle" });
  const { writeContractAsync } = useWriteContract();
  const { address: account } = useAccount();
  const publicClient = usePublicClient();
  const queryClient = useQueryClient();

  const reset = useCallback(() => setState({ status: "idle" }), []);

  const run = useCallback(
    async (request: WriteRequest): Promise<boolean> => {
      if (!publicClient) {
        setState({ status: "failed", error: new Error("No chain connection.") });
        return false;
      }
      if (!account) {
        setState({ status: "failed", error: new Error("Connect a wallet first.") });
        return false;
      }

      try {
        setState({ status: "checking" });
        await publicClient.simulateContract({ ...request, account } as never);

        setState({ status: "signing" });
        const hash = await writeContractAsync(request as never);

        setState({ status: "mining", hash });
        const receipt = await publicClient.waitForTransactionReceipt({ hash });
        if (receipt.status !== "success") {
          throw new Error("The transaction was mined but reverted.");
        }

        setState({ status: "done", hash });
        await queryClient.invalidateQueries();
        return true;
      } catch (error) {
        setState({ status: "failed", error });
        return false;
      }
    },
    [account, publicClient, queryClient, writeContractAsync],
  );

  return {
    state,
    run,
    reset,
    isBusy: state.status === "checking" || state.status === "signing" || state.status === "mining",
  };
}

/** What to show while a transaction is in flight. */
export function txStatusLabel(status: TxStatus): string {
  switch (status) {
    case "checking":
      return "Checking the policy…";
    case "signing":
      return "Waiting for the wallet…";
    case "mining":
      return "Waiting for the block…";
    case "done":
      return "Confirmed";
    case "failed":
      return "Refused";
    default:
      return "";
  }
}
