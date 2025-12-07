# Stage 1: Build the application
FROM rust:latest as builder

WORKDIR /app

# Copy manifests first to cache dependencies
COPY Cargo.toml Cargo.lock ./

# Create a dummy main.rs to build dependencies alone
RUN mkdir src && echo "fn main() {}" > src/main.rs
RUN cargo build --release

# Now copy the real source code
COPY . .

# Touch main.rs to force a rebuild of the application code
RUN touch src/main.rs
RUN cargo build --release

# Stage 2: Create the runtime image
FROM debian:bookworm-slim

WORKDIR /app

# Install necessary runtime dependencies (SSL, CA certs)
RUN apt-get update && apt-get install -y \
    ca-certificates \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy the binary from the builder stage
COPY --from=builder /app/target/release/se-explorer-agent /usr/local/bin/se-explorer-agent

CMD ["se-explorer-agent"]
