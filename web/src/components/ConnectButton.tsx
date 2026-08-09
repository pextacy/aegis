"use client";

import { useAccount, useChainId, useConnect, useDisconnect, useSwitchChain } from "wagmi";

import { buttonClass } from "@/components/ui";
import { requireConfig } from "@/lib/config";
import { shortHex } from "@/lib/format";

/**
 * Wallet connection, and the network check that goes with it.
 *
 * A wallet on the wrong chain is the most common way a person ends up staring at
 * an empty dashboard, so the mismatch is stated rather than left to be inferred
 * from missing data.
 */
export function ConnectButton() {
  const config = requireConfig();
  const { address, isConnected } = useAccount();
  const { connect, connectors, isPending, error } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain, isPending: isSwitching } = useSwitchChain();
  const chainId = useChainId();

  const injectedConnector = connectors[0];

  if (!isConnected) {
    return (
      <div className="flex items-center gap-2">
        {error && <span className="text-xs text-bad">{error.message}</span>}
        <button
          type="button"
          className={buttonClass("navy")}
          disabled={isPending || !injectedConnector}
          onClick={() => injectedConnector && connect({ connector: injectedConnector })}
        >
          {injectedConnector ? (isPending ? "Connecting…" : "Connect wallet") : "No wallet found"}
        </button>
      </div>
    );
  }

  const wrongChain = chainId !== config.chainId;

  return (
    <div className="flex items-center gap-2">
      {wrongChain && (
        <button
          type="button"
          className={buttonClass("danger")}
          disabled={isSwitching}
          onClick={() => switchChain({ chainId: config.chainId })}
        >
          {isSwitching ? "Switching…" : `Switch to chain ${config.chainId}`}
        </button>
      )}
      <span className="numeric hidden text-sm text-muted sm:inline">{address ? shortHex(address, 6, 4) : ""}</span>
      <button type="button" className={buttonClass("ghost")} onClick={() => disconnect()}>
        Disconnect
      </button>
    </div>
  );
}
