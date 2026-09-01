FROM rust:1.94-bookworm AS builder
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY libs/llm-client/Cargo.toml libs/llm-client/Cargo.toml
COPY apps/daily-agent/Cargo.toml apps/daily-agent/Cargo.toml
COPY apps/explorer-agent/Cargo.toml apps/explorer-agent/Cargo.toml
RUN mkdir -p libs/llm-client/src apps/daily-agent/src apps/explorer-agent/src \
 && echo "pub fn dummy() {}" > libs/llm-client/src/lib.rs \
 && echo "fn main() {}" > apps/daily-agent/src/main.rs \
 && echo "fn main() {}" > apps/explorer-agent/src/main.rs \
 && cargo build --release -p se-explorer-agent \
 && rm -rf libs/*/src apps/explorer-agent/src \
      target/release/.fingerprint/se-explorer-agent-* target/release/.fingerprint/llm-client-*
COPY libs libs
COPY apps/explorer-agent apps/explorer-agent
RUN cargo build --release -p se-explorer-agent

FROM debian:bookworm-slim
LABEL org.opencontainers.image.source="https://github.com/tsvet01/eng-pulse"
LABEL org.opencontainers.image.description="RSS/blog source discovery agent"
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libssl3 && rm -rf /var/lib/apt/lists/*
RUN useradd --no-create-home --shell /bin/false appuser
COPY --from=builder /app/target/release/se-explorer-agent /usr/local/bin/se-explorer-agent
USER appuser
CMD ["se-explorer-agent"]
