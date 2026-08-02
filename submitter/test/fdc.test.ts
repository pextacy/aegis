import { encodeAbiParameters, keccak256, toHex } from "viem";
import type { Hex } from "viem";
import { describe, expect, it } from "vitest";
import { nonexistenceResponseParameters, paymentResponseParameters } from "../src/abi.js";
import {
  ATTESTATION_TYPE_NONEXISTENCE,
  ATTESTATION_TYPE_PAYMENT,
  decodeNonexistenceResponse,
  decodePaymentResponse,
  FdcError,
  nonexistenceRequestBody,
  paymentRequestBody,
  prepareRequest,
  prepareRequestUrl,
  proofUrl,
  readPreparedRequest,
  readRawProof,
  SOURCE_ID_TEST_XRP,
  toBytes32Name,
  votingRoundOf,
  waitForProof,
} from "../src/fdc.js";

const TX_HASH = `0x${"ab".repeat(32)}` as Hex;
const ZERO32 = `0x${"00".repeat(32)}` as Hex;

describe("attestation identifiers", () => {
  // These have to match ExecutionVerifier's bytes32("Payment") and
  // bytes32("testXRP") exactly, or the contract rejects a proof that verified.
  it("right-pads the type name into a bytes32", () => {
    expect(toBytes32Name(ATTESTATION_TYPE_PAYMENT)).toBe(
      "0x5061796d656e7400000000000000000000000000000000000000000000000000",
    );
  });

  it("right-pads the source id into a bytes32", () => {
    expect(toBytes32Name(SOURCE_ID_TEST_XRP)).toBe(toHex("testXRP", { size: 32 }));
  });

  it("keeps ReferencedPaymentNonexistence inside 32 bytes", () => {
    expect(ATTESTATION_TYPE_NONEXISTENCE.length).toBeLessThanOrEqual(32);
    expect(toBytes32Name(ATTESTATION_TYPE_NONEXISTENCE)).toHaveLength(66);
  });
});

describe("request bodies", () => {
  it("asks about the transaction the enclave signed", () => {
    expect(paymentRequestBody(TX_HASH)).toEqual({ transactionId: TX_HASH, inUtxo: "0", utxo: "0" });
  });

  it("searches exactly the range the payment could have reached", () => {
    const body = nonexistenceRequestBody({
      firstLedgerSequence: 899_990,
      lastLedgerSequence: 900_000,
      deadlineTimestamp: 1_700_000_000,
      destinationAddressHash: keccak256(toHex("rDestination")),
      amountDrops: 1_000_000n,
      standardPaymentReference: ZERO32,
    });

    expect(body.minimalBlockNumber).toBe("899990");
    expect(body.deadlineBlockNumber).toBe("900000");
    expect(body.amount).toBe("1000000");
    // Constraining source addresses would narrow the search, and
    // ExecutionVerifier rejects a proof that did.
    expect(body.checkSourceAddresses).toBe(false);
    expect(body.sourceAddressesRoot).toBe(ZERO32);
  });
});

describe("endpoint URLs", () => {
  it("addresses the XRP verifier for each type", () => {
    expect(prepareRequestUrl("https://verifier.example/", ATTESTATION_TYPE_PAYMENT)).toBe(
      "https://verifier.example/verifier/xrp/Payment/prepareRequest",
    );
    expect(prepareRequestUrl("https://verifier.example", ATTESTATION_TYPE_NONEXISTENCE)).toBe(
      "https://verifier.example/verifier/xrp/ReferencedPaymentNonexistence/prepareRequest",
    );
  });

  it("addresses the DA layer's raw proof endpoint", () => {
    expect(proofUrl("https://da.example//")).toBe("https://da.example/api/v1/fdc/proof-by-request-round-raw");
  });
});

describe("readPreparedRequest", () => {
  it("accepts a VALID response", () => {
    expect(readPreparedRequest({ status: "VALID", abiEncodedRequest: "0xdeadbeef" })).toBe("0xdeadbeef");
  });

  it("refuses anything the verifier would not answer", () => {
    expect(() => readPreparedRequest({ status: "INVALID" })).toThrow(FdcError);
    expect(() => readPreparedRequest({ status: "VALID" })).toThrow(/no abiEncodedRequest/);
    expect(() => readPreparedRequest(null)).toThrow(FdcError);
  });
});

describe("readRawProof", () => {
  it("accepts a complete proof", () => {
    expect(readRawProof({ response_hex: "0xabcd", proof: ["0x01", "0x02"] })).toEqual({
      responseHex: "0xabcd",
      merkleProof: ["0x01", "0x02"],
    });
  });

  it("accepts a proof with an empty path", () => {
    // A round with one attestation has a root that is the leaf itself.
    expect(readRawProof({ response_hex: "0xabcd", proof: [] }).merkleProof).toEqual([]);
  });

  it("refuses a body that is not a proof yet", () => {
    expect(() => readRawProof({})).toThrow(/no response_hex/);
    expect(() => readRawProof({ response_hex: "0x" })).toThrow(/no response_hex/);
    expect(() => readRawProof({ response_hex: "0xabcd" })).toThrow(/no proof array/);
    expect(() => readRawProof({ response_hex: "0xabcd", proof: [7] })).toThrow(/proof node 0 is not hex/);
  });
});

describe("votingRoundOf", () => {
  it("floors the offset into epochs", () => {
    expect(votingRoundOf(1_658_430_000n + 269n, 1_658_430_000n, 90n)).toBe(2);
    expect(votingRoundOf(1_658_430_000n + 270n, 1_658_430_000n, 90n)).toBe(3);
  });

  it("refuses a block before the first round", () => {
    expect(() => votingRoundOf(1n, 100n, 90n)).toThrow(/predates the first voting round/);
  });

  it("refuses a zero epoch length", () => {
    expect(() => votingRoundOf(100n, 0n, 0n)).toThrow(/voting epoch duration is zero/);
  });
});

describe("response decoding", () => {
  it("round-trips a Payment response", () => {
    const response = {
      attestationType: toBytes32Name(ATTESTATION_TYPE_PAYMENT),
      sourceId: toBytes32Name(SOURCE_ID_TEST_XRP),
      votingRound: 1234n,
      lowestUsedTimestamp: 1_700_000_000n,
      requestBody: { transactionId: TX_HASH, inUtxo: 0n, utxo: 0n },
      responseBody: {
        blockNumber: 899_995n,
        blockTimestamp: 1_700_000_100n,
        sourceAddressHash: keccak256(toHex("rSource")),
        sourceAddressesRoot: ZERO32,
        receivingAddressHash: keccak256(toHex("rDestination")),
        intendedReceivingAddressHash: keccak256(toHex("rDestination")),
        spentAmount: 1_000_012n,
        intendedSpentAmount: 1_000_012n,
        receivedAmount: 1_000_000n,
        intendedReceivedAmount: 1_000_000n,
        standardPaymentReference: keccak256(toHex("reference")),
        oneToOne: true,
        status: 0,
      },
    } as const;

    const encoded = encodeAbiParameters(paymentResponseParameters, [response]);
    expect(decodePaymentResponse(encoded)).toEqual(response);
  });

  it("round-trips a ReferencedPaymentNonexistence response", () => {
    const response = {
      attestationType: toBytes32Name(ATTESTATION_TYPE_NONEXISTENCE),
      sourceId: toBytes32Name(SOURCE_ID_TEST_XRP),
      votingRound: 1234n,
      lowestUsedTimestamp: 1_700_000_000n,
      requestBody: {
        minimalBlockNumber: 899_990n,
        deadlineBlockNumber: 900_000n,
        deadlineTimestamp: 1_700_000_200n,
        destinationAddressHash: keccak256(toHex("rDestination")),
        amount: 1_000_000n,
        standardPaymentReference: keccak256(toHex("reference")),
        checkSourceAddresses: false,
        sourceAddressesRoot: ZERO32,
      },
      responseBody: {
        minimalBlockTimestamp: 1_700_000_000n,
        firstOverflowBlockNumber: 900_001n,
        firstOverflowBlockTimestamp: 1_700_000_204n,
      },
    } as const;

    const encoded = encodeAbiParameters(nonexistenceResponseParameters, [response]);
    expect(decodeNonexistenceResponse(encoded)).toEqual(response);
  });
});

describe("prepareRequest", () => {
  it("sends the type, source and body the verifier expects", async () => {
    const seen: Array<{ url: string; init: RequestInit | undefined }> = [];
    const fetchImpl = async (url: string | URL | Request, init?: RequestInit): Promise<Response> => {
      seen.push({ url: String(url), init });
      return new Response(JSON.stringify({ status: "VALID", abiEncodedRequest: "0xfeed" }), { status: 200 });
    };

    const encoded = await prepareRequest(
      { verifierUrl: "https://verifier.example", verifierApiKey: "key", daLayerUrl: "https://da.example" },
      ATTESTATION_TYPE_PAYMENT,
      paymentRequestBody(TX_HASH),
      fetchImpl,
    );

    expect(encoded).toBe("0xfeed");
    const call = seen[0];
    expect(call?.url).toBe("https://verifier.example/verifier/xrp/Payment/prepareRequest");
    expect((call?.init?.headers as Record<string, string>)["X-API-KEY"]).toBe("key");
    const body = JSON.parse(String(call?.init?.body)) as Record<string, unknown>;
    expect(body["attestationType"]).toBe(toBytes32Name(ATTESTATION_TYPE_PAYMENT));
    expect(body["sourceId"]).toBe(toBytes32Name(SOURCE_ID_TEST_XRP));
  });

  it("fails loudly when the verifier will not answer", async () => {
    const fetchImpl = async (): Promise<Response> => new Response("no such transaction", { status: 500 });
    await expect(
      prepareRequest(
        { verifierUrl: "https://verifier.example", verifierApiKey: "key", daLayerUrl: "https://da.example" },
        ATTESTATION_TYPE_PAYMENT,
        paymentRequestBody(TX_HASH),
        fetchImpl,
      ),
    ).rejects.toThrow(/verifier returned 500/);
  });
});

describe("waitForProof", () => {
  const endpoints = { verifierUrl: "https://v.example", verifierApiKey: "key", daLayerUrl: "https://da.example" };
  const submission = { votingRoundId: 42, requestBytes: "0xfeed" as Hex, transactionHash: TX_HASH };

  it("keeps polling until the round finalises", async () => {
    let calls = 0;
    const fetchImpl = async (): Promise<Response> => {
      calls += 1;
      if (calls < 3) return new Response("not finalized", { status: 404 });
      return new Response(JSON.stringify({ response_hex: "0xabcd", proof: [] }), { status: 200 });
    };

    const proof = await waitForProof(
      endpoints,
      submission,
      { pollIntervalMs: 1, timeoutMs: 10_000 },
      fetchImpl,
      async () => undefined,
      () => 0,
    );

    expect(calls).toBe(3);
    expect(proof.responseHex).toBe("0xabcd");
  });

  it("gives up rather than looping forever", async () => {
    const fetchImpl = async (): Promise<Response> => new Response("not finalized", { status: 404 });
    let clock = 0;

    await expect(
      waitForProof(endpoints, submission, { pollIntervalMs: 1, timeoutMs: 5 }, fetchImpl, async () => undefined, () => {
        clock += 10;
        return clock;
      }),
    ).rejects.toThrow(/no proof for voting round 42/);
  });

  it("surfaces an unexpected DA layer error instead of waiting it out", async () => {
    const fetchImpl = async (): Promise<Response> => new Response("boom", { status: 502 });
    await expect(
      waitForProof(endpoints, submission, { pollIntervalMs: 1, timeoutMs: 1000 }, fetchImpl, async () => undefined, () => 0),
    ).rejects.toThrow(/DA layer returned 502/);
  });
});
