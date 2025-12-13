# Stage 1: Build the application
FROM rust:1.83-bookworm as builder

WORKDIR /app

# Copy the shared engine
COPY gemini-engine/ gemini-engine/

# Copy the agent
COPY se-explorer-agent/ se-explorer-agent/

WORKDIR /app/se-explorer-agent

# Build the application
RUN cargo build --release

# Stage 2: Create the runtime image
FROM debian:bookworm-slim

WORKDIR /app

# Install necessary runtime dependencies (SSL, CA certs)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libssl3 \
    && rm -rf /var/lib/apt/lists/*

# Copy the binary from the builder stage
COPY --from=builder /app/se-explorer-agent/target/release/se-explorer-agent /usr/local/bin/se-explorer-agent

CMD ["se-explorer-agent"]