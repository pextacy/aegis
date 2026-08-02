import { describe, expect, it } from "vitest";

import {
  ATTESTATION_TYPE_NONEXISTENCE,
  ATTESTATION_TYPE_PAYMENT,
  FdcError,
  nonexistenceRequestBody,
  paymentRequestBody,
  prepareRequest,
  SOURCE_ID_TEST_XRP,
  toBytes32Name,
} from "../src/fdc.js";

/**
 * Runs `prepareRequest` against Flare's real FDC verifier server.
 *
 * This is the one call in the settlement path that needs a credential, and
 * every other test of it has supplied a stub `fetch`, which proves the function
 * handles a response we wrote and nothing about whether Flare accepts the
 * request we send. A wrong field name or a mis-encoded `sourceId` would be
 * refused by the server and never by a stub.
 *
 * The key below is the public one Flare publishes for its testnet verifiers. It
 * is a documented open credential rather than a secret — nothing in `src/`
 * defaults to it, `FDC_VERIFIER_API_KEY` is still required and still has no
 * fallback, and a mainnet deployment needs a real key. It is written here so
 * this test can run without one being issued first.
 *
 * The transaction id is a real XRPL Testnet payment this system produced and
 * settled, so the request describes something the verifier can actually find.
 *
 * Skipped unless COSTON2_RPC_URL is set, alongside the other live checks.
 */

const LIVE = Boolean(process.env.COSTON2_RPC_URL);

const ENDPOINTS = {
  verifierUrl: process.env.FDC_VERIFIER_URL ?? "https://fdc-verifiers-testnet.flare.network",
  verifierApiKey: process.env.FDC_VERIFIER_API_KEY ?? "00000000-0000-0000-0000-000000000000",
  daLayerUrl: process.env.FDC_DA_LAYER_URL ?? "https://ctn2-data-availability.flare.network",
} as const;

/** A payment Aegis signed in a TEE and settled on XRPL Testnet. */
const SETTLED_TX = "0xE82AA92EE82F483F80D23EE486C985E36B597E2FB907FC39216A9E297271D059" as const;

describe.skipIf(!LIVE)("the FDC verifier, for real", () => {
  it("accepts a Payment request and returns an encoded request", async () => {
    const encoded = await prepareRequest(ENDPOINTS, ATTESTATION_TYPE_PAYMENT, paymentRequestBody(SETTLED_TX));

    expect(encoded.startsWith("0x")).toBe(true);
    // The encoded request opens with the attestation type and source id, so a
    // mis-encoded name would show up here rather than as a proof that never
    // arrives.
    expect(encoded.slice(2, 66)).toBe(toBytes32Name(ATTESTATION_TYPE_PAYMENT).slice(2));
    expect(encoded.slice(66, 130)).toBe(toBytes32Name(SOURCE_ID_TEST_XRP).slice(2));
  });

  it("accepts a ReferencedPaymentNonexistence request too", async () => {
    const encoded = await prepareRequest(
      ENDPOINTS,
      ATTESTATION_TYPE_NONEXISTENCE,
      nonexistenceRequestBody({
        firstLedgerSequence: 19_574_700,
        lastLedgerSequence: 19_574_820,
        deadlineTimestamp: 0,
        destinationAddressHash: "0x0000000000000000000000000000000000000000000000000000000000000001",
        amountDrops: 1_000_000n,
        standardPaymentReference: "0x0000000000000000000000000000000000000000000000000000000000000002",
      }),
    );

    expect(encoded.slice(2, 66)).toBe(toBytes32Name(ATTESTATION_TYPE_NONEXISTENCE).slice(2));
  });

  /**
   * The failure path matters as much: a submitter pointed at the verifier with
   * no key must say so, not carry on and stall later with an empty proof.
   */
  it("raises FdcError rather than returning junk when the key is wrong", async () => {
    await expect(
      prepareRequest(
        { ...ENDPOINTS, verifierApiKey: "not-a-key" },
        ATTESTATION_TYPE_PAYMENT,
        paymentRequestBody(SETTLED_TX),
      ),
    ).rejects.toBeInstanceOf(FdcError);
  });
});
