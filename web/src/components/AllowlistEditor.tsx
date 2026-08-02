"use client";

import { useState } from "react";
import type { Hex } from "viem";

import { TxFeedback } from "@/components/TxFeedback";
import { Alert, buttonClass, Card, Field, inputClass } from "@/components/ui";
import { useDestinationAllowed } from "@/hooks/useAegis";
import { useAegisTx } from "@/hooks/useAegisTx";
import { contractHandles } from "@/lib/contracts";
import { classicAddressToBytes32, XrplAddressError } from "@/lib/xrpl-address";

/**
 * The destination allowlist.
 *
 * A tag of `0` permits any tag on that account, which is how an exchange deposit
 * address with per-user tags stays workable. That is a real difference in
 * authority, so the form says which one is being written rather than leaving it
 * to be inferred from a zero in a box.
 */
export function AllowlistEditor({ policyId, canEdit }: { policyId: bigint; canEdit: boolean }) {
  const { policyEngine } = contractHandles();
  const tx = useAegisTx();

  const [address, setAddress] = useState("");
  const [tag, setTag] = useState("0");

  let accountId: Hex | null = null;
  let addressError: string | null = null;
  if (address.trim() !== "") {
    try {
      accountId = classicAddressToBytes32(address.trim());
    } catch (error) {
      addressError = error instanceof XrplAddressError ? error.message : String(error);
    }
  }

  const tagValue = /^\d+$/.test(tag.trim()) ? Number(tag.trim()) : null;
  const tagError =
    tag.trim() === "" || tagValue === null
      ? "A destination tag is a whole number. Use 0 to mean any tag."
      : tagValue > 0xffffffff
        ? "A destination tag is a 32-bit number."
        : null;

  const allowed = useDestinationAllowed(policyId, accountId ?? undefined, tagValue ?? 0);
  const ready = accountId !== null && tagValue !== null && tagError === null;

  return (
    <Card
      title="Destination allowlist"
      subtitle="Checked at proposal and again at dispatch. A destination removed in between blocks a payment that already had approvals."
    >
      <div className="grid gap-4 md:grid-cols-[1fr_10rem]">
        <Field
          label="XRPL account"
          error={addressError}
          hint="Classic address. The checksum is verified here, so a typo cannot reach the chain."
        >
          <input
            className={inputClass}
            placeholder="r3ymjALibVQ6D7Rdy84NJovACu7TzBJjMX"
            value={address}
            onChange={(event) => setAddress(event.target.value)}
          />
        </Field>
        <Field
          label="Destination tag"
          error={tagError}
          hint={tagValue === 0 ? "Any tag on this account." : "This tag only."}
        >
          <input
            className={inputClass}
            inputMode="numeric"
            value={tag}
            onChange={(event) => setTag(event.target.value)}
          />
        </Field>
      </div>

      {ready && allowed.data !== undefined && (
        <div className="mt-4">
          <Alert tone={allowed.data ? "good" : "neutral"}>
            {allowed.data
              ? "This destination is currently permitted by the policy."
              : "This destination is not currently permitted. A payment to it would be refused at proposal."}
          </Alert>
        </div>
      )}

      {canEdit ? (
        <>
          <div className="mt-4 flex flex-wrap items-center gap-3">
            <button
              type="button"
              className={buttonClass("primary")}
              disabled={!ready || tx.isBusy}
              onClick={() => {
                if (!accountId || tagValue === null) return;
                void tx.run({
                  address: policyEngine.address,
                  abi: policyEngine.abi,
                  functionName: "setAllowlist",
                  args: [policyId, accountId, tagValue, true],
                });
              }}
            >
              Allow
            </button>
            <button
              type="button"
              className={buttonClass("danger")}
              disabled={!ready || tx.isBusy}
              onClick={() => {
                if (!accountId || tagValue === null) return;
                void tx.run({
                  address: policyEngine.address,
                  abi: policyEngine.abi,
                  functionName: "setAllowlist",
                  args: [policyId, accountId, tagValue, false],
                });
              }}
            >
              Remove
            </button>
          </div>

          <TxFeedback state={tx.state} doneMessage="Allowlist written" />
        </>
      ) : (
        <p className="mt-4 text-sm text-faint">Only a POLICY_ADMIN of this policy may edit the allowlist.</p>
      )}
    </Card>
  );
}
