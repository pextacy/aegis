import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  executionVerifierAbi,
  isTerminal,
  nonexistenceResponseParameters,
  paymentControllerAbi,
  paymentResponseParameters,
  RequestState,
} from "../src/abi.js";

/**
 * The submitter's ABI declarations are checked against the compiled contracts,
 * not against a second copy written by hand here. A field reordered in Solidity
 * has to fail this test — decoding a DA layer response into the wrong shape
 * produces a proof that fails Merkle verification on-chain, which is a much
 * harder failure to read than this one.
 */

interface AbiParameterJson {
  name?: string | undefined;
  type: string;
  components?: AbiParameterJson[] | undefined;
}

interface AbiEntryJson {
  type: string;
  name?: string;
  inputs?: AbiParameterJson[];
  outputs?: AbiParameterJson[];
}

function artifact(contract: string): AbiEntryJson[] {
  const path = fileURLToPath(new URL(`../../out/${contract}.sol/${contract}.json`, import.meta.url));
  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch {
    throw new Error(`${path} is missing — run "forge build" before the submitter tests`);
  }
  const parsed = JSON.parse(raw) as { abi: AbiEntryJson[] };
  return parsed.abi;
}

function entry(contract: string, kind: string, name: string): AbiEntryJson {
  const found = artifact(contract).find((item) => item.type === kind && item.name === name);
  if (found === undefined) throw new Error(`${contract} has no ${kind} named ${name}`);
  return found;
}

/** Flattens a parameter tree to `name:type` paths so the comparison is readable when it fails. */
function shape(parameters: readonly AbiParameterJson[], prefix = ""): string[] {
  return parameters.flatMap((parameter) => {
    const path = `${prefix}${parameter.name ?? ""}:${parameter.type}`;
    return parameter.components === undefined ? [path] : [path, ...shape(parameter.components, `${path}.`)];
  });
}

describe("the request struct the submitter reads", () => {
  it("matches PaymentController.getRequest", () => {
    const compiled = entry("PaymentController", "function", "getRequest").outputs ?? [];
    const declared = paymentControllerAbi.find(
      (item) => item.type === "function" && item.name === "getRequest",
    )?.outputs;

    expect(shape(declared as unknown as AbiParameterJson[])).toEqual(shape(compiled));
  });

  it("matches the PaymentSigned event", () => {
    const compiled = entry("PaymentController", "event", "PaymentSigned").inputs ?? [];
    const declared = paymentControllerAbi.find((item) => item.type === "event" && item.name === "PaymentSigned")
      ?.inputs;

    expect(shape(declared as unknown as AbiParameterJson[])).toEqual(shape(compiled));
  });
});

describe("the attestation response tuples", () => {
  it("match the Payment proof ExecutionVerifier takes", () => {
    const proof = (entry("ExecutionVerifier", "function", "confirmSettlement").inputs ?? [])[1];
    const compiled = proof?.components?.[1];
    expect(compiled).toBeDefined();

    const declared = paymentResponseParameters[0];
    expect(shape(declared.components as unknown as AbiParameterJson[])).toEqual(
      shape(compiled?.components ?? []),
    );
  });

  it("match the non-existence proof ExecutionVerifier takes", () => {
    const proof = (entry("ExecutionVerifier", "function", "confirmNonExecution").inputs ?? [])[1];
    const compiled = proof?.components?.[1];
    expect(compiled).toBeDefined();

    const declared = nonexistenceResponseParameters[0];
    expect(shape(declared.components as unknown as AbiParameterJson[])).toEqual(
      shape(compiled?.components ?? []),
    );
  });

  it("declare every ExecutionVerifier function the submitter calls", () => {
    for (const name of ["confirmSettlement", "confirmFailedExecution", "confirmNonExecution", "requestReference", "addressHashOf"]) {
      expect(executionVerifierAbi.some((item) => item.name === name)).toBe(true);
      expect(entry("ExecutionVerifier", "function", name).name).toBe(name);
    }
  });
});

describe("request states", () => {
  it("agrees with the Solidity enum order", () => {
    // PaymentController.RequestState: Proposed, Approved, Dispatched, Signed,
    // Settled, Failed, Cancelled.
    expect([
      RequestState.Proposed,
      RequestState.Approved,
      RequestState.Dispatched,
      RequestState.Signed,
      RequestState.Settled,
      RequestState.Failed,
      RequestState.Cancelled,
    ]).toEqual([0, 1, 2, 3, 4, 5, 6]);
  });

  it("treats settled, failed and cancelled as final", () => {
    expect(isTerminal(RequestState.Settled)).toBe(true);
    expect(isTerminal(RequestState.Failed)).toBe(true);
    expect(isTerminal(RequestState.Cancelled)).toBe(true);
  });

  it("does not treat a signed request as final", () => {
    expect(isTerminal(RequestState.Signed)).toBe(false);
    expect(isTerminal(RequestState.Dispatched)).toBe(false);
  });
});
