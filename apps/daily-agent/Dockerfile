FROM rust:1.94-bookworm AS builder
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY libs/llm-client/Cargo.toml libs/llm-client/Cargo.toml
COPY libs/pulse-core/Cargo.toml libs/pulse-core/Cargo.toml
COPY apps/daily-agent/Cargo.toml apps/daily-agent/Cargo.toml
COPY apps/explorer-agent/Cargo.toml apps/explorer-agent/Cargo.toml
RUN mkdir -p libs/llm-client/src libs/pulse-core/src apps/daily-agent/src apps/explorer-agent/src \
 && echo "pub fn dummy() {}" > libs/llm-client/src/lib.rs \
 && echo "pub fn dummy() {}" > libs/pulse-core/src/lib.rs \
 && echo "fn main() {}" > apps/daily-agent/src/main.rs \
 && echo "fn main() {}" > apps/explorer-agent/src/main.rs \
 && cargo build --release -p se-daily-agent \
 && rm -rf libs/*/src apps/daily-agent/src \
      target/release/.fingerprint/se-daily-agent-* target/release/.fingerprint/llm-client-* target/release/.fingerprint/pulse-core-*
COPY libs libs
COPY apps/daily-agent apps/daily-agent
RUN cargo build --release -p se-daily-agent

FROM debian:bookworm-slim
LABEL org.opencontainers.image.source="https://github.com/tsvet01/eng-pulse"
LABEL org.opencontainers.image.description="Daily engineering article summarizer"
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libssl3 && rm -rf /var/lib/apt/lists/*
RUN useradd --no-create-home --shell /bin/false appuser
COPY --from=builder /app/target/release/se-daily-agent /usr/local/bin/se-daily-agent
USER appuser
# ENTRYPOINT (not CMD) so `gcloud run jobs execute --args=...` appends to the
# binary invocation (e.g. --smoke, --date) instead of replacing the command.
ENTRYPOINT ["se-daily-agent"]
