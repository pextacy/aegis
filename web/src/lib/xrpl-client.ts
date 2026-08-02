/**
 * Read-only XRPL access.
 *
 * The dashboard never submits an XRPL transaction — the submitter does that, and
 * anyone can run one. What the dashboard needs from XRPL is the two facts a
 * dispatch depends on: what the treasury account actually holds, and which
 * ledger the network is on right now, which is the lower bound of the range a
 * non-existence proof must cover.
 */

type JsonRpcResponse<T> = { result: T & { status?: string; error?: string; error_message?: string } };

/** An XRPL request that failed, carrying the ledger's own error code. */
export class XrplRequestError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

async function call<T>(rpcUrl: string, method: string, params: Record<string, unknown>): Promise<T> {
  const response = await fetch(rpcUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ method, params: [params] }),
  });

  if (!response.ok) {
    throw new XrplRequestError("http", `XRPL ${method} returned HTTP ${response.status}.`);
  }

  const body = (await response.json()) as JsonRpcResponse<T>;
  if (body.result?.error) {
    throw new XrplRequestError(body.result.error, body.result.error_message ?? body.result.error);
  }
  return body.result;
}

export type XrplAccount = {
  /** The account's balance in drops. */
  balanceDrops: bigint;
  /** The next sequence XRPL expects from this account. */
  sequence: number;
  /** The reserve XRPL holds back, in drops, for the account and its objects. */
  ownerCount: number;
};

type AccountInfoResult = {
  account_data: { Balance: string; Sequence: number; OwnerCount: number };
};

/**
 * Reads a funded XRPL account.
 *
 * Returns `null` when the ledger has never seen the address. A treasury whose
 * key exists but which nobody has funded is a real and expected state — on XRPL
 * an account does not exist until it holds the base reserve.
 */
export async function fetchAccount(rpcUrl: string, address: string): Promise<XrplAccount | null> {
  try {
    const result = await call<AccountInfoResult>(rpcUrl, "account_info", {
      account: address,
      ledger_index: "validated",
    });
    return {
      balanceDrops: BigInt(result.account_data.Balance),
      sequence: result.account_data.Sequence,
      ownerCount: result.account_data.OwnerCount,
    };
  } catch (error) {
    if (error instanceof XrplRequestError && error.code === "actNotFound") return null;
    throw error;
  }
}

type LedgerCurrentResult = { ledger_current_index: number };

/** The ledger index the network is currently building. */
export async function fetchCurrentLedger(rpcUrl: string): Promise<number> {
  const result = await call<LedgerCurrentResult>(rpcUrl, "ledger_current", {});
  return result.ledger_current_index;
}

type FeeResult = {
  drops: { base_fee: string; open_ledger_fee: string; minimum_fee: string };
};

export type XrplFees = {
  /** The reference fee for a simple transaction, in drops. */
  baseFeeDrops: bigint;
  /** What it currently costs to make it into the open ledger, in drops. */
  openLedgerFeeDrops: bigint;
  /** The floor the network will accept, in drops. */
  minimumFeeDrops: bigint;
};

/** Current XRPL fee levels. */
export async function fetchFees(rpcUrl: string): Promise<XrplFees> {
  const result = await call<FeeResult>(rpcUrl, "fee", {});
  return {
    baseFeeDrops: BigInt(result.drops.base_fee),
    openLedgerFeeDrops: BigInt(result.drops.open_ledger_fee),
    minimumFeeDrops: BigInt(result.drops.minimum_fee),
  };
}
