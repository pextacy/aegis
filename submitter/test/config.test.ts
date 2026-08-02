import { describe, expect, it } from "vitest";
import { ConfigError, loadConfig, parseDeployedAddresses, systemAddress } from "../src/config.js";

const ADDRESSES = JSON.stringify([
  { name: "FdcHub", contractName: "FdcHub.sol", address: "0x48aC463d7975828989331F4De43341627b9c5f1D" },
  {
    name: "FdcRequestFeeConfigurations",
    contractName: "FdcRequestFeeConfigurations.sol",
    address: "0x191a1282Ac700edE65c5B0AaF313BAcC3eA7fC7e",
  },
  {
    name: "FlareSystemsManager",
    contractName: "FlareSystemsManager.sol",
    address: "0xA90Db6D10F856799b10ef2A77EBCbF460aC71e52",
  },
]);

const COMPLETE_ENV: Record<string, string> = {
  ADDRESSES_FILE: "./config/coston2/deployed-addresses.json",
  CHAIN_ID: "114",
  CHAIN_URL: "https://coston2-api.flare.network/ext/C/rpc",
  CHAIN_WS_URL: "wss://coston2-api.flare.network/ext/C/ws",
  SUBMITTER_PRIVATE_KEY: `0x${"11".repeat(32)}`,
  PAYMENT_CONTROLLER: "0xaEd2aCa19C6F54926F8482648A694E7cb62baA22",
  EXECUTION_VERIFIER: "0x1F98431c8aD98523631AE4a59f267346ea31F984",
  XRPL_WS_URL: "wss://s.altnet.rippletest.net:51233",
  FDC_VERIFIER_URL: "https://fdc-verifiers-testnet.flare.network",
  FDC_VERIFIER_API_KEY: "an-api-key",
  FDC_DA_LAYER_URL: "https://ctn2-data-availability.flare.network",
  SUBMITTER_CURSOR_FILE: "/var/lib/aegis/cursor.json",
  SUBMITTER_START_BLOCK: "20000000",
};

const readAddresses = (): string => ADDRESSES;

describe("loadConfig", () => {
  it("builds a complete configuration", () => {
    const config = loadConfig(COMPLETE_ENV, readAddresses);

    expect(config.chainId).toBe(114);
    expect(config.startBlock).toBe(20_000_000n);
    expect(config.fdcHub).toBe("0x48aC463d7975828989331F4De43341627b9c5f1D");
    expect(config.logChunkBlocks).toBe(30n);
  });

  it("checksums the addresses it was given in lower case", () => {
    const config = loadConfig(
      { ...COMPLETE_ENV, PAYMENT_CONTROLLER: "0xaed2aca19c6f54926f8482648a694e7cb62baa22" },
      readAddresses,
    );
    expect(config.paymentController).toBe("0xaEd2aCa19C6F54926F8482648A694E7cb62baA22");
  });

  // Every one of these is a way to end up pointed at the wrong chain or the
  // wrong contract, which is why none of them has a default.
  for (const name of Object.keys(COMPLETE_ENV)) {
    it(`refuses to start without ${name}`, () => {
      const env = { ...COMPLETE_ENV };
      delete env[name];
      expect(() => loadConfig(env, readAddresses)).toThrow(ConfigError);
    });
  }

  it("rejects an RPC URL that is not HTTP", () => {
    expect(() => loadConfig({ ...COMPLETE_ENV, CHAIN_URL: "wss://example.invalid" }, readAddresses)).toThrow(
      /CHAIN_URL must use one of/,
    );
  });

  it("rejects a websocket URL that is not a websocket", () => {
    expect(() => loadConfig({ ...COMPLETE_ENV, CHAIN_WS_URL: "https://example.invalid" }, readAddresses)).toThrow(
      /CHAIN_WS_URL must use one of/,
    );
  });

  it("rejects a private key of the wrong length", () => {
    expect(() => loadConfig({ ...COMPLETE_ENV, SUBMITTER_PRIVATE_KEY: "0xdeadbeef" }, readAddresses)).toThrow(
      /32-byte hex private key/,
    );
  });

  it("accepts a private key without the 0x prefix", () => {
    const config = loadConfig({ ...COMPLETE_ENV, SUBMITTER_PRIVATE_KEY: "11".repeat(32) }, readAddresses);
    expect(config.privateKey).toBe(`0x${"11".repeat(32)}`);
  });

  it("rejects a malformed contract address", () => {
    expect(() => loadConfig({ ...COMPLETE_ENV, EXECUTION_VERIFIER: "0x1234" }, readAddresses)).toThrow(
      /EXECUTION_VERIFIER is not an address/,
    );
  });

  it("rejects a start block that is not a number", () => {
    expect(() => loadConfig({ ...COMPLETE_ENV, SUBMITTER_START_BLOCK: "latest" }, readAddresses)).toThrow(
      /SUBMITTER_START_BLOCK/,
    );
  });

  it("stops when a system contract is missing from the addresses file", () => {
    const withoutHub = JSON.stringify(
      (JSON.parse(ADDRESSES) as Array<{ name: string }>).filter((entry) => entry.name !== "FdcHub"),
    );
    expect(() => loadConfig(COMPLETE_ENV, () => withoutHub)).toThrow(/FdcHub is not in the deployed-addresses file/);
  });
});

describe("parseDeployedAddresses", () => {
  it("reads the file the rest of the repository already uses", () => {
    const entries = parseDeployedAddresses(ADDRESSES);
    expect(systemAddress(entries, "FlareSystemsManager")).toBe("0xA90Db6D10F856799b10ef2A77EBCbF460aC71e52");
  });

  it("rejects a file that is not an array", () => {
    expect(() => parseDeployedAddresses("{}")).toThrow(ConfigError);
  });

  it("rejects an entry missing an address", () => {
    expect(() => parseDeployedAddresses('[{"name":"FdcHub","contractName":"FdcHub.sol"}]')).toThrow(ConfigError);
  });

  it("rejects an entry whose address is malformed", () => {
    const entries = parseDeployedAddresses('[{"name":"FdcHub","contractName":"FdcHub.sol","address":"0xnope"}]');
    expect(() => systemAddress(entries, "FdcHub")).toThrow(/malformed address/);
  });
});
