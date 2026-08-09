"use client";

import { useState } from "react";

import { XrplAccountLink, XrplTxLink } from "@/components/links";
import { TxFeedback } from "@/components/TxFeedback";
import { Alert, Badge, buttonClass, Card, inputClass, KeyValue, Mono } from "@/components/ui";
import { useSigners, useSignerSet, useWiring, useXrplLedger } from "@/hooks/useAegis";
import { useAegisTx } from "@/hooks/useAegisTx";
import { isWired } from "@/lib/chain-data";
import {
  contractHandles,
  SIGNER_SET_COLLECTING,
  SIGNER_SET_INSTALLED,
  SIGNER_SET_LOCKED,
  SIGNER_SET_NONE,
  SIGNER_SET_READY,
  wiredHandles,
  type Treasury,
} from "@/lib/contracts";
import { bytes32ToClassicAddress } from "@/lib/xrpl-address";

/**
 * A treasury's k-of-n arrangement, and the steps that build it.
 *
 * This is the surface for the limitation v1 states openly: one machine holds one
 * key, so losing the machine loses the treasury. Moving to k-of-n replaces that
 * with n machines of which any k can pay, and the panel walks the only order
 * XRPL permits — collect the keys, install the signer list, then retire the
 * master key. Retiring first would leave an account nothing could ever sign for.
 *
 * The last two steps are recorded rather than proven, and the panel says so.
 * There is no FDC attestation type for a `SignerListSet`, so what is stored is
 * the XRPL transaction hash, linked here so anyone can check it against the
 * ledger. A false claim cannot authorise a payment — it routes dispatch to a
 * quorum XRPL then refuses, which is a payment that does not land.
 */

/** The setup kinds, mirroring `AegisInstructionSender`. */
const KIND_SIGNER_LIST = 0;
const KIND_DISABLE_MASTER_KEY = 1;

/** How far past the current ledger a setup transaction stays valid. */
const EXPIRY_LEDGERS = 200;

function StateBadge({ state }: { state: number }) {
  if (state === SIGNER_SET_LOCKED) return <Badge tone="good">quorum only</Badge>;
  if (state === SIGNER_SET_INSTALLED) return <Badge tone="good">signing by quorum</Badge>;
  if (state === SIGNER_SET_READY) return <Badge tone="warn">keys collected</Badge>;
  if (state === SIGNER_SET_COLLECTING) return <Badge tone="warn">collecting keys</Badge>;
  return <Badge>single key</Badge>;
}

export function SignerSetPanel({
  treasury,
  xrplSequence,
  canAdmin,
}: {
  treasury: Treasury;
  xrplSequence: number | null;
  canAdmin: boolean;
}) {
  const set = useSignerSet(treasury.id);
  const signers = useSigners(treasury.id);
  const wiring = useWiring();
  const ledger = useXrplLedger();
  const tx = useAegisTx();

  const [quorum, setQuorum] = useState("2");
  const [signerCount, setSignerCount] = useState("3");
  const [installHash, setInstallHash] = useState("");
  const [retireHash, setRetireHash] = useState("");

  const senderAddress = wiring.data?.registryInstructionSender;
  const senderReady = isWired(senderAddress) && wiring.data?.extensionId !== null;

  // Nothing to arrange until the treasury has an account of its own to hand over.
  if (!treasury.xrplAddress) return null;

  const state = set.data?.state ?? SIGNER_SET_NONE;
  const bound = signers.data?.length ?? 0;
  const k = Number(quorum);
  const n = Number(signerCount);
  const validShape = Number.isInteger(k) && Number.isInteger(n) && k >= 1 && n >= k && n <= 32;

  // Both setup transactions consume a sequence and need an expiry, for the same
  // reason a payment does: one that cannot expire can never be proven absent.
  const sequence = xrplSequence ?? treasury.nextSequence;
  const expiry = ledger.data ? ledger.data + EXPIRY_LEDGERS : 0;
  const canSend = canAdmin && senderReady && sequence > 0 && expiry > 0;

  const sendSetup = (kind: number) => {
    if (!senderAddress || !canSend) return;
    void tx.run({
      ...wiredHandles(senderAddress, senderAddress).instructionSender,
      functionName: "requestSetup",
      args: [treasury.id, kind, sequence, expiry, 12n],
    });
  };

  const isHash = (value: string): boolean => /^0x[0-9a-fA-F]{64}$/.test(value.trim());

  return (
    <Card
      title="Signing arrangement"
      subtitle="Whether this treasury pays with one enclave key or a quorum of them."
      actions={<StateBadge state={state} />}
    >
      <dl className="mb-4">
        <KeyValue
          label="Authority"
          hint="A quorum means any k of n enclaves can authorise a payment, and losing the other n − k costs nothing."
        >
          {state === SIGNER_SET_NONE ? (
            <span className="text-muted">
              One enclave key. Losing that machine loses this treasury — the limitation k-of-n removes.
            </span>
          ) : (
            <Mono>
              {set.data?.quorum ?? 0} of {set.data?.signerCount ?? 0}
            </Mono>
          )}
        </KeyValue>

        {state !== SIGNER_SET_NONE && (
          <KeyValue label="Signer keys bound">
            <Mono>
              {bound} / {set.data?.signerCount ?? 0}
            </Mono>
          </KeyValue>
        )}

        {set.data && set.data.installTxHash !== `0x${"00".repeat(32)}` && (
          <KeyValue label="Signer list installed" hint="The XRPL transaction that handed the account to the quorum.">
            <XrplTxLink hash={set.data.installTxHash} />
          </KeyValue>
        )}

        {set.data && set.data.retireTxHash !== `0x${"00".repeat(32)}` && (
          <KeyValue label="Master key retired" hint="After this, the quorum is the only authority over the account.">
            <XrplTxLink hash={set.data.retireTxHash} />
          </KeyValue>
        )}
      </dl>

      {bound > 0 && (
        <div className="mb-4 border-t border-line pt-4">
          <p className="label-caps mb-2 text-faint">Enclave signers</p>
          <ul className="space-y-1">
            {(signers.data ?? []).map((word) => {
              const address = bytes32ToClassicAddress(word);
              return (
                <li key={word} className="text-sm">
                  {address ? <XrplAccountLink address={address} /> : <Mono>{word}</Mono>}
                </li>
              );
            })}
          </ul>
          <p className="mt-2 text-xs text-faint">
            Each is a separate machine&apos;s key, generated in its own enclave and never shared. The registry derived
            every AccountID here from the key the enclave returned, so these are verified rather than reported.
          </p>
        </div>
      )}

      {state === SIGNER_SET_INSTALLED && (
        <Alert tone="warn" title="The master key is still live">
          Payments already go to the quorum, but the key that created this account could still sign one alone. Retiring
          it is what makes the quorum the only authority.
        </Alert>
      )}

      {!canAdmin ? (
        <p className="text-sm text-faint">Only a POLICY_ADMIN of this treasury&apos;s policy may change this.</p>
      ) : !senderReady ? (
        <Alert tone="warn" title="Signing is not wired up yet">
          The instruction sender must be deployed, wired into the registry and registered as an FCC extension first.
        </Alert>
      ) : (
        <div className="space-y-4">
          {state === SIGNER_SET_NONE && (
            <div>
              <div className="flex flex-wrap items-end gap-3">
                <label className="text-sm">
                  <span className="label-caps mb-1 block text-faint">Quorum (k)</span>
                  <input
                    className={`${inputClass} w-24`}
                    value={quorum}
                    onChange={(event) => setQuorum(event.target.value)}
                    inputMode="numeric"
                  />
                </label>
                <label className="text-sm">
                  <span className="label-caps mb-1 block text-faint">Signers (n)</span>
                  <input
                    className={`${inputClass} w-24`}
                    value={signerCount}
                    onChange={(event) => setSignerCount(event.target.value)}
                    inputMode="numeric"
                  />
                </label>
                <button
                  type="button"
                  className={buttonClass("primary")}
                  disabled={tx.isBusy || !validShape}
                  onClick={() => {
                    void tx.run({
                      ...contractHandles().treasuryRegistry,
                      functionName: "configureSignerSet",
                      args: [treasury.id, k, n],
                    });
                  }}
                >
                  {tx.isBusy ? "Working…" : "Commit to a quorum"}
                </button>
              </div>
              <p className="mt-2 text-xs text-faint">
                Set once and never changed. Re-quorumming a live treasury means replacing a signer list on XRPL while
                payments are in flight, and a payment dispatched to the old set could no longer be signed by the new
                one. A different arrangement is a different treasury.
              </p>
            </div>
          )}

          {state === SIGNER_SET_COLLECTING && (
            <div>
              <button
                type="button"
                className={buttonClass("primary")}
                disabled={tx.isBusy}
                onClick={() => {
                  if (!senderAddress) return;
                  void tx.run({
                    ...wiredHandles(senderAddress, senderAddress).instructionSender,
                    functionName: "requestSignerKeygen",
                    args: [treasury.id],
                  });
                }}
              >
                {tx.isBusy ? "Working…" : `Ask ${set.data?.signerCount ?? 0} enclaves for their signer keys`}
              </button>
              <p className="mt-2 text-xs text-faint">
                One instruction reaches every machine in the set and each answers with a key of its own. They appear
                above as the registry binds them.
              </p>
            </div>
          )}

          {state === SIGNER_SET_READY && (
            <div className="space-y-3">
              <button
                type="button"
                className={buttonClass("primary")}
                disabled={tx.isBusy || !canSend}
                onClick={() => sendSetup(KIND_SIGNER_LIST)}
              >
                {tx.isBusy ? "Working…" : "Sign the signer list"}
              </button>
              <p className="text-xs text-faint">
                Signed by the treasury&apos;s master key — delegating away from that key is the one thing only that key
                can authorise. The signed transaction is published on-chain; submit it to XRPL, then record its hash
                below.
              </p>
              <div className="flex flex-wrap items-end gap-3">
                <label className="grow text-sm">
                  <span className="label-caps mb-1 block text-faint">XRPL transaction that installed it</span>
                  <input
                    className={inputClass}
                    value={installHash}
                    onChange={(event) => setInstallHash(event.target.value)}
                    placeholder="0x…"
                  />
                </label>
                <button
                  type="button"
                  className={buttonClass()}
                  disabled={tx.isBusy || !isHash(installHash)}
                  onClick={() => {
                    void tx.run({
                      ...contractHandles().treasuryRegistry,
                      functionName: "confirmSignerListInstalled",
                      args: [treasury.id, installHash.trim() as `0x${string}`],
                    });
                  }}
                >
                  Record it
                </button>
              </div>
            </div>
          )}

          {state === SIGNER_SET_INSTALLED && (
            <div className="space-y-3">
              <button
                type="button"
                className={buttonClass("danger")}
                disabled={tx.isBusy || !canSend}
                onClick={() => sendSetup(KIND_DISABLE_MASTER_KEY)}
              >
                {tx.isBusy ? "Working…" : "Sign the master key's retirement"}
              </button>
              <p className="text-xs text-faint">
                The master key&apos;s last act is making itself unusable. After this transaction reaches XRPL, no single
                machine can move this treasury&apos;s funds — and no single machine failing can stop it either.
              </p>
              <div className="flex flex-wrap items-end gap-3">
                <label className="grow text-sm">
                  <span className="label-caps mb-1 block text-faint">XRPL transaction that retired it</span>
                  <input
                    className={inputClass}
                    value={retireHash}
                    onChange={(event) => setRetireHash(event.target.value)}
                    placeholder="0x…"
                  />
                </label>
                <button
                  type="button"
                  className={buttonClass()}
                  disabled={tx.isBusy || !isHash(retireHash)}
                  onClick={() => {
                    void tx.run({
                      ...contractHandles().treasuryRegistry,
                      functionName: "confirmMasterKeyRetired",
                      args: [treasury.id, retireHash.trim() as `0x${string}`],
                    });
                  }}
                >
                  Record it
                </button>
              </div>
            </div>
          )}

          {state === SIGNER_SET_LOCKED && (
            <p className="text-sm text-muted">
              This treasury pays only by quorum. {set.data?.quorum} of {set.data?.signerCount} enclaves must each check
              the policy digest for itself before a single drop moves, and the key that could have ignored them is gone.
            </p>
          )}
        </div>
      )}

      <TxFeedback state={tx.state} doneMessage="Recorded" />
    </Card>
  );
}
