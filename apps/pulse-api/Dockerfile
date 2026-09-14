FROM rust:1.94-bookworm AS builder
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY libs/llm-client/Cargo.toml libs/llm-client/Cargo.toml
COPY libs/pulse-core/Cargo.toml libs/pulse-core/Cargo.toml
COPY apps/daily-agent/Cargo.toml apps/daily-agent/Cargo.toml
COPY apps/explorer-agent/Cargo.toml apps/explorer-agent/Cargo.toml
COPY apps/pulse-api/Cargo.toml apps/pulse-api/Cargo.toml
RUN mkdir -p libs/llm-client/src libs/pulse-core/src apps/daily-agent/src apps/explorer-agent/src apps/pulse-api/src \
 && echo "pub fn dummy() {}" > libs/llm-client/src/lib.rs \
 && echo "pub fn dummy() {}" > libs/pulse-core/src/lib.rs \
 && echo "fn main() {}" > apps/daily-agent/src/main.rs \
 && echo "fn main() {}" > apps/explorer-agent/src/main.rs \
 && echo "fn main() {}" > apps/pulse-api/src/main.rs \
 && cargo build --release -p pulse-api \
 && rm -rf libs/*/src apps/pulse-api/src \
      target/release/.fingerprint/pulse-api-* target/release/.fingerprint/llm-client-* target/release/.fingerprint/pulse-core-*
COPY libs libs
COPY apps/pulse-api apps/pulse-api
RUN cargo build --release -p pulse-api

FROM debian:bookworm-slim
LABEL org.opencontainers.image.source="https://github.com/tsvet01/eng-pulse"
LABEL org.opencontainers.image.description="Eng Pulse API service"
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
RUN useradd --no-create-home --shell /bin/false appuser
COPY --from=builder /app/target/release/pulse-api /usr/local/bin/pulse-api
USER appuser
EXPOSE 8080
ENTRYPOINT ["pulse-api"]
