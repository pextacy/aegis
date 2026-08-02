/**
 * Entry point.
 *
 * The submitter holds no authority over any treasury. Its key pays gas for an
 * attestation request and for handing a proof to `ExecutionVerifier`, and a
 * proof that does not verify is rejected by the contract. Anyone can run one;
 * running two is expected and harmless.
 */

import { createClients } from "./clients.js";
import { loadConfig } from "./config.js";
import { describeError, log } from "./log.js";
import { Settler } from "./settle.js";
import { Watcher } from "./watcher.js";

async function main(): Promise<void> {
  const config = loadConfig();
  const clients = createClients(config);
  const watcher = new Watcher(config, clients, new Settler(config, clients));

  const shutdown = (signal: string): void => {
    log.info("shutting down", { signal });
    watcher.stop();
    process.exit(0);
  };
  process.on("SIGINT", () => shutdown("SIGINT"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));

  log.info("aegis submitter starting", {
    chainId: config.chainId,
    paymentController: config.paymentController,
    executionVerifier: config.executionVerifier,
    xrpl: config.xrplWsUrl,
  });

  await watcher.start();
}

main().catch((error: unknown) => {
  log.error("submitter stopped", { reason: describeError(error) });
  process.exit(1);
});
