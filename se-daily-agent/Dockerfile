# Stage 1: Build the application
FROM rust:1.83-bookworm as builder

WORKDIR /app

# Copy only Cargo files first for dependency caching
COPY gemini-engine/Cargo.toml gemini-engine/Cargo.toml
COPY se-daily-agent/Cargo.toml se-daily-agent/Cargo.toml
COPY se-daily-agent/Cargo.lock se-daily-agent/Cargo.lock

# Create dummy source files to build dependencies
RUN mkdir -p gemini-engine/src && echo "pub fn dummy() {}" > gemini-engine/src/lib.rs
RUN mkdir -p se-daily-agent/src && echo "fn main() {}" > se-daily-agent/src/main.rs

# Build dependencies only (this layer will be cached)
WORKDIR /app/se-daily-agent
RUN cargo build --release || true
RUN rm -rf /app/gemini-engine/src /app/se-daily-agent/src

# Now copy actual source code
WORKDIR /app
COPY gemini-engine/src gemini-engine/src
COPY se-daily-agent/src se-daily-agent/src

# Build the application
WORKDIR /app/se-daily-agent
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
COPY --from=builder /app/se-daily-agent/target/release/se-daily-agent /usr/local/bin/se-daily-agent

# Switch to non-root user
USER appuser

CMD ["se-daily-agent"]
