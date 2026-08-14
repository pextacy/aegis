"use client";

import { useEffect, useRef, useState } from "react";
import { useAccount, useChainId, useConnect, useDisconnect, useSwitchChain } from "wagmi";

import { buttonClass } from "@/components/ui";
import { requireConfig } from "@/lib/config";
import { shortHex } from "@/lib/format";

/**
 * Wallet connection, and the network check that goes with it.
 *
 * Three states this has to tell apart, because collapsing them is how a person
 * ends up clicking a button that does nothing:
 *
 *   - no wallet in the browser at all, which no amount of clicking will fix;
 *   - one wallet, which should connect on a single click;
 *   - several, which need a choice rather than a guess at the first one.
 *
 * wagmi discovers installed wallets over EIP-6963, so the list is whatever the
 * browser actually has. A wallet on the wrong chain is called out separately —
 * it is the most common way someone ends up staring at an empty dashboard.
 */
export function ConnectButton() {
  const config = requireConfig();
  const { address, isConnected } = useAccount();
  const { connect, connectors, isPending, error, reset } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain, isPending: isSwitching } = useSwitchChain();
  const chainId = useChainId();

  const [open, setOpen] = useState(false);
  const menuRef = useRef<HTMLDivElement>(null);

  // wagmi always lists the generic `injected` connector whether or not anything
  // is behind it, so its presence proves nothing. EIP-6963 entries are real
  // wallets that announced themselves; the generic one is only usable if the
  // page actually has an injected provider, which can only be read after mount.
  const [hasInjectedProvider, setHasInjectedProvider] = useState(false);
  useEffect(() => {
    setHasInjectedProvider(typeof window !== "undefined" && "ethereum" in window);
  }, []);

  const announced = connectors.filter((connector) => connector.id !== "injected");
  const available = announced.length > 0 ? announced : hasInjectedProvider ? connectors : [];

  useEffect(() => {
    if (!open) return;
    const onClick = (event: MouseEvent) => {
      if (menuRef.current && !menuRef.current.contains(event.target as Node)) setOpen(false);
    };
    document.addEventListener("mousedown", onClick);
    return () => document.removeEventListener("mousedown", onClick);
  }, [open]);

  if (isConnected) {
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

  // Nothing to connect to. Say so, and say what would change it — a disabled
  // button with no explanation is the worst of the three states.
  if (available.length === 0) {
    return (
      <a
        className={buttonClass("secondary")}
        href="https://metamask.io/download/"
        target="_blank"
        rel="noreferrer noopener"
      >
        Install a wallet
      </a>
    );
  }

  const single = available.length === 1 ? available[0] : undefined;

  return (
    <div className="relative flex items-center gap-2" ref={menuRef}>
      {error && (
        <button
          type="button"
          className="max-w-[16rem] truncate text-xs text-bad underline-offset-2 hover:underline"
          title={error.message}
          onClick={() => reset()}
        >
          {error.message}
        </button>
      )}

      <button
        type="button"
        className={buttonClass("primary")}
        disabled={isPending}
        onClick={() => {
          if (single) connect({ connector: single });
          else setOpen((v) => !v);
        }}
      >
        {isPending ? "Connecting…" : "Connect wallet"}
      </button>

      {open && !single && (
        <div className="absolute right-0 top-full z-20 mt-2 w-56 overflow-hidden rounded-lg border border-line bg-surface shadow-lg">
          {available.map((connector) => (
            <button
              key={connector.uid}
              type="button"
              className="flex w-full items-center gap-2 px-4 py-3 text-left text-sm text-ink hover:bg-raised"
              onClick={() => {
                setOpen(false);
                connect({ connector });
              }}
            >
              {connector.icon && (
                // eslint-disable-next-line @next/next/no-img-element
                <img src={connector.icon} alt="" className="size-5 rounded" />
              )}
              {connector.name}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
