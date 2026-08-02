# The Aegis submitter as a long-running service.
#
# Unlike the extension image, this one is not the unit of attestation. Its hash
# is never registered on-chain and no signing policy depends on it, so the
# reproducibility machinery in REPRODUCIBILITY.md does not apply here. The base
# is still pinned by digest, for the ordinary reason that an unpinned tag is a
# silent upgrade.
#
# The submitter holds no authority. Its key pays gas for an attestation request
# and for handing a proof to ExecutionVerifier, and a proof that does not verify
# is rejected by the contract. That is why running two of these is expected
# rather than dangerous: whichever arrives second finds a terminal state and
# returns without reverting.
#
# Build from the repository root so the build context can see nothing it should
# not:
#   docker build -f submitter/Dockerfile -t aegis-submitter submitter/

FROM node:22-alpine@sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32 AS build

WORKDIR /build

# node:22 bundles npm 10, and package-lock.json is lockfile v3 written by npm
# 11. The two disagree about how an optional peer is recorded, and npm 10 reads
# that as "out of sync" and refuses to install at all. REPRODUCIBILITY.md
# already names the npm version as the reason the TypeScript path is only
# same-machine reproducible; this pins it so the image and a developer's laptop
# resolve the same tree instead of one of them failing outright.
ARG NPM_VERSION=11.6.2
RUN npm install -g "npm@${NPM_VERSION}"

# npm ci reproduces the tree from package-lock.json and fails if the lockfile
# and package.json disagree, which is the property that makes this worth doing
# as its own layer rather than folding it into the copy below.
COPY package.json package-lock.json ./
RUN npm ci

COPY tsconfig.json ./
COPY src ./src
RUN npm run build

# Re-resolve with production dependencies only. `npm ci --omit=dev` on a clean
# tree is cheaper and more honest than pruning the built one.
RUN rm -rf node_modules && npm ci --omit=dev

# --- runtime ---------------------------------------------------------------

FROM node:22-alpine@sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32

ENV NODE_ENV=production

WORKDIR /app

COPY --from=build /build/node_modules ./node_modules
COPY --from=build /build/dist ./dist
COPY --from=build /build/package.json ./package.json

# The cursor is the submitter's only persistent state: the block it has replayed
# PaymentSigned up to. Losing it costs a re-scan from SUBMITTER_START_BLOCK, not
# correctness — every entry point is idempotent against an already-terminal
# request. Mount a volume here and point SUBMITTER_CURSOR_FILE inside it, or
# accept the re-scan on every restart.
RUN mkdir -p /var/lib/aegis-submitter && chown node:node /var/lib/aegis-submitter
VOLUME ["/var/lib/aegis-submitter"]

# The image deliberately sets no defaults for the configuration. Every variable
# in submitter/src/config.ts is required and a missing one stops the process at
# startup, which is the correct behaviour for a service whose failure mode
# otherwise is "pointed at the wrong chain". See the submitter block in
# .env.example for the full list; ADDRESSES_FILE and SUBMITTER_CURSOR_FILE must
# resolve to paths that exist inside the container.

USER node

CMD ["node", "dist/index.js"]
