"use client";

import { explorerAddressUrl, explorerTxUrl, requireConfig, xrplAccountUrl, xrplTxUrl } from "@/lib/config";
import { shortHex } from "@/lib/format";

/**
 * Outbound links to the two chains.
 *
 * Every fact the dashboard shows has a public record behind it, and the point of
 * these links is that a reader never has to take the dashboard's word for
 * anything.
 */

const linkClass =
  "numeric font-medium text-accent underline decoration-accent/30 underline-offset-2 hover:decoration-accent";

export function TxLink({ hash, label }: { hash: string; label?: string }) {
  const config = requireConfig();
  return (
    <a className={linkClass} href={explorerTxUrl(config, hash)} target="_blank" rel="noreferrer">
      {label ?? shortHex(hash)}
    </a>
  );
}

export function AddressLink({ address, label }: { address: string; label?: string }) {
  const config = requireConfig();
  return (
    <a className={linkClass} href={explorerAddressUrl(config, address)} target="_blank" rel="noreferrer">
      {label ?? shortHex(address, 6, 4)}
    </a>
  );
}

export function XrplAccountLink({ address, label }: { address: string; label?: string }) {
  const config = requireConfig();
  return (
    <a className={linkClass} href={xrplAccountUrl(config, address)} target="_blank" rel="noreferrer">
      {label ?? address}
    </a>
  );
}

export function XrplTxLink({ hash, label }: { hash: string; label?: string }) {
  const config = requireConfig();
  return (
    <a className={linkClass} href={xrplTxUrl(config, hash)} target="_blank" rel="noreferrer">
      {label ?? shortHex(hash)}
    </a>
  );
}
