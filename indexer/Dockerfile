# Self-contained build of flare-system-c-chain-indexer, following the same
# pattern proxy/Dockerfile uses for tee-proxy: clone at build time so no local
# sibling checkout is needed.
#
# Why we run our own indexer at all: tee-proxy calls database.Connect
# unconditionally and panics without a C-chain indexer database. Flare operates a
# shared one at 34.38.42.208:3306, but its credentials are issued on request, and
# waiting on that blocks every other phase. This produces the same schema from
# the public Coston2 RPC, so development is not gated on a support ticket.
#
# Pinned by commit rather than tag: the tags in flight (v2.0.0-rc.*) are release
# candidates, and main carries the FSP-mode startup this configuration relies on.
ARG INDEXER_REF=65a3b809eda8930e185d443c82dfcbc35cb14c99

FROM golang:1.25.1-alpine AS builder

# build-base is required: the dependency tree reaches supranational/blst, whose
# Go bindings are cgo-only and fail to compile with CGO_ENABLED=0.
RUN apk add --no-cache git build-base

ARG INDEXER_REF

WORKDIR /src
RUN git clone https://github.com/flare-foundation/flare-system-c-chain-indexer.git . \
    && git checkout ${INDEXER_REF}

RUN go mod download
# Links against musl, which is what the alpine runtime stage provides.
RUN CGO_ENABLED=1 GOOS=linux go build -o /out/indexer ./cmd/indexer

FROM alpine:3.21

RUN apk add --no-cache ca-certificates
WORKDIR /app
COPY --from=builder /out/indexer /app/indexer

ENTRYPOINT ["/app/indexer"]
CMD ["--config", "/app/config/config.toml"]
