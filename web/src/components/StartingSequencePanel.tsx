"use client";

import { useState } from "react";

import { TxFeedback } from "@/components/TxFeedback";
import { Alert, buttonClass, Card, Mono } from "@/components/ui";
import { useAegisTx } from "@/hooks/useAegisTx";
import { contractHandles, type Treasury } from "@/lib/contracts";

/**
 * Recording the XRPL sequence a treasury's account starts at.
 *
 * This step exists because an XRPL account does not start at sequence 1. Since
 * the DeletableAccounts amendment, a newly funded account takes the ledger index
 * it was created in as its first sequence — a number in the tens of millions. A
 * treasury that assumed 1 would sign a transaction the network rejects with
 * `tefPAST_SEQ`, and because a rejected transaction never reaches a ledger there
 * is no proof that could ever move it on: settlement needs a settled payment,
 * and the failed-execution path needs a payment a ledger actually included. The
 * treasury would be stuck on its first payment forever.
 *
 * It cannot be folded into key generation either. At KEYGEN the account has no
 * sequence because it does not exist yet — XRPL creates it when it is first
 * funded. Hence the order the panel walks through: generate, bind, fund, record.
 */
export function StartingSequencePanel({
  treasury,
  xrplSequence,
  canAdmin,
}: {
  treasury: Treasury;
  xrplSequence: number | null;
  canAdmin: boolean;
}) {
  const tx = useAegisTx();
  const [entered, setEntered] = useState("");

  const recorded = treasury.nextSequence !== 0;
  const value = entered === "" ? (xrplSequence ?? null) : Number(entered);
  const valid = value !== null && Number.isInteger(value) && value > 0 && value <= 0xffffffff;

  // Nothing to do once XRPL has consumed one: the starting point is a matter of
  // record and the contract stops accepting edits.
  if (treasury.sequenceConfirmed) return null;

  return (
    <Card
      title="Starting XRPL sequence"
      subtitle="What sequence this treasury's account is at on XRPL. Payments are refused until it is recorded."
    >
      {!recorded ? (
        <Alert tone="warn" title="Not recorded yet — this treasury cannot pay">
          An XRPL account starts at the ledger index it was funded in, not at 1, so this cannot be guessed. Fund{" "}
          <Mono>{treasury.xrplAddress || "the treasury address"}</Mono> on XRPL, then record the sequence its account
          reports.
        </Alert>
      ) : (
        <p className="text-sm text-muted">
          Recorded as <Mono>{treasury.nextSequence}</Mono>
          {xrplSequence !== null && xrplSequence !== treasury.nextSequence && (
            <>
              {" "}
              — XRPL currently reports <Mono>{xrplSequence}</Mono>, so this is still correctable until a payment
              settles.
            </>
          )}
          .
        </p>
      )}

      {!canAdmin ? (
        <p className="mt-3 text-sm text-faint">
          Only a POLICY_ADMIN of this treasury&apos;s policy may record the starting sequence.
        </p>
      ) : !treasury.xrplAccountId || treasury.xrplAccountId === "0x" ? (
        <p className="mt-3 text-sm text-faint">Generate and bind the XRPL key first — there is no account yet.</p>
      ) : (
        <div className="mt-4 flex flex-wrap items-end gap-3">
          <label className="text-sm">
            <span className="block text-faint">Sequence</span>
            <input
              inputMode="numeric"
              className="mt-1 w-48 rounded border border-line bg-transparent px-2 py-1 font-mono text-sm"
              placeholder={xrplSequence !== null ? String(xrplSequence) : "from account_info"}
              value={entered}
              onChange={(event) => setEntered(event.target.value.replace(/[^0-9]/g, ""))}
            />
          </label>
          <button
            type="button"
            className={buttonClass("primary")}
            disabled={tx.isBusy || !valid}
            onClick={() => {
              if (!valid || value === null) return;
              void tx.run({
                ...contractHandles().treasuryRegistry,
                functionName: "setInitialSequence",
                args: [treasury.id, value],
              });
            }}
          >
            {tx.isBusy ? "Working…" : recorded ? "Correct the sequence" : "Record the sequence"}
          </button>
        </div>
      )}

      <p className="mt-3 text-xs text-faint">
        A wrong value here cannot authorise anything — destination, tag and amount are policy-checked and bound into the
        policy digest regardless, and XRPL enforces the sequence itself. The only cost is a payment that does not land,
        which is why this stays editable until one settles.
      </p>

      <TxFeedback state={tx.state} doneMessage="Starting sequence recorded" />
    </Card>
  );
}
