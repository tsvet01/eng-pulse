# Stage 1: Build the application
FROM rust:1.83-bookworm as builder

WORKDIR /app

# Copy only Cargo files first for dependency caching
COPY libs/gemini-engine/Cargo.toml libs/gemini-engine/Cargo.toml
COPY apps/explorer-agent/Cargo.toml apps/explorer-agent/Cargo.toml
COPY apps/explorer-agent/Cargo.lock apps/explorer-agent/Cargo.lock

# Create dummy source files to build dependencies
RUN mkdir -p libs/gemini-engine/src && echo "pub fn dummy() {}" > libs/gemini-engine/src/lib.rs
RUN mkdir -p apps/explorer-agent/src && echo "fn main() {}" > apps/explorer-agent/src/main.rs

# Build dependencies only (this layer will be cached)
WORKDIR /app/apps/explorer-agent
RUN cargo build --release || true

# Remove dummy source and compiled binary to force rebuild
RUN rm -rf /app/libs/gemini-engine/src /app/apps/explorer-agent/src \
    /app/apps/explorer-agent/target/release/se-explorer-agent \
    /app/apps/explorer-agent/target/release/deps/se_explorer_agent*

# Now copy actual source code
WORKDIR /app
COPY libs/gemini-engine/src libs/gemini-engine/src
COPY apps/explorer-agent/src apps/explorer-agent/src

# Build the application
WORKDIR /app/apps/explorer-agent
RUN cargo build --release

# Stage 2: Create the runtime image
FROM debian:bookworm-slim

LABEL org.opencontainers.image.source="https://github.com/tsvet01/eng-pulse"
LABEL org.opencontainers.image.description="RSS/blog source discovery agent"

WORKDIR /app

# Install necessary runtime dependencies (SSL, CA certs)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libssl3 \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user for security
RUN useradd --no-create-home --shell /bin/false appuser

# Copy the binary from the builder stage
COPY --from=builder /app/apps/explorer-agent/target/release/se-explorer-agent /usr/local/bin/se-explorer-agent

# Switch to non-root user
USER appuser

CMD ["se-explorer-agent"]
