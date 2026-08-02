/**
 * The payment lifecycle, mirroring PaymentController.RequestState.
 *
 * Each state carries the sentence a reader needs to know what the system is
 * waiting for. "Dispatched" and "Signed" look similar on a status chip and mean
 * very different things: one is an instruction the TEE has not answered, the
 * other is a signature that exists and can be submitted by anyone.
 */

export const REQUEST_STATES = [
  {
    key: "Proposed",
    label: "Proposed",
    tone: "pending",
    description: "Passed every policy check at proposal. Waiting for approvals.",
  },
  {
    key: "Approved",
    label: "Approved",
    tone: "ready",
    description: "Approval threshold met. Waiting for the timelock, then dispatch.",
  },
  {
    key: "Dispatched",
    label: "Dispatched",
    tone: "active",
    description: "The signing instruction is with the TEE. No signature yet.",
  },
  {
    key: "Signed",
    label: "Signed",
    tone: "active",
    description: "The enclave returned a signed transaction. Anyone can submit it to XRPL.",
  },
  {
    key: "Settled",
    label: "Settled",
    tone: "good",
    description: "An FDC proof confirmed the payment on XRPL.",
  },
  {
    key: "Failed",
    label: "Failed",
    tone: "bad",
    description: "Proven not to have executed. The window spend was released and the sequence advanced.",
  },
  {
    key: "Cancelled",
    label: "Cancelled",
    tone: "muted",
    description: "Withdrawn by its proposer before dispatch.",
  },
] as const;

export type RequestStateTone = (typeof REQUEST_STATES)[number]["tone"];
export type RequestStateInfo = (typeof REQUEST_STATES)[number];

/** The state record for a `RequestState` enum value. */
export function requestState(value: number): RequestStateInfo {
  const state = REQUEST_STATES[value];
  if (!state) throw new Error(`Unknown request state ${value}`);
  return state;
}

/** States that can still be approved. */
export function isOpenForApproval(value: number): boolean {
  return requestState(value).key === "Proposed";
}

/** States where the payment has not yet reached a terminal outcome. */
export function isLive(value: number): boolean {
  const key = requestState(value).key;
  return key !== "Settled" && key !== "Failed" && key !== "Cancelled";
}
