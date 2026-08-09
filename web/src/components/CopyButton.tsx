"use client";

import { useEffect, useState } from "react";

import { IconCheck, IconCopy } from "@/components/icons";

/**
 * Copy a value to the clipboard.
 *
 * An XRPL address is 25 to 35 characters of base58 and a mistyped one is a
 * payment to nobody, so the address is meant to be copied rather than read
 * across. The confirmation is the whole point of the control: it says the
 * clipboard actually took it.
 */
export function CopyButton({ value, label = "Copy" }: { value: string; label?: string }) {
  const [copied, setCopied] = useState(false);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    if (!copied) return;
    const timer = setTimeout(() => setCopied(false), 1500);
    return () => clearTimeout(timer);
  }, [copied]);

  return (
    <button
      type="button"
      aria-label={`${label} ${value}`}
      className="inline-flex size-8 items-center justify-center rounded-lg text-faint transition-colors hover:bg-raised hover:text-accent"
      onClick={async () => {
        try {
          await navigator.clipboard.writeText(value);
          setFailed(false);
          setCopied(true);
        } catch {
          // Clipboard access is denied outside a secure context. Saying so beats
          // a button that silently does nothing.
          setFailed(true);
        }
      }}
      title={failed ? "The browser refused clipboard access." : copied ? "Copied" : label}
    >
      {copied ? <IconCheck className="size-4 text-good" /> : <IconCopy className="size-4" />}
    </button>
  );
}
