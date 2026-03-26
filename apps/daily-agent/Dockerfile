# Stage 1: Build the application
FROM rust:1.94-bookworm as builder

WORKDIR /app

# Copy only Cargo files first for dependency caching
COPY libs/llm-client/Cargo.toml libs/llm-client/Cargo.toml
COPY apps/daily-agent/Cargo.toml apps/daily-agent/Cargo.toml
COPY apps/daily-agent/Cargo.lock apps/daily-agent/Cargo.lock

# Create dummy source files to build dependencies
RUN mkdir -p libs/llm-client/src && echo "pub fn dummy() {}" > libs/llm-client/src/lib.rs
RUN mkdir -p apps/daily-agent/src && echo "fn main() {}" > apps/daily-agent/src/main.rs

# Build dependencies only (this layer will be cached)
WORKDIR /app/apps/daily-agent
RUN cargo build --release || true

# Remove dummy source and compiled artifacts to force rebuild
# Keep deps/ intact for caching, but remove the main binary and its fingerprints
RUN rm -rf /app/libs/llm-client/src /app/apps/daily-agent/src \
    /app/apps/daily-agent/target/release/se-daily-agent \
    /app/apps/daily-agent/target/release/.fingerprint/se-daily-agent-* \
    /app/apps/daily-agent/target/release/.fingerprint/llm-client-* \
    /app/apps/daily-agent/target/release/deps/libse_daily_agent* \
    /app/apps/daily-agent/target/release/deps/libllm_client* \
    /app/apps/daily-agent/target/release/deps/se_daily_agent* \
    /app/apps/daily-agent/target/release/deps/llm_client*

# Now copy actual source code
WORKDIR /app
COPY libs/llm-client/src libs/llm-client/src
COPY apps/daily-agent/src apps/daily-agent/src

# Build the application
WORKDIR /app/apps/daily-agent
RUN cargo build --release

# Stage 2: Create the runtime image
FROM debian:bookworm-slim

LABEL org.opencontainers.image.source="https://github.com/tsvet01/eng-pulse"
LABEL org.opencontainers.image.description="Daily engineering article summarizer"

WORKDIR /app

# Install necessary runtime dependencies (SSL, CA certs)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libssl3 \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user for security
RUN useradd --no-create-home --shell /bin/false appuser

# Copy the binary from the builder stage
COPY --from=builder /app/apps/daily-agent/target/release/se-daily-agent /usr/local/bin/se-daily-agent

# Switch to non-root user
USER appuser

CMD ["se-daily-agent"]
