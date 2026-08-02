# Phase 0 — Environment Record and Status

The record `phases.md` P0-8 asks for, plus the live state of each Phase 0 task. Everything here is verified against the real environment, not assumed.

Last updated: 2026-08-02

---

## What is blocking

One thing.

| # | Blocker | Who | Effort |
|---|---|---|---|
| 1 | Fund `0xbC479252c67526f9BAa0e70E7c27Cc53222b49b5` from the faucet | you | one minute |

**The indexer credentials are no longer needed.** `tee-proxy` requires a C-chain indexer database, and Flare issues credentials for a shared one on request — unknown turnaround, gating everything. `flare-system-c-chain-indexer` is open source and writes exactly the schema `go-flare-common/pkg/database` reads, so `./scripts/indexer.sh up` now runs our own against the public Coston2 RPC. The proxy starts against it and reports `Database in sync`. Request the shared credentials anyway if you want them, but nothing waits on them.

**The tunnel is no longer a blocker either.** `./scripts/tunnel.sh` brings up a cloudflared tunnel with no account and writes `EXT_PROXY_URL` itself.

Run `./scripts/phase0-check.sh` for live state.

**The tunnel is no longer a blocker.** It was, when the plan assumed ngrok. cloudflared reaches the same result with no account, so `./scripts/tunnel.sh` now brings up a public HTTPS tunnel to port 6674 and writes the URL into `.env.coston2` and `.env` itself. The cost is that a quick tunnel gets a new URL on every restart, which means re-running `post-build.sh` to re-register the machine under it. Reserving an ngrok domain removes that annoyance and `./scripts/tunnel.sh --ngrok <domain>` uses it — worth doing eventually, not worth blocking on.

### Why neither remaining blocker has a workaround

**The proxy cannot run without the indexer.** `tee-proxy` v0.0.18 calls `database.Connect(&cfg.DB)` unconditionally in `internal/proxy/proxy.go` and panics if it fails — there is no code path that boots without a live C-chain indexer connection. The `direct` endpoint in its config looked like a possible substitute; it is not. It registers an extra `/direct` HTTP route on the external server and changes nothing about where instructions are read from. Credentials are genuinely required.

**The faucet requires a human.** `https://faucet.flare.network/coston2` serves a Google reCAPTCHA (site key `6LfSHCYsAAAAAMCSBtiMuNjEqc0P5FxmRFbNW3Lv`) and grants 100 C2FLR per address per 24 hours. There is no documented API, and working around the captcha would mean defeating a third party's abuse control, which is not something to do for convenience. The one alternative that still gets cited, `coston2-faucet.towolabs.com`, no longer resolves — NXDOMAIN — so do not spend time on it. One click in a browser is the whole task.

### 1. Indexer credentials — request text

Send via `https://flare.network/resources/technical-support` or `@FlareDevs`.

> Subject: Coston2 indexer database credentials for a Flare Compute Extension
>
> I am building Aegis, a rule-governed XRPL treasury for the current Flare program, entering both the Interoperable Asset Products and Confidential Compute Apps tracks.
>
> Spending policy lives in Solidity contracts on Coston2 (amount tiers, per-tier approval thresholds and timelocks, a rolling spend window, and a destination allowlist priced through the FTSO XRP/USD feed). The XRPL signing key is generated inside and never leaves a Flare Confidential Compute TEE, which independently recomputes the on-chain policy digest and refuses to sign on a mismatch. Settlement is confirmed on-chain by FDC `Payment` and `ReferencedPaymentNonexistence` attestations against XRPL Testnet.
>
> The extension is built on `flare-foundation/fce-extension-scaffold` and runs against Coston2 with `SIMULATED_TEE=true`. `ext-proxy` needs read access to the Coston2 C-chain indexer to observe TEE instruction events, and cannot start without it — it is the only thing blocking the build.
>
> Could you issue read credentials for the Coston2 indexer database (`34.38.42.208:3306`, database `indexer`)? The host is reachable and answers on the MySQL protocol from here, so credentials are the only thing outstanding. If access is IP-restricted, my current egress address is `85.106.117.61`.
>
> Deployer address: `0xbC479252c67526f9BAa0e70E7c27Cc53222b49b5`
> Chain: Coston2 (114)

That egress address is what the server saw during the connection test below. It is a home or office IP and will change if the connection or network does — re-check with `curl -s ifconfig.me` before quoting it, and mention it only if they say access is IP-restricted.

When the credentials arrive, put them in **both** files — `username` and `password` under `[db]`:

- `config/proxy/extension_proxy.coston2.docker.toml`
- `config/proxy/extension_proxy.coston2.toml`

Both are gitignored. The host, port and database name are already filled in and verified.

### 2. Fund the deployer

```
https://faucet.flare.network/coston2
```

Address: `0xbC479252c67526f9BAa0e70E7c27Cc53222b49b5`

The pre-flight check requires at least `0.01 C2FLR` and currently reports `balance: 0 wei`. Ask for more than the minimum — the same key pays for the deploy, the extension registration, TEE machine registration, and every per-instruction fee after that. Verify with:

```bash
cast balance 0xbC479252c67526f9BAa0e70E7c27Cc53222b49b5 --rpc-url https://coston2-api.flare.network/ext/C/rpc
```

### 3. Tunnel — done, nothing needed from you

```bash
./scripts/tunnel.sh          # leave running in its own terminal
```

Starts a cloudflared quick tunnel to port 6674 and writes `EXT_PROXY_URL` into `.env.coston2` and `.env`. No account. One is live now at `https://scheme-warren-clicks-nikon.trycloudflare.com`, verified reachable — it answers 502, which is the tunnel working and nothing listening on 6674 yet.

Each run produces a different URL. If it changes after the extension was registered, re-run `./scripts/post-build.sh` so the machine re-registers under the new one.

To stop that happening, reserve the free static ngrok domain at `https://dashboard.ngrok.com/domains`, then:

```bash
ngrok config add-authtoken <token>
./scripts/tunnel.sh --ngrok <your-domain>.ngrok-free.app
```

ngrok is installed (3.39.10) and the script handles it. This is a convenience upgrade, not a precondition.

---

## Verified environment

### Toolchain

| Tool | Version | Required | State |
|---|---|---|---|
| Docker | 29.2.1, daemon running | Desktop, Linux containers | ok |
| Foundry | forge/cast 1.5.1-stable | any | ok |
| Go | 1.26.4 darwin/arm64 | 1.25.1+ | ok |
| Node | 25.2.1, npm 11.6.2 | 20+ | ok |
| ngrok | 3.39.10 | any | installed, unauthenticated |
| jq | 1.7.1 | any | ok |
| git | 2.52.0 | any | ok |
| bash | 5.3.15 at `/opt/homebrew/bin/bash` | **4.4+** | installed — see below |

**Run the scaffold's scripts with `/opt/homebrew/bin/bash`, not the system one.** macOS ships bash 3.2.57, and the scaffold expands possibly-empty arrays under `set -u`, which only became legal in bash 4.4. On 3.2, `test-conformance.sh` dies with `body_args[@]: unbound variable` and reports three false failures on the three fixtures that send no request body. The extension is fine; the script is not portable. Installing bash 5 fixes it without touching a scaffold file, which is what P0-7 requires. `phase0-check.sh` now fails if it runs under an older shell.

### Scaffold pin

| | |
|---|---|
| Upstream | `https://github.com/flare-foundation/fce-extension-scaffold` |
| Commit | `f48cafb889441a62e47c083f4be8dd7d3f456f83` |
| Date | 2026-07-28 |
| Subject | Merge branch 'feat/multi-language-scaffold' into 'main' |

Vendored verbatim into the repository root. The scaffold's own documentation was moved to `docs/scaffold/` so the Aegis specs keep `docs/` — no source, script, or config file was modified, which is what P0-7 requires.

### Dependency pins

Reported consistent by `./scripts/check-versions.sh`:

| Component | Version |
|---|---|
| tee-node | `v0.0.21-0.20260619120252-31fc839ae6d2` |
| go-flare-common | `v1.2.2-0.20260623111601-c573c79c0924` |
| tee-proxy | `v0.0.18` |
| `TEE_NODE_REF` | `31fc839ae6d2` |

### Chain

| | |
|---|---|
| Chain | Coston2, id `114` |
| RPC | `https://coston2-api.flare.network/ext/C/rpc` (200 OK) |
| Explorer | `https://coston2-explorer.flare.network` |
| `FlareTeeManager` | `0x1a9C4A0f9D76c0b1D91d22E24E573a9b377618aE` |
| Normal proxy | `https://tee-proxy-coston2-1.flare.rocks` |
| Indexer | `34.38.42.208:3306`, database `indexer` |

### Deployment identity

| | |
|---|---|
| `INITIAL_OWNER` | `0xbC479252c67526f9BAa0e70E7c27Cc53222b49b5` |
| Balance | `0 wei` — needs funding |
| Key location | `.env.coston2`, gitignored |

Generated with `cast wallet new` for this project. It has no history and holds nothing else. The same key is `PROXY_PRIVATE_KEY`; the scaffold permits one key for both and it means a single faucet run.

### Ports

| Service | Container | Host |
|---|---|---|
| ext-proxy internal | 6663 | 6673 |
| ext-proxy external | 6664 | **6674 — this is the tunnelled one** |
| redis | 6379 | 6382 |
| extension | 7702 | — |
| config | 5501 | — |
| sign | 7701 | — |

Only 6674 is tunnelled. Exposing it makes the proxy HTTP API reachable by anyone holding the URL, so the tunnel runs against Coston2 only and gets stopped when you finish.

### To be filled after P0-7

| | |
|---|---|
| `EXTENSION_ID` | pending — written to `config/extension.env` by `pre-build.sh` |
| `INSTRUCTION_SENDER` | pending — same file |
| Code hash | pending — expect a value starting `0x194844cf` for a simulated TEE |
| Tunnel URL | `https://scheme-warren-clicks-nikon.trycloudflare.com` — live, but a quick tunnel, so re-read it from `.env.coston2` after any `tunnel.sh` restart |

---

## Task status

| Task | State | Note |
|---|---|---|
| P0-1 Indexer credentials | **blocked** | request text drafted above, needs sending |
| P0-2 Fund the wallet | **blocked** | key generated, faucet run is yours |
| P0-3 Clone and pin the scaffold | **done** | `f48cafb`, vendored, committed |
| P0-4 Public HTTPS tunnel | **done** | cloudflared live via `scripts/tunnel.sh`; ngrok domain optional |
| P0-5 Fill `.env` | **done** | `.env.coston2` written, activated |
| P0-6 Fill the indexer `[db]` block | **partial** | host/port/database filled and verified, credentials pending P0-1 |
| P0-7 Run the scaffold end-to-end | **blocked** | needs 1 and 2; everything not needing them passes |
| P0-8 Record the environment | **done** | this file |

---

## What was verified along the way

Facts established by running things, not by reading documentation:

- **Coston2 RPC responds** — `eth_chainId` returns 200.
- **The indexer host is reachable without a VPN.** `34.38.42.208:3306` is open from a plain connection; `35.241.249.150:3306` is filtered. `docs/scaffold/deployment-steps.md` lists the second one as a prerequisite behind a VPN — that host is Coston's, not Coston2's. `PLAN.md` is right and the scaffold's prerequisite line does not apply to this chain.
- **Version pins are consistent** — `check-versions.sh` passes.
- **Contract bindings generate** — `tools/pkg/contracts/helloworld/autogen.go` produced from the Solidity ABI.
- **Contracts compile** — `forge build` clean.
- **The Go extension builds, vets, and tests clean under Go 1.26.4**, above the scaffold's 1.25.1 floor.
- **The deploy path resolves end to end.** Pre-flight reaches Coston2, derives the deployer, resolves `FlareTeeManager`, and stops on exactly one thing: `insufficient funds (balance: 0 wei, minimum required: 10000000000000000 wei)`. Nothing between here and the deploy is unverified.
- **All three images build.** `aegis-extension-tee` (22.4 MB, from `go/Dockerfile` with `SOURCE_DATE_EPOCH` from git), `local/tee-proxy` (126 MB, self-cloning at `v0.0.18`), and `redis:7-alpine` are on disk. `start-services.sh` will not have to build anything on the first real run.
- **The proxy's only remaining blocker is the credentials themselves.** Starting `redis` + `ext-proxy` against Coston2 produced:

  ```
  PANIC  connecting to database: opening mysql connection to
  34.38.42.208:3306/indexer as <issued-by-flare-support>:
  Error 1045 (28000): Access denied for user ... (using password: YES)
  ```

  That is the best possible failure. The proxy parsed its config, resolved the host, opened a TCP connection, completed a MySQL handshake, and was rejected at authentication. Config format, chain id, contract addresses, volume mount, and network path are all confirmed working. Substituting real credentials is the entire remaining change. Containers were torn down afterwards.
- **The extension satisfies the container contract.** `test-unit.sh` passes, and `test-conformance.sh` passes 16 of 16 fixtures — success paths, counter accumulation, malformed payloads, unknown op type, unknown op command, invalid hex, method-not-allowed on both endpoints, unknown path, and final `GET /state`. This runs with no chain, no Docker and no proxy, so the whole request/response surface Aegis will replace in Phase 3 is verified correct before any of the blockers clear.
- **The scaffold's scripts need bash 4.4+.** Found by running them: three conformance fixtures failed under macOS bash 3.2 for a shell-portability reason, not an extension one. Documented above.

---

## When unblocked

In order, from the project root:

```bash
# terminal 1 — tunnel, before anything else. Writes EXT_PROXY_URL itself.
./scripts/tunnel.sh

# terminal 2
./scripts/phase0-check.sh                      # must be green first
./scripts/pre-build.sh                         # deploy sender, register extension
./scripts/start-services.sh --chain coston2    # redis + ext-proxy + extension-tee
./scripts/post-build.sh                        # allow code version, governance, register TEE
./scripts/test.sh                              # SAY_HELLO and SAY_GOODBYE

curl -s "$EXT_PROXY_URL/info" | jq '.machineData'
```

Phase 0 closes when `test.sh` passes and `machineData` shows a code hash starting `0x194844cf`, the extension id from `config/extension.env`, and `0xbC479252c67526f9BAa0e70E7c27Cc53222b49b5` as `initialOwner`.

Do not run `pre-build.sh --force`. It deploys a new sender and registers a new extension id while the TEE machine stays bound to the old one, and `test.sh` then fails with `MachineManager.TooMany()`. Every other known failure mode is catalogued in `DOCS.md` §7.
