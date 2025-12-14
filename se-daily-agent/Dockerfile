# Stage 1: Build the application
FROM rust:1.83-bookworm as builder

WORKDIR /app

# Copy the shared engine
COPY gemini-engine/ gemini-engine/

# Copy the agent
COPY se-daily-agent/ se-daily-agent/

WORKDIR /app/se-daily-agent

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

# Create non-root user for security
RUN useradd --create-home --shell /bin/bash appuser

# Copy the binary from the builder stage
COPY --from=builder /app/se-daily-agent/target/release/se-daily-agent /usr/local/bin/se-daily-agent

# Switch to non-root user
USER appuser

CMD ["se-daily-agent"]